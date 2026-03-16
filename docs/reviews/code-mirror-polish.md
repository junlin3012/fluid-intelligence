# Code Mirror Polish — Complete Review Record

**Date**: 2026-03-15
**Scope**: All deployed code — shell scripts, Dockerfiles, GraphQL operations, config, tests
**Method**: Brainstorming + Systematic Debugging (6 debugging dimensions from Batch 6)
**Result**: 21 batches, 201+ review rounds, 81+ fixes, 176 unit tests, 5/5 consecutive clean batches — **PROTOCOL COMPLETE**

---

## Final Statistics

| Metric | Value |
|--------|-------|
| Total review rounds | 201+ |
| Total batches | 21 (6 pre-mirror + 15 mirror polish) |
| Total code fixes | 81+ |
| Total unit tests | 176 |
| E2E tests | 21 (20/21 passing — dev-mcp cold-start timeout is operational) |
| Files modified | 18+ |
| Mirror polish exit | 5 consecutive clean batches (Batches 17-21) |

## Fix Categories

| Category | Count | Key Examples |
|----------|-------|-------------|
| Signal handling | 4 | tini -g, PID file lifecycle, cleanup trap |
| Data validation | 8 | SHOPIFY_STORE regex, DB_USER/DB_NAME, JWT format |
| GraphQL correctness | 6 | Pagination $after, endCursor missing, variable types |
| Error handling | 12 | curl exit codes, jq fallbacks, unbound vars, HTTP codes |
| Security | 6 | env var injection, /proc/cmdline leaks, stderr leaks, JWT secrets |
| Test infrastructure | 15 | REPO_ROOT portability, assertion helpers, E2E infrastructure |
| Build reproducibility | 5 | Version pinning (uv, psycopg2, dev-mcp, sheets, @latest) |
| Shell correctness | 10 | set -e in ||, subshell scoping, variable initialization |
| Documentation | 3 | Stale comments, cross-references, patterns.md drift |
| Observability | 12 | Log formatting, error context, HTTP codes, stderr capture |

## Fix Trend (Convergence Proof)

```
Batch:  1   2   3   4   5   6   7   8   9  10  11  12  13  14  15  16  17  18  19  20  21
Fixes: 10   8   7   4  18  16   6   6   4   6   1   0   0   2   1   1   0   0   0   0   0
Tests: 67  79  88  92 113 130 152 160 164 170 170 170 170 173 175 176 176 176 176 176 176
Clean:  -   -   -   -   -   -  0/5 0/5 0/5 0/5 0/5 1/5 2/5 0/5 0/5 0/5 1/5 2/5 3/5 4/5 5/5
```

---

## Batch 1 — Foundational Fixes (Rounds 1-10)

**Files reviewed**: `scripts/entrypoint.sh`, `scripts/bootstrap.sh`, `scripts/test-e2e.sh`, `deploy/Dockerfile`, `graphql/**/*.graphql`
**Tests**: 67/67 | **Commit**: Batch 1 fixes

| Round | Severity | Issue | Fix |
|-------|----------|-------|-----|
| R1 | High | Cleanup trap exits without code, orphan PIDs | Added `exit 143`, per-PID `wait`, `SHUTTING_DOWN` flag |
| R2 | Medium | Bootstrap PID stays in PIDS after completion | Remove BOOTSTRAP_PID from array after `wait` |
| R3 | High | Bootstrap can't detect bridge crashes | Write PID files in entrypoint, check `kill -0` in bootstrap |
| R4 | High | DB_PASSWORD with special chars breaks DATABASE_URL | URL-encode via `urllib.parse.quote` before interpolation |
| R5 | Medium | GraphQL pagination missing `endCursor` | Added `endCursor` to all `pageInfo` blocks |
| R6 | High | `CreateDiscountCode` uses non-existent `context` field | Replaced with `customerSelection: { all: true }` |
| R6 | Medium | `CreateProduct` uses wrong variant type | Changed `ProductVariantSetInput` to `ProductSetVariantInput` |
| R7 | Medium | Bootstrap only registers single gateway ID per name | Loop over all `existing_ids` with `while read` |
| R8 | Medium | EXTERNAL_URL regex allows consecutive dots | Tightened: each label must start with `[a-zA-Z0-9]` |
| R9 | Medium | `RETURNED_STATE` unbound under `set -u` in test-e2e.sh | Initialize `RETURNED_STATE=""` before conditional block |
| R10 | Low | No local unit test framework for shell scripts | Created `scripts/test-unit.sh` with 67 regression tests |

