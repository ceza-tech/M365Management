<#
.SYNOPSIS
    Fetches and reports all active configuration drifts from UTCM monitors.

.DESCRIPTION
    Lists all configurationMonitors, then fetches active drifts from the
    top-level /configurationDrifts endpoint (filtered by monitorId).
    Outputs a human-readable report and optionally fails the pipeline
    if drifts are found (for use in CI/CD).

.PARAMETER MonitorDisplayName
    Filter reports to a specific monitor. Default: all monitors.

.PARAMETER FailOnDrift
    If set, exits with code 1 when drifts are detected. Useful in CI pipelines.

.PARAMETER OutputFormat
    Output format: 'table' (default) or 'json'

.EXAMPLE
    ./Get-Drifts.ps1
    ./Get-Drifts.ps1 -FailOnDrift
    ./Get-Drifts.ps1 -OutputFormat json
#>
param(
    [string]$MonitorDisplayName = '',
    [switch]$FailOnDrift,
    [ValidateSet('table', 'json')]
    [string]$OutputFormat = 'table'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers' 'Auth.ps1')

function Write-Step([string]$Msg)    { Write-Host "`n▶ $Msg" -ForegroundColor Cyan }
function Write-Success([string]$Msg) { Write-Host "  ✅ $Msg" -ForegroundColor Green }
function Write-Info([string]$Msg)    { Write-Host "  ℹ  $Msg" -ForegroundColor White }

Write-Step "Authenticating..."
$token = Get-GraphAccessToken
Write-Success "Authenticated."

Write-Step "Fetching configuration monitors..."
$monitors = Invoke-GraphRequest -Endpoint '/admin/configurationManagement/configurationMonitors' -Token $token

if ($MonitorDisplayName) {
    $monitors.value = $monitors.value | Where-Object { $_.displayName -eq $MonitorDisplayName }
}

if (-not $monitors.value -or $monitors.value.Count -eq 0) {
    Write-Host "No monitors found. Run Apply-Config.ps1 first." -ForegroundColor Yellow
    exit 0
}

Write-Info "Found $($monitors.value.Count) monitor(s)."

# Fetch all drifts from the top-level configurationDrifts endpoint
# (sub-resource /configurationMonitors/{id}/drifts does not exist)
Write-Step "Fetching active configuration drifts..."
$allDriftsResponse = Invoke-GraphRequest `
    -Endpoint '/admin/configurationManagement/configurationDrifts' `
    -Token $token

$allDrifts = [System.Collections.Generic.List[object]]::new()

foreach ($monitor in $monitors.value) {
    $monitorDrifts = $allDriftsResponse.value | Where-Object { $_.monitorId -eq $monitor.id }

    foreach ($drift in $monitorDrifts) {
        # driftedProperties is an array of { propertyName, expectedValue, currentValue }
        if ($drift.driftedProperties) {
            foreach ($prop in $drift.driftedProperties) {
                $allDrifts.Add([PSCustomObject]@{
                    Monitor       = $monitor.displayName
                    ResourceType  = $drift.resourceType
                    ResourceId    = $drift.resourceInstanceIdentifier
                    Property      = $prop.propertyName
                    ExpectedValue = $prop.expectedValue
                    ActualValue   = $prop.currentValue
                    DetectedAt    = $drift.firstReportedDateTime
                    Status        = $drift.status
                })
            }
        } else {
            # Drift exists but no specific property detail
            $allDrifts.Add([PSCustomObject]@{
                Monitor       = $monitor.displayName
                ResourceType  = $drift.resourceType
                ResourceId    = $drift.resourceInstanceIdentifier
                Property      = '(see portal)'
                ExpectedValue = $null
                ActualValue   = $null
                DetectedAt    = $drift.firstReportedDateTime
                Status        = $drift.status
            })
        }
    }
}

if ($OutputFormat -eq 'json') {
    $allDrifts | ConvertTo-Json -Depth 10
} else {
    if ($allDrifts.Count -eq 0) {
        Write-Host "`n✅ No drifts detected! Tenant configuration is aligned with desired state." -ForegroundColor Green
    } else {
        Write-Host "`n⚠️  $($allDrifts.Count) drift(s) detected:" -ForegroundColor Red
        $allDrifts | Format-Table -AutoSize
    }
}

if ($FailOnDrift -and $allDrifts.Count -gt 0) {
    Write-Host "Pipeline failing due to detected drifts." -ForegroundColor Red
    exit 1
}
