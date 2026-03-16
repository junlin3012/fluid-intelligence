# Mirror Polish Batch 1 — Phase 1 Code Changes

**Date**: 2026-03-16
**Target**: Phase 1 implementation (15 commits, f731d1a..243c2e8)
**Mode**: Code-only verification
**Method**: Brainstorming + Systematic Debugging
**Clean batch counter**: 0/5

## Review Angles (10 rounds)

| Round | Complexity | Angle | Status |
|-------|-----------|-------|--------|
| R1 | Complex | SSE probe race condition (entrypoint vs bootstrap) | CLEAN |
| R2 | Complex | GDPR webhook DB connection leak on exception | CLEAN |
| R3 | Complex | Migration script SQL injection / data corruption | CLEAN |
| R4 | Complex | flock portability on UBI container | **ISSUE FOUND** |
| R5 | Medium | Liveness probe /health path through auth-proxy | CLEAN (observation) |
| R6 | Medium | GDPR webhook Content-Type validation | CLEAN |
| R7 | Medium | delete_customer_data no-op commit | CLEAN |
| R8 | Medium | SSE probe curl -sf exit code handling | **ISSUE FOUND** |
| R9 | Simple | .env.example comment accuracy | CLEAN |
| R10 | Simple | Shell test file shebangs | CLEAN |

## Fixes Applied

| Round | Severity | Issue | Fix | Verification |
|-------|----------|-------|-----|-------------|
| R4 | High | `flock` (util-linux) not installed in UBI container — bootstrap advisory lock fails silently at runtime | Added `util-linux` to `microdnf install` in Dockerfile.base | Structural test `test_flock_available.sh` (RED→GREEN) |
| R8 | Medium | SSE probe uses `if curl -sf` which requires exit code 0, but SSE endpoints return 28 (timeout=streaming=alive) — probe always reports WARNING | Changed to capture rc and accept both 0 and 28, matching bootstrap.sh pattern | Structural test `test_sse_probe_exit_code.sh` (RED→GREEN) |

## Observations (not flaws)

| Finding | Assessment |
|---------|-----------|
| R3: Migration script lacks try/finally around DB connection | One-time operator tool; Python GC handles cleanup. Quality concern, not defect. |
| R3: Migration script silently skips corrupted tokens | By design — dry-run first, "skipped" count alerts operator. Corruption is extremely unlikely for AES-GCM encrypted tokens. |
| R5: Liveness probe hits /health on port 8080 (auth-proxy) | Auth proxies typically have built-in health endpoints. Cannot confirm without mcp-auth-proxy source. Will verify in Live mode. |
| R7: delete_customer_data commits without DML | Harmless no-op in PostgreSQL. Slightly wasteful but explicit about transaction boundary. |

## Key Decisions & Rationale

- **flock vs alternatives**: Kept `flock` approach (already implemented and tested) rather than switching to PID-file or other locking. Just needed the package installed.
- **SSE probe pattern**: Adopted the same `rc=0; curl ... || rc=$?; check 0 or 28` pattern already used in bootstrap.sh for consistency.

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable Corrections |
|-------|-------|--------|-------------------|
| 1 | 2 | No | flock missing from container, SSE probe exit code bug |

**Clean batch counter: 0/5**
**Accumulated verified-clean angles: SSE race conditions, GDPR connection management, migration script SQL safety, Content-Type validation, no-op commit handling, env comment accuracy, shell shebangs**
