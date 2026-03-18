# Mirror Polish Batch 8 — Identity RBAC Plan

**Date**: 2026-03-17
**Mode**: Code-only | **Clean batch counter**: 0/3 (reset)

| Round | Angle | Status |
|-------|-------|--------|
| R71 | `git rm -r` after `rm -rf` (works fine) | CLEAN |
| R72 | Startup probe vs RBAC time (probe already passed) | CLEAN |
| R73 | jq --arg special chars (plain ASCII) | CLEAN |
| R74 | GOOGLE_ALLOWED_USERS vs SSO_GOOGLE_ADMIN_DOMAINS (different layers) | CLEAN |
| R75 | Task 8 step numbering (Steps 1-4 consistent) | CLEAN |
| R76 | `jq | head -1` under pipefail (guarded by `|| true`) | CLEAN |
| R77 | AUTH_REQUIRED + UI disabled interaction (independent) | CLEAN |
| R78 | Line number references accuracy (all verified) | CLEAN |
| R79 | 10s timeout for localhost team API (generous) | CLEAN |
| R80 | Missing check_contextforge before RBAC | ISSUE FOUND |

**Fix:** Added `check_contextforge` before RBAC setup, consistent with the pattern used before every gateway registration group.

**Fix trend: 5→3→7→4→1→1→0→1→1** | **Counter: 0/3**
