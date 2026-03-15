# Code Review Batch 6 — Mirror Shine

**Date**: 2026-03-15
**Tests**: 130/130 unit tests passing
**Method**: Brainstorming + Systematic Debugging — invented 6 debugging dimensions, then applied Phase 1-4 rigor to each

## Approach

Previous batches (1-5, rounds 1-51) focused on **surface correctness**: syntax bugs, missing error handling, curl patterns, GraphQL schema compliance, security hygiene. This batch targeted **deeper structural properties** that surface-level review cannot catch.

Six debugging dimensions were brainstormed, each requiring a different investigative lens:

| Dimension | What It Catches |
|-----------|----------------|
| **D1: Timeout Arithmetic** | Do all timeout/retry chains add up? Inner < outer? Fits Cloud Run probe? |
| **D2: Failure Cascade** | What happens when component X dies at time T? Zombie state? |
| **D3: Data Flow Integrity** | Do transformations (URL encode, JSON parse, shell expand) preserve correctness? |
| **D4: Contract Compliance** | Are tools (curl, jq, bash) used per their documented contracts? |
| **D5: Validation Completeness** | Every input validated? Every code path tested? Any bypass routes? |
| **D6: Observability Gaps** | Can every failure be diagnosed from logs alone? |

## Fixes Applied (14 fixes)

| Dimension | Severity | Issue | Fix |
|-----------|----------|-------|-----|
| **D1** | **High** | ContextForge health timeout (180s) exceeded Cloud Run startup probe (240s). Worst case: 295s, pod killed. | Reduced to 120s. Worst case now 225s. |
| **D1** | Low | Temp files `/tmp/shopify-curl-err-$$.log` orphaned if SIGTERM arrives during token fetch | Added cleanup to `cleanup()` trap |
| **D2** | Medium | ContextForge death during bootstrap not detected — curl retries against dead process for minutes | Added `check_contextforge()` health check before each of 3 registrations |
| **D4** | Medium | `tail -1` for HTTP code extraction breaks on empty-body responses (e.g., 204 No Content) | Added `parse_http_code()` helper with numeric validation in bootstrap.sh |
| **D4** | Medium | entrypoint.sh HTTP code not validated as numeric before arithmetic comparison | Added `[[ "$http_code" =~ ^[0-9]+$ ]] || http_code=0` guard |
| **D4** | Medium | E2E malformed JSON test false-passes via HTTP 400 fallback without verifying JSON-RPC -32700 | Split into separate JSON-RPC check and HTTP-only WARN fallback |
| **D5** | Medium | `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET` not validated at startup — auth-proxy starts broken | Added `: "${VAR:?msg}"` checks in env validation block |
| **D5** | Medium | VS_ID not validated after virtual server creation — empty ID produces `/servers//mcp` (404) | Added null/empty check with FATAL exit and diagnostic output |
| **D5** | Medium | `GetInventoryLevels.graphql` missing `endCursor` in pageInfo — pagination breaks on page 2+ | Added `endCursor` (missed in R46 batch) |
| **D6** | Medium | `register_gateway` curl errors (connection refused, DNS, timeout) sent to `/dev/null` | Capture to temp file, log on failure |
| **D5** | **High** | `DB_USER`/`DB_NAME` interpolated into DATABASE_URL without validation — `@?/` chars corrupt URI | Added alphanumeric regex check |
| **D5** | Medium | PID file contents not validated as numeric — corrupted file triggers false crash detection | Added `^[0-9]+$` check on all 3 PID reads |
| **D5** | Medium | JWT token format not validated — Python warnings in stdout produce garbage token | Added header.payload.signature regex check |
| **D5** | Medium | Virtual server deletion assumes single ID — multiple stale entries leave orphans | Changed to `while read` loop (matches gateway pattern) |

## Stale Agent Findings (triaged from previous session)

| Agent | Finding | Status |
|-------|---------|--------|
| R21 | Temp file not in cleanup trap | **Fixed** (D1) |
| R22 | HTTP code parsing needs numeric validation | **Fixed** (D4) |
| R23 | PID array substring corruption | Already fixed in R50 |
| R24 | Malformed JSON test false-pass | **Fixed** (D4) |
| R25 | Unpinned uv binary | Already tracked (architectural) |
| R26 | GetInventoryLevels missing endCursor | **Fixed** (D5) |
| R27 | AUTH_REQUIRED=false | Already tracked (architectural) |
| R28 | EXTERNAL_URL regex test over-escaping | False positive |
| R29 | PID file write atomicity | Theoretical (5-byte writes effectively atomic) |
| R30 | Missing GOOGLE_OAUTH env var validation | **Fixed** (D5) |
| R31 | mcp-auth-proxy checksum | Already tracked (architectural) |
| R32 | PYTHONUNBUFFERED + DB_POOL_SIZE | Already present in cloudbuild.yaml |
| R33 | SSE casing in patterns.md | Already fixed |
| R41 | Final entrypoint sweep | CLEAN |
| R42 | Final bootstrap sweep | VS_ID validation — **Fixed** (D5) |
| R43 | Final E2E test sweep | CLEAN |
| R44 | Final Dockerfile sweep | CLEAN |

## Timeout Arithmetic Proof

Cloud Run startup probe: `failureThreshold=48 × periodSeconds=5 = 240s`

| Step | Worst Case | Cumulative |
|------|-----------|------------|
| Env validation + URL encoding | 1s | 1s |
| Shopify token (5 attempts) | 95s | 96s |
| 4 process starts (4 × 2s verify) | 8s | 104s |
| ContextForge health wait | **120s** (was 180s) | 224s |
| Auth-proxy start | 2s | **226s** |

**226s < 240s probe limit** (14s margin). Previously 295s (55s overrun).

## Statistics

| Metric | Value |
|--------|-------|
| Debugging dimensions | 6 |
| Fixes applied | 14 |
| Unit tests (total) | 130 |
| New tests this batch | 17 |
| Stale agents triaged | 17 |
| Genuine findings from stale agents | 6 |
| False positives / already fixed | 11 |

## Cumulative Project Statistics (Batches 1-6)

| Metric | Value |
|--------|-------|
| Total review rounds | 51+ |
| Total debugging dimensions | 6 |
| Total code fixes | 52+ |
| Total unit tests | 130 |
| E2E tests | 21 |
| Files modified | 18+ |
