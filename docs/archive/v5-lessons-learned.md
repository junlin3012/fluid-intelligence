# v5 Implementation — Lessons Learned

> Written after the v5 implementation failed to achieve end-to-end SSO login.
> This document is the **mandatory reading** for any v6 attempt.
> Every lesson has a concrete, actionable fix.

---

## Summary

v5 goal: Zero custom code. Configure ContextForge + Keycloak + sidecars to work together using only env vars, realm JSON, and UI configuration. Deploy to Cloud Run with Microsoft SSO login working end-to-end.

**Result: Failed.** SSO login flow reached Keycloak successfully but never completed the round-trip back to the ContextForge admin panel. Multiple interacting configuration issues created a chain of failures that took ~8 hours to diagnose.

**The deepest lesson:** When integrating 3+ SaaS applications via configuration, you cannot debug by reading code — you must understand the **contract between each pair of services** and verify each contract independently before connecting them together.

---

## The 7 Bugs That Blocked SSO Login (in order of discovery)

### Bug 1: `MCP_CLIENT_AUTH_ENABLED=false` — The Silent Killer

**What:** ContextForge's `get_current_user_with_permissions()` has TWO code paths:
- `MCP_CLIENT_AUTH_ENABLED=true` → Standard JWT authentication (reads cookies, validates tokens)
- `MCP_CLIENT_AUTH_ENABLED=false` → Proxy auth only (ignores JWT cookies entirely)

We set `MCP_CLIENT_AUTH_ENABLED=false` thinking it only controlled MCP client auth. In reality, it **disabled ALL JWT-based authentication**, including the admin panel's SSO cookie.

**Why it was hard to find:** A separate Starlette middleware (`TokenScopingMiddleware`) ran independently and successfully validated the JWT, logging "Admin bypass: skipping team validation." This made it look like auth was working. But the actual FastAPI dependency that gates admin access never even read the JWT.

**The fix:** `MCP_CLIENT_AUTH_ENABLED=true`

**Lesson:** When a SaaS app has a setting that sounds like it only affects one subsystem, **read the source code** to verify its actual scope. The name `MCP_CLIENT_AUTH_ENABLED` implies it only affects MCP clients, but it's the master switch for all JWT auth.

**Prevention for v6:** Before setting ANY auth-related env var to `false`, trace every code path that reads it. Use `grep -rn "mcp_client_auth" /app/` inside the container.

---

### Bug 2: `ALLOWED_ORIGINS` — Two Cloud Run URL Formats

**What:** Cloud Run generates two URL formats for the same service:
1. `service-HASH-REGION.a.run.app` (old format)
2. `service-PROJECTNUMBER-REGION.run.app` (new format)

`ALLOWED_ORIGINS` had format 1. The browser used format 2. ContextForge rejected the SSO redirect_uri as invalid.

**Lesson:** Always include BOTH Cloud Run URL formats in `ALLOWED_ORIGINS`. Or better: set a custom domain to avoid this entirely.

**Prevention for v6:** After deploying, run:
```bash
gcloud run services describe SERVICE --region=REGION --format='value(status.url)'
```
and verify that URL is in `ALLOWED_ORIGINS`.

---

### Bug 3: `redirect_uri` Not in Keycloak Client

**What:** Keycloak's `fluid-gateway-sso` client has a whitelist of valid redirect URIs. The new Cloud Run URL format wasn't in the list. Keycloak returned "Invalid parameter: redirect_uri."

**Lesson:** The redirect_uri must be whitelisted in THREE places:
1. ContextForge `ALLOWED_ORIGINS` env var
2. Keycloak client `redirectUris` list
3. The actual URL the browser uses

All three must match exactly.

**Prevention for v6:** Create a checklist:
```
[ ] ALLOWED_ORIGINS contains the gateway URL
[ ] Keycloak client redirectUris contains gateway/auth/sso/callback/keycloak
[ ] Keycloak client webOrigins contains the gateway URL
[ ] Browser URL matches one of the above
```

---

### Bug 4: Missing `realm-roles` Client Scope Assignment

**What:** Even though `realm-roles` was in `defaultDefaultClientScopes` in realm-fluid.json, Keycloak doesn't always import default scope assignments for existing clients. The `fluid-gateway-sso` client didn't have `realm-roles` as a default scope, so JWTs didn't contain `realm_access.roles`.

**Lesson:** After Keycloak realm import, verify each client's assigned scopes through the Admin UI. The realm-level defaults only apply to NEW clients created after import.

**Prevention for v6:** Post-import verification checklist:
```
[ ] Open Keycloak Admin → Clients → fluid-gateway-sso → Client Scopes
[ ] Verify realm-roles is in Default scopes
[ ] Verify fluid-audience is in Default scopes
[ ] Verify fluid-session is in Default scopes
[ ] Get a test token and decode it to verify claims are present
```

