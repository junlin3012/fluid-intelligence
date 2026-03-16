# Mirror Polish Batch 3 — Phase 1 Code Changes

**Date**: 2026-03-16
**Target**: Phase 1 implementation + Batch 1-2 fixes
**Mode**: Code-only verification
**Method**: Brainstorming + Systematic Debugging
**Clean batch counter**: 0/5

## Review Angles (10 rounds)

| Round | Complexity | Angle | Status |
|-------|-----------|-------|--------|
| R1 | Complex | OAuth callback empty `code` before HTTP exchange | CLEAN |
| R2 | Complex | Webhook HMAC on empty body/header edge cases | CLEAN |
| R3 | Medium | GraphQL `productSet` mutation input types | CLEAN |
| R4 | Medium | `_success_html` XSS via URL href injection | CLEAN |
| R5 | Complex | PID file race between entrypoint and bootstrap | CLEAN |
| R6 | Medium | `set -euo pipefail` vs `|| true` interaction | CLEAN |
| R7 | Complex | OAuth nonce replay protection after callback | CLEAN |
| R8 | Medium | Webhook HMAC encoding consistency (base64 vs hex) | CLEAN |
| R9 | Medium | test_convergence_log_accuracy.sh pipe kills grep exit code | **ISSUE FOUND** |
| R10 | Simple | New test file shebangs consistency | CLEAN |

## Fixes Applied

| Round | Severity | Issue | Fix | Verification |
|-------|----------|-------|-----|-------------|
| R9 | Medium | `grep -q ... \| head -1` always returns 0 (grep -q produces no output; head -1 on empty stdin = 0). Test's first condition was dead code — pass/fail depended only on second check. Could false-positive if "stabilized" string was removed. | Rewrote as `if ! grep -q ...; then FAIL; elif ! grep -B2 ... \| grep -q 'stable'; then FAIL; else PASS` — each check has an independent, correct exit code | Re-ran test, verified PASS on correct code |

## Observations (not flaws)

| Finding | Assessment |
|---------|-----------|
| R1: OAuth callback doesn't check empty `code` before exchange | exchange_code_for_token gracefully returns ("", "") on failure. Unnecessary HTTP call to Shopify on empty code, but not a defect — no incorrect behavior. |
| R2: Empty HMAC header → HMAC of empty body is a non-empty b64 string, `compare_digest("hash", "")` returns False | Correctly rejects requests with missing HMAC |
| R4: `_success_html` href uses `html.escape(shop)`, and shop is regex-validated to `*.myshopify.com` | Double-protected: validation + escaping prevents XSS and javascript: URIs |
| R5: PID files written before `start_and_verify`, bootstrap runs after all bridges start | No race: PID files always exist when bootstrap reads them |
| R7: OAuth nonce in httpOnly/secure cookie, code is single-use server-side, cookies deleted after callback | Multi-layer protection against replay |
| R8: Webhooks use base64 HMAC, OAuth uses hex HMAC — both match Shopify's conventions for their respective APIs | Correct differentiation, not inconsistency |

## Key Decisions & Rationale

- **R9 test fix**: Split the compound `grep -q | head` condition into separate `if/elif/else` branches. Each branch has a clear, independent check with correct exit code semantics. This pattern is more debuggable than chained pipes with `-q`.

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable Corrections |
|-------|-------|--------|-------------------|
| 1 | 2 | No | flock missing from container, SSE probe exit code bug |
| 2 | 3 | No | JWT comment accuracy, convergence log misleading, Dockerfile comment |
| 3 | 1 | No | Test pipe bug (grep -q | head always returns 0) |

**Clean batch counter: 0/5**
**Accumulated verified-clean angles: SSE race conditions, GDPR connection management, migration script SQL safety, Content-Type validation, no-op commit handling, env comment accuracy, shell shebangs, SIGTERM vs SSE probe, GDPR shop-redact idempotency, Cloud Run timeout budget, curl_err scope, OTEL endpoint format, mark/delete order, test coverage for Batch 1 fixes, JWT comment accuracy, convergence log accuracy, Dockerfile comment accuracy, OAuth callback empty code, webhook HMAC empty body, GraphQL productSet types, success_html XSS, PID file race, set -e vs || true, OAuth nonce replay, HMAC encoding consistency, test shebangs**
