# Code Review Batch 14 — Mirror Polish (Round 8)

**Date**: 2026-03-15
**Tests**: 173/173 unit tests passing
**Method**: Brainstorming (10 novel angles on build/runtime/security) + Systematic Debugging
**Clean batch counter**: 0/5 (2 fixes found — counter resets)

## Review Angles (10 rounds)

| Round | Angle | Status |
|-------|-------|--------|
| R1 | Dockerfile.base build reproducibility | ISSUE FOUND |
| R2 | Network binding and port conflicts | CLEAN |
| R3 | Temp file atomicity and cleanup | ISSUE FOUND |
| R4 | Unicode and locale handling | CLEAN |
| R5 | Exit code semantics | CLEAN |
| R6 | Log message consistency | CLEAN (optimization, not bug) |
| R7 | Permissions and file ownership | CLEAN |
| R8 | Cold start optimization | CLEAN (design tradeoff, not bug) |
| R9 | GraphQL query complexity/cost | CLEAN |
| R10 | Injection vectors beyond env vars | CLEAN |

## Fixes Applied (2 fixes)

| Round | Severity | Issue | Fix | Test |
|-------|----------|-------|-----|------|
| **R1** | Medium | `uv` binary downloaded from `/latest/` URL — non-reproducible builds (tini and mcp-auth-proxy are pinned) | Pinned uv to 0.10.10 via `ARG UV_VERSION`; pinned `psycopg2-binary==2.9.10` | `grep 'UV_VERSION=' Dockerfile.base` → PASS |
| **R3** | Low | `/tmp/jq-err-$$.log` not cleaned on token success path (only `curl-err` was cleaned) | Added `jq-err-$$.log` to `rm -f` on success path | `grep -A5 'token acquired' \| grep jq-err` → PASS |

## Observations (not flaws)

| Finding | Assessment |
|---------|-----------|
| R6: No elapsed time on token fetch success log | Minor debuggability gap. Overall timing on line 259 is sufficient |
| R8: Sequential start_and_verify adds 8s | Design tradeoff for simplicity. Within 240s probe budget |
| R3: PID file writes not atomic (write-then-rename) | Mitigated by `[[ =~ ^[0-9]+$ ]]` validation in bootstrap |

## Test Results

```
ALL TESTS PASSED: 173/173
```

## Mirror Polish Protocol Status

| Batch | Fixes | Tests | Clean? |
|-------|-------|-------|--------|
| 7 | 6 | 152 | No |
| 8 | 6 | 160 | No |
| 9 | 4 | 164 | No |
| 10 | 6 | 170 | No |
| 11 | 1 | 170 | No |
| 12 | 0 | 170 | YES |
| 13 | 0 | 170 | YES |
| 14 | 2 | 173 | No |

**Clean batch counter: 0/5** — Reset after 2 consecutive clean batches.
Trend: 6 → 6 → 4 → 6 → 1 → 0 → 0 → 2 fixes.

## Cumulative Statistics (Batches 1-14)

| Metric | Value |
|--------|-------|
| Total review rounds | 131+ |
| Total code fixes | 79+ |
| Total unit tests | 173 |
| E2E tests | 21 |
| Mirror Polish clean batches | 0/5 |
