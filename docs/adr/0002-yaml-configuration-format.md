# 2. YAML Configuration Format

Date: 2026-01-20

## Status

Accepted

## Context

Configuration files needed a format that is:
- Human-readable and editable
- Supports comments for documentation
- Easy to diff in pull requests
- Compatible with existing tooling (linters, schema validators)

Options considered:
1. **JSON** - Native to Graph API, but no comments and verbose
2. **YAML** - Human-friendly, supports comments, widely adopted in GitOps
3. **HCL** - Terraform-style, powerful but less familiar to most teams
4. **PowerShell Data Files (.psd1)** - Native to PowerShell but limited tooling

## Decision

We use **YAML** as the configuration format with the following conventions:

```yaml
resources:
  - resourceType: microsoft.entra.conditionalaccesspolicy
    properties:
      Id: "<GUID>"
      DisplayName: "Policy Name"
      State: enabled
      Ensure: Present
```

Key conventions:
- One file per logical grouping (e.g., all CA policies in one file)
- Lowercase resource types with dot notation
- Comments encouraged for documenting policy purpose
- JSON Schema validation for structure enforcement

## Consequences

### Positive

- Excellent readability in PR diffs
- Comments allow inline documentation
- Wide ecosystem of YAML tools (yamllint, IDE support)
- Easy conversion to JSON for API calls

### Negative

- Requires `powershell-yaml` module dependency
- YAML indentation errors can be subtle
- Some loss of type information vs JSON

### Neutral

- Team needs to learn YAML syntax if unfamiliar
- Schema validation adds a build step

## References

- [YAML Specification](https://yaml.org/spec/1.2.2/)
- [powershell-yaml Module](https://github.com/cloudbase/powershell-yaml)
- [JSON Schema for YAML](https://json-schema.org/)
