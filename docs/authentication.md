# Authentication Setup

## Overview

This project uses a **service principal** (App Registration) to authenticate to Microsoft Graph.
Two authentication methods are supported:

| Method | Recommended for | Notes |
|--------|----------------|-------|
| **OIDC / Workload Identity Federation** | GitHub Actions (CI/CD) | ✅ **Recommended** — no long-lived secrets, no rotation |
| **Client credentials (client secret)** | Local development, non-GitHub CI | Requires secret rotation; store in GitHub Secrets |

> **Security note:** OIDC is the preferred method for all GitHub Actions workflows. Client secrets should only be used as a fallback when OIDC is not yet configured. All workflows in this repo default to `USE_OIDC: 'true'` and will fall back to a client secret if one is present.

## Step 1: Create an App Registration in Entra

1. Go to [Entra portal](https://entra.microsoft.com) → **App registrations** → **New registration**
2. Name: `M365Management-GitOps` (or anything descriptive)
3. Supported account types: **Single tenant**
4. No redirect URI needed (this is a daemon/service app)

## Step 2: Create a Client Secret

1. In your app registration → **Certificates & secrets** → **New client secret**
2. Copy the **Value** immediately (it won't be shown again)
3. Note the secret's expiry date — add a calendar reminder to rotate it

## Step 3: Grant API Permissions

Go to **API permissions** → **Add a permission** → **Microsoft Graph** → **Application permissions**, and add:

| Permission | Purpose |
|---|---|
| `TenantConfiguration.ReadWrite.All` | Core UTCM access |
| `Policy.Read.All` | Read Conditional Access, auth policies |
| `Policy.ReadWrite.ConditionalAccess` | Manage CA policies |
| `Policy.ReadWrite.AuthenticationMethod` | Manage auth methods |
| `User.Read.All` | Read user properties |
| `Group.Read.All` | Read group properties |
| `RoleManagement.Read.All` | Read role assignments |

> **Admin consent required**: After adding permissions, click **"Grant admin consent for [your org]"**

## Step 4: Add UTCM Service Principal (one-time)

```powershell
# Run this once per tenant. Uses interactive auth.
pwsh ./scripts/Setup-UTCM.ps1
```

This adds the official Microsoft UTCM service principal (`03b07b79-c5bc-4b5e-9bfa-13acf4a99998`) to your tenant and grants it the permissions it needs to evaluate configuration settings.

## Step 5: Configure GitHub Secrets

In your GitHub repo → **Settings** → **Secrets and variables** → **Actions**, add:

| Secret name | Value |
|---|---|
| `AZURE_TENANT_ID` | Your Entra tenant ID (GUID) |
| `AZURE_CLIENT_ID` | App Registration client ID (GUID) |
| `AZURE_CLIENT_SECRET` | Client secret value from Step 2 |

## Optional: Use OIDC (Workload Identity Federation) — Recommended

Instead of a long-lived client secret, use [Workload Identity Federation](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure) for keyless auth from GitHub Actions. This is the **recommended** approach — it eliminates secret rotation and reduces credential exposure risk.

### Setup

1. In your Entra App Registration → **Certificates & secrets** → **Federated credentials** → **Add credential**
2. Select scenario: **GitHub Actions deploying Azure resources**
3. Fill in:
   - **Organization**: your GitHub org/user
   - **Repository**: `M365Management`
   - **Entity**: `Environment` → select the GitHub Environment name (e.g., `kustomize`)
4. Remove `AZURE_CLIENT_SECRET` from your GitHub Environment secrets (it is no longer needed)
5. Keep `AZURE_TENANT_ID` and `AZURE_CLIENT_ID` as secrets

The workflows already have `id-token: write` and `USE_OIDC: 'true'` set. No workflow changes are required.

```yaml
# The workflows already include this — shown here for reference only:
permissions:
  id-token: write   # Enables OIDC token request
  contents: read
```