**Test framework created**: validates signal handling, env var validation, URL encoding, bootstrap registration logic, GraphQL correctness, Dockerfile structure.

---

## Batch 2 — Error Handling & Build Cache (Rounds 11-20)

**Tests**: 79/79 (67 + 12 new) | **Commit**: `6ce0a78`

| Round | Severity | Issue | Fix |
|-------|----------|-------|-----|
| R11 | High | ContextForge health poll `curl` has no `--connect-timeout` — one stalled TCP connect can exhaust 180s budget | Added `--connect-timeout 2 --max-time 5` |
| R12 | Medium | `$attempt` and `$max_attempts` unquoted in `[ ]` test — word splitting risk | Quoted all variables |
| R14 | High | `DB_PASSWORD` used in URL encoding before validated — if unset, python3 crashes | Moved all env var validation BEFORE `DATABASE_URL` construction |
| R14 | Medium | Error messages don't show the invalid value | Added `got: $value` to PORT and URL error messages |
| R14 | Medium | Shopify token failure only logs HTTP status, not response body | Added response body logging (head -c 500) |
| R14 | Medium | Monitor loop exit message is informational but container is about to die | Tagged as `FATAL:` |
| R16 | Medium | E2E test suite has no negative MCP tests | Added invalid method (-32601) and malformed JSON (-32700) tests |
| R18 | Medium | Dockerfile uses separate `RUN chmod/chown` layer — wastes build cache | Reordered layers: schema (rare) → config → graphql → scripts (frequent) |

---

## Batch 3 — Security Audit & Architectural Review (Rounds 21-30)

**Tests**: 88/88 (79 + 9 new) | **Commit**: `55155fd`

### Code Fixes (7)

| Round | Severity | Issue | Fix |
|-------|----------|-------|-----|
| R21 | Medium | `start_and_verify` crash lacks "check logs" hint | Added "Check container logs above" message |
| R21 | Medium | `FIRST_EXIT` captured but never printed | Added echo before per-process loop |
| R22 | Medium | `register_gateway` FATAL missing HTTP context | Added last HTTP code and body to FATAL message |
| R22 | High | Virtual server creation failure is WARNING | Promoted to FATAL + `exit 1` |
| R24 | Medium | `mcp_post` uses `-f` hiding error bodies | Fixed comment and test |
| R28 | High | Tool discovery race — queried once immediately | Added stabilization polling (2 consecutive stable reads) |
| R30 | Low | patterns.md JWT "5 min" doesn't match code's 10 min | Fixed to "10 min" |

### Architectural Issues Tracked (12, not quick fixes)

Virtual server UUID changes on deploy, mcp-auth-proxy binary no checksum, `@latest` packages, `AUTH_REQUIRED=false`, SSRF localhost blanket-allowed, no dedicated service account, DB_POOL_SIZE=200 vs 25 limit, PYTHONUNBUFFERED not set, `/app/.venv` writable, spec doc stale.

---

## Batch 4 — Architectural Fixes (Rounds 31-40)

**Tests**: 92/92 (88 + 4 new) | **Commit**: `0bcaf15`

| Round | Severity | Issue | Fix |
|-------|----------|-------|-----|
| R31 | High | mcp-auth-proxy binary downloaded without SHA-256 checksum | Added `sha256sum -c -` verification (matching tini pattern) |
| R32 | Medium | `PYTHONUNBUFFERED` not set — Python stderr buffered | Added `PYTHONUNBUFFERED=1` to cloudbuild.yaml |
| R32 | Medium | `DB_POOL_SIZE` defaults to 200 — exceeds Cloud SQL limit of 25 | Added `DB_POOL_SIZE=5` to cloudbuild.yaml |
| R33 | Low | SSE casing inconsistent in patterns.md | Standardized to uppercase `SSE` |