---

### Bug 5: No SSO Role Mappings Configured

**What:** `SSO_KEYCLOAK_MAP_REALM_ROLES=true` enables extracting realm roles from JWTs. But ContextForge's `_map_groups_to_roles()` also needs `role_mappings` in the provider metadata to know WHICH Keycloak role maps to WHICH ContextForge role. Without this, the logs showed: `"No role mappings configured for provider keycloak, skipping role sync"`

The user had `is_admin=true` in the DB (from `SSO_TRUSTED_DOMAINS` domain matching), and `platform_admin` role was manually inserted, but the automatic role-mapping pipeline was non-functional.

**Lesson:** `SSO_KEYCLOAK_MAP_REALM_ROLES=true` is only HALF the configuration. You also need role_mappings. The ContextForge docs don't make this obvious.

**Prevention for v6:** After SSO is working, verify role sync:
```
1. Create a realm role "platform_admin" in Keycloak
2. Assign it to the user in Keycloak
3. Configure role_mappings in ContextForge (via Admin API or UI)
4. Log in via SSO
5. Check user_roles table: does the user have platform_admin?
```

---

### Bug 6: `admin.dashboard` Permission Requires RBAC Role, Not Just `is_admin=true`

**What:** The admin panel route uses `@require_permission("admin.dashboard", allow_admin_bypass=False)`. This explicitly DISABLES the `is_admin` shortcut. Even with `is_admin=true` in the database, the user must have a `platform_admin` RBAC role explicitly assigned in the `user_roles` table.

**Lesson:** `is_admin=true` is NOT the same as having admin access. ContextForge uses two separate authorization layers:
1. `is_admin` flag — used by some code paths (token scoping, team resolution)
2. RBAC roles + permissions — used by the admin panel

The admin panel deliberately uses layer 2 with `allow_admin_bypass=False` for security.

**Prevention for v6:** After creating an admin user, verify BOTH:
```sql
SELECT is_admin FROM email_users WHERE email = 'user@domain.com';  -- Should be true
SELECT r.name FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE ur.user_email = 'user@domain.com';  -- Should include platform_admin
```

---

### Bug 7: `email_verified` Mapper Type Mismatch

**What:** The Keycloak identity provider mapper for `email_verified` used `hardcoded-attribute-idp-mapper` (string attribute) instead of `hardcoded-user-session-attribute-idp-mapper`. This caused email verification to not propagate correctly from Microsoft Entra ID to Keycloak to ContextForge.

**Lesson:** Keycloak has multiple mapper types that sound similar but work differently. Always verify the mapper type in the Admin UI and test with a real login.

---

## Systemic Failures (Not Just Bugs)

### Failure 1: Debugging by Reading Source Code Instead of Testing Contracts

**What happened:** When SSO failed, the agent spent ~4 hours reading ContextForge source code (auth.py, rbac.py, sso_service.py, permission_service.py, token_scoping.py) line by line, tracing code paths, building mental models of how the auth pipeline worked.

**Why it failed:** The code was correct. Every function did what it was supposed to. The bug was in the CONFIGURATION — env vars that changed which code path was taken. Reading code can tell you what WOULD happen if the right path is taken, but it can't tell you which path IS being taken with a given configuration.

**What should have been done:** Instead of reading source code, test each contract:

```bash
# Contract 1: Does Keycloak issue valid tokens?
curl -X POST keycloak/realms/fluid/protocol/openid-connect/token \
  -d "grant_type=client_credentials&client_id=fluid-gateway-sso&client_secret=SECRET"
# Decode the JWT — does it have realm_access.roles?

# Contract 2: Does ContextForge accept the token?
curl -H "Authorization: Bearer $TOKEN" gateway/admin/
# What status code? What error message?

# Contract 3: Does the SSO callback work?
curl -v gateway/auth/sso/login/keycloak
# Does it redirect to Keycloak? What redirect_uri does it use?
```

**Lesson for v6:** When debugging SSO integrations, NEVER read source code first. Instead:
1. Test each service independently (can Keycloak issue tokens? can ContextForge validate them?)
2. Test each interface between services (does the redirect_uri match? does the callback URL work?)
3. Only read source code AFTER you've isolated which specific interface is failing

### Failure 2: Not Testing Locally Before Cloud Deployment

**What happened:** Many issues were discovered on Cloud Run, leading to slow debug cycles (deploy → wait → check logs → fix → redeploy). The 3-deploy limit rule existed but was not followed systematically.

**What should have been done:** Complete the ENTIRE SSO flow locally first:
1. `docker-compose up` with all services
2. Open browser to `localhost:8080/admin`
3. Click "Continue with Keycloak"
4. Complete login flow
5. Verify admin panel loads
6. Only THEN deploy to Cloud Run

