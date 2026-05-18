#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Unit tests for scripts/helpers/Auth.ps1
#>

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'helpers' 'Auth.ps1'
    . $scriptPath
}

Describe 'Get-OidcToken' -Tag 'Unit', 'Auth' {
    BeforeEach {
        $env:ACTIONS_ID_TOKEN_REQUEST_URL = $null
        $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = $null
    }

    It 'Should return null when OIDC environment is not available' {
        $token = Get-OidcToken -TenantId 'tenant-id' -ClientId 'client-id'
        $token | Should -BeNullOrEmpty
    }

    It 'Should acquire and exchange OIDC token successfully' {
        $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://token.actions.githubusercontent.com/_apis/oidc/token'
        $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'request-token'

        Mock Invoke-RestMethod {
            param($Method)
            if ($Method -eq 'Get') {
                return @{ value = 'github-oidc-token' }
            }
            return @{ access_token = 'azure-access-token' }
        }

        $token = Get-OidcToken -TenantId 'tenant-id' -ClientId 'client-id'

        $token | Should -Be 'azure-access-token'
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Method -eq 'Get' -and $Uri -match 'audience=api://AzureADTokenExchange' }
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Method -eq 'Post' -and $Body.client_assertion -eq 'github-oidc-token' }
    }

    It 'Should return null when OIDC acquisition fails' {
        $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://token.actions.githubusercontent.com/_apis/oidc/token'
        $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'request-token'
        Mock Invoke-RestMethod { throw 'OIDC request failed' }

        $token = Get-OidcToken -TenantId 'tenant-id' -ClientId 'client-id'

        $token | Should -BeNullOrEmpty
    }
}

Describe 'Get-GraphAccessToken' -Tag 'Unit', 'Auth' {

    BeforeEach {
        # Clear environment variables before each test
        $env:AZURE_TENANT_ID = $null
        $env:AZURE_CLIENT_ID = $null
        $env:AZURE_CLIENT_SECRET = $null
        $env:USE_OIDC = $null
        $env:ACTIONS_ID_TOKEN_REQUEST_URL = $null
        $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = $null
    }

    Context 'When credentials are provided via parameters' {

        It 'Should request token from correct endpoint' {
            # Arrange
            Mock Invoke-RestMethod {
                return @{ access_token = 'mock-token-12345' }
            }

            # Act
            $token = Get-GraphAccessToken -TenantId 'test-tenant' -ClientId 'test-client' -ClientSecret 'test-secret'

            # Assert
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -eq 'https://login.microsoftonline.com/test-tenant/oauth2/v2.0/token'
            }
        }

        It 'Should return the access token' {
            # Arrange
            Mock Invoke-RestMethod {
                return @{ access_token = 'expected-token-value' }
            }

            # Act
            $token = Get-GraphAccessToken -TenantId 'test-tenant' -ClientId 'test-client' -ClientSecret 'test-secret'

            # Assert
            $token | Should -Be 'expected-token-value'
        }

        It 'Should use client_credentials grant type' {
            # Arrange
            Mock Invoke-RestMethod {
                param($Body)
                return @{ access_token = 'mock-token' }
            }

            # Act
            Get-GraphAccessToken -TenantId 'test-tenant' -ClientId 'test-client' -ClientSecret 'test-secret'

            # Assert
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Body.grant_type -eq 'client_credentials'
            }
        }

        It 'Should request Graph API default scope' {
            # Arrange
            Mock Invoke-RestMethod {
                param($Body)
                return @{ access_token = 'mock-token' }
            }

            # Act
            Get-GraphAccessToken -TenantId 'test-tenant' -ClientId 'test-client' -ClientSecret 'test-secret'

            # Assert
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Body.scope -eq 'https://graph.microsoft.com/.default'
            }
        }
    }

    Context 'When credentials are provided via environment variables' {

        It 'Should use environment variables when parameters are empty' {
            # Arrange
            $env:AZURE_TENANT_ID = 'env-tenant-id'
            $env:AZURE_CLIENT_ID = 'env-client-id'
            $env:AZURE_CLIENT_SECRET = 'env-client-secret'

            Mock Invoke-RestMethod {
                return @{ access_token = 'mock-token' }
            }

            # Act
            $token = Get-GraphAccessToken

            # Assert
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -like '*env-tenant-id*'
            }
        }
    }

    Context 'When credentials are missing' {

        It 'Should throw when no credentials available' {
            # Arrange - ensure no .env file interferes
            Mock Test-Path { return $false } -ParameterFilter { $Path -like '*.env' }

            # Act & Assert
            { Get-GraphAccessToken } | Should -Throw '*Missing credentials*'
        }

        It 'Should throw when client secret is missing and OIDC is disabled' {
            # Arrange
            $env:AZURE_TENANT_ID = 'tenant-id'
            $env:AZURE_CLIENT_ID = 'client-id'
            $env:AZURE_CLIENT_SECRET = $null
            $env:USE_OIDC = 'false'
            Mock Test-Path { return $false } -ParameterFilter { $Path -like '*.env' }

            # Act & Assert
            { Get-GraphAccessToken } | Should -Throw '*Missing AZURE_CLIENT_SECRET*'
        }
    }

    Context 'When .env file exists' {

        It 'Should load credentials from .env file' {
            # Arrange
            $envContent = @'
AZURE_TENANT_ID=file-tenant-id
AZURE_CLIENT_ID=file-client-id
AZURE_CLIENT_SECRET=file-client-secret
'@
            Mock Test-Path { return $true } -ParameterFilter { $Path -like '*.env' }
            Mock Get-Content { return $envContent -split "`n" } -ParameterFilter { $Path -like '*.env' }
            Mock Invoke-RestMethod { return @{ access_token = 'mock-token' } }

            # Act
            $token = Get-GraphAccessToken

            # Assert
            $token | Should -Be 'mock-token'
        }

        It 'Should ignore comment lines in .env file' {
            # Arrange
            $envContent = @'
# This is a comment
AZURE_TENANT_ID=file-tenant-id
# Another comment
AZURE_CLIENT_ID=file-client-id
AZURE_CLIENT_SECRET=file-client-secret
'@
            Mock Test-Path { return $true } -ParameterFilter { $Path -like '*.env' }
            Mock Get-Content { return $envContent -split "`n" } -ParameterFilter { $Path -like '*.env' }
            Mock Invoke-RestMethod { return @{ access_token = 'mock-token' } }

            # Act & Assert (should not throw)
            { Get-GraphAccessToken } | Should -Not -Throw
        }
    }

    Context 'When OIDC is enabled' {
        It 'Should return OIDC token without client secret' {
            Mock Get-OidcToken { return 'oidc-token-value' }

            $token = Get-GraphAccessToken -TenantId 'tenant-id' -ClientId 'client-id' -ClientSecret '' -UseOidc $true

            $token | Should -Be 'oidc-token-value'
            Should -Invoke Get-OidcToken -Times 1
        }

        It 'Should fall back to client secret when OIDC returns null' {
            Mock Get-OidcToken { return $null }
            Mock Invoke-RestMethod { return @{ access_token = 'fallback-token' } }

            $token = Get-GraphAccessToken -TenantId 'tenant-id' -ClientId 'client-id' -ClientSecret 'secret' -UseOidc $true

            $token | Should -Be 'fallback-token'
            Should -Invoke Get-OidcToken -Times 1
            Should -Invoke Invoke-RestMethod -Times 1
        }
    }
}