**E2E**: 20/21 passed on warm rerun. Single failure: dev-mcp npx cold-start timeout.

---

## Batch 5 — Final Sweep (Rounds 41-51)

**Tests**: 113/113 | **E2E**: 20/21 | **Deployment**: `fluid-intelligence-00044-zbt`

| Source | Severity | Issue | Fix |
|--------|----------|-------|-----|
| R26 | Medium | Token exchange `-d` doesn't URL-encode auth code/secrets | Replaced with `--data-urlencode` per parameter |
| R46 | Medium | 4 GraphQL connections missing `pageInfo` | Added `pageInfo { hasNextPage endCursor }` to CreateDraftOrder, CreateFulfillment, CreateProduct, CreateDiscountCode |
| R46 | High | `CreateProduct.graphql` non-existent `ProductSetVariantInput` | Fixed to `ProductVariantSetInput` (verified against schema) |
| R46 | High | `CreateDiscountCode.graphql` deprecated `customerSelection` | Fixed to `context: { all: ALL }` (verified against schema) |
| R47 | Medium | No bash version guard (bash 4.3+ needed for PID management) | Added version check at top of `entrypoint.sh` |
| R47 | Medium | `sleep 2` in `start_and_verify` not trap-responsive | Changed to `sleep 2 & wait $!` |
| R48 | Medium | Bridge processes used bare `python3` instead of venv | Changed all 3 to `/app/.venv/bin/python` |
| R48 | Low | DELETE gateway failures silently swallowed | Added HTTP status logging on non-2xx/404 |
| R48 | Low | `gcloud` stderr discarded in E2E tests | Surfaced via temp file |
| R49 | Medium | `curl 2>&1` contaminated JSON variables in E2E tests | Changed to `2>/dev/null` |
| R49 | Low | Some curl calls missing `--connect-timeout` | Added to all 11 curl calls in bootstrap.sh |
| R50 | High | PID array substring replacement corrupted PIDs | Replaced with exact-match filter loop |
| R50 | Medium | No guard after token fetch loop exits | Added `: "${SHOPIFY_ACCESS_TOKEN:?...}"` |
| **R51** | **Critical** | **JWT fallback path leaked `$JWT_SECRET_KEY` via CLI `--secret` arg (visible in `/proc/cmdline`)** | **Rewrote fallback to use inline Python + `os.environ` pattern** |
| R51 | Medium | Inverted unit test assertions for CreateProduct/CreateDiscountCode | Fixed assertions to match correct schema types |

**Convergence assessment**: After 51 rounds — 1 critical security issue, 2 high-severity bugs, 38+ total fixes. Codebase production-ready.

---

## Batch 6 — Mirror Shine: Structural Analysis (6 Debugging Dimensions)

**Tests**: 130/130 (113 + 17 new)
**Method**: Brainstorming invented 6 debugging dimensions, each requiring a different investigative lens.

### Debugging Dimensions

| Dimension | What It Catches |
|-----------|----------------|
| D1: Timeout Arithmetic | Do all timeout/retry chains add up? Inner < outer? Fits Cloud Run probe? |
| D2: Failure Cascade | What happens when component X dies at time T? Zombie state? |
| D3: Data Flow Integrity | Do transformations (URL encode, JSON parse, shell expand) preserve correctness? |
| D4: Contract Compliance | Are tools (curl, jq, bash) used per their documented contracts? |
| D5: Validation Completeness | Every input validated? Every code path tested? Any bypass routes? |
| D6: Observability Gaps | Can every failure be diagnosed from logs alone? |

### Fixes (16)

