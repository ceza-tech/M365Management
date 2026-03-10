<#
.SYNOPSIS
    Applies declarative config from the config/ directory to your M365 tenant
    using the UTCM Configuration Monitor APIs.

.DESCRIPTION
    Reads YAML config files from config/<workload>/*.yaml,
    creates or updates a UTCM configurationMonitor with the specified baseline,
    then triggers an immediate evaluation.

.PARAMETER WorkloadTypes
    Which workloads to apply config for. Defaults to all with config files.

.PARAMETER DryRun
    If set, shows what would be applied without making API calls.

.PARAMETER MonitorDisplayName
    Name for the UTCM monitor. Default: "M365Management-GitOps"

.EXAMPLE
    ./Apply-Config.ps1
    ./Apply-Config.ps1 -DryRun
    ./Apply-Config.ps1 -WorkloadTypes entra
#>
param(
    [string[]]$WorkloadTypes     = @(),
    [switch]$DryRun,
    # DisplayName rules: 8-32 chars, alphanumeric + spaces only (no hyphens, underscores, or special chars)
    [string]$MonitorDisplayName  = 'M365 Management GitOps'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers' 'Auth.ps1')

#region Helpers
function Write-Step([string]$Msg) { Write-Host "`n▶ $Msg" -ForegroundColor Cyan }
function Write-Success([string]$Msg) { Write-Host "  ✅ $Msg" -ForegroundColor Green }
function Write-Info([string]$Msg) { Write-Host "  ℹ  $Msg" -ForegroundColor White }
function Write-DryRun([string]$Msg) { Write-Host "  [DRY-RUN] $Msg" -ForegroundColor Magenta }

function ConvertFrom-YamlFile([string]$Path) {
    # Requires powershell-yaml module; fallback to JSON if .json extension
    if ($Path -match '\.json$') {
        return Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable
    }
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Write-Warning "powershell-yaml not installed. Install with: Install-Module powershell-yaml"
        Write-Warning "Attempting to parse as JSON instead..."
        return Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable
    }
    Import-Module powershell-yaml -ErrorAction Stop
    return Get-Content $Path -Raw | ConvertFrom-Yaml
}
#endregion

$configRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'config'

# Discover workloads from config/ if not explicitly specified
if ($WorkloadTypes.Count -eq 0) {
    $WorkloadTypes = Get-ChildItem -Path $configRoot -Directory | Select-Object -ExpandProperty Name
}

if ($WorkloadTypes.Count -eq 0) {
    Write-Host "No config files found in $configRoot. Add YAML files to config/<workload>/ first." -ForegroundColor Yellow
    exit 0
}

Write-Step "Config-as-Code Apply"
Write-Info "Workloads      : $($WorkloadTypes -join ', ')"
Write-Info "Monitor name   : $MonitorDisplayName"
if ($DryRun) { Write-Info "DRY-RUN mode — no changes will be made." }

# Validate monitor display name early — the API enforces: 8-32 chars, alphanumeric + spaces only
if ($MonitorDisplayName.Length -lt 8 -or $MonitorDisplayName.Length -gt 32) {
    throw "MonitorDisplayName must be 8-32 characters. Got $($MonitorDisplayName.Length): '$MonitorDisplayName'"
}
if ($MonitorDisplayName -match '[^a-zA-Z0-9 ]') {
    throw "MonitorDisplayName may only contain letters, numbers, and spaces. Got: '$MonitorDisplayName'"
}

Write-Step "Authenticating to Microsoft Graph..."
$token = Get-GraphAccessToken
Write-Success "Authenticated."

# Build the baseline resources list from all config files
$baselineResources = [System.Collections.Generic.List[object]]::new()

foreach ($workload in $WorkloadTypes) {
    $workloadConfigDir = Join-Path $configRoot $workload
    if (-not (Test-Path $workloadConfigDir)) {
        Write-Info "No config directory found for '$workload'. Skipping."
        continue
    }

    $configFiles = Get-ChildItem -Path $workloadConfigDir -Include '*.yaml','*.yml','*.json' -Recurse
    if ($configFiles.Count -eq 0) {
        Write-Info "No config files found in $workloadConfigDir. Skipping."
        continue
    }

    foreach ($file in $configFiles) {
        Write-Info "Loading: $($file.Name)"
        $config = ConvertFrom-YamlFile -Path $file.FullName

        # Each config file may define one or more resources
        $resources = if ($config.resources) { $config.resources } else { @($config) }

        foreach ($resource in $resources) {
            $baselineResources.Add($resource)
        }
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
        $r = $_
        $rType = if ($r -is [hashtable]) { $r['resourceType'] } else { $r.resourceType }
        $rId   = if ($r -is [hashtable]) { $r['id'] ?? $r['properties']?['DisplayName'] ?? '(unnamed)' } else { $r.id ?? $r.displayName ?? '(unnamed)' }
        Write-DryRun "  - ${rType}: ${rId}"
    }
    exit 0
}

Write-Step "Checking for existing monitor '$MonitorDisplayName'..."
$monitors = Invoke-GraphRequest -Endpoint '/admin/configurationManagement/configurationMonitors' -Token $token
$existingMonitor = $monitors.value | Where-Object { $_.displayName -eq $MonitorDisplayName } | Select-Object -First 1

# Normalize resources: the BaselineResource API type only accepts 'resourceType' and 'properties'.
# If a YAML entry has a top-level 'id', move it into properties.Id (e.g. CA policy GUIDs, 'Global').
$normalizedResources = $baselineResources | ForEach-Object {
    $r = $_
    if ($r -is [hashtable]) {
        $rType  = $r['resourceType']
        $rProps = if ($r['properties']) { [hashtable]($r['properties'].Clone()) } else { @{} }
        if ($r['id'] -and -not $rProps['Id']) { $rProps['Id'] = $r['id'] }
        $rDisplayName = $rProps['DisplayName'] ?? $rProps['Identity'] ?? $rProps['Id'] ?? $rType
        # Teams resources reject DisplayName as an unknown property; Entra resources require it
        if ($rType -like 'microsoft.teams.*') { $rProps.Remove('DisplayName') }
        @{ displayName = $rDisplayName; resourceType = $rType; properties = $rProps }
    } else {
        $rProps = if ($r.properties) { $r.properties | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable } else { @{} }
        if ($r.id -and -not $rProps['Id']) { $rProps['Id'] = $r.id }
        $rDisplayName = $rProps['DisplayName'] ?? $rProps['Identity'] ?? $rProps['Id'] ?? $r.resourceType
        if ($r.resourceType -like 'microsoft.teams.*') { $rProps.Remove('DisplayName') }
        @{ displayName = $rDisplayName; resourceType = $r.resourceType; properties = $rProps }
    }
}

$monitorBody = @{
    displayName = $MonitorDisplayName
    baseline    = @{
        displayName = $MonitorDisplayName   # Baseline also requires a displayName
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
    $monitorId = $existingMonitor.id
} else {
    Write-Info "Creating new monitor..."
    $newMonitor = Invoke-GraphRequest -Method POST `
        -Endpoint '/admin/configurationManagement/configurationMonitors' `
        -Body $monitorBody `
        -Token $token
    Write-Success "Monitor created (ID: $($newMonitor.id))."
    $monitorId = $newMonitor.id
}

Write-Host "`n🎉 Config applied! Monitor '$MonitorDisplayName' is active and will evaluate every 6 hours." -ForegroundColor Green
Write-Host "   Run Get-Drifts.ps1 to check for any configuration drift." -ForegroundColor White
