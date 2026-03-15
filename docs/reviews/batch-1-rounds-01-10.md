# Code Review Batch 1 — Rounds 1-10

**Date**: 2026-03-15
**Files reviewed**: `scripts/entrypoint.sh`, `scripts/bootstrap.sh`, `scripts/test-e2e.sh`, `deploy/Dockerfile`, `graphql/**/*.graphql`
**Tests**: 67/67 passing
**Commit**: Batch 1 fixes committed

## Findings

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

## Test Framework

Created `scripts/test-unit.sh` — a local unit test framework that validates:
- Signal handling (trap, exit codes, PID management)
- Env var validation (required vars, format checks, ordering)
- URL encoding of passwords
- Bootstrap registration logic (idempotency, liveness checks)
- GraphQL operation correctness (types, pagination, field names)
- Dockerfile structure (layer ordering, permissions)

## Architectural Issues (Tracked, Not Quick Fixes)

- mcp-auth-proxy secrets visible in `/proc/cmdline` (needs upstream support)
- Unpinned `@latest` packages in npx/uv commands
- No query cost estimation for GraphQL execute tool
- Base image not pinned by digest