**Why it wasn't done:** The Microsoft Entra ID IdP was only configured on the Cloud Run Keycloak instance, not locally. So SSO testing required Cloud Run.

**Lesson for v6:** Configure the identity provider (Google/Microsoft) on the LOCAL Keycloak first. Use `localhost:8180` redirect URIs for local testing. Get the entire flow working locally before touching Cloud Run.

### Failure 3: Too Many Variables Changed at Once

**What happened:** The v5 implementation changed everything simultaneously:
- New docker-compose (3 → 6 services)
- New Keycloak realm JSON (from scratch)
- New ContextForge config (SSO instead of custom plugin)
- New Cloud Run deployment
- New Microsoft Entra ID IdP
- New Apollo GraphOS integration

When SSO failed, it was impossible to tell which change caused the failure.

**What should have been done:** Change ONE thing at a time and verify:
1. First: Get ContextForge running with local email/password auth only
2. Then: Add Keycloak with SSO to ContextForge (no Microsoft yet)
3. Then: Add Microsoft IdP to Keycloak
4. Then: Add sidecars
5. Then: Deploy to Cloud Run

**Lesson for v6:** Each phase should have exactly ONE new integration. Verify end-to-end before adding the next.

---

## The v6 Implementation Order (Recommended)

Based on all lessons learned, here's the order that minimizes risk:

### Phase 0: Local ContextForge with Email Auth (30 min)
```
docker-compose: postgres + contextforge only
AUTH_REQUIRED=true
MCP_CLIENT_AUTH_ENABLED=true  ← CRITICAL
PLATFORM_ADMIN_EMAIL=admin@example.com
PLATFORM_ADMIN_PASSWORD=secure-password
```
**Verify:** Log in at localhost:8080/admin with email/password. See the dashboard.

### Phase 1: Add Keycloak with SSO (1 hour)
```
Add keycloak service to docker-compose
SSO_ENABLED=true
SSO_KEYCLOAK_ENABLED=true
SSO_KEYCLOAK_BASE_URL=http://keycloak:8080
SSO_KEYCLOAK_REALM=fluid
SSO_KEYCLOAK_CLIENT_ID=fluid-gateway-sso
SSO_KEYCLOAK_CLIENT_SECRET=test-secret
SSO_KEYCLOAK_MAP_REALM_ROLES=true
SSO_AUTO_CREATE_USERS=true
ALLOWED_ORIGINS=http://localhost:8080
```
**Verify:** Click "Continue with Keycloak" → login with Keycloak local user → see dashboard.

### Phase 2: Add Microsoft/Google IdP to Keycloak (30 min)
```
Configure in Keycloak Admin UI (localhost:8180)
Add identity provider: Microsoft or Google
Set redirect URIs
```
**Verify:** Click "Continue with Keycloak" → redirected to Microsoft/Google → login → see dashboard.

### Phase 3: Add Sidecars (30 min)
```
Add apollo, devmcp, sheets to docker-compose
Register backends via ContextForge Admin UI
```
**Verify:** See MCP tools in the admin panel.

### Phase 4: Deploy to Cloud Run (1 hour)
```
Deploy all services
Update redirect URIs for Cloud Run URLs (BOTH formats!)
Update ALLOWED_ORIGINS for Cloud Run URLs (BOTH formats!)
Update Keycloak client redirectUris for Cloud Run callback URL
```
**Verify:** Complete SSO flow on Cloud Run URL.

---

## Critical Env Vars — The Complete Correct Configuration

```yaml
# ContextForge
AUTH_REQUIRED: "true"
MCP_CLIENT_AUTH_ENABLED: "true"        # MUST be true for SSO to work
SSO_ENABLED: "true"
SSO_KEYCLOAK_ENABLED: "true"
SSO_KEYCLOAK_BASE_URL: "http://keycloak:8080"  # Internal Docker hostname
SSO_KEYCLOAK_REALM: "fluid"
SSO_KEYCLOAK_CLIENT_ID: "fluid-gateway-sso"
SSO_KEYCLOAK_CLIENT_SECRET: "${SSO_CLIENT_SECRET}"
SSO_KEYCLOAK_MAP_REALM_ROLES: "true"
SSO_AUTO_CREATE_USERS: "true"
SSO_TRUSTED_DOMAINS: '["junlinleather.com"]'
ALLOWED_ORIGINS: "http://localhost:8080,http://localhost:8180"  # ALL service URLs
TRUST_PROXY_AUTH: "false"
TRUST_PROXY_AUTH_DANGEROUSLY: "false"
JWT_SECRET_KEY: "a-long-random-string-at-least-32-chars"
MCPGATEWAY_UI_ENABLED: "true"
MCPGATEWAY_ADMIN_API_ENABLED: "true"
HOST: "0.0.0.0"
PORT: "8080"
MCG_HOST: "0.0.0.0"
MCG_PORT: "8080"
WORKERS: "2"
DB_POOL_SIZE: "5"
DB_MAX_OVERFLOW: "5"
DATABASE_URL: "postgresql+psycopg://user:pass@postgres:5432/contextforge"
SSRF_ALLOW_LOCALHOST: "true"        # Required for sidecar communication
SSRF_ALLOW_PRIVATE_NETWORKS: "true" # Required for sidecar communication
```

