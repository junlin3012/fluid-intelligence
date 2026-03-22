# Mirror Polish Batch 14 — v4 Design Spec

**Date**: 2026-03-20
**Mode**: Adversarial (10 fresh dimensions)
**Clean batch counter**: 0/5 (reset — 1 fix)

## Review Dimensions

| Round | Dimension | Status |
|-------|-----------|--------|
| R1 | Bootstrap token_endpoint_auth_methods | CLEAN |
| R2 | Admin API after bootstrap | CLEAN |
| R3 | Logout + refresh token family | CLEAN |
| R4 | Cloud Run 10-container limit | CLEAN |
| R5 | tenant_id JWT mapper type | CLEAN |
| R6 | **Tool caching + RBAC cross-tenant leak** | **ISSUE FOUND** |
| R7 | Alembic advisory lock timeout | CLEAN |
| R8 | Realm name "fluid" hardcoded in spec | CLEAN |
| R9 | SIGTERM + database connection drain | CLEAN |
| R10 | Invalid tool name error handling | CLEAN |

## Fix Applied

| Severity | Issue | Fix |
|----------|-------|-----|
| **HIGH** | Tool result caching uses SHA256(tool+args) as key — no tenant_id or role in key. Cross-tenant data leakage: tenant A sees tenant B's cached Shopify data. Cross-role leakage: viewer sees admin's cached results. | Added security note to caching: cache keys MUST include {tenant_id, user_role}. Verify ContextForge cache key composition; disable caching if keys can't be scoped. |

Fix trend: 27→18→5→5→1→10→12→11→6→4→4→0→0→**1**
