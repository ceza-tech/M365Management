# PSScriptAnalyzer settings for M365Management
# Reference: https://github.com/PowerShell/PSScriptAnalyzer

@{
    # Severity levels to include
    Severity = @('Error', 'Warning')

    # Rules to exclude
    ExcludeRules = @(
        # Allow Write-Host for CLI output (we use colored output intentionally)
        'PSAvoidUsingWriteHost',

        # Allow positional parameters for common cmdlets
        'PSAvoidUsingPositionalParameters'
    )

    # Rules to include (uncomment to be more selective)
    # IncludeRules = @(
    #     'PSAvoidUsingCmdletAliases',
    #     'PSAvoidUsingPlainTextForPassword',
    #     'PSUseApprovedVerbs'
    # )

    Rules = @{
        # Enforce approved verbs
        PSUseApprovedVerbs = @{
            Enable = $true
        }

        # Check for credential parameters
        PSAvoidUsingPlainTextForPassword = @{
            Enable = $true
        }

        # Require compatible syntax
        PSUseCompatibleSyntax = @{
            Enable = $true
            TargetVersions = @('7.0', '7.4')
        }

        # Align assignment statements
        PSAlignAssignmentStatement = @{
            Enable = $true
            CheckHashtable = $true
        }

        # Use consistent indentation
        PSUseConsistentIndentation = @{
            Enable = $true
            IndentationSize = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            Kind = 'space'
        }

        # Use consistent whitespace
        PSUseConsistentWhitespace = @{
            Enable = $true
            CheckInnerBrace = $true
            CheckOpenBrace = $true
            CheckOpenParen = $true
            CheckOperator = $true
            CheckPipe = $true
            CheckPipeForRedundantWhitespace = $true
            CheckSeparator = $true
            CheckParameter = $false
            IgnoreAssignmentOperatorInsideHashTable = $true
        }

        # Place opening brace on same line
        PSPlaceOpenBrace = @{
            Enable = $true
            OnSameLine = $true
            NewLineAfter = $true
            IgnoreOneLineBlock = $true
        }

        # Place closing brace on new line
        PSPlaceCloseBrace = @{
            Enable = $true
            NewLineAfter = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore = $false
        }
    }
}
