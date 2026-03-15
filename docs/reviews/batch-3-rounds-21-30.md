# Code Review Batch 3 — Rounds 21-30

**Date**: 2026-03-15
**Files reviewed**: All scripts, Dockerfiles, config, GraphQL, docs, cloudbuild.yaml
**Tests**: 88/88 passing (79 from batch 2 + 9 new)
**Commit**: `55155fd` — batch 3 fixes

## Review Agent Coverage

| Round | Focus | Agent Result |
|-------|-------|-------------|
| R21 | Security audit entrypoint.sh | Crash diagnostics, FIRST_EXIT not printed |
| R22 | Security audit bootstrap.sh | JWT handling, registration error context |
| R23 | Robustness / resource exhaustion | PYTHONUNBUFFERED, cache eviction, gunicorn timeout |
| R24 | E2E test completeness | mcp_post -f flag, auth code replay, section numbering |
| R25 | Dockerfile.base / permissions | Predictable temp files, .venv writability, /proc/cmdline |
| R26 | GraphQL operations | (still pending) |
| R27 | Config / Cloud Run | DB_POOL_SIZE=200 vs 25 limit, SSRF bypass, AUTH_REQUIRED=false |
| R28 | Unit test quality / bootstrap | Tool discovery race, virtual server UUID instability |
| R29 | Process lifecycle | SSE connection leaks, signal delivery edge cases |
| R30 | Full system / supply chain | mcp-auth-proxy checksum, @latest pins, doc drift |

## Fixed Issues (7 code fixes)

| Round | Severity | Issue | Fix |
|-------|----------|-------|-----|
| R21 | Medium | `start_and_verify` crash lacks "check logs" hint | Added "Check container logs above" message |
| R21 | Medium | `FIRST_EXIT` captured but never printed | Added echo before per-process loop |
| R22 | Medium | `register_gateway` FATAL missing HTTP context | Added last HTTP code and body to FATAL message |
| R22 | High | Virtual server creation failure is WARNING | Promoted to FATAL + `exit 1` |
| R24 | Medium | `mcp_post` uses `-f` hiding error bodies | Was already `-s` only; fixed comment and test |
| R28 | High | Tool discovery race — queried once immediately | Added stabilization polling (2 consecutive stable reads) |
| R30 | Low | patterns.md JWT "5 min" doesn't match code's 10 min | Fixed to "10 min" |

## Build Fix

| Issue | Fix |
|-------|-----|
| `COPY --chmod` requires BuildKit (Cloud Build lacks it) | Reverted to `RUN chmod` + `chown` layer |

## Tracked Architectural Issues (Not Quick Fixes)

These are real findings that require design decisions or upstream changes:

| Round | Issue | Severity | Notes |
|-------|-------|----------|-------|
| R28 | Virtual server UUID changes on every deploy (breaks clients) | High | Needs stable alias or PUT update |
| R30 | mcp-auth-proxy binary has no SHA-256 checksum verification | High | Pattern exists (tini); apply to auth-proxy |
| R30 | `@latest` runtime installs (dev-mcp, sheets) | High | Pin versions, install at build time |
| R30 | `uv` binary downloaded without version pin or checksum | Medium | Pin and verify |
| R27 | `AUTH_REQUIRED=false` — no defense-in-depth | High | Set to `true` on ContextForge |
| R27 | SSRF protection enabled but localhost/private blanket-allowed | Medium | Whitelist specific internal ports |
| R27 | No dedicated service account (uses default Editor) | Medium | Create least-privilege SA |
| R27 | DB_POOL_SIZE defaults to 200 but Cloud SQL allows 25 | Medium | Set `DB_POOL_SIZE=5` |
| R23 | `PYTHONUNBUFFERED=1` not set — log buffering | Low | Add to cloudbuild.yaml env vars |
| R23 | `CACHE_TYPE=database` has no TTL/eviction | Medium | Investigate ContextForge cache config |
| R25 | `/app/.venv` writable by UID 1001 | Medium | Make read-only in Dockerfile.base |
| R30 | Spec doc stale: /healthz, StreamableHTTP, max-instances | Medium | Update or supersede spec |

## Test Additions (9 new tests)

- R21: start_and_verify crash hints at log location
- R21: Monitor prints FIRST_EXIT code
- R22: register_gateway FATAL includes HTTP context
- R22: Virtual server failure is FATAL severity
- R23: Temp files use mktemp or PID suffix
- R24: mcp_post doesn't use -f flag
- R24: No duplicate section numbers in E2E
- R28: Tool discovery waits for count to stabilize
- R30: patterns.md JWT expiry matches code (10 min)
