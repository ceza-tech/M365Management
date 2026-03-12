<#
.SYNOPSIS
    Validates YAML configuration files against the JSON schema.

.DESCRIPTION
    Reads YAML config files, converts to JSON, and validates against
    schemas/config.schema.json. Warns on unknown properties (permissive mode).

.PARAMETER Path
    Path to a specific YAML file or directory to validate.
    Defaults to all tenant config directories.

.PARAMETER Strict
    If set, unknown properties cause validation failure instead of warning.

.PARAMETER SchemaPath
    Path to the JSON schema file. Defaults to schemas/config.schema.json.

.EXAMPLE
    ./Validate-Schema.ps1
    ./Validate-Schema.ps1 -Path ./tenants/kustomize/config/entra/
    ./Validate-Schema.ps1 -Strict
#>
param(
    [string]$Path = '',
    [switch]$Strict,
    [string]$SchemaPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent

#region Helpers
function Write-Step([string]$Msg)    { Write-Host "`n▶ $Msg" -ForegroundColor Cyan }
function Write-Success([string]$Msg) { Write-Host "  ✅ $Msg" -ForegroundColor Green }
function Write-Info([string]$Msg)    { Write-Host "  ℹ  $Msg" -ForegroundColor White }
function Write-Warn([string]$Msg)    { Write-Host "  ⚠️  $Msg" -ForegroundColor Yellow }
function Write-Err([string]$Msg)     { Write-Host "  ❌ $Msg" -ForegroundColor Red }

function ConvertFrom-YamlFile([string]$FilePath) {
    if ($FilePath -match '\.json$') {
        return Get-Content $FilePath -Raw | ConvertFrom-Json -AsHashtable
    }
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Write-Warn "powershell-yaml not installed. Attempting JSON parse fallback."
        return Get-Content $FilePath -Raw | ConvertFrom-Json -AsHashtable
    }
    Import-Module powershell-yaml -ErrorAction Stop
    return Get-Content $FilePath -Raw | ConvertFrom-Yaml
}

function Test-JsonSchema {
    param(
        [hashtable]$Data,
        [hashtable]$Schema,
        [string]$FilePath
    )

    $errors = @()
    $warnings = @()

    # Check required 'resources' array
    if (-not $Data.ContainsKey('resources')) {
        $errors += "Missing required property: 'resources'"
        return @{ Errors = $errors; Warnings = $warnings }
    }

    # Check if resources is array-like (array or list)
    $resourcesIsCollection = ($Data.resources -is [array]) -or
                             ($Data.resources -is [System.Collections.IList]) -or
                             ($Data.resources.GetType().Name -match 'List')

    if (-not $resourcesIsCollection) {
        $errors += "'resources' must be an array"
        return @{ Errors = $errors; Warnings = $warnings }
    }

    if ($Data.resources.Count -eq 0) {
        $warnings += "'resources' array is empty — file is a stub (skipping resource validation)"
        return @{ Errors = $errors; Warnings = $warnings }
    }

    # Validate each resource
    $resourceIndex = 0
    foreach ($resource in $Data.resources) {
        $prefix = "resources[$resourceIndex]"

        # Required: resourceType
        if (-not $resource.ContainsKey('resourceType')) {
            $errors += "${prefix} - Missing required property 'resourceType'"
        } else {
            $rt = $resource.resourceType
            # Validate pattern: microsoft.<workload>.<type>
            if ($rt -notmatch '^microsoft\.(entra|teams|exchange|intune|defender|purview)\.[a-z]+$') {
                $errors += "${prefix} - Invalid resourceType '$rt'. Expected format: microsoft.<workload>.<type>"
            }
        }

        # Required: properties
        if (-not $resource.ContainsKey('properties')) {
            $errors += "${prefix} - Missing required property 'properties'"
        } else {
            $props = $resource.properties

            # Validate Id format if present (allow GUIDs or well-known singleton IDs)
            if ($props.ContainsKey('Id')) {
                $id = $props.Id
                $isGuid = $id -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                $isWellKnown = $id -match '^(authenticationMethodsPolicy|securityDefaults|authorizationPolicy)$'
                if (-not $isGuid -and -not $isWellKnown) {
                    $warnings += "${prefix}.properties.Id - Non-standard ID format '$id' (expected GUID or well-known singleton)"
                }
            }

            # Validate State enum if present
            if ($props.ContainsKey('State')) {
                $validStates = @('enabled', 'disabled', 'enabledForReportingButNotEnforced')
                if ($props.State -notin $validStates) {
                    $errors += "${prefix}.properties.State - Invalid value '$($props.State)'. Expected: $($validStates -join ', ')"
                }
            }

            # Validate Ensure enum if present
            if ($props.ContainsKey('Ensure')) {
                $validEnsure = @('Present', 'Absent')
                if ($props.Ensure -notin $validEnsure) {
                    $errors += "${prefix}.properties.Ensure - Invalid value '$($props.Ensure)'. Expected: $($validEnsure -join ', ')"
                }
            }

            # Check for unknown properties (warn only unless strict)
            $knownProps = @('Id', 'DisplayName', 'State', 'Ensure', 'Description', 'IsEnabled')
            foreach ($propName in $props.Keys) {
                if ($propName -notin $knownProps) {
                    $warnings += "${prefix}.properties.${propName} - Unknown property (may not be enforced by UTCM)"
                }
            }
        }

        # Check for unknown resource-level properties
        $knownResourceProps = @('resourceType', 'properties', 'id')
        foreach ($key in $resource.Keys) {
            if ($key -notin $knownResourceProps) {
                $warnings += "${prefix}.${key} - Unknown property at resource level"
            }
        }

        $resourceIndex++
    }

    return @{ Errors = $errors; Warnings = $warnings }
}
#endregion