### Env Vars That Sound Harmless But Are Dangerous

| Env Var | Dangerous Value | What Actually Happens |
|---------|----------------|----------------------|
| `MCP_CLIENT_AUTH_ENABLED=false` | Disables ALL JWT auth including admin panel SSO cookies |
| `ALLOWED_ORIGINS=*` | Allows any origin — security hole |
| `ALLOWED_ORIGINS` missing a URL | SSO redirect_uri rejected silently |
| `JWT_SECRET_KEY` (default) | 11-char default key, insecure + warning spam |
| `WORKERS=16` (default) | Exhausts DB connection pool (16 workers × 200 pool = 3200 connections) |
| `DB_POOL_SIZE=200` (default) | Way too many for local dev or small Cloud SQL |

---

## Keycloak Realm — What Must Be Verified After Import

The realm JSON import does NOT guarantee everything works. After import, verify in Admin UI:

1. **Client `fluid-gateway-sso`:**
   - [ ] Client scopes include: `realm-roles`, `fluid-audience`, `fluid-session`
   - [ ] Redirect URIs include: `http://localhost:8080/*` AND Cloud Run URLs
   - [ ] Web Origins include: `http://localhost:8080` AND Cloud Run URLs
   - [ ] Client authentication: ON (confidential client)
   - [ ] Service accounts enabled: depends on use case

2. **Realm roles:**
   - [ ] `platform_admin` role exists
   - [ ] Assigned to admin users

3. **Identity Providers (if using Microsoft/Google):**
   - [ ] Client ID and Secret are set (not REPLACE_AT_RUNTIME)
   - [ ] Redirect URI matches Keycloak's actual URL
   - [ ] First broker login flow is correct

4. **Get a test token and decode it:**
   ```bash
   # Get token
   curl -X POST keycloak/realms/fluid/protocol/openid-connect/token \
     -d "grant_type=client_credentials&client_id=fluid-gateway-sso&client_secret=SECRET"

   # Decode at jwt.io — verify:
   # - aud contains "fluid-gateway"
   # - realm_access.roles contains "platform_admin"
   # - sid claim is present
   ```

---

## What Worked Well in v5

1. **Source code analysis was thorough.** The root cause of every bug was eventually found by reading ContextForge source code from inside the container. The technique of `docker compose exec -T contextforge python -c "import inspect; ..."` was invaluable.

2. **The "configure don't code" principle was right.** Zero custom Python code was written. All issues were configuration problems.

3. **The Keycloak Dockerfile optimization was good.** Health-enabled, features-disabled, optimized build — this worked correctly.

4. **The sidecar architecture was sound.** Apollo, devmcp, and sheets containers all started correctly.

5. **Cloud SQL integration worked.** DATABASE_URL with psycopg driver, connection pooling — all correct from v4 lessons.

---

## Files to Keep for v6

```
keycloak/Dockerfile                    — Optimized Keycloak build (KEEP)
keycloak/realm-fluid.json              — Base realm config (KEEP but verify post-import)
sidecars/apollo/Dockerfile             — Apollo MCP Server build (KEEP)
sidecars/apollo/config.yaml            — Apollo config (KEEP)
sidecars/devmcp/Dockerfile             — dev-mcp build (KEEP)
sidecars/sheets/Dockerfile             — Sheets build (KEEP)
scripts/init-postgres.sql              — DB initialization (KEEP)
scripts/init-postgres-wrapper.sh       — DB init wrapper (KEEP)
docker-compose.yml                     — Full stack definition (KEEP, fix env vars)
.env.example                           — Env var template (KEEP)
tests/keycloak/test_realm_json.py      — Realm validation tests (KEEP)
docs/specs/v5-contextforge-capabilities.md  — Complete env var reference (KEEP)
docs/specs/v5-keycloak-capabilities.md      — Keycloak API reference (KEEP)
```

---

## The One Thing That Would Have Prevented All of This

**A local end-to-end test before ANY cloud deployment.**

If the implementation had followed this exact sequence:
1. `docker-compose up` (postgres + keycloak + contextforge)
2. Open `localhost:8080/admin`
3. Click "Continue with Keycloak"
4. Log in with a local Keycloak user (not Microsoft)
5. Verify the admin dashboard loads

Every single one of the 7 bugs would have been discovered in minutes, not hours. The bugs were all configuration issues that manifest immediately on first login attempt.

**The v6 rule:** Do not touch Cloud Run until step 5 works locally.