Describe 'Invoke-GraphRequest' -Tag 'Unit', 'Auth' {

    BeforeAll {
        # Mock Get-GraphAccessToken for all tests in this block
        Mock Get-GraphAccessToken { return 'mock-bearer-token' }
    }

    Context 'When making GET requests' {

        It 'Should call the correct Graph API endpoint' {
            # Arrange
            Mock Invoke-RestMethod {
                return @{ value = @() }
            }

            # Act
            Invoke-GraphRequest -Endpoint '/users' -Token 'test-token'

            # Assert
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -eq 'https://graph.microsoft.com/beta/users'
            }
        }

        It 'Should include Bearer token in Authorization header' {
            # Arrange
            Mock Invoke-RestMethod {
                param($Headers)
                return @{ value = @() }
            }

            # Act
            Invoke-GraphRequest -Endpoint '/users' -Token 'my-secret-token'

            # Assert
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Headers.Authorization -eq 'Bearer my-secret-token'
            }
        }

        It 'Should default to GET method' {
            # Arrange
            Mock Invoke-RestMethod { return @{} }

            # Act
            Invoke-GraphRequest -Endpoint '/test' -Token 'token'

            # Assert
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'GET'
            }
        }
    }

    Context 'When making POST requests with body' {

        It 'Should serialize body to JSON' {
            # Arrange
            Mock Invoke-RestMethod {
                param($Body)
                return @{ id = 'new-resource' }
            }

            $requestBody = @{
                displayName = 'Test Resource'
                enabled = $true
            }

            # Act
            Invoke-GraphRequest -Method POST -Endpoint '/resources' -Body $requestBody -Token 'token'

            # Assert
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Body -ne $null -and $Body -match '"displayName"'
            }
        }

        It 'Should set Content-Type to application/json' {
            # Arrange
            Mock Invoke-RestMethod { return @{} }

            # Act
            Invoke-GraphRequest -Method POST -Endpoint '/resources' -Body @{} -Token 'token'

            # Assert
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Headers.'Content-Type' -eq 'application/json'
            }
        }
    }

    Context 'When token is not provided' {

        It 'Should automatically acquire token' {
            # Arrange
            Mock Invoke-RestMethod { return @{} }
            Mock Get-GraphAccessToken { return 'auto-acquired-token' }

            # Act
            Invoke-GraphRequest -Endpoint '/test'

            # Assert
            Should -Invoke Get-GraphAccessToken -Times 1
        }
    }

    Context 'When Graph API returns an error' {
        It 'Should throw a formatted Graph API error message' {
            $exception = [System.Exception]::new('request failed')
            Add-Member -InputObject $exception -MemberType NoteProperty -Name Response -Value ([PSCustomObject]@{
                StatusCode = [PSCustomObject]@{ value__ = 429 }
            }) -Force

            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                $exception,
                'GraphError',
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                $null
            )
            $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('Too Many Requests')

            Mock Invoke-RestMethod { throw $errorRecord }

            {
                Invoke-GraphRequest -Endpoint '/test' -Token 'token'
            } | Should -Throw '*Graph API error*429*Too Many Requests*'
        }
    }
}
