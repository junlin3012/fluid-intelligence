# Mirror Polish Batch 1 — Identity RBAC Plan

**Date**: 2026-03-17
**Target**: `docs/superpowers/plans/2026-03-17-identity-rbac.md` (implementation plan)
**Mode**: Code-only (plan document verified against actual codebase files)
**Method**: Brainstorming + Systematic Debugging (7 parallel subagents)
**Clean batch counter**: 0/3

## Review Angles (10 rounds)

| Round | Angle | Status |
|-------|-------|--------|
| R1 | Line number accuracy (Dockerfile.base, cloudbuild, bootstrap, entrypoint) | ISSUE FOUND |
| R2 | Go build command correctness (main package location) | CLEAN |
| R3 | SHA-256 checksum command on macOS | CLEAN |
| R4 | cloudbuild.yaml env var quoting (hyphens in YAML) | CLEAN |
| R5 | ContextForge team/role API endpoint existence | CLEAN |
| R6 | `parse_http_code` scope availability in bootstrap RBAC section | CLEAN |
| R7 | JWT token 10-min expiry vs worst-case bootstrap timing | ISSUE FOUND |
| R8 | Go build path (`go build .` vs `cmd/` subdirectory) | CLEAN |
| R9 | Upstream proxy.go line numbers (handleProxy at line 58) | CLEAN |
| R10 | gcloud logging filter pattern match against actual log format | ISSUE FOUND |

## Fixes Applied

| Round | Severity | Issue | Fix | Verification |
|-------|----------|-------|-----|-------------|
| R1 | Low | `Dockerfile.base:22-25` should be `:21-25` (Stage 2 starts at line 21) | Updated File Map and Task 2 references | Verified against actual file — line 21 is `# Stage 2: mcp-auth-proxy binary` |
| R7 | Medium | JWT 10-min expiry may be insufficient — worst-case existing bootstrap takes ~596s, leaving <4s for RBAC | Added JWT expiry warning + mitigation note to Task 5 context | Calculated from bootstrap.sh wait loops: Apollo 60s + registration retries + dev-mcp 120s + sheets 60s + tool discovery 60s |
| R10 | Low | gcloud logging filter assumes exact field names but ContextForge log format unverified | Added verification note to Task 7 Step 3 with fallback approach | Confirmed ContextForge uses textPayload (not jsonPayload) from architecture.md |

## Observations (not flaws)

| Finding | Assessment |
|---------|-----------|
| R3: `sha256sum` not default macOS | User has coreutils installed (`/sbin/sha256sum`), so not an issue for THIS user. A different engineer might need `shasum -a 256`. Acceptable — plan is for this team. |
| R5: Response format assumption | bootstrap-teams.sh assumes `POST /teams` returns `{id: "..."}` not `{team: {id: "..."}}`. Verified correct from POC + deep knowledge docs, but will be caught immediately in Task 7 if wrong. |
| R9: POC vs upstream line numbers | POC proxy.go already has the patch applied (lines 78-88), so its line numbers differ from upstream. Plan correctly references upstream line numbers (verified by R9 agent reading actual upstream). |

## Key Decisions & Rationale

- **JWT expiry: warning, not a mandatory fix in this plan.** The 10-min expiry issue only manifests under worst-case timing (all 3 backends hitting max retry loops). Normal startup is ~20s. Added as a warning with mitigation path rather than a blocking fix.
- **Log filter: note rather than fix.** The filter pattern can't be verified without a live deployment. Added a fallback approach (inspect raw logs first) so the engineer isn't blocked.

## Pre-Protocol Fixes (Plan Reviewer)

Before Mirror Polish, the plan reviewer found and we fixed 5 issues:
1. (Critical) `create_team` stdout capture bug — log messages mixed with return value → added `>&2`
2. (Medium) `gh repo fork --org=junlin3012` fails for user accounts → removed `--org`
3. (Low) POC reference implied Step 2 was included → clarified it's not
4. (Low) File Map described Task 4 as code change → corrected to documentation
5. (Low) Env var count wording → clarified "6 new + 1 modified = 7"

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable Corrections |
|-------|-------|--------|-------------------|
| Pre | 5 | — | stdout capture bug, fork command, POC reference accuracy |
| 1 | 3 | No | JWT expiry timing, Dockerfile line numbers, log filter verification |

**Clean batch counter: 0/3**
**Accumulated verified-clean angles:** R2 (Go build path), R3 (SHA256 macOS), R4 (YAML quoting), R5 (API endpoints), R6 (parse_http_code scope), R8 (main package location), R9 (upstream line numbers)
