# Mirror Polish — Domain 2: Identity & Security — COMPLETE

**Date**: 2026-03-18
**Total batches**: 7 | **Total dimensions**: 71 | **Total fixes**: 4 | **Consecutive clean**: 6

## Fix Summary (Batch 1 only)

| # | Severity | Issue | Fix |
|---|----------|-------|-----|
| 1 | HIGH | Identity forwarding chain never E2E verified | Documented verification steps + known gaps in system-understanding.md |
| 2 | Medium | PRIMARY_USER_EMAIL whitespace from `%%,*` expansion | Added `${PRIMARY_USER_EMAIL// /}` trim |
| 3 | Low | Email in URL path `/rbac/users/$email/roles/` not URL-encoded | Added `urlencode()` helper using Python urllib |
| 4 | Medium | PLATFORM_ADMIN_EMAIL=admin@ is phantom identity that can't OAuth login | Documented mismatch in system-understanding.md with recommendation |

## Convergence

| Batch | Fixes | Clean? |
|-------|-------|--------|
| 1 | 4 | No |
| 2 | 0 | YES |
| 3 | 0 | YES |
| 4 | 0 | YES |
| 5 | 0 | YES |
| 6 | 0 | YES |
| 7 | 0 | YES |

**Fix trend: 4→0→0→0→0→0→0**

## Key Findings (verified clean)

- TRUST_PROXY_AUTH_DANGEROUSLY is safe — port 4444 is internal-only
- JWT types (HMAC for bootstrap, RS256 for clients) serve different paths correctly
- SSO_AUTO_CREATE_USERS + SSO_GOOGLE_ADMIN_DOMAINS correctly auto-promote on first login
- Auth-proxy RSA keys regenerate on cold start — tokens auto-invalidate (feature, not bug)
- RBAC functions are non-fatal by design — partial service > total failure
- Unix socket to Cloud SQL = no TLS needed (never leaves machine)
- Bootstrap JWT on localhost only — zero network exposure
- Fosite `sub` claim fix verified — JWTClaims.Subject set correctly at token exchange
