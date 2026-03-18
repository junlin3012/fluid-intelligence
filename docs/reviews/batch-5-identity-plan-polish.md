# Mirror Polish Batch 5 — Identity RBAC Plan

**Date**: 2026-03-17
**Target**: `docs/superpowers/plans/2026-03-17-identity-rbac.md`
**Mode**: Code-only
**Method**: Brainstorming + Systematic Debugging
**Clean batch counter**: 0/3

## Review Angles (10 rounds)

| Round | Angle | Status |
|-------|-------|--------|
| R41 | Plan internal consistency after 4 batches of fixes | CLEAN |
| R42 | Step ordering within Task 1 (non-overlapping edits) | CLEAN |
| R43 | gcloud --sort-by flag validity | CLEAN |
| R44 | "Append after line 311" still accurate | CLEAN |
| R45 | CRLF header injection via JWT sub claim | CLEAN (Go transport blocks) |
| R46 | Prose contradictions ("7 env vars" vs "6 new + 1 change") | CLEAN (borderline but execution instructions clear) |
| R47 | Task 8 missing POC cleanup step | ISSUE FOUND |
| R48 | gh repo fork remote naming (origin = fork) | CLEAN |
| R49 | Dockerfile.base comment style consistency | CLEAN |
| R50 | Total step count (28 steps, reasonable) | CLEAN |

## Fixes Applied

| Round | Severity | Issue | Fix | Verification |
|-------|----------|-------|-----|-------------|
| R47 | Low | Dependency graph says "Task 8 (docs + POC cleanup)" but no POC cleanup step exists | Added Step 3 (delete POC), renumbered commit to Step 4, updated Files list | POC has known stdout bug; leaving it risks copy-paste errors |

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable |
|-------|-------|--------|---------|
| Pre | 5 | — | stdout bug, fork cmd |
| 1 | 3 | No | JWT expiry, line numbers |
| 2 | 7 | No | JWT mismatch (HIGH), dependency graph |
| 3 | 4 | No | Spec criteria, AUTH_REQUIRED edit |
| 4 | 1 | No | Rollback format |
| 5 | 1 | No | POC cleanup step |

**Fix trend: 5 → 3 → 7 → 4 → 1 → 1** (converging)
**Clean batch counter: 0/3**
**Accumulated verified-clean angles:** R2-R6, R8-R9, R16, R18, R21-R22, R25-R28, R31-R38, R40-R46, R48-R50
