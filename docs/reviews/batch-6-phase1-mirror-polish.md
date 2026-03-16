# Mirror Polish Batch 6 — Phase 1 Code Changes

**Date**: 2026-03-16
**Target**: Phase 1 implementation + Batch 1-3 fixes
**Mode**: Code-only verification
**Method**: Brainstorming + Systematic Debugging
**Clean batch counter**: 3/5

## Review Angles (10 rounds)

| Round | Complexity | Angle | Status |
|-------|-----------|-------|--------|
| R1 | Medium | Leading-zero octal arithmetic in bash loop variables | CLEAN |
| R2 | Complex | CLI flag injection via env var expansion in auth-proxy args | CLEAN |
| R3 | Medium | `productSet` vs `productUpdate` GraphQL API consistency | CLEAN |
| R4 | Medium | GraphQL `first: 50` variant pagination limit | CLEAN |
| R5 | Medium | `CREDENTIALS_CONFIG` format for Google Sheets MCP | CLEAN |
| R6 | Simple | `--allow-unauthenticated` Cloud Run intentionality | CLEAN |
| R7 | Medium | Python venv integrity after `uv pip install` psycopg2 | CLEAN |
| R8 | Simple | `head -c 50` JWT debugging — sensitive data exposure | CLEAN |
| R9 | Medium | Apollo binary name vs config reference consistency | CLEAN |
| R10 | Complex | `curl --connect-timeout 2` adequacy for localhost HTTP | CLEAN |

## Fixes Applied

None — all 10 angles verified clean.

## Observations (not flaws)

| Finding | Assessment |
|---------|-----------|
| R2: env vars passed as CLI args to auth-proxy expose values in /proc/cmdline | Known limitation documented in entrypoint.sh comment (lines 278-281). All processes run as UID 1001 in same container. |
| R4: GetProduct queries up to 50 variants; Shopify allows 100 | pageInfo.hasNextPage enables pagination. AI can use execute tool for additional pages. |
| R7: uv pip install corrupts mcpgateway CLI entry point | Code bypasses this by direct `from mcpgateway.cli import main` invocation. Verified by Dockerfile.base lines 56-57. |

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable Corrections |
|-------|-------|--------|-------------------|
| 1 | 2 | No | flock missing from container, SSE probe exit code bug |
| 2 | 3 | No | JWT comment accuracy, convergence log misleading, Dockerfile comment |
| 3 | 1 | No | Test pipe bug (grep -q | head always returns 0) |
| 4 | 0 | YES | First clean batch |
| 5 | 0 | YES | Second clean batch |
| 6 | 0 | YES | Third clean batch |

**Clean batch counter: 3/5**
**Fix trend: 2→3→1→0→0→0**
