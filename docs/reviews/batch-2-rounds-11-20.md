# Code Review Batch 2 — Rounds 11-20

**Date**: 2026-03-15
**Files reviewed**: `scripts/entrypoint.sh`, `scripts/bootstrap.sh`, `deploy/Dockerfile`, `scripts/test-e2e.sh`
**Tests**: 79/79 passing (67 from batch 1 + 12 new)
**Commit**: `6ce0a78` — batch 2 fixes

## Findings

| Round | Severity | Issue | Fix |
|-------|----------|-------|-----|
| R11 | High | ContextForge health poll `curl` has no `--connect-timeout` — one stalled TCP connect can exhaust 180s budget | Added `--connect-timeout 2 --max-time 5` to health poll curl |
| R12 | Medium | `$attempt` and `$max_attempts` unquoted in `[ ]` test and `sleep` in bootstrap.sh — word splitting risk | Quoted all variables: `"$attempt"`, `"$max_attempts"` |
| R14 | High | `DB_PASSWORD` used in URL encoding (line 27) before validated (line 41) — if unset, python3 crashes with confusing error | Moved all env var validation BEFORE `DATABASE_URL` construction |
| R14 | Medium | PORT and URL error messages don't show the invalid value — hard to debug | Added `got: $value` to MCPGATEWAY_PORT and EXTERNAL_URL error messages |
| R14 | Medium | Shopify token failure only logs HTTP status, not the response body — Shopify error messages lost | Added `echo "[fluid-intelligence] Response body: $(echo "$body" \| head -c 500)"` |
| R14 | Medium | Monitor loop exit message is informational but container is about to die | Tagged as `FATAL:` to match severity |
| R16 | Medium | E2E test suite has no negative MCP tests — invalid methods and malformed JSON untested | Added section 8: invalid method (-32601) and malformed JSON (-32700) tests |
| R18 | Medium | Dockerfile uses separate `RUN chmod/chown` layer — wastes build cache, adds layer | Replaced with `COPY --chmod=755 --chown=root:0` (BuildKit native) |
| R18 | Low | Dockerfile copies scripts before schema — scripts change most often, invalidating cache for stable layers | Reordered: schema (rare) -> config -> graphql -> scripts (frequent) |

## Test Additions

12 new unit tests added to `scripts/test-unit.sh`:
- R11: `--connect-timeout` present on health poll
- R14: Validation ordering (DB_PASSWORD validated before URL encoding)
- R14: Error messages include variable values (PORT, URL)
- R14: Token failure logs response body
- R14: Monitor messages tagged FATAL
- R12: Variable quoting in bootstrap while-test and sleep
- R18: Dockerfile uses `COPY --chmod`
- R18: Dockerfile layer ordering (schema before scripts)
- R16: E2E has invalid method test
- R16: E2E has malformed JSON test

## Bug Fixes in Test Framework

- Fixed `grep -c` with `\|` patterns returning multi-line output causing `integer expression expected` — switched to `grep -cE` with `||` fallback assignment

## Remaining Architectural Issues

Carried from batch 1 (not quick fixes):
- mcp-auth-proxy secrets in `/proc/cmdline`
- Unpinned `@latest` packages
- No query cost estimation for GraphQL execute tool
- Base image not pinned by digest