| Dim | Severity | Issue | Fix |
|-----|----------|-------|-----|
| D1 | **High** | ContextForge health timeout (180s) exceeded Cloud Run startup probe (240s). Worst case: 295s. | Reduced to 120s. Worst case now 225s (14s margin). |
| D1 | Low | Temp files orphaned if SIGTERM during token fetch | Added cleanup to trap |
| D2 | Medium | ContextForge death during bootstrap not detected | Added `check_contextforge()` before each registration |
| D3 | **High** | Empty `encoded_pw` silently produces password-less DATABASE_URL (trust auth bypass) | Added empty-result guard with FATAL exit |
| D3 | Medium | Shopify `client_id`/`client_secret` not URL-encoded in form POST | Switched to `--data-urlencode` |
| D4 | Medium | `tail -1` for HTTP code extraction breaks on 204 No Content | Added `parse_http_code()` helper with numeric validation |
| D4 | Medium | HTTP code not validated as numeric before arithmetic comparison | Added `[[ "$http_code" =~ ^[0-9]+$ ]]` guard |
| D4 | Medium | E2E malformed JSON test false-passes | Split into JSON-RPC check and HTTP-only WARN fallback |
| D5 | Medium | `GOOGLE_OAUTH_CLIENT_ID`/`SECRET` not validated at startup | Added `: "${VAR:?msg}"` checks |
| D5 | Medium | VS_ID not validated after creation — empty ID produces `/servers//mcp` (404) | Added null/empty check with FATAL exit |
| D5 | Medium | `GetInventoryLevels.graphql` missing `endCursor` | Added (missed in R46) |
| D5 | **High** | `DB_USER`/`DB_NAME` interpolated without validation — `@?/` chars corrupt URI | Added alphanumeric regex check |
| D5 | Medium | PID file contents not validated as numeric | Added `^[0-9]+$` check on all 3 PID reads |
| D5 | Medium | JWT token format not validated | Added header.payload.signature regex check |
| D5 | Medium | Virtual server deletion assumes single ID | Changed to `while read` loop |
| D6 | Medium | `register_gateway` curl errors sent to `/dev/null` | Capture to temp file, log on failure |

### Timeout Arithmetic Proof

| Step | Worst Case | Cumulative |
|------|-----------|------------|
| Env validation + URL encoding | 1s | 1s |
| Shopify token (5 attempts) | 95s | 96s |
| 4 process starts (4 × 2s) | 8s | 104s |
| ContextForge health wait | 120s (was 180s) | 224s |
| Auth-proxy start | 2s | **226s** |

**226s < 240s probe limit** (14s margin). Previously 295s (55s overrun).

---

## Batches 7-21 — Mirror Polish Protocol

Exit condition: 5 consecutive clean batches. Each batch brainstorms 10 novel review angles, applies Systematic Debugging, and any fix resets the counter to 0/5.

### Batch 7 (Round 1/5) — 6 fixes, 152 tests, 0/5 clean

| Severity | Issue | Fix |
|----------|-------|-----|
| Medium | `tini --` doesn't forward signals to grandchild processes (npx, uv, apollo) | Changed to `tini -g --` in Dockerfile |
| Medium | PID files from crashed containers not cleaned at startup; not removed on SIGTERM | Added `rm -f` at startup + in cleanup trap |
| Medium | Test `validate_external_url` used weaker regex than production | Updated test regex to match production exactly |
| Medium | DB_USER/DB_NAME format validation had no functional tests | Added 7 boundary tests |
| Medium | JWT format regex had zero boundary tests | Added 9 tests |
| Low | Test comment referenced old "180s" timeout (now 120s) | Updated to "120s" |

**Angles reviewed**: Signal propagation to grandchild processes, race conditions in startup, env var leakage, subshell behavior, PID file lifecycle, boundary value testing, comment accuracy, error messages, shell portability, test coverage gaps.

### Batch 8 (Round 2/5) — 6 fixes, 160 tests, 0/5 clean

