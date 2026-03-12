#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Unit tests for scripts/Validate-Schema.ps1
#>

BeforeAll {
    $repoRoot = Join-Path $PSScriptRoot '..' '..'
    $validateScript = Join-Path $repoRoot 'scripts' 'Validate-Schema.ps1'
}

Describe 'Validate-Schema.ps1' -Tag 'Unit', 'Schema' {

    BeforeAll {
        # Create a temp directory for test fixtures
        $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "M365Test_$(Get-Random)"
        New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null

        # Create mock schema
        $script:schemaPath = Join-Path $script:tempDir 'config.schema.json'
        @{
            '$schema' = 'https://json-schema.org/draft/2020-12/schema'
            type = 'object'
            required = @('resources')
        } | ConvertTo-Json | Set-Content $script:schemaPath
    }

    AfterAll {
        # Cleanup temp directory
        if (Test-Path $script:tempDir) {
            Remove-Item $script:tempDir -Recurse -Force
        }
    }

    Context 'Valid configuration files' {

        It 'Should pass for valid YAML with all required fields' {
            # Arrange
            $validYaml = @'
resources:
  - resourceType: microsoft.entra.conditionalaccesspolicy
    properties:
      Id: "12345678-1234-1234-1234-123456789012"
      DisplayName: "Test Policy"
      State: enabled
      Ensure: Present
'@
            $testFile = Join-Path $script:tempDir 'valid.yaml'
            $validYaml | Set-Content $testFile

            # Need powershell-yaml module for this test
            if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
                return
            }

            # Act
            $result = & $validateScript -Path $testFile -SchemaPath (Join-Path $repoRoot 'schemas' 'config.schema.json') 2>&1

            # Assert
            $LASTEXITCODE | Should -Be 0
        }

        It 'Should accept multiple resources in a single file' {
            # Arrange
            $multiResourceYaml = @'
resources:
  - resourceType: microsoft.entra.conditionalaccesspolicy
    properties:
      Id: "11111111-1111-1111-1111-111111111111"
      DisplayName: "Policy One"
      State: enabled
      Ensure: Present
  - resourceType: microsoft.entra.conditionalaccesspolicy
    properties:
      Id: "22222222-2222-2222-2222-222222222222"
      DisplayName: "Policy Two"
      State: disabled
      Ensure: Present
'@
            $testFile = Join-Path $script:tempDir 'multi.yaml'
            $multiResourceYaml | Set-Content $testFile

            if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
                return
            }

            # Act
            $result = & $validateScript -Path $testFile -SchemaPath (Join-Path $repoRoot 'schemas' 'config.schema.json') 2>&1

            # Assert
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context 'Invalid configuration files' {

        It 'Should fail when resources array is missing' {
            # Arrange
            $invalidYaml = @'
notResources:
  - something: else
'@
            $testFile = Join-Path $script:tempDir 'missing-resources.yaml'
            $invalidYaml | Set-Content $testFile

            if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
                return
            }

            # Act
            & $validateScript -Path $testFile -SchemaPath (Join-Path $repoRoot 'schemas' 'config.schema.json') 2>&1 | Out-Null

            # Assert
            $LASTEXITCODE | Should -Be 1
        }

        It 'Should fail when resourceType is missing' {
            # Arrange
            $invalidYaml = @'
resources:
  - properties:
      Id: "12345678-1234-1234-1234-123456789012"
      DisplayName: "Test"
'@
            $testFile = Join-Path $script:tempDir 'missing-resourcetype.yaml'
            $invalidYaml | Set-Content $testFile

            if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
                return
            }

            # Act
            & $validateScript -Path $testFile -SchemaPath (Join-Path $repoRoot 'schemas' 'config.schema.json') 2>&1 | Out-Null

            # Assert
            $LASTEXITCODE | Should -Be 1
        }

        It 'Should fail when resourceType has invalid format' {
            # Arrange
            $invalidYaml = @'
resources:
  - resourceType: InvalidFormat
    properties:
      DisplayName: "Test"
'@
            $testFile = Join-Path $script:tempDir 'invalid-format.yaml'
            $invalidYaml | Set-Content $testFile

            if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
                return
            }

            # Act
            & $validateScript -Path $testFile -SchemaPath (Join-Path $repoRoot 'schemas' 'config.schema.json') 2>&1 | Out-Null

            # Assert
            $LASTEXITCODE | Should -Be 1
        }

        It 'Should fail when Id is not a valid GUID' {
            # Arrange
            $invalidYaml = @'
resources:
  - resourceType: microsoft.entra.conditionalaccesspolicy
    properties:
      Id: "not-a-valid-guid"
      DisplayName: "Test"
'@
            $testFile = Join-Path $script:tempDir 'invalid-guid.yaml'
            $invalidYaml | Set-Content $testFile

            if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
                return
            }

            # Act
            & $validateScript -Path $testFile -SchemaPath (Join-Path $repoRoot 'schemas' 'config.schema.json') 2>&1 | Out-Null

            # Assert
            $LASTEXITCODE | Should -Be 1
        }

        It 'Should fail when State has invalid value' {
            # Arrange
            $invalidYaml = @'
resources:
  - resourceType: microsoft.entra.conditionalaccesspolicy
    properties:
      Id: "12345678-1234-1234-1234-123456789012"
      State: invalid_state
'@
            $testFile = Join-Path $script:tempDir 'invalid-state.yaml'
            $invalidYaml | Set-Content $testFile

            if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
                return
            }

            # Act
            & $validateScript -Path $testFile -SchemaPath (Join-Path $repoRoot 'schemas' 'config.schema.json') 2>&1 | Out-Null

            # Assert
            $LASTEXITCODE | Should -Be 1
        }

        It 'Should fail when Ensure has invalid value' {
            # Arrange
            $invalidYaml = @'
resources:
  - resourceType: microsoft.entra.conditionalaccesspolicy
    properties:
      Id: "12345678-1234-1234-1234-123456789012"
      Ensure: Maybe
'@
            $testFile = Join-Path $script:tempDir 'invalid-ensure.yaml'
            $invalidYaml | Set-Content $testFile

            if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
                return
            }

            # Act
            & $validateScript -Path $testFile -SchemaPath (Join-Path $repoRoot 'schemas' 'config.schema.json') 2>&1 | Out-Null

            # Assert
            $LASTEXITCODE | Should -Be 1
        }
    }

    Context 'Unknown properties (permissive mode)' {

        It 'Should warn but pass when unknown properties are present' {
            # Arrange
            $yamlWithUnknown = @'
resources:
  - resourceType: microsoft.entra.conditionalaccesspolicy
    properties:
      Id: "12345678-1234-1234-1234-123456789012"
      DisplayName: "Test"
      State: enabled
      Ensure: Present
      UnknownProperty: "should warn"
'@
            $testFile = Join-Path $script:tempDir 'unknown-props.yaml'
            $yamlWithUnknown | Set-Content $testFile

            if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
                return
            }

            # Act
            $output = & $validateScript -Path $testFile -SchemaPath (Join-Path $repoRoot 'schemas' 'config.schema.json') 2>&1

            # Assert - should pass (exit 0) but contain warning
            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Match 'Unknown property'
        }

        It 'Should fail in strict mode when unknown properties are present' {
            # Arrange
            $yamlWithUnknown = @'
resources:
  - resourceType: microsoft.entra.conditionalaccesspolicy
    properties:
      Id: "12345678-1234-1234-1234-123456789012"
      DisplayName: "Test"
      State: enabled
      Ensure: Present
      UnknownProperty: "should fail in strict"
'@
            $testFile = Join-Path $script:tempDir 'unknown-strict.yaml'
            $yamlWithUnknown | Set-Content $testFile

            if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                Set-ItResult -Skipped -Because 'powershell-yaml module not installed'
                return
            }

            # Act
            & $validateScript -Path $testFile -Strict -SchemaPath (Join-Path $repoRoot 'schemas' 'config.schema.json') 2>&1 | Out-Null

            # Assert
            $LASTEXITCODE | Should -Be 1
        }
    }
}
