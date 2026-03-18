# Mirror Polish Batch 2 — Deployment Infrastructure

**Date**: 2026-03-18
**Target**: Deployment infrastructure (deeper pass — JWT budget, flock, crypto, SSE probes, version pins, USER directives)
**Mode**: Code-only verification
**Method**: Brainstorming + Parallel Agents + Systematic Debugging + Verification
**Clean batch counter**: 0/6

## Review Dimensions (10 rounds)

| Round | Dimension | Status |
|-------|-----------|--------|
| R11 | cloudbuild secrets coverage — all runtime secrets injected? | CLEAN |
| R12 | bootstrap JWT expiry budget — 15 min enough for worst case? | ISSUE FOUND |
| R13 | flock lock — exec error handling, necessity with max-instances=1 | ISSUE FOUND |
| R14 | Dockerfile.base version pinning — UV SHA256, nodejs unpinned | CLEAN (already documented) |
| R15 | cloudbuild machine type and build optimization | CLEAN |
| R16 | entrypoint DB token query — decrypt_token edge cases | ISSUE FOUND |
| R17 | sheets SSE probe — curl rc=0 logic, WARNING vs FATAL | ISSUE FOUND |
| R18 | Dockerfile USER directives — UID 1001 permissions | CLEAN |
| R19 | tini -g signal forwarding — double SIGTERM safety | CLEAN |
| R20 | cloudbuild env var completeness — proxy auth flags, secrets separation | CLEAN |

## Fixes Applied (4 issues)

| Round | Severity | Issue | Fix | Verification |
|-------|----------|-------|-----|-------------|
| R12 | High | JWT 15-min expiry too tight — worst case is ~14.2 min with zero margin. No token refresh logic. | Bumped expiry from 15 to 30 minutes. Updated comment with accurate worst-case math. | Margin now ~19 min (30 - 11 min worst case) |
| R13 | Medium | `exec 9>"$BOOTSTRAP_LOCK"` has no error check — if /tmp is read-only, fd 9 is invalid and flock incorrectly exits 0 | Added `|| { warn; exec 9>/dev/null }` fallback + `2>/dev/null` on flock call | Script continues gracefully if lock file cannot be created |
| R16 | Medium | `decrypt_token()` has zero input validation — empty key, corrupted data, wrong key size all raise opaque exceptions | Added explicit checks: empty key/token, key size validation, data length minimum | Error messages now name the specific misconfiguration |
| R17 | High | SSE probe accepts curl rc=0 (connection closed = NOT ready). WARNING doesn't exit, continues with broken bridge. Only 30s budget. | Changed to accept only rc=28 (streaming). Upgraded WARNING to FATAL+exit. Extended to 60s (30 attempts × 2s). | Consistent with bootstrap.sh's FATAL pattern |

## Observations (not flaws)

| Finding | Assessment |
|---------|-----------|
| R14: uv missing SHA256, nodejs unpinned | Already documented in architecture.md Issues 11 & 12 with a phased fix plan |
| R13: flock unnecessary with max-instances=1 | True, but removing it would also remove util-linux dep. Low priority cleanup — keep as defense-in-depth. |
| R20: PRIMARY_USER_EMAIL not in cloudbuild.yaml | bootstrap.sh derives it from GOOGLE_ALLOWED_USERS (line 78). Not a gap — just indirect. |
| R12: Sequential backend registration burns token time | Design improvement (parallelize) but not a bug. Current 30-min expiry provides adequate margin. |

## Key Decisions & Rationale

- **JWT 30 min instead of "just add refresh"**: Adding token refresh to bootstrap.sh would require restructuring all curl calls to check for 401 and regenerate. The simpler fix (longer expiry) provides adequate margin with zero code complexity. Refresh logic can be added if max-instances increases.
- **SSE probe: FATAL not WARNING**: Inconsistency with bootstrap.sh's behavior (which exits on failure) was the deciding factor. A broken sheets bridge means tools/list returns incomplete results — better to fail fast.
- **decrypt_token validation**: The outer try/except in entrypoint.sh catches all errors, but the error messages were opaque ("ValueError: invalid key size"). Now the errors explicitly name what's misconfigured.

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable Corrections |
|-------|-------|--------|-------------------|
| 1 | 6 | No | SHA256 hash (security), bare python3 (reliability), PIDS race (signal safety) |
| 2 | 4 | No | JWT expiry budget (availability), SSE probe logic (correctness), decrypt validation (diagnostics) |

**Clean batch counter: 0/6**
**Accumulated verified-clean dimensions: R3, R4, R6, R7, R8-liveness, R10, R11, R14, R15, R18, R19, R20**
