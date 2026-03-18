# Mirror Polish — Domain 3: MCP Protocol & Integration — COMPLETE

**Date**: 2026-03-18
**Total batches**: 7 | **Total dimensions**: 70 | **Genuine fixes**: 3 | **Documented observations**: 10

## Fix Summary

| # | Severity | Issue | Fix |
|---|----------|-------|-----|
| 1 | HIGH | MIN_TOOL_COUNT=70 triggers false WARNING every deploy — real count is ~27-31 | Changed defaults.env from 70 to 25, updated bootstrap.sh comment to "Apollo ~7 + dev-mcp ~3-7 + sheets ~17 = ~27-31" |
| 2 | HIGH | Bootstrap comment "dev-mcp ~50+" is 10x inflated | Corrected to "~3-7" based on actual deployment data |
| 3 | MEDIUM | Stale StreamableHTTP=False documentation confuses future agents | Added clarifying note in system-understanding.md that limitation was bridge-specific, not Apollo-native |

## Documented Observations (not code defects)

| Finding | Assessment |
|---------|-----------|
| npx cold start on every restart (~30-60s) | Known, documented. No caching on ephemeral storage. |
| SSE 5-minute timeout (Cloud Run --timeout) | Already set to 3600s in cloudbuild.yaml. |
| Schema staleness risk | Operational — requires base image rebuild to update |
| No runtime subprocess health monitoring | Design gap — bridge stays alive when subprocess crashes |
| Premature tool stabilization risk | Mitigated by MIN_TOOL_COUNT floor (now correct at 25) |
| Tool disappearance during re-registration | Low risk with single instance, happens only at startup |
| Virtual server stale tool references | By design — re-created on every restart |

## Convergence

Fix trend: 3→0→0→0→0→0→0 (all observations in batches 2-7 were documented limitations, not genuine defects)

## Key Protocol Findings (all verified clean)

- Apollo STREAMABLEHTTP works correctly with ContextForge direct connection
- dev-mcp and sheets SSE bridges serve at `/sse` endpoint correctly
- Tool names are unique across all 3 backends (no conflicts)
- Gateway registration is synchronous — tools available immediately after 2xx
- Tool convergence loop correctly waits for stabilization
- Virtual server creation bundles all discovered tools
- MCP protocol compliance verified (notifications/initialized, JSON-RPC IDs)
- RBAC setup correctly runs after VS creation
- All curl calls use `-L` for redirect following
