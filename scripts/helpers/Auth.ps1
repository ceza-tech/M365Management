<#
.SYNOPSIS
    Shared authentication helper for all M365Management scripts.
    Supports both interactive (user) and non-interactive (service principal / GitHub Actions) flows.
#>

function Get-GraphAccessToken {
    <#
    .SYNOPSIS
        Returns a bearer token for Microsoft Graph using client credentials.
        Reads from environment variables or a .env file.
    #>
    param(
        [string]$TenantId     = $env:AZURE_TENANT_ID,
        [string]$ClientId     = $env:AZURE_CLIENT_ID,
        [string]$ClientSecret = $env:AZURE_CLIENT_SECRET
    )

    if (-not $TenantId -or -not $ClientId -or -not $ClientSecret) {
        # Try to load from .env in repo root
        $envFile = Join-Path (Split-Path $PSScriptRoot -Parent) '.env'
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
        }
    }

    if (-not $TenantId -or -not $ClientId -or -not $ClientSecret) {
        throw "Missing credentials. Set AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET environment variables or create a .env file."
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
        throw "Graph API error [$statusCode] on $Method $uri: $errorBody"
    }
}
