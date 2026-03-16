# Mirror Polish Batch 7 — Phase 1 Code Changes

**Date**: 2026-03-16
**Target**: Phase 1 implementation + Batch 1-3 fixes
**Mode**: Code-only verification
**Method**: Brainstorming + Systematic Debugging
**Clean batch counter**: 4/5

## Review Angles (10 rounds)

| Round | Complexity | Angle | Status |
|-------|-----------|-------|--------|
| R1 | Medium | UPSERT COALESCE shop_id behavior on reinstall | CLEAN |
| R2 | Complex | `MAX_WEBHOOK_BODY` check after full body read | CLEAN |
| R3 | Medium | `autocommit=True` test vs production path divergence | CLEAN |
| R4 | Medium | Lazy cryptography imports in `_derive_signing_key` | CLEAN |
| R5 | Simple | conftest.py secret vs test env var consistency | CLEAN |
| R6 | Medium | Cursor-based pagination in GetProducts query | CLEAN |
| R7 | Medium | `productSet synchronous: true` correctness for MCP | CLEAN |
| R8 | Simple | `app.on_event("startup")` deprecation status | CLEAN |
| R9 | Medium | `setup_db` fixture autouse + yield lifecycle | CLEAN |
| R10 | Complex | psycopg2 `connect_timeout=5` for Unix socket | CLEAN |

## Fixes Applied

None — all 10 angles verified clean.

## Observations (not flaws)

| Finding | Assessment |
|---------|-----------|
| R2: `await request.body()` reads full body before size check | Defense-in-depth — Shopify payloads are <10KB, Cloud Run has 4Gi memory, auth-proxy fronts the service. Not exploitable in current deployment. |
| R3: Tests use autocommit=True but production uses autocommit=False | Explicit `conn.commit()` calls make behavior identical regardless of autocommit setting. |
| R8: `@app.on_event("startup")` deprecated in recent FastAPI | Still functional. Would use lifespan context manager in a refactor but not a defect. |

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable Corrections |
|-------|-------|--------|-------------------|
| 1 | 2 | No | flock missing from container, SSE probe exit code bug |
| 2 | 3 | No | JWT comment accuracy, convergence log misleading, Dockerfile comment |
| 3 | 1 | No | Test pipe bug (grep -q | head always returns 0) |
| 4 | 0 | YES | First clean batch |
| 5 | 0 | YES | Second clean batch |
| 6 | 0 | YES | Third clean batch |
| 7 | 0 | YES | Fourth clean batch |

**Clean batch counter: 4/5**
**Fix trend: 2→3→1→0→0→0→0**