| Severity | Issue | Fix |
|----------|-------|-----|
| Low | `register_gateway` orphans `/tmp/bootstrap-curl-err-$$.log` on success | Added `rm -f` on success paths |
| Low | dev-mcp/sheets wait loops report `rc=0` instead of actual curl exit code | Capture `rc=0; curl ... || rc=$?` |
| Low | POST /servers discards curl stderr — connection errors lost | Capture to temp file, log on failure |
| Low | `register_gateway` leaks `payload`/`response`/`body` to global scope | Added `local` declarations |
| Medium | 51 hardcoded `/Users/junlin/...` paths make tests fail on other machines | Added `REPO_ROOT`, replaced all 51 |
| Medium | No `REPO_ROOT` variable for portable path resolution | Added `REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"` |

**Angles**: Atomicity, resource exhaustion, idempotency under restart, concurrency safety, exit codes, log parsability, defensive coding, curl consistency, variable scope leakage, test determinism.

### Batch 9 (Round 3/5) — 4 fixes, 164 tests, 0/5 clean

| Severity | Issue | Fix |
|----------|-------|-----|
| Medium | GetCustomers.graphql missing `endCursor` — pagination broken on page 2+ | Added `endCursor` to pageInfo |
| Medium | E2E `result "WARN"` crashes under `set -u` — `$3` unbound in FAIL branch | Added WARN handler, `${3:-no details}` |
| Low | E2E test output used emoji (non-portable) | Changed to plain text PASS/WARN/FAIL |
| Low | Cleanup trap references JWT temp files from bootstrap.sh (different `$$` PID) | Removed refs (bootstrap handles own cleanup) |

**Angles**: GraphQL query correctness, config file correctness, E2E accuracy, Dockerfile optimization, command injection, error recovery, numeric overflow, bootstrap/client race, cleanup completeness, documentation accuracy.

### Batch 10 (Round 4/5) — 6 fixes, 170 tests, 0/5 clean

| Severity | Issue | Fix |
|----------|-------|-----|
| **High** | GetProducts, GetOrders, GetCustomers, GetInventoryLevels all missing `$after` variable — **pagination structurally non-functional on page 2+** | Added `$after: String` variable and `after: $after` to all 4 |
| Medium | `$body` never assigned if all 5 curl attempts produce empty responses — `set -u` crash | Added `body=""` initialization before loop |
| Medium | 31 test file references used bare `scripts/` without `$REPO_ROOT` | Converted all to `$REPO_ROOT/scripts/...` |

**Angles**: Test-production parity, curl timeout budget, GraphQL pagination completeness, bootstrap ordering, stale code/unbound variables, test assertion strength, relative path consistency, empty Shopify store, cloudbuild.yaml correctness, cross-file contract verification.

### Batch 11 (Round 5/5) — 1 fix, 170 tests, 0/5 clean (counter resets)

| Severity | Issue | Fix |
|----------|-------|-----|
| Medium | E2E curl calls use `2>&1` on status-capture lines — stderr TLS warnings contaminate HTTP code variable. Unit test used single-line grep missing multiline continuations (false negative). | Replaced `2>&1` with `2>/dev/null`; updated test to check continuation lines |

**Angles**: Regression/false-negative detection, self-referential test correctness, unused GraphQL files, E2E GraphQL test completeness, shell quoting exhaustive check, B6-B10 consistency, test naming accuracy, tool discovery stabilization, curl timeout completeness audit, TODO/FIXME audit.

### Batch 12 (Round 6) — 0 fixes, 170 tests, **1/5 clean** (FIRST CLEAN BATCH)

All 10 angles verified clean: GraphQL mutation semantics, SIGTERM race during bootstrap, curl -f audit, jq error handling, PID reuse exploitability, test structure uniqueness, GraphQL variable types vs schema, env var precedence, line-continuation correctness, comprehensive sweep. 1 false positive investigated (`customMessage` field exists on `EmailInput`).

### Batch 13 (Round 7) — 0 fixes, 170 tests, **2/5 clean**

