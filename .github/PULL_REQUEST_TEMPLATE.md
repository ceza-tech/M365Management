## What does this PR change?

<!-- Briefly describe what config is being changed and why -->

## Tenant(s) affected

- [ ] kustomize
- [ ] _(other tenants)_

## Type of change

- [ ] Config update — changing a desired-state value
- [ ] New resource — adding a resource to be monitored
- [ ] New tenant — onboarding a new tenant folder
- [ ] Script / workflow change
- [ ] Documentation

## Checklist

- [ ] I ran `Apply-Config.ps1 -TenantName <name> -DryRun` and reviewed the output
- [ ] I checked the snapshot to confirm the current live value before changing it
- [ ] Property names are PascalCase and match the UTCM API schema
- [ ] `resourceType` uses the `microsoft.<workload>.<resource>` dotted format
- [ ] No secrets or credentials are included in this PR
- [ ] I've updated `docs/multitenantsupport.md` if a new tenant was added

## Current value (from snapshot)

<!-- Paste the relevant section from snapshots/output/snapshot-*.json -->

```json

```

## Desired value (after this PR)

<!-- Paste the YAML block being changed -->

```yaml

```
