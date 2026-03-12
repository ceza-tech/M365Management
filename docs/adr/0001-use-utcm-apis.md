# 1. Use UTCM APIs for Configuration Management

Date: 2026-01-15

## Status

Accepted

## Context

We needed a way to manage Microsoft 365 tenant configuration as code, enabling GitOps workflows with version control, PR reviews, and automated deployment.

Several approaches were considered:

1. **Microsoft Graph direct API calls** - Low-level control but requires managing each resource type individually
2. **Microsoft365DSC** - PowerShell DSC-based, mature but complex and primarily designed for compliance reporting
3. **UTCM (Unified Tenant Configuration Management) APIs** - New Graph beta APIs designed specifically for config-as-code scenarios

## Decision

We chose to use the **UTCM APIs** (Microsoft Graph beta) for the following reasons:

1. **Purpose-built**: UTCM is designed for GitOps-style configuration management
2. **Unified interface**: Single API surface for multiple workloads (Entra, Teams, Exchange, Intune)
3. **Built-in drift detection**: Native support for baseline comparison and drift alerts
4. **Snapshot capability**: Point-in-time capture of tenant state for auditing and rollback
5. **Official Microsoft support**: Part of the Graph API roadmap

## Consequences

### Positive

- Simplified codebase - one API pattern for all workloads
- Native drift detection without custom polling logic
- Easier onboarding for teams familiar with Graph API
- Future-proof as UTCM moves to GA

### Negative

- **Beta API**: Breaking changes possible; requires monitoring Graph changelog
- **Limited properties**: UTCM monitors enforce high-level state (enabled/disabled) only; complex nested properties like CA policy conditions must be managed in the portal
- **6-hour evaluation cycle**: Drift detection is not real-time

### Neutral

- Requires UTCM service principal setup per tenant (one-time)
- Learning curve for teams not familiar with Graph beta APIs

## References

- [UTCM Overview](https://learn.microsoft.com/en-us/graph/utcm-overview)
- [Configuration Monitor API](https://learn.microsoft.com/en-us/graph/api/resources/configurationmonitor)
- [Graph Beta Changelog](https://developer.microsoft.com/en-us/graph/changelog)
