<#
.SYNOPSIS
    Restores tenant configuration to a previous baseline snapshot.

.DESCRIPTION
    Restores the UTCM monitor baseline to a specified snapshot. This can be used
    for manual rollback or automated rollback on Apply-Config.ps1 failure.

    Critical errors (auth failures) are NOT automatically rolled back.

.PARAMETER TenantName
    Logical name of the tenant.

.PARAMETER SnapshotId
    ID of the snapshot to restore to. If not specified, uses the most recent
    pre-apply snapshot from tenants/<name>/snapshots/pre-apply/

.PARAMETER MonitorId
    ID of the monitor to update. If not specified, finds the monitor by name.

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    ./Restore-Baseline.ps1 -TenantName kustomize
    ./Restore-Baseline.ps1 -TenantName kustomize -SnapshotId "snap-123" -Force
#>
param(
    [Parameter(Mandatory)]
    [string]$TenantName,

    [string]$SnapshotId = '',
    [string]$MonitorId = '',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers' 'Auth.ps1')

#region Helpers
function Write-Step([string]$Msg)    { Write-Host "`n▶ $Msg" -ForegroundColor Cyan }
function Write-Success([string]$Msg) { Write-Host "  ✅ $Msg" -ForegroundColor Green }
function Write-Info([string]$Msg)    { Write-Host "  ℹ  $Msg" -ForegroundColor White }
function Write-Warn([string]$Msg)    { Write-Host "  ⚠️  $Msg" -ForegroundColor Yellow }
function Write-Err([string]$Msg)     { Write-Host "  ❌ $Msg" -ForegroundColor Red }
#endregion

$repoRoot = Split-Path $PSScriptRoot -Parent

# --- Find pre-apply snapshot if not specified ---
if (-not $SnapshotId) {
    $preApplyDir = Join-Path $repoRoot 'tenants' $TenantName 'snapshots' 'pre-apply'
    if (Test-Path $preApplyDir) {
        $latestSnapshot = Get-ChildItem $preApplyDir -Filter '*.json' |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($latestSnapshot) {
            Write-Info "Found pre-apply snapshot: $($latestSnapshot.Name)"
            $snapshotData = Get-Content $latestSnapshot.FullName -Raw | ConvertFrom-Json -AsHashtable
            $SnapshotId = $snapshotData.id ?? $latestSnapshot.BaseName
        }
    }
}

if (-not $SnapshotId) {
    throw "No snapshot specified and no pre-apply snapshots found. Cannot restore."
}

Write-Step "Restore Baseline"
Write-Info "Tenant    : $TenantName"
Write-Info "Snapshot  : $SnapshotId"

# --- Authenticate ---
Write-Step "Authenticating to Microsoft Graph..."
$token = Get-GraphAccessToken
Write-Success "Authenticated."

# --- Find monitor ---
if (-not $MonitorId) {
    Write-Step "Finding monitor for tenant '$TenantName'..."
    $safeName = ($TenantName -replace '[^a-zA-Z0-9 ]', ' ').Trim()
    $prefix = $safeName.Substring(0,1).ToUpper() + $safeName.Substring(1)

    $monitors = Invoke-GraphRequest -Endpoint '/admin/configurationManagement/configurationMonitors' -Token $token
    $monitor = $monitors.value | Where-Object { $_.displayName -like "$prefix*" } | Select-Object -First 1

    if (-not $monitor) {
        throw "No monitor found for tenant '$TenantName'. Run Apply-Config.ps1 first."
    }

    $MonitorId = $monitor.id
    Write-Info "Found monitor: $($monitor.displayName) (ID: $MonitorId)"
}

# --- Fetch snapshot data ---
Write-Step "Fetching snapshot data..."
$snapshotEndpoint = "/admin/configurationManagement/configurationSnapshots/$SnapshotId"

try {
    $snapshot = Invoke-GraphRequest -Endpoint $snapshotEndpoint -Token $token
    Write-Info "Snapshot contains $($snapshot.resources.Count) resource(s)"
}
catch {
    # If snapshot is stored locally, load from file
    $localSnapshotPath = Join-Path $repoRoot 'tenants' $TenantName 'snapshots' 'pre-apply' "$SnapshotId.json"
    if (Test-Path $localSnapshotPath) {
        Write-Info "Loading snapshot from local file..."
        $snapshot = Get-Content $localSnapshotPath -Raw | ConvertFrom-Json -AsHashtable
    }
    else {
        throw "Failed to fetch snapshot '$SnapshotId': $_"
    }
}

# --- Confirmation ---
if (-not $Force) {
    Write-Warn "This will restore the monitor baseline to snapshot '$($snapshot.displayName ?? $SnapshotId)'."
    Write-Warn "Resources in the baseline:"
    foreach ($resource in $snapshot.resources) {
        $rType = $resource.resourceType ?? $resource['resourceType']
        $rName = $resource.properties.DisplayName ?? $resource.properties['DisplayName'] ?? $resource.id ?? 'unnamed'
        Write-Info "  - ${rType}: ${rName}"
    }

    $confirm = Read-Host "Continue? (y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Info "Restore cancelled."
        exit 0
    }
}

# --- Restore baseline ---
Write-Step "Restoring baseline..."

# Normalize resources for UTCM API
$normalizedResources = $snapshot.resources | ForEach-Object {
    $r = $_
    $rType = $r.resourceType ?? $r['resourceType']
    $rProps = if ($r.properties) {
        $r.properties | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
    } else {
        @{}
    }
    $rDisplayName = $rProps['DisplayName'] ?? $rProps['Identity'] ?? $rProps['Id'] ?? $rType

    # Teams resources: DisplayName must NOT be in properties
    if ($rType -like 'microsoft.teams.*') {
        $rProps.Remove('DisplayName')
    }

    @{
        displayName = $rDisplayName
        resourceType = $rType
        properties = $rProps
    }
}

$monitorBody = @{
    baseline = @{
        displayName = "Restored from $($snapshot.displayName ?? $SnapshotId)"
        resources = @($normalizedResources)
    }
}

Invoke-GraphRequest -Method PATCH `
    -Endpoint "/admin/configurationManagement/configurationMonitors/$MonitorId" `
    -Body $monitorBody `
    -Token $token | Out-Null

Write-Success "Baseline restored successfully."
Write-Host "`n🔄 Monitor baseline has been restored to snapshot '$($snapshot.displayName ?? $SnapshotId)'." -ForegroundColor Green
Write-Host "   Run Get-Drifts.ps1 -TenantName $TenantName to verify current state." -ForegroundColor White
