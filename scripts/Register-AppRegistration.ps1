<#
.SYNOPSIS
    Creates an Entra App Registration with the required Microsoft Graph permissions for M365Management GitOps.

.DESCRIPTION
    Automates Steps 1-3 of docs/authentication.md:
      1. Creates a new App Registration (single-tenant, no redirect URI)
      2. Creates a client secret
      3. Grants the required Microsoft Graph application permissions and prompts for admin consent

    After running, add the output values as GitHub Actions secrets:
      AZURE_TENANT_ID    → Your Entra tenant ID
      AZURE_CLIENT_ID    → The app's client ID (printed at the end)
      AZURE_CLIENT_SECRET → The secret value (printed once — save it now!)

.PARAMETER AppName
    Display name for the App Registration. Defaults to 'M365Management-GitOps'.

.PARAMETER SecretDisplayName
    Description shown in the Entra portal for the client secret. Defaults to 'GitOps-CI'.

.PARAMETER SecretExpiryYears
    How many years until the client secret expires. Defaults to 1.

.EXAMPLE
    ./Register-AppRegistration.ps1
    ./Register-AppRegistration.ps1 -AppName 'M365Mgmt-Prod' -SecretExpiryYears 2
#>
param(
    [string]$AppName          = 'M365Management-GitOps',
    [string]$SecretDisplayName = 'GitOps-CI',
    [int]   $SecretExpiryYears = 1
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
function Write-Info([string]$Message) {
    Write-Host "  ℹ️  $Message" -ForegroundColor White
}
#endregion

# ---------------------------------------------------------------------------
# Required permissions to grant as Application permissions on Microsoft Graph
# ---------------------------------------------------------------------------
$requiredPermissions = @(
    @{ Name = 'TenantConfiguration.ReadWrite.All'; Purpose = 'Core UTCM access'                     }
    @{ Name = 'Policy.Read.All';                   Purpose = 'Read Conditional Access, auth policies' }
    @{ Name = 'Policy.ReadWrite.ConditionalAccess'; Purpose = 'Manage CA policies'                   }
    @{ Name = 'Policy.ReadWrite.AuthenticationMethod'; Purpose = 'Manage auth methods'               }
    @{ Name = 'User.Read.All';                     Purpose = 'Read user properties'                  }
    @{ Name = 'Group.Read.All';                    Purpose = 'Read group properties'                 }
    @{ Name = 'RoleManagement.Read.All';           Purpose = 'Read role assignments'                 }
)

$GRAPH_APP_ID = '00000003-0000-0000-c000-000000000000'  # Microsoft Graph

# ---------------------------------------------------------------------------
# Step 0 — Module check
# ---------------------------------------------------------------------------
Write-Step "Checking required PowerShell modules..."
$requiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Applications'
)
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Warn "$mod not found. Installing from PSGallery..."
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber
    }
    else {
        Write-Success "$mod is available."
    }
}

# ---------------------------------------------------------------------------
# Step 0 — Connect (interactive; needs Application.ReadWrite.All + consent scope)
# ---------------------------------------------------------------------------
Write-Step "Connecting to Microsoft Graph (interactive)..."
Connect-MgGraph -Scopes @(
    'Application.ReadWrite.All',
    'AppRoleAssignment.ReadWrite.All'
) -NoWelcome
Write-Success "Connected."

$context  = Get-MgContext
$tenantId = $context.TenantId
Write-Info "Tenant ID : $tenantId"

# ---------------------------------------------------------------------------
# Step 1 — Create App Registration
# ---------------------------------------------------------------------------
Write-Step "Step 1/3 · Creating App Registration '$AppName'..."

$existingApp = Get-MgApplication -Filter "DisplayName eq '$AppName'" -ErrorAction SilentlyContinue |
               Select-Object -First 1

