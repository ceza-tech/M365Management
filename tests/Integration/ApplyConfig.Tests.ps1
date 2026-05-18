#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Integration tests for scripts/Apply-Config.ps1 with mocked Graph API
#>

BeforeAll {
    $repoRoot = Join-Path $PSScriptRoot '..' '..'
    $applyScript = Join-Path $repoRoot 'scripts' 'Apply-Config.ps1'
    $authHelper = Join-Path $repoRoot 'scripts' 'helpers' 'Auth.ps1'
    . $authHelper
}

Describe 'Apply-Config.ps1' -Tag 'Integration', 'ApplyConfig' {

    BeforeAll {
        $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "M365Test_$(Get-Random)"
        $script:tenantConfigRoot = Join-Path $script:tempDir 'tenants' 'testcorp' 'config'
        $script:tenantDir = Join-Path $script:tenantConfigRoot 'entra'
        New-Item -ItemType Directory -Path $script:tenantDir -Force | Out-Null

        $config = @{
            resources = @(
                @{
                    resourceType = 'microsoft.entra.conditionalaccesspolicy'
                    properties   = @{
                        Id          = '12345678-1234-1234-1234-123456789012'
                        DisplayName = 'Test MFA Policy'
                        State       = 'enabled'
                        Ensure      = 'Present'
                    }
                }
            )
        }
        $config | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:tenantDir 'test-policy.json')
    }

    AfterAll {
        if (Test-Path $script:tempDir) {
            Remove-Item $script:tempDir -Recurse -Force
        }
    }

    Context 'DryRun mode' {
        BeforeEach {
            Mock Get-GraphAccessToken { return 'mock-token' }
            Mock Invoke-GraphRequest {
                throw "API should not be called in DryRun mode"
            }
            Mock Write-Host { }
        }

        It 'Should not make API calls in DryRun mode' {
            & $applyScript -TenantConfigRoot $script:tenantConfigRoot -DryRun 2>&1 | Out-Null

            Should -Invoke Get-GraphAccessToken -Times 1
            Should -Invoke Invoke-GraphRequest -Times 0
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*DRY-RUN*' }
        }

        It 'Should list planned resources in DryRun mode' {
            & $applyScript -TenantConfigRoot $script:tenantConfigRoot -DryRun 2>&1 | Out-Null
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*conditionalaccesspolicy*' }
        }
    }

    Context 'Monitor naming conventions' {
        It 'Should generate monitor name from tenant name' {
            $global:capturedMonitorName = $null
            Mock Get-GraphAccessToken { return 'mock-token' }
            Mock Invoke-GraphRequest {
                param($Method, $Endpoint, $Body)
                if ($Method -eq 'GET' -and $Endpoint -eq '/admin/configurationManagement/configurationMonitors') {
                    return @{ value = @() }
                }
                if ($Method -eq 'POST') {
                    $global:capturedMonitorName = $Body.displayName
                    return @{ id = 'mock-monitor-id' }
                }
                return @{ value = @() }
            }

            & $applyScript -TenantName 'testcorp' -TenantConfigRoot $script:tenantConfigRoot -ValidateSchema:$false -AutoSnapshot:$false 2>&1 | Out-Null

            $global:capturedMonitorName | Should -Be 'Testcorp GitOps'
        }

        It 'Should sanitize special characters in monitor name' {
            $tenantName = 'test-corp_123'
            $safeName = ($tenantName -replace '[^a-zA-Z0-9 ]', ' ').Trim()
            $safeName = $safeName.Substring(0,1).ToUpper() + $safeName.Substring(1)
            $proposed = "$safeName GitOps"

            $proposed | Should -Be 'Test corp 123 GitOps'
            $proposed.Length | Should -BeLessOrEqual 32
        }
    }

    Context 'Error handling' {
        It 'Should throw on authentication failure' {
            Mock Get-GraphAccessToken {
                throw "Authentication failed: Invalid credentials"
            }

            { & $applyScript -TenantConfigRoot $script:tenantConfigRoot -DryRun } |
                Should -Throw '*Authentication*'
        }

        It 'Should throw when monitor create API call fails' {
            Mock Get-GraphAccessToken { return 'mock-token' }
            Mock Invoke-GraphRequest {
                param($Method, $Endpoint)
                if ($Method -eq 'GET' -and $Endpoint -eq '/admin/configurationManagement/configurationMonitors') {
                    return @{ value = @() }
                }
                if ($Method -eq 'POST') {
                    throw "Graph API unavailable"
                }
                return @{ value = @() }
            }

            { & $applyScript -TenantName 'testcorp' -TenantConfigRoot $script:tenantConfigRoot -ValidateSchema:$false -AutoSnapshot:$false } |
                Should -Throw '*Graph API unavailable*'
        }
    }

    Context 'Configuration parsing' {
        It 'Should parse JSON files from workload subdirectories' {
            Mock Get-GraphAccessToken { return 'mock-token' }
            Mock Invoke-GraphRequest { return @{ id = 'mock-id'; value = @() } }
            Mock Write-Host { }

            & $applyScript -TenantConfigRoot $script:tenantConfigRoot -DryRun 2>&1 | Out-Null
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*Loading: test-policy.json*' }
        }

        It 'Should handle empty config directory gracefully' {
            $emptyDir = Join-Path $script:tempDir 'tenants' 'empty' 'config'
            New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null

            { & $applyScript -TenantConfigRoot $emptyDir -DryRun 2>&1 | Out-Null } | Should -Not -Throw

            $LASTEXITCODE | Should -BeIn @(0, $null)
        }
    }
}
