# M365 Tenant Configuration Management - AI Coding Instructions

## Project Overview

This is a **GitOps-style Config-as-Code** repository for managing Microsoft 365 tenant configuration using the **UTCM (Unified Tenant Configuration Management) APIs** via Microsoft Graph beta. Changes flow through PRs → GitHub Actions → tenant application.

## Architecture

```
tenants/<TenantName>/config/<workload>/*.yaml  →  Apply-Config.ps1  →  UTCM Monitor API
                                               ←  Take-Snapshot.ps1 ←  Snapshot API
                                               ←  Get-Drifts.ps1    ←  Drift Detection API
```

**Key components:**
- **Config YAML files**: Declarative desired state per workload (entra, teams, exchange, intune)
- **PowerShell scripts**: Orchestrate UTCM API calls; all scripts source `helpers/Auth.ps1`
- **Multi-tenant**: Each tenant folder maps 1:1 to a GitHub Environment with isolated credentials
- **Schema validation**: JSON Schema in `schemas/config.schema.json` validates YAML before apply
- **Rollback support**: Auto-snapshot before apply, restore on critical failures

## Critical Patterns

### YAML Configuration Schema
Config files follow this exact structure—do not deviate:
```yaml
resources:
  - resourceType: microsoft.entra.conditionalaccesspolicy   # Lowercase, dot-separated
    properties:
      Id: "<GUID>"              # From snapshot; required for updates
      DisplayName: "Policy Name"
      State: enabled            # enabled | disabled | enabledForReportingButNotEnforced
      Ensure: Present           # Present | Absent
```

**Important:** UTCM monitors enforce *high-level state only* (enabled/disabled, present/absent). Complex nested properties like `GrantControls` or `Conditions` are not supported—configure those in the Entra portal directly.

### Authentication Pattern
All scripts use `helpers/Auth.ps1` with this priority:
1. **OIDC/Workload Identity** (GitHub Actions with `USE_OIDC=true`)
2. **Client credentials** (`AZURE_CLIENT_SECRET`)
3. **`.env` file fallback** for local development

Required env vars: `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, and either `AZURE_CLIENT_SECRET` or OIDC configuration.

### Naming Conventions
- **Monitor names**: `<TenantName> GitOps` (8-32 chars, alphanumeric + spaces only—no hyphens/underscores)
- **Snapshot names**: `Snapshot yyyyMMdd HHmmss` format
- **Resource types**: Lowercase with dots, e.g., `microsoft.entra.conditionalaccesspolicy`

## Developer Workflows

### Local Testing
```powershell
# Set credentials
cp .env.example .env && code .env

# Install pre-commit hooks
pip install pre-commit && pre-commit install

# Validate config schema
pwsh ./scripts/Validate-Schema.ps1 -Path ./tenants/kustomize/config

# Take a snapshot to discover resource IDs
pwsh ./scripts/Take-Snapshot.ps1 -Resources @('microsoft.entra.conditionalaccesspolicy')

# Dry-run config application (no API writes)
pwsh ./scripts/Apply-Config.ps1 -TenantName kustomize -DryRun

# Apply with auto-rollback on failure
pwsh ./scripts/Apply-Config.ps1 -TenantName kustomize -RollbackOnFailure

# Check for drifts
pwsh ./scripts/Get-Drifts.ps1 -TenantName kustomize -FailOnDrift
```

### Running Tests
```powershell
# Install Pester v5
Install-Module Pester -MinimumVersion 5.0.0 -Force

# Run all tests
Invoke-Pester -Configuration (Import-PowerShellDataFile ./pester.config.psd1)

# Run specific test file
Invoke-Pester ./tests/Unit/Auth.Tests.ps1
```

### Adding a New Tenant
1. Create `tenants/<name>/config/` directory structure
2. Add GitHub Environment named `<name>` with secrets
3. Scripts auto-discover tenants from the `tenants/` folder

### Git Workflow
- **No direct pushes to main** (enforced by `scripts/hooks/pre-push`)
- Install hooks: `pwsh ./scripts/Install-GitHooks.ps1`
- Pre-commit runs: yamllint, PSScriptAnalyzer, gitleaks, schema validation
- Emergency bypass: `git push --no-verify`

## Code Style

- **PowerShell**: Use `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`
- **Helper functions**: `Write-Step`, `Write-Success`, `Write-Info`, `Write-Warn`, `Write-Err` for CLI output
- **Structured logging**: Use `helpers/Logging.ps1` for JSON-formatted logs in CI
- **YAML**: 2-space indent, max 200 char lines (see `.yamllint.yaml`)

## Key Files Reference

| File | Purpose |
|------|---------|
| `scripts/helpers/Auth.ps1` | Token acquisition (OIDC + client credentials) |
| `scripts/helpers/Logging.ps1` | Structured JSON logging for observability |
| `scripts/Apply-Config.ps1` | Creates/updates UTCM monitors with rollback support |
| `scripts/Take-Snapshot.ps1` | Captures current tenant state |
| `scripts/Get-Drifts.ps1` | Detects deviations from baseline |
| `scripts/Restore-Baseline.ps1` | Manual rollback to previous snapshot |
| `scripts/Validate-Schema.ps1` | JSON Schema validation for YAML configs |
| `schemas/config.schema.json` | JSON Schema for config validation |
| `docs/adr/` | Architecture Decision Records |
| `docs/runbooks/` | Incident response and rollback procedures |
