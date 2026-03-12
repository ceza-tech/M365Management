<#
.SYNOPSIS
    Structured logging helper for M365Management scripts.
    Outputs JSON-formatted log entries for observability.
#>

$script:LogContext = @{}

function Set-LogContext {
    <#
    .SYNOPSIS
        Sets context that will be included in all log entries.
    #>
    param(
        [hashtable]$Context
    )

    foreach ($key in $Context.Keys) {
        $script:LogContext[$key] = $Context[$key]
    }
}

function Clear-LogContext {
    $script:LogContext = @{}
}

function Write-StructuredLog {
    <#
    .SYNOPSIS
        Writes a structured log entry in JSON format.
    #>
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory)]
        [string]$Message,

        [hashtable]$Data = @{},

        [string]$Operation = '',

        [switch]$ToFile,
        [string]$LogFile = ''
    )

    $entry = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        level     = $Level
        message   = $Message
    }

    # Add operation if specified
    if ($Operation) {
        $entry.operation = $Operation
    }

    # Merge global context
    foreach ($key in $script:LogContext.Keys) {
        $entry[$key] = $script:LogContext[$key]
    }

    # Merge call-specific data
    foreach ($key in $Data.Keys) {
        $entry[$key] = $Data[$key]
    }

    $json = $entry | ConvertTo-Json -Compress -Depth 5

    # Console output (also visible in GitHub Actions logs)
    switch ($Level) {
        'DEBUG' { Write-Verbose $json }
        'INFO'  { Write-Host $json }
        'WARN'  { Write-Warning $json }
        'ERROR' { Write-Host $json -ForegroundColor Red }
    }

    # File output
    if ($ToFile -and $LogFile) {
        Add-Content -Path $LogFile -Value $json -Encoding utf8
    }

    # GitHub Actions annotations
    if ($env:GITHUB_ACTIONS) {
        switch ($Level) {
            'WARN'  { Write-Host "::warning::$Message" }
            'ERROR' { Write-Host "::error::$Message" }
        }
    }

    return $entry
}

function Write-GitHubSummary {
    <#
    .SYNOPSIS
        Appends content to the GitHub Actions job summary.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Content
    )

    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Content -Encoding utf8
    }
}

function Write-Metric {
    <#
    .SYNOPSIS
        Records a metric for GitHub Actions or external monitoring.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [double]$Value,

        [string]$Unit = '',

        [hashtable]$Tags = @{}
    )

    $metric = @{
        name      = $Name
        value     = $Value
        unit      = $Unit
        timestamp = (Get-Date).ToString('o')
        tags      = $Tags
    }

    # Log as structured entry
    Write-StructuredLog -Level INFO -Message "metric:$Name=$Value" -Data $metric -Operation 'metric'

    # GitHub Actions output variable (for later steps)
    if ($env:GITHUB_OUTPUT) {
        $safeName = $Name -replace '[^a-zA-Z0-9_]', '_'
        Add-Content -Path $env:GITHUB_OUTPUT -Value "${safeName}=${Value}" -Encoding utf8
    }
}

function Start-Operation {
    <#
    .SYNOPSIS
        Starts timing an operation. Returns a stopwatch.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    Write-StructuredLog -Level INFO -Message "Starting: $Name" -Operation $Name

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    return @{
        Name = $Name
        Stopwatch = $stopwatch
    }
}

function Stop-Operation {
    <#
    .SYNOPSIS
        Stops timing an operation and logs duration.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Operation,

        [ValidateSet('success', 'failure', 'skipped')]
        [string]$Status = 'success'
    )

    $Operation.Stopwatch.Stop()
    $durationMs = $Operation.Stopwatch.ElapsedMilliseconds

    Write-StructuredLog -Level INFO `
        -Message "Completed: $($Operation.Name)" `
        -Operation $Operation.Name `
        -Data @{
            durationMs = $durationMs
            status = $Status
        }

    Write-Metric -Name "$($Operation.Name)_duration_ms" -Value $durationMs -Unit 'milliseconds'

    return $durationMs
}

Export-ModuleMember -Function Set-LogContext, Clear-LogContext, Write-StructuredLog,
    Write-GitHubSummary, Write-Metric, Start-Operation, Stop-Operation
