# Mirror Polish Batch 12 — v4 Design Spec

**Date**: 2026-03-20
**Mode**: Adversarial fresh dimensions (10 angles not covered in Batches 1-11)
**Clean batch counter**: 1/5

## Review Dimensions

| Round | Dimension | Status |
|-------|-----------|--------|
| R1 | Keycloak realm JSON attack surface | **CLEAN** |
| R2 | ContextForge plugin hook ordering guarantee | **CLEAN** |
| R3 | Cloud Run Pre-GA container dependency risk | **CLEAN** |
| R4 | Keycloak-ContextForge clock skew | **CLEAN** |
| R5 | Database migration conflict (Liquibase vs Alembic) | **CLEAN** |
| R6 | Tenant credential injection detail | LOW — already tracked as open item #902 |
| R7 | MCP SSE stream termination on SIGTERM | **CLEAN** |
| R8 | Google Sheets service account security | **CLEAN** |
| R9 | Apollo schema introspection rate limits | **CLEAN** |
| R10 | Spec completeness for new implementer | **CLEAN** |

## Fixes Applied: 0

R6 finding (tenant-to-secret-name resolution unspecified) is intentionally deferred design tracked by open item #902. Input validation on `tenant_id` (non-empty alphanumeric, max 64 chars) covers the security-critical path traversal risk. Not a spec defect.

## Cumulative: Fix trend 27→18→5→5→1→10→12→11→6→4→4→**0**

**Clean batch counter: 1/5**
