<#
.SYNOPSIS
    Takes a configuration snapshot of the current M365 tenant state
    and saves it to the snapshots/ directory.

.DESCRIPTION
    Calls the UTCM Snapshot APIs (POST /admin/configurationManagement/configurationSnapshots/createSnapshot)
    to initiate an async snapshot job, polls until complete, then downloads the result
    via the resourceLocation URL returned by the completed job.

    Required permission: ConfigurationMonitoring.ReadWrite.All (Application)

.PARAMETER Resources
    Which UTCM resource types to snapshot.
    Use the string names that match the Graph API resource identifiers.
    Defaults to a broad set covering Entra, conditional access, and auth methods.

.PARAMETER DisplayName
    Display name for the snapshot job in the Entra portal.

.PARAMETER OutputDir
    Where to save the snapshot JSON. Defaults to snapshots/output/

.EXAMPLE
    ./Take-Snapshot.ps1
    ./Take-Snapshot.ps1 -DisplayName "Baseline-2026-Q1"
    ./Take-Snapshot.ps1 -Resources @('conditionalAccessPolicy','authenticationMethodsPolicy')
#>
param(
    [string[]]$Resources = @(
        'microsoft.entra.conditionalaccesspolicy',
        'microsoft.entra.authenticationmethodpolicy',
        'microsoft.entra.authorizationpolicy',
        'microsoft.entra.securitydefaults'
    ),

    # DisplayName rules: 8-32 chars, alphanumeric + spaces only (no hyphens or special chars)
    [string]$DisplayName = "Snapshot $(Get-Date -Format 'yyyyMMdd HHmmss')",
    [string]$Description = 'Automated snapshot taken by Take-Snapshot.ps1',
    [string]$OutputDir   = (Join-Path (Split-Path $PSScriptRoot -Parent) 'snapshots' 'output')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers' 'Auth.ps1')


function Write-Step([string]$Msg)    { Write-Host "`n▶ $Msg" -ForegroundColor Cyan }
function Write-Success([string]$Msg) { Write-Host "  ✅ $Msg" -ForegroundColor Green }
function Write-Info([string]$Msg)    { Write-Host "  ℹ  $Msg" -ForegroundColor White }
function Write-Warn([string]$Msg)    { Write-Host "  ⚠️  $Msg" -ForegroundColor Yellow }

Write-Step "Authenticating to Microsoft Graph..."
$token = Get-GraphAccessToken
Write-Success "Token acquired."

Write-Step "Creating snapshot job '$DisplayName' (resources: $($Resources -join ', '))..."
$snapshotBody = @{
    displayName = $DisplayName
    description = $Description
    resources   = $Resources
}

# POST /admin/configurationManagement/configurationSnapshots/createSnapshot
# Returns a configurationSnapshotJob object with an 'id' and initial 'status'
$job = Invoke-GraphRequest -Method POST `
    -Endpoint '/admin/configurationManagement/configurationSnapshots/createSnapshot' `
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
        -Endpoint "/admin/configurationManagement/configurationSnapshotJobs/$($job.id)" `
        -Token $token

    Write-Info "Status: $($jobStatus.status) (${elapsed}s elapsed)"

    if ($elapsed -ge $maxWaitSeconds) {
        throw "Snapshot job timed out after ${maxWaitSeconds}s. Job ID: $($job.id)"
    }
} while ($jobStatus.status -notin @('succeeded', 'failed', 'partiallySuccessful'))

if ($jobStatus.status -eq 'failed') {
    throw "Snapshot job failed: $($jobStatus | ConvertTo-Json -Depth 5)"
}
if ($jobStatus.status -eq 'partiallySuccessful') {
    Write-Warn "Snapshot completed with partial success. Some resources may be missing. Error: $($jobStatus.errorDetails | ConvertTo-Json -Depth 3)"
}

Write-Success "Snapshot completed!"

# The completed job exposes a resourceLocation URL pointing to the snapshot file.
# Download it directly rather than calling a /result sub-resource.
Write-Step "Downloading snapshot from resourceLocation..."
if (-not $jobStatus.resourceLocation) {
    throw "No resourceLocation on completed job. Full job: $($jobStatus | ConvertTo-Json -Depth 5)"
}

$token_header = @{ Authorization = "Bearer $token" }
$results = Invoke-RestMethod -Uri $jobStatus.resourceLocation -Headers $token_header -Method GET

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputFile = Join-Path $OutputDir "snapshot-$timestamp.json"
$results | ConvertTo-Json -Depth 50 | Set-Content -Path $outputFile -Encoding UTF8

Write-Success "Snapshot saved: $outputFile"
Write-Host "`n💡 Review this file and copy desired configuration to config/ as your baseline." -ForegroundColor Yellow
Write-Host "   Then run Apply-Config.ps1 to enforce it going forward." -ForegroundColor Yellow
