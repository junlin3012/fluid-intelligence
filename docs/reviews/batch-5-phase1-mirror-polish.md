# Mirror Polish Batch 5 — Phase 1 Code Changes

**Date**: 2026-03-16
**Target**: Phase 1 implementation + Batch 1-3 fixes
**Mode**: Code-only verification
**Method**: Brainstorming + Systematic Debugging
**Clean batch counter**: 2/5

## Review Angles (10 rounds)

| Round | Complexity | Angle | Status |
|-------|-----------|-------|--------|
| R1 | Medium | OAuth HMAC `params.pop("hmac")` dict mutation safety | CLEAN |
| R2 | Complex | Scope comparison with `:` delimiter and whitespace | CLEAN |
| R3 | Medium | `parse_http_code()` empty/malformed curl output | CLEAN |
| R4 | Medium | PostgreSQL connection per-request in webhook handler | CLEAN |
| R5 | Medium | `register_webhooks` base URL extraction via rsplit | CLEAN |
| R6 | Simple | tini SHA256 checksum pinning correctness | CLEAN |
| R7 | Complex | Shell variable expansion in inline Python scripts | CLEAN |
| R8 | Medium | Virtual server jq `--argjson` with invalid TOOL_IDS | CLEAN |
| R9 | Medium | `existing_ids` newline-separated iteration in delete loop | CLEAN |
| R10 | Complex | httpx timeout exception handling in token exchange | CLEAN |

## Fixes Applied

None — all 10 angles verified clean.

## Observations (not flaws)

| Finding | Assessment |
|---------|-----------|
| R2: SHOPIFY_SCOPES not set in production (cloudbuild.yaml) | Scope comparison code exists but is behind `if settings.SHOPIFY_SCOPES:` guard. Dead code in current deployment but correct for future use. |
| R4: No connection pooling in webhook handlers | Low volume (Shopify sends ~1-2 webhooks per event). get_connection() + close() per request is adequate for current scale. |
| R7: `DB_PASSWORD="$DB_PASSWORD" python3 -c "..."` — shell expands first `$DB_PASSWORD` | Safe because GCP Secret Manager injects values directly into env, not through shell parsing. os.environ access in Python avoids double-expansion. |

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable Corrections |
|-------|-------|--------|-------------------|
| 1 | 2 | No | flock missing from container, SSE probe exit code bug |
| 2 | 3 | No | JWT comment accuracy, convergence log misleading, Dockerfile comment |
| 3 | 1 | No | Test pipe bug (grep -q | head always returns 0) |
| 4 | 0 | YES | First clean batch |
| 5 | 0 | YES | Second clean batch |

**Clean batch counter: 2/5**
**Fix trend: 2→3→1→0→0**
