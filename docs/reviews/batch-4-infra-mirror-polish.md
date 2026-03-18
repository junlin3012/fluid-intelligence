# Mirror Polish Batch 4 — Deployment Infrastructure

**Date**: 2026-03-18
**Target**: Deployment infrastructure (adversarial — overflow, timing, token lifetime, API contracts)
**Mode**: Code-only verification
**Method**: Brainstorming + Single Comprehensive Agent + Systematic Debugging
**Clean batch counter**: 0/6 (reset from 1)

## Review Dimensions (10 rounds)

| Round | Dimension | Status |
|-------|-----------|--------|
| R31 | Integer overflow in bash arithmetic | CLEAN |
| R32 | Parallel curl requests — ContextForge contention | CLEAN |
| R33 | SHOPIFY_ACCESS_TOKEN 24h expiry — no refresh | ISSUE FOUND |
| R34 | bootstrap exit code propagation | CLEAN |
| R35 | sed '$d' with binary data edge cases | CLEAN |
| R36 | DNS resolution failure handling | CLEAN |
| R37 | ContextForge trailing slash inconsistency | ISSUE FOUND |
| R38 | Virtual server tool ID staleness during async discovery | CLEAN |
| R39 | Cloud Run cold start with scale-to-zero | CLEAN |
| R40 | DATABASE_URL Unix socket path correctness | CLEAN |

## Fixes Applied (2 issues)

| Round | Severity | Issue | Fix | Verification |
|-------|----------|-------|-----|-------------|
| R33 | Medium | client_credentials fallback token expires in 24h with no refresh mechanism. If container runs 24h+ on this path, all Shopify API calls fail. | Added explicit WARNING log when fallback path is used, advising to install OAuth app for permanent tokens. | Primary path (Cloud SQL offline token) is unaffected. Warning ensures operators know the limitation. |
| R37 | Medium | Gateway/server/tool curl calls missing `-L` (follow redirects). RBAC calls correctly use `-L` + trailing slashes. If ContextForge enables `redirect_slashes`, gateway POSTs would break (307 redirect loses body). | Added `-L` to ALL non-RBAC curl calls (register_gateway, delete gateway, tool discovery, virtual server CRUD, debug dumps). | All curl calls now consistently use `-L`, matching the RBAC section's defensive pattern. |

## Observations (not flaws)

| Finding | Assessment |
|---------|-----------|
| R33: No token refresh for fallback | Design limitation, not a bug. Primary path (offline token) doesn't expire. Adding a refresh mechanism would be over-engineering for a degraded path. Warning log is sufficient. |
| R39: 15-20s cold start latency | Expected with min-instances=0. --cpu-boost mitigates. Cost tradeoff is documented in patterns.md. |

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable Corrections |
|-------|-------|--------|-------------------|
| 1 | 6 | No | SHA256 hash, bare python3, PIDS race, transport docs |
| 2 | 4 | No | JWT expiry, SSE probe logic, decrypt validation, flock error |
| 3 | 0 | YES | First clean — deep security/error/race review |
| 4 | 2 | No | Token lifetime warning, curl -L consistency |

**Clean batch counter: 0/6 (reset)**
**Accumulated verified-clean dimensions: 38 of 40 reviewed**
