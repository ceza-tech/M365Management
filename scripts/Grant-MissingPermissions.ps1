<#
.SYNOPSIS
    Grants any missing Microsoft Graph permissions to the M365Management-GitOps app registration.

.DESCRIPTION
    Compares the permissions currently granted on the service principal against the full
    required set and grants only what is missing. Does NOT create a new client secret.
    Run this interactively whenever you add new permissions to the required set.

.PARAMETER ClientId
    The App (client) ID of the M365Management-GitOps app registration.
    Defaults to the AZURE_CLIENT_ID environment variable.

.EXAMPLE
    ./Grant-MissingPermissions.ps1
    ./Grant-MissingPermissions.ps1 -ClientId '9d961172-7ba8-4f93-91c1-595365b83f2c'
#>
param(
    [string]$ClientId = $env:AZURE_CLIENT_ID
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helpers
function Write-Step([string]$Message)    { Write-Host "`n▶ $Message" -ForegroundColor Cyan }
function Write-Success([string]$Message) { Write-Host "  ✅ $Message" -ForegroundColor Green }
function Write-Warn([string]$Message)    { Write-Host "  ⚠️  $Message" -ForegroundColor Yellow }
function Write-Info([string]$Message)    { Write-Host "  ℹ️  $Message" -ForegroundColor White }
#endregion

# ---------------------------------------------------------------------------
# Full required permission set (keep in sync with Register-AppRegistration.ps1)
# ---------------------------------------------------------------------------
# Microsoft Graph permissions
$graphPermissions = @(
    # --- UTCM core (all workloads) ---
    @{ Name = 'ConfigurationMonitoring.ReadWrite.All'; Purpose = 'Create/manage UTCM monitors and snapshots' }
    @{ Name = 'ConfigurationMonitoring.Read.All';      Purpose = 'Read UTCM monitors, drifts, baselines'     }

    # --- Entra ---
    @{ Name = 'Policy.Read.All';                       Purpose = 'Read Conditional Access, auth policies'    }
    @{ Name = 'Policy.ReadWrite.ConditionalAccess';    Purpose = 'Manage CA policies'                        }
    @{ Name = 'Policy.ReadWrite.AuthenticationMethod'; Purpose = 'Manage auth methods'                       }
    @{ Name = 'Policy.ReadWrite.Authorization';        Purpose = 'Manage authorization policy'               }
    @{ Name = 'Policy.ReadWrite.CrossTenantAccess';    Purpose = 'Manage cross-tenant access policy'         }
    @{ Name = 'User.Read.All';                         Purpose = 'Read user properties'                      }
    @{ Name = 'Group.Read.All';                        Purpose = 'Read group properties'                     }
    @{ Name = 'RoleManagement.Read.All';               Purpose = 'Read role assignments'                     }
    @{ Name = 'IdentityRiskyUser.Read.All';            Purpose = 'Read risky user policies'                  }
    @{ Name = 'NamedPlace.Read.All';                   Purpose = 'Read named locations'                      }

    # --- Teams ---
    @{ Name = 'TeamworkDevice.ReadWrite.All';          Purpose = 'Read Teams device configurations'          }
    @{ Name = 'TeamworkTag.ReadWrite';                 Purpose = 'Manage Teams tags'                         }

    # --- Intune ---
    @{ Name = 'DeviceManagementConfiguration.ReadWrite.All';  Purpose = 'Read/write Intune device configs'  }
    @{ Name = 'DeviceManagementManagedDevices.ReadWrite.All'; Purpose = 'Read/write Intune managed devices' }
    @{ Name = 'DeviceManagementApps.ReadWrite.All';           Purpose = 'Read/write Intune app policies'    }
    @{ Name = 'DeviceManagementRBAC.ReadWrite.All';           Purpose = 'Read/write Intune RBAC roles'      }
)

# Exchange Online permissions (separate service principal)
$exchangePermissions = @(
    @{ Name = 'Exchange.ManageAsApp'; Purpose = 'Read/write all Exchange Online settings via UTCM' }
)


$GRAPH_APP_ID     = '00000003-0000-0000-c000-000000000000'
$EXCHANGE_APP_ID  = '00000002-0000-0ff1-ce00-000000000000'   # Office 365 Exchange Online

# ---------------------------------------------------------------------------
# Module check
# ---------------------------------------------------------------------------
Write-Step "Checking required PowerShell modules..."
foreach ($mod in @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications')) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Warn "$mod not found. Installing..."
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber
    } else {
        Write-Success "$mod is available."
    }
}

# ---------------------------------------------------------------------------
# Connect (interactive)
# ---------------------------------------------------------------------------
Write-Step "Connecting to Microsoft Graph (interactive)..."
Connect-MgGraph -Scopes @(
    'Application.ReadWrite.All',
    'AppRoleAssignment.ReadWrite.All'
) -NoWelcome
Write-Success "Connected."

# ---------------------------------------------------------------------------
# Resolve the app and its service principal
# ---------------------------------------------------------------------------
if (-not $ClientId) {
    throw "ClientId is required. Pass -ClientId or set AZURE_CLIENT_ID in your environment."
}

