<#
.SYNOPSIS
    One-time setup: Adds the UTCM service principal to your tenant and grants required permissions.

.DESCRIPTION
    This script performs the prerequisite steps for the Unified Tenant Configuration Management (UTCM) APIs.
    Run this once per tenant before using any other scripts.

    Reference: https://learn.microsoft.com/en-us/graph/utcm-authentication-setup

.PARAMETER Permissions
    Array of Microsoft Graph permissions to grant to the UTCM service principal.
    Defaults to a sensible baseline covering Entra, Teams, Exchange, and Intune.

.EXAMPLE
    ./Setup-UTCM.ps1
    ./Setup-UTCM.ps1 -Permissions @('Policy.Read.All', 'User.Read.All')
#>
param(
    [string[]]$Permissions = @(
        # Entra
        'Policy.Read.All',
        'Policy.ReadWrite.ConditionalAccess',
        'Policy.ReadWrite.AuthenticationMethod',
        'User.Read.All',
        'Group.Read.All',
        'RoleManagement.Read.All',
        'Application.Read.All',
        # Shared
        'TenantConfiguration.ReadWrite.All'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helpers
function Write-Step([string]$Message) {
    Write-Host "`n▶ $Message" -ForegroundColor Cyan
}
function Write-Success([string]$Message) {
    Write-Host "  ✅ $Message" -ForegroundColor Green
}
function Write-Warn([string]$Message) {
    Write-Host "  ⚠️  $Message" -ForegroundColor Yellow
}
#endregion

Write-Step "Checking required PowerShell modules..."
$requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications')
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Warn "$mod not found. Installing..."
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber
    } else {
        Write-Success "$mod already installed."
    }
}

Write-Step "Connecting to Microsoft Graph (interactive)..."
Connect-MgGraph -Scopes @(
    'Application.ReadWrite.All',
    'AppRoleAssignment.ReadWrite.All'
)
Write-Success "Connected."

$UTCM_APP_ID = '03b07b79-c5bc-4b5e-9bfa-13acf4a99998'

Write-Step "Checking if UTCM service principal already exists in tenant..."
$existing = Get-MgServicePrincipal -Filter "AppId eq '$UTCM_APP_ID'" -ErrorAction SilentlyContinue

if ($existing) {
    Write-Warn "UTCM service principal already exists (Object ID: $($existing.Id)). Skipping creation."
    $utcmSP = $existing
} else {
    Write-Step "Creating UTCM service principal..."
    $utcmSP = New-MgServicePrincipal -AppId $UTCM_APP_ID
    Write-Success "Created UTCM service principal (Object ID: $($utcmSP.Id))."
}

Write-Step "Fetching Microsoft Graph service principal..."
$graphSP = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
Write-Success "Found Microsoft Graph SP (Object ID: $($graphSP.Id))."

Write-Step "Granting permissions to UTCM service principal..."
$existingAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $utcmSP.Id

foreach ($permission in $Permissions) {
    $appRole = $graphSP.AppRoles | Where-Object { $_.Value -eq $permission }
    if (-not $appRole) {
        Write-Warn "Permission '$permission' not found on Microsoft Graph SP. Skipping."
        continue
    }

    $alreadyAssigned = $existingAssignments | Where-Object { $_.AppRoleId -eq $appRole.Id }
    if ($alreadyAssigned) {
        Write-Warn "'$permission' already granted. Skipping."
        continue
    }

    $body = @{
        AppRoleId   = $appRole.Id
        ResourceId  = $graphSP.Id
        PrincipalId = $utcmSP.Id
    }
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $utcmSP.Id -BodyParameter $body | Out-Null
    Write-Success "Granted: $permission"
}

Write-Host "`n🎉 UTCM setup complete!" -ForegroundColor Green
Write-Host "   UTCM Service Principal Object ID: $($utcmSP.Id)" -ForegroundColor White
Write-Host "   Next step: Run Take-Snapshot.ps1 to capture your current tenant config as a baseline." -ForegroundColor White
