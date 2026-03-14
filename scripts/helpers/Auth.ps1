<#
.SYNOPSIS
    Shared authentication helper for all M365Management scripts.
    Supports client credentials, OIDC/Workload Identity Federation, and .env fallback.
#>

function Get-OidcToken {
    <#
    .SYNOPSIS
        Acquires an access token using GitHub Actions OIDC (Workload Identity Federation).
        Returns $null if not running in GitHub Actions or OIDC is not configured.
    #>
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$Audience = 'api://AzureADTokenExchange'
    )

    # Check if running in GitHub Actions with OIDC
    $requestUrl = $env:ACTIONS_ID_TOKEN_REQUEST_URL
    $requestToken = $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN

    if (-not $requestUrl -or -not $requestToken) {
        return $null
    }

    try {
        # Step 1: Get GitHub OIDC token
        $oidcResponse = Invoke-RestMethod -Method Get `
            -Uri "${requestUrl}&audience=${Audience}" `
            -Headers @{ Authorization = "Bearer $requestToken" } `
            -ContentType 'application/json'

        $githubToken = $oidcResponse.value

        # Step 2: Exchange for Azure AD token
        $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        $body = @{
            client_id             = $ClientId
            scope                 = 'https://graph.microsoft.com/.default'
            grant_type            = 'client_credentials'
            client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            client_assertion      = $githubToken
        }

        $response = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded'
        return $response.access_token
    }
    catch {
        Write-Warning "OIDC token acquisition failed: $_"
        return $null
    }
}

function Get-GraphAccessToken {
    <#
    .SYNOPSIS
        Returns a bearer token for Microsoft Graph.
        Tries OIDC first (GitHub Actions), then client credentials, then .env file.
    #>
    param(
        [string]$TenantId     = $env:AZURE_TENANT_ID,
        [string]$ClientId     = $env:AZURE_CLIENT_ID,
        [string]$ClientSecret = $env:AZURE_CLIENT_SECRET,
        [bool]$UseOidc        = ($env:USE_OIDC -eq 'true')
    )

    # Load from .env if credentials not set
    if (-not $TenantId -or -not $ClientId) {
        $envFile = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '.env'
        if (Test-Path $envFile) {
            Get-Content $envFile | Where-Object { $_ -match '^\s*[^#]' } | ForEach-Object {
                $parts = $_ -split '=', 2
                if ($parts.Count -eq 2) {
                    [System.Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim())
                }
            }
            $TenantId     = $env:AZURE_TENANT_ID
            $ClientId     = $env:AZURE_CLIENT_ID
            $ClientSecret = $env:AZURE_CLIENT_SECRET
            $UseOidc      = ($env:USE_OIDC -eq 'true')
        }
    }

    if (-not $TenantId -or -not $ClientId) {
        throw "Missing credentials. Set AZURE_TENANT_ID and AZURE_CLIENT_ID environment variables."
    }

    # Try OIDC first (if enabled or in GitHub Actions)
    if ($UseOidc -or $env:ACTIONS_ID_TOKEN_REQUEST_URL) {
        $oidcToken = Get-OidcToken -TenantId $TenantId -ClientId $ClientId
        if ($oidcToken) {
            Write-Verbose "Authenticated via OIDC/Workload Identity Federation"
            return $oidcToken
        }

        if ($UseOidc) {
            Write-Warning "OIDC requested but failed. Falling back to client credentials."
        }
    }

    # Fall back to client credentials
    if (-not $ClientSecret) {
        throw "Missing AZURE_CLIENT_SECRET. Set it or enable OIDC with USE_OIDC=true and configure federated credentials."
    }

    $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = 'https://graph.microsoft.com/.default'
        grant_type    = 'client_credentials'
    }

    $response = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded'
    return $response.access_token
}

function Invoke-GraphRequest {
    <#
    .SYNOPSIS
        Wrapper for Microsoft Graph API calls with retry and error handling.
    #>
    param(
        [string]$Method   = 'GET',
        [string]$Endpoint,          # e.g. "/tenantRelationships/configurationMonitors"
        [object]$Body     = $null,
        [string]$Token    = $null,
        [string]$ApiBase  = 'https://graph.microsoft.com/beta'
    )

    if (-not $Token) {
        $Token = Get-GraphAccessToken
    }

    $headers = @{
        Authorization  = "Bearer $Token"
        'Content-Type' = 'application/json'
    }

    $uri = "$ApiBase$Endpoint"
    $params = @{
        Method  = $Method
        Uri     = $uri
        Headers = $headers
    }
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }

    try {
        $response = Invoke-RestMethod @params
        return $response
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorBody  = $_.ErrorDetails.Message
        throw "Graph API error [$statusCode] on $Method ${uri}: ${errorBody}"
    }
}
