# Rollback Procedure Runbook

## Overview

This runbook covers the process for rolling back configuration changes when an Apply-Config operation fails or causes issues.

## When to Rollback

- Apply-Config.ps1 fails partway through
- Post-apply validation shows incorrect state
- Users report issues after config change
- Security incident traced to config change

## Automatic Rollback

Apply-Config.ps1 supports automatic rollback on critical errors:

```powershell
pwsh ./scripts/Apply-Config.ps1 -TenantName <tenant> -RollbackOnFailure
```

**What triggers automatic rollback:**
- API errors during monitor update (5xx, validation errors)
- Partial apply failures

**What does NOT trigger automatic rollback:**
- Authentication failures (nothing was changed)
- Permission errors (nothing was changed)
- Network timeouts (transient, retry later)

## Manual Rollback

### Step 1: Locate the Pre-Apply Snapshot

Pre-apply snapshots are stored in:
```
tenants/<tenant>/snapshots/pre-apply/
```

List available snapshots:
```powershell
Get-ChildItem ./tenants/<tenant>/snapshots/pre-apply/ -Filter *.json |
    Sort-Object LastWriteTime -Descending |
    Select-Object Name, LastWriteTime
```

### Step 2: Execute Rollback

```powershell
# Interactive rollback (with confirmation)
pwsh ./scripts/Restore-Baseline.ps1 -TenantName <tenant>

# Use specific snapshot
pwsh ./scripts/Restore-Baseline.ps1 -TenantName <tenant> -SnapshotId "pre-apply-20260311-090000"

# Force (no confirmation)
pwsh ./scripts/Restore-Baseline.ps1 -TenantName <tenant> -Force
```

### Step 3: Verify Rollback

```powershell
# Check for drifts (should be none after successful rollback)
pwsh ./scripts/Get-Drifts.ps1 -TenantName <tenant>

# Take a new snapshot to confirm state
pwsh ./scripts/Take-Snapshot.ps1 -Resources @('microsoft.entra.conditionalaccesspolicy')
```

## Emergency Rollback via Portal

If scripts are unavailable or failing:

1. Go to [Entra Admin Center](https://entra.microsoft.com)
2. Navigate to the affected resource (e.g., Conditional Access)
3. Manually revert settings using audit log as reference
4. Document all manual changes made

## Rollback Limitations

**UTCM monitors only control high-level state:**
- ✅ Can rollback: Policy enabled/disabled, Ensure Present/Absent
- ❌ Cannot rollback: GrantControls, Conditions, complex nested properties

For complex property rollback, you must:
1. Review the snapshot JSON for the original values
2. Manually update in the Entra portal
3. Update the YAML config to prevent future drift

## Post-Rollback Checklist

- [ ] Verify services are functioning normally
- [ ] Check for any new drifts
- [ ] Investigate root cause of the failed apply
- [ ] Update YAML config if it was incorrect
- [ ] Document the incident

## Snapshot Retention

Pre-apply snapshots should be retained for:
- **Production tenants**: 30 days minimum
- **Non-production**: 7 days

Clean up old snapshots:
```powershell
Get-ChildItem ./tenants/*/snapshots/pre-apply/*.json |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
    Remove-Item -Confirm
```

## References

- [Restore-Baseline.ps1](../../scripts/Restore-Baseline.ps1)
- [Apply-Config.ps1 Rollback Options](../../scripts/Apply-Config.ps1)
- [Drift Response Runbook](./drift-response.md)
