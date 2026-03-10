<#
.SYNOPSIS
    Takes a configuration snapshot of the current M365 tenant state
    and saves it as a baseline YAML file.

.DESCRIPTION
    Calls the UTCM Snapshot APIs to extract current tenant configuration,
    polls until the job completes, then downloads and saves the result
    to the config/ directory as the desired-state baseline.

.PARAMETER WorkloadTypes
    Which workloads to snapshot. Defaults to all supported workloads.
    Valid values: entra, teams, exchange, intune, defender, purview

.PARAMETER OutputDir
    Where to save the snapshot output. Defaults to snapshots/

.EXAMPLE
    ./Take-Snapshot.ps1
    ./Take-Snapshot.ps1 -WorkloadTypes @("entra","teams") -OutputDir "./snapshots"
#>
param(
    [ValidateSet('entra', 'teams', 'exchange', 'intune', 'defender', 'purview')]
    [string[]]$WorkloadTypes = @('entra', 'teams', 'exchange', 'intune'),

    [string]$OutputDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'snapshots' 'output')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers' 'Auth.ps1')

#region Workload mapping (UTCM API workload type strings)
$workloadMap = @{
    entra    = 'microsoftEntra'
    teams    = 'microsoftTeams'
    exchange = 'microsoftExchangeOnline'
    intune   = 'microsoftIntune'
    defender = 'microsoftDefender'
    purview  = 'microsoftPurview'
}
#endregion

function Write-Step([string]$Msg) { Write-Host "`n▶ $Msg" -ForegroundColor Cyan }
function Write-Success([string]$Msg) { Write-Host "  ✅ $Msg" -ForegroundColor Green }
function Write-Info([string]$Msg) { Write-Host "  ℹ  $Msg" -ForegroundColor White }

Write-Step "Authenticating to Microsoft Graph..."
$token = Get-GraphAccessToken
Write-Success "Token acquired."

$resolvedWorkloads = $WorkloadTypes | ForEach-Object { $workloadMap[$_] }

Write-Step "Creating snapshot job for workloads: $($WorkloadTypes -join ', ')..."
$snapshotBody = @{
    workloadTypes = $resolvedWorkloads
}

$job = Invoke-GraphRequest -Method POST `
    -Endpoint '/tenantRelationships/configurationSnapshotJobs' `
    -Body $snapshotBody `
    -Token $token

Write-Success "Snapshot job created (ID: $($job.id))"

Write-Step "Polling for snapshot completion..."
$maxWaitSeconds = 300
$pollIntervalSeconds = 10
$elapsed = 0

do {
    Start-Sleep -Seconds $pollIntervalSeconds
    $elapsed += $pollIntervalSeconds

    $jobStatus = Invoke-GraphRequest `
        -Endpoint "/tenantRelationships/configurationSnapshotJobs/$($job.id)" `
        -Token $token

    Write-Info "Status: $($jobStatus.status) (${elapsed}s elapsed)"

    if ($elapsed -ge $maxWaitSeconds) {
        throw "Snapshot job timed out after ${maxWaitSeconds}s. Job ID: $($job.id)"
    }
} while ($jobStatus.status -notin @('succeeded', 'failed'))

if ($jobStatus.status -eq 'failed') {
    throw "Snapshot job failed: $($jobStatus | ConvertTo-Json -Depth 5)"
}

Write-Success "Snapshot completed!"

Write-Step "Downloading snapshot results..."
$results = Invoke-GraphRequest `
    -Endpoint "/tenantRelationships/configurationSnapshotJobs/$($job.id)/result" `
    -Token $token

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputFile = Join-Path $OutputDir "snapshot-$timestamp.json"
$results | ConvertTo-Json -Depth 50 | Set-Content -Path $outputFile -Encoding UTF8

Write-Success "Snapshot saved: $outputFile"
Write-Host "`n💡 Review this file and copy desired configuration to config/ as your baseline." -ForegroundColor Yellow
Write-Host "   Then run Apply-Config.ps1 to enforce it going forward." -ForegroundColor Yellow
