# Code Review Batch 9 — Mirror Polish (Round 3/5)

**Date**: 2026-03-15
**Tests**: 164/164 unit tests passing
**Method**: Brainstorming (invent review angles) + Systematic Debugging (verify before fixing)
**Clean batch counter**: 0/5 (4 fixes found)

## Review Angles (10 rounds)

| Round | Angle | Status |
|-------|-------|--------|
| R1 | GraphQL query correctness | ISSUE FOUND |
| R2 | Config file correctness | CLEAN |
| R3 | E2E test accuracy | ISSUE FOUND |
| R4 | Dockerfile layer optimization | CLEAN |
| R5 | Security: command injection vectors | CLEAN |
| R6 | Error recovery paths | CLEAN |
| R7 | Numeric overflow/underflow | CLEAN (port validation is intentional) |
| R8 | Race between bootstrap and clients | ARCHITECTURAL (documented) |
| R9 | Cleanup completeness on all exit paths | ISSUE FOUND |
| R10 | Documentation accuracy | CLEAN |

## Fixes Applied (4 fixes)

| Round | Severity | Issue | Fix | Test |
|-------|----------|-------|-----|------|
| **R1** | Medium | GetCustomers.graphql missing `endCursor` in pageInfo — pagination broken on page 2+ | Added `endCursor` to pageInfo block | `grep 'endCursor' GetCustomers.graphql` → PASS |
| **R3** | Medium | E2E `result "WARN"` crashes under `set -u` — `$3` is unbound in the FAIL branch when called with 2 args | Added WARN handler to `result()`, used `${3:-no details}` for safety | `grep -A1 'WARN' test-e2e.sh \| grep 'WARN:'` → PASS |
| **R3** | Low | E2E test output used emoji (non-portable, encoding-dependent) | Changed to plain text PASS/WARN/FAIL prefixes | Visual inspection |
| **R9** | Low | Entrypoint cleanup trap references `jwt-primary-err-$$.log` and `jwt-fallback-err-$$.log` but these are created by bootstrap.sh (different `$$` PID) — cleanup targets non-existent files | Removed JWT temp file refs from entrypoint trap (bootstrap handles its own cleanup) | `grep -A5 'cleanup()' entrypoint.sh \| grep 'jwt-primary-err'` → correctly absent |

## False Positives / Architectural Items

| Finding | Verdict | Reason |
|---------|---------|--------|
| R1-3: CreateDiscountCode `context` field | UNVERIFIED | Cannot validate against live Shopify schema; file not loaded by Apollo |
| R7: Port validation accepts out-of-range values | NOT A FLAW | Intentional injection defense; OS rejects invalid ports at bind time |
| R8: Race between bootstrap and clients | ARCHITECTURAL | Documented in system-understanding.md; requires Cloud Run startup probe config change, not bash fix |

## Test Results

```
ALL TESTS PASSED: 164/164
```

New tests this batch: 4 (1 GetCustomers endCursor + 1 E2E WARN handler + 1 cleanup trap + 1 endcursor check_endcursor call)

## Cumulative Statistics (Batches 1-9)

| Metric | Value |
|--------|-------|
| Total review rounds | 81+ |
| Total code fixes | 70+ |
| Total unit tests | 164 |
| E2E tests | 21 |
| Mirror Polish clean batches | 0/5 |
