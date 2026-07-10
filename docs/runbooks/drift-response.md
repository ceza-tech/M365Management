# Incident Response Runbook: Configuration Drift Detected

## Overview

This runbook covers the response process when the drift detection system identifies configuration changes that deviate from the defined baseline.

## Alert Sources

- GitHub Issue (automated via drift-alert workflow)
- Scheduled drift-check GitHub Action failure
- Manual `Get-Drifts.ps1` execution

## Severity Classification

| Severity | Criteria | Response Time |
|----------|----------|---------------|
| **P1 - Critical** | Security policy disabled, MFA bypassed | Immediate |
| **P2 - High** | Auth method changes, CA policy state changes | 4 hours |
| **P3 - Medium** | Teams/Exchange policy changes | 24 hours |
| **P4 - Low** | Display name changes, non-security settings | Next sprint |

## Response Process

### Step 1: Assess the Drift

```powershell
# Get detailed drift information
pwsh ./scripts/Get-Drifts.ps1 -TenantName <tenant> -OutputFormat json
```

Review the output to understand:
- Which resources drifted
- What properties changed
- Baseline vs current values

### Step 2: Determine Root Cause

Common causes:
1. **Manual portal change** - Someone modified settings directly
2. **Another automation** - Conflicting Intune/SCCM policy
3. **Microsoft service change** - Preview feature rollout
4. **Baseline error** - Config YAML was incorrect

### Step 3: Decide on Action

#### Option A: Remediate (Restore Baseline)

Use when the drift is unauthorized or unintended:

```powershell
# Re-apply the baseline configuration
pwsh ./scripts/Apply-Config.ps1 -TenantName <tenant>

# Verify drift is resolved
pwsh ./scripts/Get-Drifts.ps1 -TenantName <tenant> -FailOnDrift
```

#### Option B: Accept (Update Baseline)

Use when the current state is correct and the baseline should be updated:

```powershell
# Take a new snapshot
pwsh ./scripts/Take-Snapshot.ps1 -Resources @('microsoft.entra.conditionalaccesspolicy')

# Update the YAML config file with new values
code ./tenants/<tenant>/config/entra/conditional-access-policies.yaml

# Commit and push
git add -A && git commit -m "Accept drift: <description>" && git push
```

#### Option C: Investigate Further

For complex or unclear situations:

1. Check Entra audit logs for who/what made the change
2. Review change management tickets
3. Consult with the team that owns the resource

### Step 4: Close the Alert

1. If a GitHub Issue was created:
   - Add a comment explaining the resolution
   - Close the issue with appropriate label (remediated/accepted/false-positive)

2. Document any process improvements needed

## Escalation Path

| Level | Contact | When | SLA |
|-------|---------|------|-----|
| L1 | On-call engineer (`@oncall-m365` team or PagerDuty rotation) | Initial response to any drift alert | Acknowledge within 15 min (P1), 30 min (P2), 2 hrs (P3/P4) |
| L2 | Security team (`@security-team`) | P1/P2 security-related drifts (MFA, CA policies, auth methods) | Engaged within 30 min of L1 escalation |
| L3 | Platform team lead | Repeated drifts (≥3 in 24 hrs on same resource), automation conflicts, or failed rollback | Engaged within 1 hr of L2 escalation |

**Break-glass access:** If GitHub Actions cannot authenticate (expired secret, OIDC misconfigured), the designated break-glass admin must apply configuration manually via the Entra portal using the snapshot JSON as reference. Break-glass admin: **`<PLACEHOLDER: fill in admin name/alias before using this runbook>`** — access controlled via the `M365Management-BreakGlass` Entra role assignment.

> **After-hours P1/P2:** Page the on-call engineer directly via PagerDuty. Do not wait for the next business day. The drift-check workflow creates a GitHub Issue automatically — also send a manual Teams message to `#m365-incidents` if the alert is P1.

### Notification Channels

- **GitHub Issues** — automatic (created by drift detection workflow for all drift events)
- **Teams / Slack** — configure a webhook secret `TEAMS_WEBHOOK_URL` (or `SLACK_WEBHOOK_URL`) in your GitHub Environment secrets and add the optional notification step below to your drift-check workflow. For P1/P2 drifts, do not rely solely on GitHub Issues.

```yaml
# Optional: add this step after the "Warn on drift" step in drift-check.yml
# Requires TEAMS_WEBHOOK_URL secret in the GitHub Environment
- name: Notify Teams on P1/P2 drift
  if: steps.check.outputs.drift_count != '0'
  shell: pwsh
  env:
    TEAMS_WEBHOOK_URL: ${{ secrets.TEAMS_WEBHOOK_URL }}
  run: |
    if (-not $env:TEAMS_WEBHOOK_URL) { exit 0 }
    $payload = @{
      text = "⚠️ **Configuration drift detected** in tenant **${{ matrix.tenant }}**: ${{ steps.check.outputs.drift_count }} drift(s). [View details](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }})"
    } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri $env:TEAMS_WEBHOOK_URL -Body $payload -ContentType 'application/json'
```

## Prevention Checklist

After resolving a drift:

- [ ] Root cause identified and documented
- [ ] Config YAML updated if needed
- [ ] Access controls reviewed (who can modify tenant settings)
- [ ] Change management process followed
- [ ] Monitoring/alerting adequate for this drift type

## References

- [Get-Drifts.ps1 Documentation](../README.md)
- [Apply-Config.ps1 Documentation](../README.md)
- [Entra Audit Logs](https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/Audit)
