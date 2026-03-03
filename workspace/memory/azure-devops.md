# Azure DevOps — Pipeline Status

Use the `azure-builds` command to check CI/CD pipeline status.

## List recent builds
```
azure-builds          # last 5 builds
azure-builds 10       # last 10 builds
```

## Inspect a specific build
```
azure-builds <buildId>   # shows status + per-stage timeline
```

## Connection details
- Organization : 
- Project      : 
- Definition   :  (default pipeline)
- Auth         : PAT via environment (pre-configured, no MFA needed)

## Result icons
- ✅ succeeded
- ❌ failed
- ⚠️  partiallySucceeded
- 🔄 in progress
- 🚫 canceled
