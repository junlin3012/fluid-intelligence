# Code Review Batch 8 — Mirror Polish (Round 2/5)

**Date**: 2026-03-15
**Tests**: 160/160 unit tests passing
**Method**: Brainstorming (invent review angles) + Systematic Debugging (verify before fixing)
**Clean batch counter**: 0/5 (6 fixes found)

## Review Angles (10 rounds)

| Round | Angle | Status |
|-------|-------|--------|
| R1 | Atomicity of multi-step operations | CLEAN |
| R2 | Resource exhaustion (temp file orphans) | ISSUE FOUND |
| R3 | Idempotency under restart | CLEAN |
| R4 | Concurrency safety | CLEAN (per-container ContextForge) |
| R5 | Exit code correctness | ISSUE FOUND |
| R6 | Log parsability | CLEAN (bare echo is intentional formatting) |
| R7 | Defensive coding completeness | CLEAN (theoretical only) |
| R8 | Curl option consistency | ISSUE FOUND |
| R9 | Variable scope leakage | ISSUE FOUND |
| R10 | Test determinism (portable paths) | ISSUE FOUND |

## Fixes Applied (6 fixes)

| Round | Severity | Issue | Fix | Test |
|-------|----------|-------|-----|------|
| **R2** | Low | `register_gateway` orphans `/tmp/bootstrap-curl-err-$$.log` on success paths (success + 409) | Added `rm -f "$curl_err"` before `return 0` on both paths | `grep -B2 'Registered.*via /gateways' \| grep 'rm -f'` → PASS |
| **R5** | Low | dev-mcp and sheets wait loops use bare `$?` for curl exit code in FATAL message — always reports `rc=0` because `[ "$i" -eq N ]` overwrites it | Capture `rc=0; curl ... \|\| rc=$?` (matches Apollo pattern) | `grep 'curl.*8003.*healthz' \| grep 'rc=0.*\|\| rc='` → PASS |
| **R8** | Low | POST /servers discards curl stderr (`2>/dev/null`) — connection errors lost on virtual server creation failure | Capture to `$vs_curl_err`, log on failure, clean on success | `grep -B3 'CF/servers.*2>' \| grep 'vs_curl_err'` → PASS |
| **R9** | Low | `register_gateway` leaks `payload`, `response`, `body` to global scope (no `local` declaration) | Added to existing `local` declaration line | `grep -A2 'local max_attempts' \| grep 'payload.*response.*body'` → PASS |
| **R10** | Medium | 51 hardcoded `/Users/junlin/...` paths make tests fail on any other machine | Added `REPO_ROOT` variable, replaced all 51 instances | Self-test: `grep -c '/Users/junlin'` (excluding self) = 0 → PASS |
| **R10** | Medium | No `REPO_ROOT` variable for portable path resolution | Added `REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"` | `head -10 test-unit.sh \| grep 'REPO_ROOT='` → PASS |

## False Positives Triaged

| Finding | Verdict | Reason |
|---------|---------|--------|
| R5-1: JWT fallback silent exit on double-failure | FALSE POSITIVE | `set -e` is disabled inside `\|\| { ... }` blocks per bash spec — fallback failure falls through to empty-token check with diagnostics |
| R6: Bare echo in service summary | NOT A FLAW | Intentional indented sub-items under the `[fluid-intelligence]` header line |
| R7: jq garbage in existing_ids | THEORETICAL | Self-heals via 404 on DELETE; empty/null guard catches most cases |

## Test Results

```
ALL TESTS PASSED: 160/160
```

New tests this batch: 8 (4 for R2/R5 fixes + 4 for R8/R9/R10)

## Cumulative Statistics (Batches 1-8)

| Metric | Value |
|--------|-------|
| Total review rounds | 71+ |
| Total code fixes | 66+ |
| Total unit tests | 160 |
| E2E tests | 21 |
| Mirror Polish clean batches | 0/5 |
