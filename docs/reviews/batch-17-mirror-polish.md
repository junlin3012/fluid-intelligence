# Mirror Polish Batch 17
**Date**: 2026-03-20 | **Clean counter**: 0/5 (reset — 2 fixes)

| Round | Dimension | Status |
|-------|-----------|--------|
| R1-R3 | SSO Session fix, cache key fix, PKCE vs bootstrap | CLEAN |
| R4 | **Graceful shutdown ordering** | **ISSUE** — no mechanism to enforce sidecars outliving ContextForge |
| R5-R9 | Auto-create race, refresh cap, cost, Cargo.lock, EXPOSE | CLEAN |
| R10 | **Realm import idempotency** | **ISSUE** — skip-if-exists behavior undocumented |

Fixes: (1) Added SIGTERM delay mechanism for sidecars. (2) Documented --import-realm skip-if-exists behavior.
