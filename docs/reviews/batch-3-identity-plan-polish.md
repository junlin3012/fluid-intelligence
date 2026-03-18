# Mirror Polish Batch 3 — Identity RBAC Plan

**Date**: 2026-03-17
**Target**: `docs/superpowers/plans/2026-03-17-identity-rbac.md`
**Mode**: Code-only (plan document verified against spec + codebase)
**Method**: Brainstorming + Systematic Debugging
**Clean batch counter**: 0/3

## Review Angles (10 rounds)

| Round | Angle | Status |
|-------|-------|--------|
| R21 | `go build ./...` vs `go build .` redundancy | CLEAN |
| R22 | `CGO_ENABLED=0` safety for crypto/rsa | CLEAN |
| R23 | Commit message conventional types (`config:` invalid) | ISSUE FOUND |
| R24 | RBAC bootstrap re-entrancy edge cases | ISSUE FOUND |
| R25 | architecture.md section findability | CLEAN |
| R26 | `--no-auto-tls` preserved in fork | CLEAN |
| R27 | VIEWER_TEAM_ID empty guard in commented code | CLEAN |
| R28 | Cloud Build timeout for base image | CLEAN |
| R29 | AUTH_REQUIRED duplicate risk in env var edit | ISSUE FOUND |
| R30 | Spec success criteria coverage (1/4 tested) | ISSUE FOUND |

## Fixes Applied

| Round | Severity | Issue | Fix | Verification |
|-------|----------|-------|-----|-------------|
| R23 | Low | `config:` not a valid Conventional Commits type | Changed to `ci:` | Standard types: feat, fix, build, ci, docs, style, refactor, perf, test, chore |
| R24 | Low | Empty team_id after 2xx not warned about | Added explicit warning when `team_id` is empty/null after successful creation | Matches existing pattern in bootstrap.sh virtual server ID check (lines 286-291) |
| R29 | Low | Plan says "don't duplicate" but doesn't show exact edit | Added precise instructions: replace `AUTH_REQUIRED=false` → `true` in-place, then append 6 new vars | Eliminates ambiguity for executing agent |
| R30 | Medium | Only 1 of 4 spec success criteria tested | Added criteria coverage table to Task 7 explaining which are tested and why others are deferred | Criteria #1,3,4 need a viewer user (not yet provisioned) |

## Observations (not flaws)

| Finding | Assessment |
|---------|-----------|
| R21: Step 4 redundant | `go build ./...` catches orphan packages; `go build .` catches all transitive deps. Redundant for this patch but harmless |
| R22: crypto/rsa with CGO_ENABLED=0 | Pure Go fallback used (not boring crypto). Safe |
| R26: --no-auto-tls | CLI flag in main.go, untouched by our proxy.go patch |
| R28: 3600s timeout | More than enough — Go binary downloaded pre-built, only Rust compiles |

## Key Decisions & Rationale

- **Success criteria #1,3,4 deferred to viewer-user follow-up.** No viewer user is provisioned in this initial deployment (commented out). Testing non-admin filtering requires a real second user. This is expected — the plan delivers identity attribution (criterion #2) and the RBAC infrastructure. Access filtering becomes testable when the first viewer is added.

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable Corrections |
|-------|-------|--------|-------------------|
| Pre | 5 | — | stdout capture bug, fork command, POC reference |
| 1 | 3 | No | JWT expiry timing, Dockerfile line numbers, log filter |
| 2 | 7 | No | Admin API JWT mismatch (HIGH), dependency graph, rollback |
| 3 | 4 | No | Spec criteria coverage, AUTH_REQUIRED edit precision |

**Clean batch counter: 0/3**
**Accumulated verified-clean angles:** R2, R3, R4, R5, R6, R8, R9, R16, R18, R21, R22, R25, R26, R27, R28
