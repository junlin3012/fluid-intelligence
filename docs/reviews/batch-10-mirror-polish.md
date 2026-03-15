# Code Review Batch 10 — Mirror Polish (Round 4/5)

**Date**: 2026-03-15
**Tests**: 170/170 unit tests passing
**Method**: Brainstorming (meta-level + cross-cutting angles) + Systematic Debugging (verify before fixing)
**Clean batch counter**: 0/5 (6 fixes found)

## Review Angles (10 rounds)

| Round | Angle | Status |
|-------|-------|--------|
| R1 | Test-production parity | CLEAN (parse_http_code gap is Low) |
| R2 | Curl timeout budget | CLEAN (startup probe is ultimate guard) |
| R3 | GraphQL pagination completeness | ISSUE FOUND |
| R4 | Bootstrap ordering dependencies | CLEAN |
| R5 | Stale code / unbound variables | ISSUE FOUND |
| R6 | Test assertion strength | CLEAN (Low observations only) |
| R7 | Consistency of patterns (relative paths) | ISSUE FOUND |
| R8 | Edge case: empty Shopify store | CLEAN |
| R9 | cloudbuild.yaml correctness | CLEAN (redundant MCG_PORT is Low) |
| R10 | Cross-file contract verification | ISSUE FOUND (same as R7) |

## Fixes Applied (6 fixes)

| Round | Severity | Issue | Fix | Test |
|-------|----------|-------|-----|------|
| **R3** | High | GetProducts, GetOrders, GetCustomers, GetInventoryLevels all return `endCursor` but don't accept `$after` variable — pagination structurally non-functional | Added `$after: String` variable and `after: $after` to all 4 queries | `check_after_var` → 4/4 PASS |
| **R5** | Medium | `$body` never assigned if all 5 curl attempts to Shopify produce empty responses — `set -u` crashes with "unbound variable" instead of FATAL diagnostic | Added `body=""` initialization before token fetch loop | `grep -B5 'for attempt' \| grep 'body=""'` → PASS |
| **R7/R10** | Medium | 31 test file references used bare `scripts/` paths without `$REPO_ROOT` — tests fail from any directory other than repo root | Converted all to `$REPO_ROOT/scripts/...` | `grep ... \| grep -cv 'REPO_ROOT'` = 0 → PASS |

## False Positives / Architectural Items

| Finding | Verdict | Reason |
|---------|---------|--------|
| R2: Curl timeout can make health loop take 720s | NOT A BUG | Cloud Run startup probe (240s) is the ultimate guard; curl on localhost typically returns instantly |
| R9: Redundant MCG_PORT in cloudbuild.yaml | LOW | entrypoint.sh exports overwrites it; maintenance trap but not a current bug |
| R1: parse_http_code not functionally tested | LOW | Structural test exists; function is simple |

## Test Results

```
ALL TESTS PASSED: 170/170
```

New tests this batch: 6 (4 pagination $after checks + 1 $body init + 1 REPO_ROOT completeness)

## Cumulative Statistics (Batches 1-10)

| Metric | Value |
|--------|-------|
| Total review rounds | 91+ |
| Total code fixes | 76+ |
| Total unit tests | 170 |
| E2E tests | 21 |
| Mirror Polish clean batches | 0/5 |
