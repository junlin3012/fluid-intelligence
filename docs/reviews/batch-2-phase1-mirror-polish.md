# Mirror Polish Batch 2 — Phase 1 Code Changes

**Date**: 2026-03-16
**Target**: Phase 1 implementation (15 commits, f731d1a..243c2e8 + Batch 1 fixes)
**Mode**: Code-only verification
**Method**: Brainstorming + Systematic Debugging
**Clean batch counter**: 0/5

## Review Angles (10 rounds)

| Round | Complexity | Angle | Status |
|-------|-----------|-------|--------|
| R1 | Complex | SIGTERM during SSE probe (signal vs curl) | CLEAN |
| R2 | Medium | Bootstrap JWT expiry comment accuracy (dev-mcp timeout) | **ISSUE FOUND** |
| R3 | Complex | GDPR shop-redact for already-uninstalled shop | CLEAN |
| R4 | Complex | Cloud Run timeout 3600s vs startup probe 240s budget | CLEAN |
| R5 | Medium | curl_err variable scope leak in register_gateway() | CLEAN |
| R6 | Medium | OTEL endpoint format (Cloud Trace OTLP path) | CLEAN (observation) |
| R7 | Medium | mark_uninstalled vs delete_shop_data order correctness | CLEAN |
| R8 | Medium | Convergence loop "stabilized" log when it didn't | **ISSUE FOUND** |
| R9 | Simple | Dockerfile.base comment missing util-linux purpose | **ISSUE FOUND** |
| R10 | Simple | Test coverage for both Batch 1 fix paths | CLEAN |

## Fixes Applied

| Round | Severity | Issue | Fix | Verification |
|-------|----------|-------|-----|-------------|
| R2 | Low | bootstrap.sh JWT comment says "dev-mcp 90s" but actual wait loop is 120s; total says "3.5 min" but actual worst case is ~5 min (including convergence) | Updated comment to "dev-mcp 120s + sheets 60s + convergence 60s = 5 min" | Structural test `test_bootstrap_comment_accuracy.sh` (RED→GREEN) |
| R8 | Medium | Convergence loop log says "stabilized after Xs" even when stable<2 (loop exhausted without stabilizing) — misleading during debugging | Added `if [ "$stable" -ge 2 ]` check; separate "did NOT stabilize" message for exhausted loop | Structural test `test_convergence_log_accuracy.sh` (RED→GREEN) |
| R9 | Low | Dockerfile.base comment lists package purposes but omits util-linux (for flock) and tar/gzip (for uv) added/present in install line | Extended comment to include "util-linux for flock advisory lock, tar/gzip for uv install" | Grep verification against Dockerfile.base |

## Observations (not flaws)

| Finding | Assessment |
|---------|-----------|
| R4: Startup budget is tight (~235s worst case vs 240s probe) | Math works out. CF_HEALTH_TIMEOUT was already reduced from 180→120 for this reason. Comment documents the budget. Not a defect. |
| R6: OTEL endpoint `https://cloudtrace.googleapis.com` may need GCP-specific auth headers | Standard OTLP exporter may not add ADC auth automatically. Cannot verify in code-only mode — needs live validation. |
| R5: `curl_err` in register_gateway() is `local` but defined inside while loop | Bash `local` scopes to function, not block. Variable correctly available after loop ends for error reporting. |

## Key Decisions & Rationale

- **R8 fix approach**: Used conditional check on `$stable` rather than tracking a separate flag. This is the simplest fix — the variable is already there, just wasn't being checked.
- **R2 comment**: Included convergence time (30 iterations × 2s = 60s) in the budget calculation since it runs after bridge registration and consumes JWT validity.

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable Corrections |
|-------|-------|--------|-------------------|
| 1 | 2 | No | flock missing from container, SSE probe exit code bug |
| 2 | 3 | No | JWT comment accuracy, convergence log misleading, Dockerfile comment |

**Clean batch counter: 0/5**
**Accumulated verified-clean angles: SSE race conditions, GDPR connection management, migration script SQL safety, Content-Type validation, no-op commit handling, env comment accuracy, shell shebangs, SIGTERM vs SSE probe, GDPR shop-redact idempotency, Cloud Run timeout budget, curl_err scope, OTEL endpoint format, mark/delete order, test coverage for Batch 1 fixes**