if ($existingApp) {
    Write-Warn "An app named '$AppName' already exists (App ID: $($existingApp.AppId)). Using existing app."
    $app = $existingApp
}
else {
    $app = New-MgApplication -DisplayName $AppName `
               -SignInAudience 'AzureADMyOrg'  # Single tenant
    Write-Success "Created App Registration."
}

$clientId = $app.AppId
$objectId = $app.Id
Write-Info "App (Client) ID : $clientId"
Write-Info "Object ID       : $objectId"

# Ensure a service principal exists for the app (needed for role assignments)
$sp = Get-MgServicePrincipal -Filter "AppId eq '$clientId'" -ErrorAction SilentlyContinue
if (-not $sp) {
    Write-Step "Creating service principal for the app..."
    $sp = New-MgServicePrincipal -AppId $clientId
    Write-Success "Service principal created (Object ID: $($sp.Id))."
}

# ---------------------------------------------------------------------------
# Step 2 — Create client secret
# ---------------------------------------------------------------------------
Write-Step "Step 2/3 · Creating client secret '$SecretDisplayName'..."

$secretExpiry = (Get-Date).AddYears($SecretExpiryYears).ToString('yyyy-MM-ddT00:00:00Z')

$secretParams = @{
    PasswordCredential = @{
        DisplayName = $SecretDisplayName
        EndDateTime = $secretExpiry
    }
}

$secretResult = Add-MgApplicationPassword -ApplicationId $objectId -BodyParameter $secretParams
$clientSecret = $secretResult.SecretText

Write-Success "Client secret created. Expires: $secretExpiry"
Write-Host "`n  ⚠️  SAVE THIS NOW — it will not be shown again:" -ForegroundColor Yellow
Write-Host "  AZURE_CLIENT_SECRET = $clientSecret" -ForegroundColor Magenta

# ---------------------------------------------------------------------------
# Step 3 — Grant Microsoft Graph application permissions
# ---------------------------------------------------------------------------
Write-Step "Step 3/3 · Granting Microsoft Graph application permissions..."

# Resolve Graph service principal (needed to look up AppRole IDs)
$graphSP = Get-MgServicePrincipal -Filter "AppId eq '$GRAPH_APP_ID'"

# Build the required resource-access list for the app manifest
$resourceAccess = foreach ($perm in $requiredPermissions) {
    $appRole = $graphSP.AppRoles | Where-Object { $_.Value -eq $perm.Name }
    if (-not $appRole) {
        Write-Warn "Permission '$($perm.Name)' not found on Microsoft Graph — skipping."
        continue
    }
    [PSCustomObject]@{
        Id   = $appRole.Id
        Type = 'Role'   # 'Role' = Application permission; 'Scope' = Delegated
    }
}

# Update the app registration's requiredResourceAccess
$requiredResourceAccessBody = @{
    ResourceAppId  = $GRAPH_APP_ID
    ResourceAccess = @($resourceAccess | ForEach-Object { @{ Id = $_.Id; Type = $_.Type } })
}

Update-MgApplication -ApplicationId $objectId `
    -RequiredResourceAccess @($requiredResourceAccessBody)

Write-Success "Permissions added to app manifest."

# Grant admin consent by creating app-role assignments on the service principal
$existingAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id

foreach ($perm in $requiredPermissions) {
    $appRole = $graphSP.AppRoles | Where-Object { $_.Value -eq $perm.Name }
    if (-not $appRole) { continue }

    $alreadyGranted = $existingAssignments | Where-Object { $_.AppRoleId -eq $appRole.Id }
    if ($alreadyGranted) {
        Write-Warn "'$($perm.Name)' already consented. Skipping."
        continue
    }

    $body = @{
        AppRoleId   = $appRole.Id
        ResourceId  = $graphSP.Id
        PrincipalId = $sp.Id
    }
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -BodyParameter $body | Out-Null
    Write-Success "Granted + consented: $($perm.Name)  ($($perm.Purpose))"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host "🎉 App Registration setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Add these as GitHub Actions secrets" -ForegroundColor White
Write-Host "  (Repo → Settings → Secrets and variables → Actions):" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  AZURE_TENANT_ID     = $tenantId"     -ForegroundColor Cyan
Write-Host "  AZURE_CLIENT_ID     = $clientId"     -ForegroundColor Cyan
Write-Host "  AZURE_CLIENT_SECRET = $clientSecret" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Secret expires: $secretExpiry" -ForegroundColor DarkGray
Write-Host "  ⚠️  Set a calendar reminder to rotate the secret before expiry!" -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Next step: Run Setup-UTCM.ps1 to add the UTCM service principal." -ForegroundColor White
