# Pester v5 configuration for M365Management
# Run with: Invoke-Pester -Configuration (Import-PowerShellDataFile ./pester.config.psd1)

@{
    Run = @{
        Path = './tests'
        Exit = $true
        Throw = $true
    }

    CodeCoverage = @{
        Enabled = $true
        Path = @(
            './scripts/*.ps1',
            './scripts/helpers/*.ps1'
        )
        OutputFormat = 'JaCoCo'
        OutputPath = './tests/coverage/coverage.xml'
        CoveragePercentTarget = 70
    }

    TestResult = @{
        Enabled = $true
        OutputFormat = 'NUnitXml'
        OutputPath = './tests/results/testResults.xml'
    }

    Output = @{
        Verbosity = 'Detailed'
        StackTraceVerbosity = 'Filtered'
        CIFormat = 'Auto'
    }

    Filter = @{
        # Tag = @('Unit', 'Integration')
        # ExcludeTag = @('Slow')
    }

    Should = @{
        ErrorAction = 'Continue'
    }
}
