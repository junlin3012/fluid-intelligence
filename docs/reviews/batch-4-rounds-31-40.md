# Code Review Batch 4 — Rounds 31-40

**Date**: 2026-03-15
**Tests**: 92/92 passing (88 from batch 3 + 4 new)
**Commit**: `0bcaf15` — batch 4 fixes

## Review Focus

Batch 4 shifted from finding new bugs to fixing architectural issues identified in batch 3. Three targeted agents were dispatched for specific fixes.

## Fixed Issues (4 fixes)

| Round | Severity | Issue | Fix |
|-------|----------|-------|-----|
| R31 | High | mcp-auth-proxy binary downloaded without SHA-256 checksum | Added `sha256sum -c -` verification (matching tini pattern) |
| R32 | Medium | `PYTHONUNBUFFERED` not set — Python stderr buffered | Added `PYTHONUNBUFFERED=1` to cloudbuild.yaml env vars |
| R32 | Medium | `DB_POOL_SIZE` defaults to 200 — exceeds Cloud SQL limit of 25 | Added `DB_POOL_SIZE=5` to cloudbuild.yaml env vars |
| R33 | Low | SSE casing inconsistent in patterns.md (`sse` vs `SSE`) | Standardized to uppercase `SSE` throughout |

## E2E Test Results (post-deployment)

**20/21 passed** on warm rerun. Single failure:
- **dev-mcp tool**: No tools registered — likely npx cold-start timeout during bridge startup

This is a pre-existing operational issue that the batch 3 tool discovery stabilization polling should help mitigate on future deploys.

## Remaining Architectural Issues

From batches 3-4, these issues are tracked but not quick fixes:

| Issue | Severity | Status |
|-------|----------|--------|
| `@latest` runtime installs (dev-mcp, sheets) | High | Needs version pin + build-time install |
| `uv` binary downloaded without version pin/checksum | Medium | Needs version pin in Dockerfile.base |
| `psycopg2-binary` unpinned | Medium | Needs version pin |
| `AUTH_REQUIRED=false` on ContextForge | High | Needs investigation if auth-proxy forwards creds |
| SSRF localhost/private blanket-allowed | Medium | Needs ContextForge whitelist support |
| No dedicated service account | Medium | Create least-privilege SA |
| Virtual server UUID changes on redeploy | High | Needs stable alias or PUT update |
| Spec doc stale vs implementation | Medium | Update or supersede spec |
| `/app/.venv` writable by UID 1001 | Medium | Make read-only in Dockerfile.base |

## Test Additions (4 new tests)

- R31: mcp-auth-proxy has SHA-256 checksum in Dockerfile.base
- R32: PYTHONUNBUFFERED=1 set in cloudbuild.yaml
- R32: DB_POOL_SIZE explicitly set in cloudbuild.yaml
- R33: patterns.md SSE casing consistent (no lowercase `sse`)
