# Multi-Tenant Support

This repo manages multiple M365 tenants from a single codebase. Each tenant has
its own configuration tree, its own credentials, and gets a dedicated GitHub
Environment so pipelines run in full isolation.

---

## How it works

```
tenants/
├── kustomize/              ← one folder per tenant
│   └── config/
│       ├── entra/
│       │   ├── security-defaults.yaml
│       │   ├── authentication-methods.yaml
│       │   └── conditional-access-policies.yaml
│       └── teams/
│           ├── meeting-policies.yaml
│           └── messaging-policies.yaml
│
└── fabrikam/               ← second tenant (example)
    └── config/
        ├── entra/
        │   └── security-defaults.yaml   ← different values from kustomize
        └── teams/
            └── meeting-policies.yaml
```

Each folder name must exactly match the GitHub Environment name — this is how
the workflow knows which credentials to inject for that tenant.

---

## Credentials — GitHub Environments

Every tenant has its own **GitHub Environment** with three secrets:

| Secret | Description |
|---|---|
| `AZURE_TENANT_ID` | The tenant's Entra directory (tenant) ID |
| `AZURE_CLIENT_ID` | The app registration client ID in that tenant |
| `AZURE_CLIENT_SECRET` | The client secret for that app registration |

The workflow matrix picks up `environment: ${{ matrix.tenant }}` automatically,
so each leg runs with the right credentials. You never need to change workflow
files when adding a new tenant.

---

## Adding a new tenant

### Step 1 — Register an app in the new tenant

Connect to the new tenant interactively and run the registration script:

```powershell
Connect-MgGraph -TenantId <new-tenant-id> -Scopes "Application.ReadWrite.All","AppRoleAssignment.ReadWrite.All"
pwsh ./scripts/Register-AppRegistration.ps1
```

Note the printed `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, and `AZURE_CLIENT_SECRET`.

### Step 2 — Set up the UTCM service principal

```powershell
pwsh ./scripts/Setup-UTCM.ps1
```

### Step 3 — Create the tenant config folder

```bash
mkdir -p tenants/<tenant-name>/config/entra
mkdir -p tenants/<tenant-name>/config/teams
```

Copy the YAML files from an existing tenant as a starting point and adjust the
values to reflect the desired state for the new tenant:

```bash
cp -r tenants/kustomize/config/ tenants/<tenant-name>/config/
```

> **Tip:** Run a snapshot first to capture the live state of the new tenant
> and use it as the baseline, rather than copying another tenant's desired state:
>
> ```bash
> pwsh -Command "./scripts/Take-Snapshot.ps1 -Resources @('microsoft.entra.securitydefaults','microsoft.entra.authorizationpolicy')"
> ```

### Step 4 — Create the GitHub Environment

```bash
gh api repos/ceza-tech/M365Management/environments/<tenant-name> -X PUT
```

### Step 5 — Set the environment secrets

```bash
gh secret set AZURE_TENANT_ID     --body "<tenant-id>"     --env <tenant-name> --repo ceza-tech/M365Management
gh secret set AZURE_CLIENT_ID     --body "<client-id>"     --env <tenant-name> --repo ceza-tech/M365Management
gh secret set AZURE_CLIENT_SECRET --body "<client-secret>" --env <tenant-name> --repo ceza-tech/M365Management
```

### Step 6 — Commit and push

```bash
git add tenants/<tenant-name>/
git commit -m "feat: onboard tenant <tenant-name>"
git push
```

The `discover-tenants` job automatically detects the new folder and adds it to
the matrix. No workflow changes required.

---

## Running workflows for a specific tenant

All three workflows (`apply.yml`, `drift-check.yml`, `snapshot.yml`) accept an
optional `tenant` input so you can target a single tenant manually:

```bash
# Apply config for one tenant only
gh workflow run apply.yml --ref main -f tenant=kustomize

# Check drift for one tenant
gh workflow run drift-check.yml --ref main -f tenant=fabrikam

# Take a snapshot for one tenant
gh workflow run snapshot.yml --ref main -f tenant=kustomize
```

Omitting `tenant` runs against all tenants discovered in `tenants/`.

---

## Running scripts locally

```powershell
# Apply config
pwsh ./scripts/Apply-Config.ps1 -TenantName kustomize

# Dry-run (no changes applied)
pwsh ./scripts/Apply-Config.ps1 -TenantName kustomize -DryRun

# Check drift
pwsh ./scripts/Get-Drifts.ps1 -TenantName kustomize

# Take snapshot
pwsh -Command "./scripts/Take-Snapshot.ps1 -Resources @('microsoft.entra.securitydefaults')"
```

Environment variables must be set for the target tenant before running locally:

```bash
export AZURE_TENANT_ID=<tenant-id>
export AZURE_CLIENT_ID=<client-id>
export AZURE_CLIENT_SECRET=<client-secret>
```

Or use a `.env` file (already gitignored):

```ini
AZURE_TENANT_ID=<tenant-id>
AZURE_CLIENT_ID=<client-id>
AZURE_CLIENT_SECRET=<client-secret>
```

---

## How the monitor name is derived

Each tenant gets a dedicated UTCM configuration monitor named automatically
from the tenant folder name:

| Tenant folder | Monitor name |
|---|---|
| `kustomize` | `Kustomize GitOps` |
| `fabrikam` | `Fabrikam GitOps` |
| `my-corp` | `My corp GitOps` |

Special characters and hyphens are replaced with spaces. The name is
auto-capitalised and truncated to 32 characters if needed (API limit).

You can override this by passing `-MonitorDisplayName` explicitly.

---

## Secret rotation

Client secrets expire (default: 2 years). When a secret is due for rotation:

1. In the Entra portal for that tenant, go to the app registration →
   **Certificates & secrets** → **New client secret**
2. Copy the new secret value immediately
3. Update the GitHub Environment secret:
   ```bash
   gh secret set AZURE_CLIENT_SECRET --body "<new-secret>" --env <tenant-name> --repo ceza-tech/M365Management
   ```
4. Delete the old secret in the Entra portal

> **Reminder:** Set a calendar event for each tenant's secret expiry date.
> Secret expiry dates were printed when you ran `Register-AppRegistration.ps1`.

---

## Tenant inventory

| Tenant | Folder | GitHub Environment | Secret expires |
|---|---|---|---|
| Kustomize | `tenants/kustomize` | `kustomize` | 2027-03-10 |
| _(add rows as you onboard tenants)_ | | | |
