# Mirror Polish Batch 1 — Identity & Security

**Date**: 2026-03-18
**Target**: Identity forwarding, RBAC setup, proxy auth mode, JWT handling
**Mode**: Code-only verification
**Clean batch counter**: 0/6

## Review Dimensions (10 rounds + 1 bonus)

| Round | Dimension | Status |
|-------|-----------|--------|
| D2-R1 | Identity forwarding E2E chain verification | ISSUE FOUND (HIGH — needs live test) |
| D2-R2 | RBAC bootstrap user existence race | CLEAN (correctly mitigated) |
| D2-R3 | SSO_GOOGLE_ADMIN_DOMAINS config | CLEAN |
| D2-R4 | TRUST_PROXY_AUTH_DANGEROUSLY safety | CLEAN |
| D2-R5 | JWT_SECRET_KEY vs AUTH_ENCRYPTION_SECRET | CLEAN |
| D2-R6 | PROXY_USER_HEADER coupling | CLEAN (documented latent risk) |
| D2-R7 | RBAC error handling — non-fatal design | CLEAN |
| D2-R8 | PRIMARY_USER_EMAIL whitespace from expansion | ISSUE FOUND |
| D2-R9 | CLI args in /proc/cmdline | CLEAN (accepted risk) |
| D2-R10 | Email in URL path — encoding | ISSUE FOUND |
| D2-R11 | PLATFORM_ADMIN_EMAIL vs GOOGLE_ALLOWED_USERS | ISSUE FOUND (documented) |

## Fixes Applied (4 issues)

| Round | Severity | Issue | Fix |
|-------|----------|-------|-----|
| D2-R1 | HIGH | Identity forwarding never E2E verified | Documented in system-understanding.md as known gap with verification steps |
| D2-R8 | Medium | `${GOOGLE_ALLOWED_USERS%%,*}` can leave trailing whitespace | Added `${PRIMARY_USER_EMAIL// /}` trim after derivation |
| D2-R10 | Low | Email with `@` or `+` chars used directly in URL path `/rbac/users/$email/roles/` | Added `urlencode()` helper, applied to assign_role and user lookup |
| D2-R11 | Medium | PLATFORM_ADMIN_EMAIL=admin@ is a phantom identity that can't authenticate | Documented mismatch in system-understanding.md with recommendation to align |

## Cumulative Protocol Status

| Batch | Fixes | Clean? |
|-------|-------|--------|
| D2-B1 | 4 | No |

**Clean batch counter: 0/6**
