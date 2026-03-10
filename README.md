# M365 Tenant Configuration Management

> Config-as-Code for Microsoft 365 using the **Unified Tenant Configuration Management (UTCM) APIs** (Microsoft Graph beta).

## Overview

This repository implements a GitOps-style SDLC for managing your M365 tenant configuration across:

| Workload | Status |
|---|---|
| Microsoft Entra (Azure AD) | ✅ Supported |
| Microsoft Teams | ✅ Supported |
| Microsoft Exchange Online | ✅ Supported |
| Microsoft Intune | ✅ Supported |
| Microsoft Defender | ✅ Supported |
| Microsoft Purview | ✅ Supported |

## How it works

```
config/                    ← Declarative YAML config files (your "desired state")
    entra/
    teams/
    exchange/
    intune/
scripts/                   ← PowerShell scripts to apply, snapshot, and monitor
    Apply-Config.ps1
    Take-Snapshot.ps1
    Get-Drifts.ps1
    Setup-UTCM.ps1
.github/workflows/         ← GitHub Actions CI/CD pipelines
    apply.yml              ← Applies config on push to main
    drift-check.yml        ← Scheduled drift detection
    snapshot.yml           ← Scheduled snapshot/baseline capture
```

### SDLC Flow

```
Developer edits YAML → PR → Review → Merge to main → GitHub Actions applies to tenant
                                                    ↓
                                         Scheduled drift checks compare
                                         live tenant vs baseline, alert on deviation
```

## Prerequisites

1. **Azure App Registration** with the following:
   - Client ID, Tenant ID, Client Secret stored as GitHub Secrets
   - Microsoft Graph API permissions (delegated or application):
     - `TenantConfiguration.ReadWrite.All` (for UTCM)
     - Workload-specific permissions (see `docs/permissions.md`)

2. **UTCM Service Principal** added to your tenant (one-time setup):
   ```powershell
   ./scripts/Setup-UTCM.ps1
   ```

3. GitHub Secrets configured:
   - `AZURE_TENANT_ID`
   - `AZURE_CLIENT_ID`
   - `AZURE_CLIENT_SECRET`

## Quick Start

```bash
# 1. Clone the repo
git clone <your-repo-url>
cd M365Management

# 2. Configure your tenant details
cp .env.example .env
# Edit .env with your Tenant ID, Client ID, Client Secret

# 3. Run one-time UTCM setup
pwsh ./scripts/Setup-UTCM.ps1

# 4. Take an initial snapshot of current config
pwsh ./scripts/Take-Snapshot.ps1 -WorkloadTypes "entra","teams"

# 5. Edit config YAML files and push — CI/CD does the rest
```

## Documentation

- [Authentication Setup](docs/authentication.md)
- [Configuration Reference](docs/configuration-reference.md)
- [GitHub Actions Workflows](docs/workflows.md)
- [Permissions Reference](docs/permissions.md)
