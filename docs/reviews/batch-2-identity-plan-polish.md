# Mirror Polish Batch 2 — Identity RBAC Plan

**Date**: 2026-03-17
**Target**: `docs/superpowers/plans/2026-03-17-identity-rbac.md`
**Mode**: Code-only (plan document verified against actual codebase)
**Method**: Brainstorming + Systematic Debugging (1 comprehensive subagent)
**Clean batch counter**: 0/3

## Review Angles (10 rounds)

| Round | Angle | Status |
|-------|-------|--------|
| R11 | Task 7 TOKEN placeholder not executable | ISSUE FOUND |
| R12 | Dependency graph overstates Task 1 dependencies | ISSUE FOUND |
| R13 | AUTH_REQUIRED=true impact on bootstrap HMAC JWT calls | ISSUE FOUND (uncertainty) |
| R14 | Missing rollback plan for breaking change | ISSUE FOUND |
| R15 | `gh repo fork --clone` location depends on CWD | ISSUE FOUND |
| R16 | `git push` before `gh release create` | CLEAN |
| R17 | Admin API through auth-proxy rejects HMAC JWT (HIGH) | ISSUE FOUND |
| R18 | RBAC failure mode (WARNING vs FATAL) | CLEAN |
| R19 | `git add -A` stages cross-compiled binary | ISSUE FOUND |
| R20 | POC cleanup after implementation | ISSUE FOUND |

## Fixes Applied

| Round | Severity | Issue | Fix | Verification |
|-------|----------|-------|-----|-------------|
| R11+R17 | High | Task 7 Steps 4-5 curl admin API through auth-proxy with HMAC JWT — auth-proxy only accepts RS256 JWTs | Rewrote Steps 4-5 to use `gcloud logging read` instead of admin API calls | Traced auth flow: auth-proxy validates own RS256 JWT → ContextForge HMAC JWT would be rejected |
| R12 | Low | Dependency graph says Tasks 3,4,5 depend on Task 1 — they don't | Corrected graph: only Task 2 depends on Task 1; Tasks 3,4,5 can start immediately | Verified: env vars (T3), comment (T4), bootstrap code (T5) have no reference to fork URL/SHA |
| R13 | Low | AUTH_REQUIRED=true might break bootstrap's HMAC JWT calls to :4444 | Added compatibility note to Task 5 context with isolation guidance | ContextForge auth pipeline Phase 2 validates JWT against JWT_SECRET_KEY — should still work |
| R14 | Medium | No rollback plan for AUTH_REQUIRED false→true breaking change | Added Rollback Plan section with `gcloud run services update-traffic` command | Standard Cloud Run rollback pattern |
| R15 | Low | `gh repo fork --clone` clones to CWD, not ~/Projects/Claude/ | Added `cd ~/Projects/Claude` before fork command | Verified: gh fork clones to `./repo-name/` in CWD |
| R19 | Medium | `git add -A` stages the 15MB cross-compiled binary | Changed to `git add pkg/proxy/proxy.go` (only the patched file) | Binary is uploaded as release asset in Step 8, not committed |
| R20 | Low | POC has known stdout bug, plan doesn't mention cleanup | Added POC cleanup note to Task 8 and dependency graph | POC `bootstrap-teams.sh` has unfixed stdout capture bug |

## Observations (not flaws)

| Finding | Assessment |
|---------|-----------|
| R16: Tag before release | Sequence is correct — Step 7 pushes tag, Step 8 creates release referencing it |
| R18: RBAC non-fatal | Correct design — gateway works without RBAC, WARNING is appropriate |

## Key Decisions & Rationale

- **Admin API verification moved to logs.** Auth-proxy creates an impenetrable boundary between external callers and ContextForge admin API unless you go through the full OAuth flow. For deployment verification, Cloud Run logs are more reliable and don't require JWT gymnastics.
- **Dependency graph relaxed.** Tasks 3,4,5 can now start in parallel with Task 1, significantly reducing the critical path. Only Task 2 (Dockerfile) is blocked on the fork's release.

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable Corrections |
|-------|-------|--------|-------------------|
| Pre | 5 | — | stdout capture bug, fork command, POC reference |
| 1 | 3 | No | JWT expiry timing, Dockerfile line numbers, log filter |
| 2 | 7 | No | Admin API JWT mismatch (HIGH), dependency graph, rollback plan |

**Clean batch counter: 0/3**
**Accumulated verified-clean angles:** R2, R3, R4, R5, R6, R8, R9, R16, R18
