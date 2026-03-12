<#
.SYNOPSIS
    Assigns the Exchange Administrator Entra directory role to the M365Management-GitOps
    service principal. Required for UTCM Exchange Online snapshots.

.DESCRIPTION
    Exchange.ManageAsApp API permission alone is not sufficient for UTCM Exchange snapshots.
    The service principal must also hold the "Exchange Administrator" directory role.
    This script assigns it interactively using your admin credentials.

.PARAMETER ServicePrincipalObjectId
    The Object ID of the M365Management-GitOps service principal.
    Defaults to the value from AZURE_CLIENT_ID by looking up the SP.

.EXAMPLE
    ./Grant-ExchangeAdminRole.ps1
#>
param(
    [string]$ClientId = $env:AZURE_CLIENT_ID
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$Msg)    { Write-Host "`n▶ $Msg" -ForegroundColor Cyan }
function Write-Success([string]$Msg) { Write-Host "  ✅ $Msg" -ForegroundColor Green }
function Write-Info([string]$Msg)    { Write-Host "  ℹ  $Msg" -ForegroundColor White }
function Write-Warn([string]$Msg)    { Write-Host "  ⚠️  $Msg" -ForegroundColor Yellow }

# Exchange Administrator built-in role ID (same across all tenants)
$EXCHANGE_ADMIN_ROLE_ID = '29232cdf-9323-42fd-ade2-1d097af3e4de'

# Check/install SDK module
Write-Step "Checking required PowerShell modules..."
foreach ($mod in @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.Governance')) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Warn "$mod not found — installing..."
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber
    } else {
        Write-Success "$mod is available."
    }
}

# Connect interactively with role management scope
Write-Step "Connecting to Microsoft Graph (interactive — requires Global Admin or Privileged Role Admin)..."
Connect-MgGraph -Scopes @(
    'RoleManagement.ReadWrite.Directory',
    'Application.Read.All'
) -NoWelcome
Write-Success "Connected."

# Resolve service principal
Write-Step "Resolving service principal for app: $ClientId..."
$sp = Get-MgServicePrincipal -Filter "AppId eq '$ClientId'" -ErrorAction SilentlyContinue
if (-not $sp) {
    throw "No service principal found for ClientId '$ClientId'. Run Register-AppRegistration.ps1 first."
}
Write-Success "Found SP: '$($sp.DisplayName)' (Object ID: $($sp.Id))"

# Check if already assigned
Write-Step "Checking existing role assignments..."
$existing = Get-MgRoleManagementDirectoryRoleAssignment `
    -Filter "principalId eq '$($sp.Id)' and roleDefinitionId eq '$EXCHANGE_ADMIN_ROLE_ID'" `
    -ErrorAction SilentlyContinue

if ($existing) {
    Write-Success "Exchange Administrator role is already assigned — nothing to do."
    return
}

# Assign the role
Write-Step "Assigning Exchange Administrator directory role..."
$params = @{
    PrincipalId      = $sp.Id
    RoleDefinitionId = $EXCHANGE_ADMIN_ROLE_ID
    DirectoryScopeId = '/'
}
New-MgRoleManagementDirectoryRoleAssignment -BodyParameter $params | Out-Null
Write-Success "Exchange Administrator role assigned to '$($sp.DisplayName)'."

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host "🎉 Done! The service principal can now snapshot Exchange Online resources." -ForegroundColor Green
Write-Host "   Next: pwsh ./scripts/Take-Snapshot.ps1 -Resources @('microsoft.exchange.antiphishpolicy',...)" -ForegroundColor White
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