Write-Step "Resolving app registration (Client ID: $ClientId)..."
$app = Get-MgApplication -Filter "AppId eq '$ClientId'" -ErrorAction SilentlyContinue
if (-not $app) {
    throw "No app registration found with Client ID '$ClientId'. Check the value and try again."
}
Write-Success "Found app: '$($app.DisplayName)' (Object ID: $($app.Id))"

$sp = Get-MgServicePrincipal -Filter "AppId eq '$ClientId'" -ErrorAction SilentlyContinue
if (-not $sp) {
    Write-Warn "No service principal found — creating one..."
    $sp = New-MgServicePrincipal -AppId $ClientId
    Write-Success "Service principal created (Object ID: $($sp.Id))."
}

# ---------------------------------------------------------------------------
# Resolve Microsoft Graph SP (for AppRole IDs)
# ---------------------------------------------------------------------------
Write-Step "Fetching Microsoft Graph service principal..."
$graphSP = Get-MgServicePrincipal -Filter "AppId eq '$GRAPH_APP_ID'"
Write-Success "Found (Object ID: $($graphSP.Id))."

# ---------------------------------------------------------------------------
# Update app manifest (requiredResourceAccess)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Fetch Exchange Online SP
# ---------------------------------------------------------------------------
Write-Step "Fetching Exchange Online service principal..."
$exchangeSP = Get-MgServicePrincipal -Filter "AppId eq '$EXCHANGE_APP_ID'" -ErrorAction SilentlyContinue
if ($exchangeSP) {
    Write-Success "Found Exchange Online SP (Object ID: $($exchangeSP.Id))."
} else {
    Write-Warn "Exchange Online SP not found — Exchange permissions will be skipped."
}

# ---------------------------------------------------------------------------
# Update app manifest permissions
# ---------------------------------------------------------------------------
Write-Step "Updating app manifest permissions..."

$graphAccess = foreach ($perm in $graphPermissions) {
    $appRole = $graphSP.AppRoles | Where-Object { $_.Value -eq $perm.Name }
    if (-not $appRole) {
        Write-Warn "'$($perm.Name)' not found on Microsoft Graph AppRoles — skipping."
        continue
    }
    @{ Id = $appRole.Id; Type = 'Role' }
}

$requiredResourceAccess = @(@{ ResourceAppId = $GRAPH_APP_ID; ResourceAccess = @($graphAccess) })

if ($exchangeSP) {
    $exchangeAccess = foreach ($perm in $exchangePermissions) {
        $appRole = $exchangeSP.AppRoles | Where-Object { $_.Value -eq $perm.Name }
        if (-not $appRole) {
            Write-Warn "'$($perm.Name)' not found on Exchange Online AppRoles — skipping."
            continue
        }
        @{ Id = $appRole.Id; Type = 'Role' }
    }
    $requiredResourceAccess += @{ ResourceAppId = $EXCHANGE_APP_ID; ResourceAccess = @($exchangeAccess) }
}

Update-MgApplication -ApplicationId $app.Id -RequiredResourceAccess $requiredResourceAccess
Write-Success "App manifest updated."

# ---------------------------------------------------------------------------
# Grant admin consent for any missing role assignments
# ---------------------------------------------------------------------------
Write-Step "Granting admin consent for missing permissions..."

$existingAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id
$granted = 0
$skipped = 0

# Grant Graph permissions
foreach ($perm in $graphPermissions) {
    $appRole = $graphSP.AppRoles | Where-Object { $_.Value -eq $perm.Name }
    if (-not $appRole) { continue }

    $alreadyGranted = $existingAssignments | Where-Object { $_.AppRoleId -eq $appRole.Id }
    if ($alreadyGranted) {
        Write-Info "'$($perm.Name)' already consented — skipping."
        $skipped++; continue
    }
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -BodyParameter @{
        AppRoleId   = $appRole.Id
        ResourceId  = $graphSP.Id
        PrincipalId = $sp.Id
    } | Out-Null
    Write-Success "Granted (Graph): $($perm.Name)"
    $granted++
}

# Grant Exchange Online permissions
if ($exchangeSP) {
    foreach ($perm in $exchangePermissions) {
        $appRole = $exchangeSP.AppRoles | Where-Object { $_.Value -eq $perm.Name }
        if (-not $appRole) { continue }

        $alreadyGranted = $existingAssignments | Where-Object { $_.AppRoleId -eq $appRole.Id }
        if ($alreadyGranted) {
            Write-Info "'$($perm.Name)' already consented — skipping."
            $skipped++; continue
        }
        New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -BodyParameter @{
            AppRoleId   = $appRole.Id
            ResourceId  = $exchangeSP.Id
            PrincipalId = $sp.Id
        } | Out-Null
        Write-Success "Granted (Exchange): $($perm.Name)"
        $granted++
    }
}

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host "🎉 Done!  $granted permission(s) newly granted, $skipped already present." -ForegroundColor Green
Write-Host "   Next step: retry   pwsh ./scripts/Take-Snapshot.ps1" -ForegroundColor White
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
