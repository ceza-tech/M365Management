<#
.SYNOPSIS
    Fetches and reports all active configuration drifts from UTCM monitors.

.DESCRIPTION
    Lists configurationMonitors for a given tenant, then checks the top-level
    /configurationDrifts endpoint for any active drifts.

.PARAMETER TenantName
    Logical name of the tenant. Used to filter monitors by name prefix.
    Default: all monitors in the tenant.

.PARAMETER MonitorDisplayName
    Filter to a specific monitor by exact display name. Default: all monitors.

.PARAMETER FailOnDrift
    If set, exits with code 1 when drifts are detected. Useful in CI pipelines.

.PARAMETER OutputFormat
    Output format: 'table' (default) or 'json'

.EXAMPLE
    ./Get-Drifts.ps1 -TenantName kustomize
    ./Get-Drifts.ps1 -TenantName kustomize -FailOnDrift
    ./Get-Drifts.ps1 -TenantName kustomize -OutputFormat json
#>
param(
    [string]$TenantName         = '',
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
$monitorsResponse = Invoke-GraphRequest -Endpoint '/admin/configurationManagement/configurationMonitors' -Token $token
$monitors = $monitorsResponse.value

# Filter: explicit MonitorDisplayName takes priority, then TenantName prefix match
if ($MonitorDisplayName) {
    $monitors = $monitors | Where-Object { $_.displayName -eq $MonitorDisplayName }
} elseif ($TenantName) {
    # Monitor names are auto-generated as "<TenantName> GitOps" — match by prefix
    $safeName = ($TenantName -replace '[^a-zA-Z0-9 ]', ' ').Trim()
    $prefix   = $safeName.Substring(0,1).ToUpper() + $safeName.Substring(1)
    $monitors = $monitors | Where-Object { $_.displayName -like "$prefix*" }
}

if (-not $monitors -or @($monitors).Count -eq 0) {
    Write-Host "No monitors found. Run Apply-Config.ps1 -TenantName $TenantName first." -ForegroundColor Yellow
    if ($OutputFormat -eq 'json') { '[]' }
    exit 0
}

Write-Info "Found $(@($monitors).Count) monitor(s)."

# Fetch all drifts from the top-level endpoint (no per-monitor sub-resource exists)
Write-Step "Fetching active configuration drifts..."
$allDriftsResponse = Invoke-GraphRequest `
    -Endpoint '/admin/configurationManagement/configurationDrifts' `
    -Token $token

$allDrifts = [System.Collections.Generic.List[object]]::new()

# Helper: safely read a property regardless of casing, returns $null if missing
function Get-PropSafe($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    # Case-insensitive fallback
    $prop = $Obj.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    return $prop?.Value
}

foreach ($monitor in @($monitors)) {
    $monitorDrifts = $allDriftsResponse.value | Where-Object { $_.monitorId -eq $monitor.id }

    # Log raw schema of first drift once so we can verify field names
    if ($monitorDrifts -and $OutputFormat -ne 'json') {
        $first = @($monitorDrifts)[0]
        Write-Info "Raw drift fields: $($first.PSObject.Properties.Name -join ', ')"
        if ($first.driftedProperties) {
            $firstProp = @($first.driftedProperties)[0]
            Write-Info "Raw driftedProperty fields: $($firstProp.PSObject.Properties.Name -join ', ')"
        }
    }

    foreach ($drift in $monitorDrifts) {
        $driftedProps = Get-PropSafe $drift 'driftedProperties'
        if ($driftedProps) {
            foreach ($prop in @($driftedProps)) {
                $allDrifts.Add([PSCustomObject]@{
                    Tenant        = $TenantName
                    Monitor       = $monitor.displayName
                    ResourceType  = (Get-PropSafe $drift 'resourceType')
                    ResourceId    = (Get-PropSafe $drift 'resourceInstanceIdentifier') ?? (Get-PropSafe $drift 'resourceId')
                    Property      = (Get-PropSafe $prop 'propertyName') ?? (Get-PropSafe $prop 'name')
                    ExpectedValue = (Get-PropSafe $prop 'expectedValue') ?? (Get-PropSafe $prop 'baselineValue')
                    ActualValue   = (Get-PropSafe $prop 'currentValue') ?? (Get-PropSafe $prop 'actualValue')
                    DetectedAt    = (Get-PropSafe $drift 'firstReportedDateTime') ?? (Get-PropSafe $drift 'detectedDateTime')
                    Status        = (Get-PropSafe $drift 'status')
                })
            }
        } else {
            $allDrifts.Add([PSCustomObject]@{
                Tenant        = $TenantName
                Monitor       = $monitor.displayName
                ResourceType  = (Get-PropSafe $drift 'resourceType')
                ResourceId    = (Get-PropSafe $drift 'resourceInstanceIdentifier') ?? (Get-PropSafe $drift 'resourceId')
                Property      = '(see portal)'
                ExpectedValue = $null
                ActualValue   = $null
                DetectedAt    = (Get-PropSafe $drift 'firstReportedDateTime') ?? (Get-PropSafe $drift 'detectedDateTime')
                Status        = (Get-PropSafe $drift 'status')
            })
        }
    }
}

if ($OutputFormat -eq 'json') {
    $allDrifts | ConvertTo-Json -Depth 10
} else {
    if ($allDrifts.Count -eq 0) {
        Write-Host "`n✅ No drifts detected! Tenant '$TenantName' configuration is aligned with desired state." -ForegroundColor Green
    } else {
        Write-Host "`n⚠️  $($allDrifts.Count) drift(s) detected for tenant '$TenantName':" -ForegroundColor Red
        $allDrifts | Format-Table -AutoSize
    }
}

if ($FailOnDrift -and $allDrifts.Count -gt 0) {
    Write-Host "Pipeline failing due to detected drifts." -ForegroundColor Red
    exit 1
}
