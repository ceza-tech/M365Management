<#
.SYNOPSIS
    Applies declarative config from a tenant's config/ directory to an M365 tenant
    using the UTCM Configuration Monitor APIs.

.DESCRIPTION
    Reads YAML config files from <TenantConfigRoot>/<workload>/*.yaml,
    creates or updates a UTCM configurationMonitor with the specified baseline.

.PARAMETER TenantConfigRoot
    Path to the tenant's config directory. Defaults to tenants/<TenantName>/config
    relative to the repo root, or 'config/' for backwards compatibility.

.PARAMETER TenantName
    Logical name for this tenant (used to derive TenantConfigRoot and the monitor name
    if MonitorDisplayName is not set). Default: auto-detected from TenantConfigRoot.

.PARAMETER WorkloadTypes
    Which workloads to apply config for. Default: all subdirectories in TenantConfigRoot.

.PARAMETER DryRun
    If set, shows what would be applied without making API calls.

.PARAMETER MonitorDisplayName
    Name for the UTCM monitor (8-32 chars, alphanumeric + spaces only).
    Defaults to "<TenantName> GitOps" (truncated to 32 chars if needed).

.EXAMPLE
    ./Apply-Config.ps1 -TenantName kustomize
    ./Apply-Config.ps1 -TenantName kustomize -DryRun
    ./Apply-Config.ps1 -TenantConfigRoot ./tenants/kustomize/config
#>
param(
    [string]$TenantName       = '',
    [string]$TenantConfigRoot = '',
    [string[]]$WorkloadTypes  = @(),
    [switch]$DryRun,
    # 8-32 chars, alphanumeric + spaces only (no hyphens, underscores, or special chars)
    [string]$MonitorDisplayName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers' 'Auth.ps1')

#region Helpers
function Write-Step([string]$Msg)    { Write-Host "`n▶ $Msg" -ForegroundColor Cyan }
function Write-Success([string]$Msg) { Write-Host "  ✅ $Msg" -ForegroundColor Green }
function Write-Info([string]$Msg)    { Write-Host "  ℹ  $Msg" -ForegroundColor White }
function Write-DryRun([string]$Msg)  { Write-Host "  [DRY-RUN] $Msg" -ForegroundColor Magenta }

function ConvertFrom-YamlFile([string]$Path) {
    if ($Path -match '\.json$') {
        return Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable
    }
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Write-Warning "powershell-yaml not installed. Install with: Install-Module powershell-yaml"
        return Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable
    }
    Import-Module powershell-yaml -ErrorAction Stop
    return Get-Content $Path -Raw | ConvertFrom-Yaml
}
#endregion

$repoRoot = Split-Path $PSScriptRoot -Parent

# --- Resolve TenantConfigRoot ---
if (-not $TenantConfigRoot) {
    if ($TenantName) {
        $TenantConfigRoot = Join-Path $repoRoot 'tenants' $TenantName 'config'
    } else {
        # Auto-detect: prefer tenants/ structure, fall back to legacy config/
        $tenantsDir = Join-Path $repoRoot 'tenants'
        if (Test-Path $tenantsDir) {
            $firstTenant = Get-ChildItem $tenantsDir -Directory | Select-Object -First 1
            if ($firstTenant) {
                $TenantName       = $firstTenant.Name
                $TenantConfigRoot = Join-Path $firstTenant.FullName 'config'
                Write-Warning "No TenantName specified. Defaulting to '$TenantName'."
            }
        }
        if (-not $TenantConfigRoot) {
            $TenantConfigRoot = Join-Path $repoRoot 'config'
        }
    }
}

# Derive TenantName from path if still empty
if (-not $TenantName) {
    $TenantName = (Split-Path (Split-Path $TenantConfigRoot -Parent) -Leaf)
}

# --- Resolve MonitorDisplayName ---
if (-not $MonitorDisplayName) {
    # Capitalise first letter, replace special chars, pad/truncate to 8-32 chars
    $safeName = ($TenantName -replace '[^a-zA-Z0-9 ]', ' ').Trim()
    $safeName = $safeName.Substring(0,1).ToUpper() + $safeName.Substring(1)
    $proposed = "$safeName GitOps"
    $MonitorDisplayName = if ($proposed.Length -gt 32) { $proposed.Substring(0, 32).TrimEnd() } else { $proposed }
}

# --- Validate MonitorDisplayName ---
if ($MonitorDisplayName.Length -lt 8 -or $MonitorDisplayName.Length -gt 32) {
    throw "MonitorDisplayName must be 8-32 characters. Got $($MonitorDisplayName.Length): '$MonitorDisplayName'"
}
if ($MonitorDisplayName -match '[^a-zA-Z0-9 ]') {
    throw "MonitorDisplayName may only contain letters, numbers, and spaces. Got: '$MonitorDisplayName'"
}

# --- Discover workloads ---
if ($WorkloadTypes.Count -eq 0) {
    if (Test-Path $TenantConfigRoot) {
        $WorkloadTypes = Get-ChildItem -Path $TenantConfigRoot -Directory | Select-Object -ExpandProperty Name
    }
}

if ($WorkloadTypes.Count -eq 0) {
    Write-Host "No config files found in $TenantConfigRoot. Add YAML files first." -ForegroundColor Yellow
    exit 0
}

Write-Step "Config-as-Code Apply"
Write-Info "Tenant         : $TenantName"
Write-Info "Config root    : $TenantConfigRoot"
Write-Info "Workloads      : $($WorkloadTypes -join ', ')"
Write-Info "Monitor name   : $MonitorDisplayName"
if ($DryRun) { Write-Info "DRY-RUN mode — no changes will be made." }

Write-Step "Authenticating to Microsoft Graph..."
$token = Get-GraphAccessToken
Write-Success "Authenticated."

# --- Load resources from config files ---
$baselineResources = [System.Collections.Generic.List[object]]::new()

foreach ($workload in $WorkloadTypes) {
    $workloadConfigDir = Join-Path $TenantConfigRoot $workload
    if (-not (Test-Path $workloadConfigDir)) {
        Write-Info "No config directory for '$workload'. Skipping."
        continue
    }

    $configFiles = Get-ChildItem -Path $workloadConfigDir -Include '*.yaml','*.yml','*.json' -Recurse
    if ($configFiles.Count -eq 0) {
        Write-Info "No config files in $workloadConfigDir. Skipping."
        continue
    }

    foreach ($file in $configFiles) {
        Write-Info "Loading: $($file.Name)"
        $config    = ConvertFrom-YamlFile -Path $file.FullName
        $resources = if ($config.resources) { $config.resources } else { @($config) }
        foreach ($resource in $resources) { $baselineResources.Add($resource) }
    }
}

if ($baselineResources.Count -eq 0) {
    Write-Host "No resources found in config files. Nothing to apply." -ForegroundColor Yellow
    exit 0
}

Write-Step "Loaded $($baselineResources.Count) resource(s) from config files."

if ($DryRun) {
    Write-DryRun "Would create/update monitor '$MonitorDisplayName' with $($baselineResources.Count) resource(s):"
    $baselineResources | ForEach-Object {
        $r     = $_
        $rType = if ($r -is [hashtable]) { $r['resourceType'] } else { $r.resourceType }
        $rId   = if ($r -is [hashtable]) { $r['id'] ?? $r['properties']?['DisplayName'] ?? '(unnamed)' } else { $r.id ?? $r.displayName ?? '(unnamed)' }
        Write-DryRun "  - ${rType}: ${rId}"
    }
    exit 0
}

# --- Normalize resources for the UTCM API ---
# BaselineResource only allows: displayName, resourceType, properties
# - Teams resources: DisplayName must NOT be in properties
# - Entra resources: DisplayName MUST be in properties (it's a key)
Write-Step "Checking for existing monitor '$MonitorDisplayName'..."
$monitors      = Invoke-GraphRequest -Endpoint '/admin/configurationManagement/configurationMonitors' -Token $token
$existingMonitor = $monitors.value | Where-Object { $_.displayName -eq $MonitorDisplayName } | Select-Object -First 1

$normalizedResources = $baselineResources | ForEach-Object {
    $r = $_
    if ($r -is [hashtable]) {
        $rType    = $r['resourceType']
        $rProps   = if ($r['properties']) { [hashtable]($r['properties'].Clone()) } else { @{} }
        if ($r['id'] -and -not $rProps['Id']) { $rProps['Id'] = $r['id'] }
        $rDisplayName = $rProps['DisplayName'] ?? $rProps['Identity'] ?? $rProps['Id'] ?? $rType
        if ($rType -like 'microsoft.teams.*') { $rProps.Remove('DisplayName') }
        @{ displayName = $rDisplayName; resourceType = $rType; properties = $rProps }
    } else {
        $rProps   = if ($r.properties) { $r.properties | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable } else { @{} }
        if ($r.id -and -not $rProps['Id']) { $rProps['Id'] = $r.id }
        $rDisplayName = $rProps['DisplayName'] ?? $rProps['Identity'] ?? $rProps['Id'] ?? $r.resourceType
        if ($r.resourceType -like 'microsoft.teams.*') { $rProps.Remove('DisplayName') }
        @{ displayName = $rDisplayName; resourceType = $r.resourceType; properties = $rProps }
    }
}

$monitorBody = @{
    displayName = $MonitorDisplayName
    baseline    = @{
        displayName = $MonitorDisplayName
        resources   = @($normalizedResources)
    }
}

if ($existingMonitor) {
    Write-Info "Updating existing monitor (ID: $($existingMonitor.id))..."
    Invoke-GraphRequest -Method PATCH `
        -Endpoint "/admin/configurationManagement/configurationMonitors/$($existingMonitor.id)" `
        -Body $monitorBody `
        -Token $token | Out-Null
    Write-Success "Monitor updated."
} else {
    Write-Info "Creating new monitor..."
    $newMonitor = Invoke-GraphRequest -Method POST `
        -Endpoint '/admin/configurationManagement/configurationMonitors' `
        -Body $monitorBody `
        -Token $token
    Write-Success "Monitor created (ID: $($newMonitor.id))."
}

Write-Host "`n🎉 Config applied! Monitor '$MonitorDisplayName' is active and will evaluate every 6 hours." -ForegroundColor Green
Write-Host "   Run Get-Drifts.ps1 -TenantName $TenantName to check for drift." -ForegroundColor White
