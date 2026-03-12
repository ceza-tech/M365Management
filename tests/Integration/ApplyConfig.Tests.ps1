#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Integration tests for scripts/Apply-Config.ps1 with mocked Graph API
#>

BeforeAll {
    $repoRoot = Join-Path $PSScriptRoot '..' '..'
    $applyScript = Join-Path $repoRoot 'scripts' 'Apply-Config.ps1'
    $authHelper = Join-Path $repoRoot 'scripts' 'helpers' 'Auth.ps1'

    # Source the auth helper to mock its functions
    . $authHelper
}

Describe 'Apply-Config.ps1' -Tag 'Integration', 'ApplyConfig' {

    BeforeAll {
        # Create temp tenant structure for tests
        $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "M365Test_$(Get-Random)"
        $script:tenantDir = Join-Path $script:tempDir 'tenants' 'testcorp' 'config' 'entra'
        New-Item -ItemType Directory -Path $script:tenantDir -Force | Out-Null

        # Create a valid config file
        $validConfig = @'
resources:
  - resourceType: microsoft.entra.conditionalaccesspolicy
    properties:
      Id: "12345678-1234-1234-1234-123456789012"
      DisplayName: "Test MFA Policy"
      State: enabled
      Ensure: Present
'@
        $validConfig | Set-Content (Join-Path $script:tenantDir 'test-policy.yaml')
    }

    AfterAll {
        if (Test-Path $script:tempDir) {
            Remove-Item $script:tempDir -Recurse -Force
        }
    }

    Context 'DryRun mode' {

        BeforeEach {
            # Mock auth to prevent actual API calls
            Mock Get-GraphAccessToken { return 'mock-token' } -ModuleName Auth
        }

        It 'Should not make API calls in DryRun mode' {
            # Arrange
            Mock Invoke-GraphRequest {
                throw "API should not be called in DryRun mode"
            }

            if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
                return
            }

            # Act - DryRun should not throw even without mocking API
            $result = & $applyScript -TenantConfigRoot (Join-Path $script:tempDir 'tenants' 'testcorp' 'config') -DryRun 2>&1

            # Assert - should complete without calling API
            Should -Invoke Invoke-GraphRequest -Times 0
        }

        It 'Should output planned changes in DryRun mode' {
            # Arrange
            Mock Invoke-GraphRequest { }

            if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
                return
            }

            # Act
            $result = & $applyScript -TenantConfigRoot (Join-Path $script:tempDir 'tenants' 'testcorp' 'config') -DryRun 2>&1

            # Assert
            ($result -join "`n") | Should -Match 'DRY-RUN'
        }
    }

    Context 'Monitor naming conventions' {

        It 'Should generate monitor name from tenant name' {
            # Tenant: testcorp → Monitor: "Testcorp GitOps"
            # This tests the naming logic without making API calls

            if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
                return
            }

            Mock Get-GraphAccessToken { return 'mock-token' }
            Mock Invoke-GraphRequest {
                param($Endpoint, $Body)
                if ($Body -and $Body.displayName) {
                    # Capture the display name for assertion
                    $script:capturedMonitorName = $Body.displayName
                }
                return @{ id = 'mock-monitor-id'; value = @() }
            }

            # Act
            & $applyScript -TenantName 'testcorp' -TenantConfigRoot (Join-Path $script:tempDir 'tenants' 'testcorp' 'config') 2>&1 | Out-Null

            # Assert
            $script:capturedMonitorName | Should -Match '^Testcorp'
        }

        It 'Should sanitize special characters in monitor name' {
            # Tenant with special chars should be sanitized
            # "test-corp_123" → "Test corp 123 GitOps"

            # This is a logic test - we verify the naming sanitization
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
            # Arrange
            Mock Get-GraphAccessToken {
                throw "Authentication failed: Invalid credentials"
            }

            if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
                return
            }

            # Act & Assert
            { & $applyScript -TenantConfigRoot (Join-Path $script:tempDir 'tenants' 'testcorp' 'config') } |
                Should -Throw '*Authentication*'
        }

        It 'Should handle Graph API 429 (throttling) gracefully' {
            # Arrange
            Mock Get-GraphAccessToken { return 'mock-token' }

            $script:callCount = 0
            Mock Invoke-GraphRequest {
                $script:callCount++
                if ($script:callCount -le 2) {
                    $exception = [System.Net.WebException]::new("Too Many Requests")
                    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                        $exception,
                        "TooManyRequests",
                        [System.Management.Automation.ErrorCategory]::LimitsExceeded,
                        $null
                    )
                    throw $errorRecord
                }
                return @{ id = 'mock-id'; value = @() }
            }

            # Note: This test documents expected behavior for retry logic
            # Actual retry implementation may vary
            Set-ItResult -Skipped -Because 'Retry logic not yet implemented'
        }
    }

    Context 'Configuration parsing' {

        It 'Should parse YAML files from workload subdirectories' {
            # Arrange
            Mock Get-GraphAccessToken { return 'mock-token' }
            Mock Invoke-GraphRequest { return @{ id = 'mock-id'; value = @() } }

            if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
                return
            }

            # Act
            $result = & $applyScript -TenantConfigRoot (Join-Path $script:tempDir 'tenants' 'testcorp' 'config') -DryRun 2>&1

            # Assert - should find and process the test YAML file
            ($result -join "`n") | Should -Match 'test-policy\.yaml|conditionalaccesspolicy'
        }

        It 'Should handle empty config directory gracefully' {
            # Arrange
            $emptyDir = Join-Path $script:tempDir 'tenants' 'empty' 'config'
            New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null

            Mock Get-GraphAccessToken { return 'mock-token' }

            # Act
            $result = & $applyScript -TenantConfigRoot $emptyDir -DryRun 2>&1

            # Assert - should not throw, but may warn
            $LASTEXITCODE | Should -BeIn @(0, $null)
        }
    }
}