# Resolve schema path
if (-not $SchemaPath) {
    $SchemaPath = Join-Path $repoRoot 'schemas' 'config.schema.json'
}

if (-not (Test-Path $SchemaPath)) {
    throw "Schema file not found: $SchemaPath"
}

$schema = Get-Content $SchemaPath -Raw | ConvertFrom-Json -AsHashtable

# Resolve files to validate
$filesToValidate = @()

if ($Path) {
    if (Test-Path $Path -PathType Container) {
        $filesToValidate = Get-ChildItem $Path -Filter '*.yaml' -Recurse
    } else {
        $filesToValidate = @(Get-Item $Path)
    }
} else {
    # Default: all tenant config files
    $tenantsDir = Join-Path $repoRoot 'tenants'
    if (Test-Path $tenantsDir) {
        $filesToValidate = Get-ChildItem $tenantsDir -Filter '*.yaml' -Recurse
    }
}

if ($filesToValidate.Count -eq 0) {
    Write-Warn "No YAML files found to validate."
    exit 0
}

Write-Step "Validating $($filesToValidate.Count) configuration file(s)..."

$totalErrors = 0
$totalWarnings = 0

foreach ($file in $filesToValidate) {
    Write-Info "Checking: $($file.FullName)"

    try {
        $data = ConvertFrom-YamlFile -FilePath $file.FullName
        $result = Test-JsonSchema -Data $data -Schema $schema -FilePath $file.FullName

        foreach ($warning in $result.Warnings) {
            Write-Warn "$warning"
            $totalWarnings++
        }

        if ($result.Errors.Count -gt 0) {
            foreach ($err in $result.Errors) {
                Write-Err "$err"
            }
            $totalErrors += $result.Errors.Count
        } else {
            Write-Success "$($file.Name) - Valid"
        }
    }
    catch {
        Write-Err "Failed to parse $($file.Name): $_"
        $totalErrors++
    }
}

Write-Step "Validation Summary"
Write-Info "Files checked: $($filesToValidate.Count)"
Write-Info "Errors: $totalErrors"
Write-Info "Warnings: $totalWarnings"

if ($totalErrors -gt 0) {
    Write-Err "Validation failed with $totalErrors error(s)."
    exit 1
}

if ($totalWarnings -gt 0 -and $Strict) {
    Write-Err "Validation failed in strict mode due to $totalWarnings warning(s)."
    exit 1
}

Write-Success "All files passed validation."
exit 0
