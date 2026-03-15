# Code Review Batch 7 — Mirror Polish (Round 1/5)

**Date**: 2026-03-15
**Tests**: 152/152 unit tests passing
**Method**: Brainstorming (invent review angles) + Systematic Debugging (verify before fixing)
**Clean batch counter**: 0/5 (6 fixes found)

## Review Angles (10 rounds)

| Round | Angle | Status |
|-------|-------|--------|
| R1 | Signal propagation to grandchild processes | ISSUE FOUND |
| R2 | Race conditions in process startup | CLEAN |
| R3 | Environment variable leakage between processes | CLEAN |
| R4 | Subshell behavior with set -e | CLEAN |
| R5 | PID file lifecycle (create/use/cleanup) | ISSUE FOUND |
| R6 | Boundary value testing | ISSUE FOUND (3) |
| R7 | Comment accuracy | ISSUE FOUND |
| R8 | Error message accuracy | CLEAN (1 false positive) |
| R9 | Shell portability & correctness | CLEAN |
| R10 | Test coverage gaps | CLEAN (observations only) |

## Fixes Applied (6 fixes)

| Round | Severity | Issue | Fix | Test |
|-------|----------|-------|-----|------|
| **R1** | Medium | `tini --` doesn't forward signals to grandchild processes (npx, uv, apollo spawned by translate bridges) | Changed to `tini -g --` in Dockerfile | `grep -q 'tini.*-g' deploy/Dockerfile` → PASS |
| **R5** | Medium | PID files from crashed containers not cleaned at startup; not removed on SIGTERM | Added `rm -f` at startup + in cleanup trap | `head -40 entrypoint.sh \| grep 'rm.*apollo.pid'` → PASS; `grep -A15 'cleanup()' \| grep 'apollo.pid'` → PASS |
| **R6-1** | Medium | Test's `validate_external_url` used weaker regex than production (allowed dots in labels, non-alphanumeric first char) | Updated test regex to match production exactly | `validate_external_url ".leading-dot.com"` → correctly rejected |
| **R6-4** | Medium | DB_USER/DB_NAME format validation had no functional tests | Added 7 boundary tests (valid, @, ?, /, empty, spaces) | 7/7 PASS |
| **R6-5** | Medium | JWT format regex (security-critical) had zero boundary tests | Added 9 tests (valid 3-part, 2-part, 4-part, spaces, +, empty, multiline) | 9/9 PASS |
| **R7-4** | Low | Test comment referenced old "180s" timeout (now 120s) | Updated to "120s" | Verified in test-unit.sh lines 512, 517 |

## False Positives Triaged

| Finding | Verdict | Reason |
|---------|---------|--------|
| R8-2: `$body` unbound in register_gateway FATAL | FALSE POSITIVE | `body` is always assigned in loop body (line 94); loop always runs ≥1 iteration; `set -e` kills script on curl connection failure before FATAL path |
| R10-*: Various test coverage gaps | NOT FLAWS | Valid observations about untested paths, but all are integration-level (require real curl/processes) — not unit-testable |

## Test Results

```
ALL TESTS PASSED: 152/152
```

New tests this batch: 19 (3 from R1/R5 + 2 boundary for EXTERNAL_URL + 7 DB identifier + 9 JWT format - 2 removed with strict function)

## Cumulative Statistics (Batches 1-7)

| Metric | Value |
|--------|-------|
| Total review rounds | 61+ |
| Total debugging dimensions | 6 |
| Total code fixes | 60+ |
| Total unit tests | 152 |
| E2E tests | 21 |
| Mirror Polish clean batches | 0/5 |