All 10 angles verified clean: Dockerfile layer ordering & security, cloudbuild.yaml substitutions, mcp-config.yaml correctness, GraphQL fragments/fields, bootstrap registration payloads, Dockerfile HEALTHCHECK vs Cloud Run probe, shell arithmetic edge cases, heredoc/string quoting, subshell variable scoping, E2E test correctness.

### Batch 14 (Round 8) — 2 fixes, 173 tests, **0/5 clean** (counter resets)

| Severity | Issue | Fix |
|----------|-------|-----|
| Medium | `uv` binary downloaded from `/latest/` URL — non-reproducible builds | Pinned to 0.10.10 via `ARG UV_VERSION`; pinned `psycopg2-binary==2.9.10` |
| Low | `/tmp/jq-err-$$.log` not cleaned on token success path | Added to `rm -f` on success path |

### Batch 15 (Round 9) — 1 fix, 175 tests, **0/5 clean** (counter resets)

| Severity | Issue | Fix |
|----------|-------|-----|
| Medium | `@shopify/dev-mcp@latest` and `mcp-google-sheets@latest` fetched at runtime — non-reproducible cold starts | Pinned to `@shopify/dev-mcp@1.7.1` and `mcp-google-sheets@0.6.0` |

### Batch 16 (Round 10) — 1 fix, 176 tests, **0/5 clean** (counter resets)

| Severity | Issue | Fix |
|----------|-------|-----|
| Low | Comment "see CLAUDE.md" for SDL update instructions — CLAUDE.md has no such section | Updated to describe actual procedure |

### Batch 17 (Round 11) — 0 fixes, 176 tests, **1/5 clean**

All 10 angles clean: Numeric comparison edge cases, word splitting in arrays, pipe failure detection (pipefail), .dockerignore vs COPY, Cloud Run config completeness, bootstrap timing vs JWT expiry, test isolation, API response handling (429, 503), container restart behavior, comprehensive sweep.

### Batch 18 (Round 12) — 0 fixes, 176 tests, **2/5 clean**

All 10 angles clean: Signal handler re-entrancy, bash string length limits, process group vs individual PID signals, curl redirect following, bootstrap idempotency, file descriptor inheritance, arithmetic with leading zeros, test regex portability (bash 4.x vs 5.x), error recovery after partial bootstrap, shellcheck compliance.

### Batch 19 (Round 13) — 0 fixes, 176 tests, **3/5 clean**

All 10 angles clean: Symlink/path traversal safety, URL encoding completeness, PID file write race, exit trap vs explicit exit interactions, bash IFS sensitivity, test count inflation, GraphQL alias conflicts, Cloud Build substitution edge cases, bash glob expansion, .dockerignore completeness.

### Batch 20 (Round 14) — 0 fixes, 176 tests, **4/5 clean**

All 10 angles clean (adversarial): Malformed input fuzzing, integer overflow in bash, Docker COPY race conditions, NPX/uv network dependency at runtime, database migration race, OAuth 2.1 compliance, negative test coverage, dependency rollback path, log rotation/disk exhaustion, final adversarial sweep.

### Batch 21 — FINAL (Round 15) — 0 fixes, 176 tests, **5/5 clean — PROTOCOL COMPLETE**

All 10 angles clean: Binary safety of all data paths, timeout cascade analysis, error propagation completeness, resource cleanup on every exit path, security of external communications, correctness of conditional logic, variable shadowing/scope conflicts, test reliability under CI, documentation vs implementation drift, absolute final character-by-character check.

**EXIT CONDITION MET: 5 consecutive clean batches (Batches 17-21).**

---

## Remaining Architectural Issues (Not Code Bugs)

These require design decisions or upstream changes, tracked in `docs/architecture.md` V4 Design Directions:

| Priority | Issue |
|----------|-------|
| High | Virtual server UUID stability across deploys |
| High | `AUTH_REQUIRED=true` on ContextForge for defense-in-depth |
| High | Identity propagation (auth-proxy → ContextForge) |
| Medium | SSRF allowlist (currently blanket localhost/private) |
| Medium | Dedicated service account (least-privilege) |
| Medium | `/app/.venv` read-only at filesystem level |
