# GitHub Actions Workflows

## Overview

Three workflows implement the GitOps SDLC for M365 configuration management:

```
apply.yml          → Runs when config/ changes are pushed to main
drift-check.yml    → Runs every 6 hours to detect configuration drift
snapshot.yml       → Runs weekly to capture a fresh baseline snapshot
```

## `apply.yml` — Apply Configuration

**Triggers:**
- Push to `main` branch with changes in `config/**`
- Manual (`workflow_dispatch`) with optional dry-run

**What it does:**
1. Authenticates to Microsoft Graph using service principal credentials
2. Reads all YAML files from `config/` subdirectories
3. Creates or updates the UTCM monitor named `M365Management-GitOps`
4. Triggers an immediate monitor evaluation
5. Waits 30s then checks for any drifts

**Dry-run mode:**
```
Actions → Apply M365 Configuration → Run workflow → Enable "dry-run"
```

## `drift-check.yml` — Drift Detection

**Triggers:**
- Every 6 hours (cron schedule: `0 */6 * * *`)
- Manual (`workflow_dispatch`)

**What it does:**
1. Fetches all UTCM monitors
2. Retrieves detected drifts for each monitor
3. Writes a summary table to the workflow run summary
4. **Creates a GitHub Issue** if drifts are found (with label `drift-detected`)
5. **Closes the GitHub Issue** automatically when drifts are gone
6. Optionally fails the workflow (for alerting integrations that watch run status)

## `snapshot.yml` — Configuration Snapshot

**Triggers:**
- Weekly on Sundays at 2am UTC
- Manual (`workflow_dispatch`)

**What it does:**
1. Calls UTCM Snapshot APIs for the specified workloads
2. Saves the JSON output as a **GitHub Actions artifact** (retained 30 days)
3. Optionally commits the snapshot JSON to the repo

**Manual snapshot for a specific workload:**
```
Actions → Take Configuration Snapshot → Run workflow
  → workloads: entra,teams
  → commit_to_repo: false
```

## Required GitHub Secrets

| Secret | Description |
|---|---|
| `AZURE_TENANT_ID` | Entra tenant ID |
| `AZURE_CLIENT_ID` | App registration client ID |
| `AZURE_CLIENT_SECRET` | App registration client secret |

Set these in: **Settings → Secrets and variables → Actions**

## Required Repository Settings

Enable **Issues** (for drift detection auto-issue creation):
**Settings → General → Features → Issues** ✅
