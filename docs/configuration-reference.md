# Configuration Reference

## Directory Structure

```
config/
├── entra/                        # Microsoft Entra (Azure AD)
│   ├── conditional-access-policies.yaml
│   ├── authentication-methods.yaml
│   └── security-defaults.yaml
├── teams/                        # Microsoft Teams
│   ├── meeting-policies.yaml
│   └── messaging-policies.yaml
├── exchange/                     # Exchange Online
│   └── transport-rules.yaml      # (add your own)
└── intune/                       # Microsoft Intune
    └── compliance-policies.yaml  # (add your own)
```

## YAML Schema

Each config file follows this structure:

```yaml
resources:
  - resourceType: <UTCM resource type>    # Required
    id: "<resource GUID or policy name>"  # Required for updates; omit to match by type
    properties:                           # Key-value pairs to enforce
      <propertyName>: <value>
```

### Finding Resource IDs

When you don't know IDs yet, take a snapshot first:

```powershell
pwsh ./scripts/Take-Snapshot.ps1 -WorkloadTypes @("entra","teams")
```

The snapshot JSON output contains all IDs and current property values for your tenant.

## Supported Resource Types

### Microsoft Entra

| Resource Type | Description |
|---|---|
| `conditionalAccessPolicy` | Conditional Access policies |
| `authenticationMethodPolicy` | Auth methods policy (global) |
| `authenticationMethodPolicyFido2` | FIDO2 / passkeys |
| `authenticationMethodPolicySoftware` | Microsoft Authenticator |
| `authenticationMethodPolicySms` | SMS OTP |
| `authenticationMethodPolicyEmail` | Email OTP |
| `authorizationPolicy` | Tenant authorization settings |
| `securityDefaults` | Security defaults on/off |
| `crossTenantAccessPolicy` | B2B cross-tenant settings |
| `namedLocationPolicy` | Named locations |
| `tokenLifetimePolicy` | Token lifetime policies |
| `roleDefinition` | Custom role definitions |
| `user` | User properties |
| `group` | Group properties |
| `servicePrincipal` | App/service principal config |

### Microsoft Teams

| Resource Type | Description |
|---|---|
| `meetingPolicy` | Meeting settings |
| `messagingPolicy` | Chat/messaging settings |
| `callingPolicy` | Calling configuration |
| `appPermissionPolicy` | App permission policies |
| `appSetupPolicy` | App setup policies |
| `channelsPolicy` | Channels settings |
| `federationConfiguration` | External access / federation |
| `guestMeetingConfiguration` | Guest meeting settings |
| `upgradePolicy` | Teams upgrade settings |

### Microsoft Exchange Online

| Resource Type | Description |
|---|---|
| `transportRule` | Mail flow / transport rules |
| (additional via Exchange module) | |

### Microsoft Intune

| Resource Type | Description |
|---|---|
| (via Intune Graph APIs) | Device compliance, config profiles |

## Property Values

Property names and allowed values match the Microsoft Graph API schema exactly.  
Refer to the [UTCM resource documentation](https://learn.microsoft.com/en-us/graph/api/resources/unified-tenant-configuration-management-api-overview?view=graph-rest-beta) for the full list.

## Monitoring Limits

| Limit | Value |
|---|---|
| Max monitors per tenant | 30 |
| Monitor run interval | Every 6 hours |
| Max resources monitored per day | 800 |
| Snapshot resources per month | 20,000 |
| Snapshot retention | 7 days |
