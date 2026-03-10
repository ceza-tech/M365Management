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
    [string]$MonitorDisplayName  = 'M365Management-GitOps'
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
Write-Info "Workloads: $($WorkloadTypes -join ', ')"
if ($DryRun) { Write-Info "DRY-RUN mode — no changes will be made." }

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
        Write-DryRun "  - $($_.resourceType): $($_.id ?? $_.displayName ?? '(unnamed)')"
    }
    exit 0
}

Write-Step "Checking for existing monitor '$MonitorDisplayName'..."
$monitors = Invoke-GraphRequest -Endpoint '/tenantRelationships/configurationMonitors' -Token $token
$existingMonitor = $monitors.value | Where-Object { $_.displayName -eq $MonitorDisplayName } | Select-Object -First 1

$monitorBody = @{
    displayName = $MonitorDisplayName
    baseline    = @{
        resources = $baselineResources
    }
}

if ($existingMonitor) {
    Write-Info "Updating existing monitor (ID: $($existingMonitor.id))..."
    Invoke-GraphRequest -Method PATCH `
        -Endpoint "/tenantRelationships/configurationMonitors/$($existingMonitor.id)" `
        -Body $monitorBody `
        -Token $token | Out-Null
    Write-Success "Monitor updated."
    $monitorId = $existingMonitor.id
} else {
    Write-Info "Creating new monitor..."
    $newMonitor = Invoke-GraphRequest -Method POST `
        -Endpoint '/tenantRelationships/configurationMonitors' `
        -Body $monitorBody `
        -Token $token
    Write-Success "Monitor created (ID: $($newMonitor.id))."
    $monitorId = $newMonitor.id
}

Write-Step "Triggering immediate monitoring evaluation..."
Invoke-GraphRequest -Method POST `
    -Endpoint "/tenantRelationships/configurationMonitors/$monitorId/run" `
    -Token $token | Out-Null

Write-Success "Evaluation triggered. Monitor will run every 6 hours automatically."
Write-Host "`n🎉 Config applied! Run Get-Drifts.ps1 to check for any configuration drift." -ForegroundColor Green
