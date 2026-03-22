# Fluid Intelligence — All Challenges v3 to v5

> **Mandatory reading before any future implementation.**
> Three versions. Three failures. Each one got closer but none crossed the finish line.
> This document extracts every lesson so v6 doesn't repeat a single one.

---

## Version Timeline

| Version | Duration | Cost | Result |
|---------|----------|------|--------|
| v3 | ~3 days | ~$25 | Gateway running, 27 tools, no identity |
| v4 | ~2 days | ~$43 ($28 wasted) | Keycloak + Gateway live, SSO partially working |
| v5 | ~1.5 days | ~$20 | Clean codebase, SSO flow reaches Keycloak but never completes round-trip |

**Combined waste:** ~$48 in unnecessary deploys, wrong-path debugging, and code that got deleted.

---

## PART 1: v3 Challenges (Foundation Layer)

### v3-C1: No User Identity
Built an entire gateway with OAuth 2.1, JWT, tool aggregation — but no concept of WHO is using it. Logs showed token hashes, not human names. The agent designed "a better version of the same broken thing."

**Lesson:** Identity is not a feature. It is the foundation. Answer WHO before HOW.

### v3-C2: Guessed API Config Instead of Reading Docs
Apollo MCP Server config used invented field names (`server.name`, `shopify.store`). ContextForge health endpoint assumed to be `/healthz` (it's `/health`). Port variable assumed to be `MCPGATEWAY_PORT` (it's `MCG_PORT`). Host assumed to bind all interfaces (it binds `127.0.0.1`).

**Lesson:** NEVER assume config field names. Read the actual source code or `--help` output. This failure appeared 6+ times across v3-v5.

### v3-C3: `uv pip install` Corrupts Third-Party Venvs
Installing psycopg2 into ContextForge's venv broke the `mcpgateway` CLI entry point. The module was still importable but the CLI script was corrupted. ContextForge already ships psycopg2 — the install was both redundant and destructive.

**Lesson:** Never `pip install` into a third-party Docker image's venv. Check if the package already exists first.

### v3-C4: ContextForge StreamableHTTP Bug
Apollo registration returned 2xx but tools never appeared. ContextForge's MCP SDK logs showed `StreamableHTTP=False` from the start — the protocol was broken in RC-2. Wasted 8+ deploys trying to fix what was a platform bug.

**Lesson:** When a platform claims to support a protocol, check its own logs for protocol status. Use what works (SSE), not what's newest.

### v3-C5: Apollo File-Loading Silently Drops Queries
Only 2 of 7 GraphQL operations loaded. No error, no warning. Root cause: Apollo's schema tree-shaking algorithm couldn't handle complex type graphs. Workaround: use `introspection.execute` to bypass the broken pipeline.

**Lesson:** When a tool silently drops valid inputs, don't keep testing variations. Enable diagnostic tools and bypass the broken pipeline.

### v3-C6: Double-Auth Problem
Auth-proxy (RS256 JWT) + ContextForge (HMAC JWT) = mutual rejection. Auth-proxy strips the Authorization header, but ContextForge with `AUTH_REQUIRED=true` rejects requests without it.

**Lesson:** When a reverse proxy handles auth, the backend must trust the proxy, not double-check with incompatible credentials.

### v3-C7: JSON Parsing Fails on ContextForge Descriptions
Tool descriptions contain literal newlines. Python's `json.loads()` rejects these with `strict=True`.

**Lesson:** Always use `json.loads(data, strict=False)` when parsing JSON from MCP servers.

### v3-C8: 47 Hardcoded Business Values
Emails, domain names, GCP project IDs, Cloud SQL instances, port numbers scattered across 15 files. Would break on any fork, domain change, or second customer.

**Lesson:** Zero hardcoded business values. Everything comes from env vars. If someone forks the repo, they should only need to change `.env`.

---

## PART 2: v4 Challenges (Identity + Keycloak Layer)

### v4-C1: Built 741 Lines That 9 Env Vars Replace (MOST CRITICAL)
Custom `resolve_user.py` plugin to bridge Keycloak → ContextForge. Spent ~8 hours debugging plugin loading, JWT verification, role mapping. All replaceable by `SSO_KEYCLOAK_ENABLED=true` + 8 env vars.

**Root cause:** The spec said "build a plugin" — written before discovering ContextForge has native Keycloak SSO. The agent followed the spec literally.

**Lesson:** Before writing ANY custom code that connects two applications, search for built-in integrations. Custom code is a code smell in SaaS integration.

### v4-C2: 15 Failed Cloud Deploys (~$28 wasted, ~150 minutes)
8 Keycloak + 7 Gateway deploys. Every failure could have been caught with `docker-compose up` locally:
- Feature flag syntax → `docker run` shows error
- Realm import failures → `docker run --import-realm` shows error
- Missing Python modules → `docker run` shows import error
- DATABASE_URL not set → `docker run` shows SQLite fallback
- HTTP vs HTTPS issuer → `docker-compose up` + browser shows it

**Lesson:** NEVER deploy to cloud until docker-compose works locally. Each Cloud Build costs $0.50-1.00 and 5-10 minutes.

### v4-C3: Keycloak Realm Import Accepts Subset of Export
`userProfile`, `clientProfiles`, `clientPolicies` all rejected during import. The JSON format documented online is the EXPORT format — not all fields are importable.

**Lesson:** Keep realm JSON minimal. Configure advanced features post-import via Admin API. Test import locally first.

### v4-C4: Cloud SQL Connectivity — 5 Wrong Methods Before Working
Tried direct IP, Cloud SQL connector with socketFactory, `?host=/cloudsql/`, localhost:5432, `?unixSocketPath=`. Keycloak's Quarkus/Agroal strips JDBC URL params.

**Working solution:** Public IP with authorized networks for Keycloak (JDBC). Cloud SQL connector with Unix socket for ContextForge (Python).

**Lesson:** Java/JDBC and Python/SQLAlchemy connect to Cloud SQL differently. Test connectivity before anything else.

### v4-C5: Keycloak 26.x Breaking Changes
Feature flags, health endpoints, admin bootstrap, hostname config — all different from older docs.

**Lesson:** Use version-specific docs. Use `context7` for every config option. Test locally.

### v4-C6: ContextForge Auth Architecture Misunderstanding
`AUTH_REQUIRED` controls both admin UI and MCP endpoints. `MCP_CLIENT_AUTH_ENABLED` controls JWT validation for all auth paths. SSO login returns JSON, not redirect. `BASIC_AUTH_PASSWORD` ≠ `PLATFORM_ADMIN_PASSWORD`. `DATABASE_URL` must be explicitly set.

**Lesson:** Read the FULL env var list before setting ANY config. ContextForge has 95+ settings — many interact in non-obvious ways.

### v4-C7: Zero Mandatory Skills Invoked
15+ security skills listed in the plan. ZERO invoked. `subagent-driven-development` displaced skill discipline. Speed pressure caused shortcuts. Skills were listed as comments, not executable tasks.

**Lesson:** Skills must be checkboxed TASKS in the plan. The controller must invoke skills BEFORE dispatching implementers.

### v4-C8: AUTH_REQUIRED=true Regression
The same bug (double-auth) was introduced TWICE. Fixed in one commit, re-introduced in another. The failure log documented the fix but wasn't consulted.

**Lesson:** When re-introducing a previously-fixed setting, search the failure log first.

### v4-C9: Claude.ai OAuth Bug Misdiagnosed as Server Bug
Claude.ai showed auth error. Spent hours debugging server-side OAuth. The bug was in Claude.ai's OAuth proxy (known GitHub issues #5826, #3515, #11814).

**Lesson:** When a client reports an error, check for known client-side issues before debugging server-side code.

---

## PART 3: v5 Challenges (SSO + Clean Codebase Layer)

### v5-C1: `MCP_CLIENT_AUTH_ENABLED=false` — The Silent Killer (MOST CRITICAL)
Set to `false` thinking it only controls MCP client auth. In reality, it disabled ALL JWT-based authentication — including admin panel SSO cookies. The name is misleading.

**How we set it wrong:** v4 used `AUTH_REQUIRED=false` with auth-proxy. v5 removed auth-proxy and enabled SSO, but kept `MCP_CLIENT_AUTH_ENABLED=false` as a leftover assumption.

**Why it was hard to find:** A separate Starlette middleware (`TokenScopingMiddleware`) independently validated the JWT and logged "Admin bypass: skipping team validation." This made it LOOK like auth was working. But the FastAPI dependency that actually gates admin access (`get_current_user_with_permissions`) never even read the JWT.

**The code path:**
```python
if not settings.mcp_client_auth_enabled:      # We entered HERE
    if is_proxy_auth_trust_active():           # No (TRUST_PROXY_AUTH=false)
        ...
    if settings.auth_required:                 # Yes
        raise 302 → /admin/login              # JWT NEVER READ
```

**Lesson:** When a SaaS app has an env var that sounds subsystem-specific, `grep` the codebase to see everywhere it's read. `MCP_CLIENT_AUTH_ENABLED` gates the entire JWT auth code path.

### v5-C2: Two Cloud Run URL Formats
Cloud Run generates two URLs for the same service:
1. `service-HASH-REGION.a.run.app`
2. `service-PROJECTNUMBER-REGION.run.app`

`ALLOWED_ORIGINS` had format 1. Browser used format 2. SSO redirect_uri rejected.

**Lesson:** Include BOTH Cloud Run URL formats in `ALLOWED_ORIGINS`. Or use a custom domain.

### v5-C3: redirect_uri Not in Keycloak Client
The Keycloak client's `redirectUris` whitelist must include the ContextForge callback URL — for BOTH Cloud Run URL formats. Missing this produces "Invalid parameter: redirect_uri" on Keycloak's login page.

**Lesson:** The redirect_uri must match in THREE places: ContextForge `ALLOWED_ORIGINS`, Keycloak client `redirectUris`, and the actual browser URL.

### v5-C4: `realm-roles` Client Scope Not Assigned to Client
The realm JSON had `realm-roles` in `defaultDefaultClientScopes`, but Keycloak doesn't retroactively assign default scopes to EXISTING clients created during import. The `fluid-gateway-sso` client didn't have `realm-roles`, so JWTs didn't contain `realm_access.roles`.

**Lesson:** After realm import, verify each client's assigned scopes in the Admin UI. Default scopes only auto-apply to NEW clients.

### v5-C5: SSO Role Mappings Not Configured
`SSO_KEYCLOAK_MAP_REALM_ROLES=true` extracts roles from JWTs. But `_map_groups_to_roles()` ALSO needs `role_mappings` in provider metadata. Without both, roles are extracted but never mapped to ContextForge RBAC roles.

**Lesson:** `MAP_REALM_ROLES=true` is only half the config. You also need role_mappings.

### v5-C6: `admin.dashboard` Requires RBAC Role, Not Just `is_admin=true`
The admin panel uses `@require_permission("admin.dashboard", allow_admin_bypass=False)`. This explicitly DISABLES the `is_admin` shortcut. The user must have `platform_admin` RBAC role in `user_roles` table.

**Lesson:** `is_admin=true` and having an RBAC role are TWO SEPARATE authorization layers. The admin panel requires the RBAC layer.

### v5-C7: email_verified Mapper Type Wrong
Used `hardcoded-attribute-idp-mapper` instead of the correct mapper type for boolean claims.

**Lesson:** Keycloak has dozens of mapper types that sound similar but work differently. Test with a real login.

### v5-C8: Debugging by Reading Source Code Instead of Testing Contracts
Spent ~4 hours reading ContextForge source code line by line. The code was correct — the bug was in configuration. Source code tells you what WOULD happen, not what IS happening with a given config.

**What should have been done:** Test each contract between services independently:
```bash
# Can Keycloak issue tokens?
curl -X POST keycloak/token -d "grant_type=client_credentials..."

# Can ContextForge accept a token?
curl -H "Authorization: Bearer $TOKEN" gateway/admin/

# Does the SSO callback URL work?
curl -v gateway/auth/sso/login/keycloak
```

**Lesson:** When debugging SSO integrations, test contracts between services first. Only read source code after isolating which interface fails.

### v5-C9: Too Many Variables Changed at Once
v5 changed docker-compose, realm JSON, ContextForge config, Cloud Run deployment, Microsoft IdP, and Apollo GraphOS simultaneously. When SSO failed, impossible to tell which change caused it.

**Lesson:** Change ONE integration at a time. Verify end-to-end before adding the next.

---

## PART 4: Cross-Version Patterns

### Pattern A: "Looks Like It Works" Traps
| Version | What looked working | What was actually broken |
|---------|-------------------|------------------------|
| v3 | Apollo registered (2xx) | Zero tools discovered (StreamableHTTP bug) |
| v4 | Keycloak login page loads | JWT issuer HTTP vs HTTPS mismatch |
| v5 | "Admin bypass" log appeared | JWT was never read by the auth dependency |

**The pattern:** Partial success masquerades as full success. A 2xx response, a positive log message, or a working UI element creates false confidence.

**Prevention:** Define SUCCESS CRITERIA upfront. Not "Keycloak loads" but "I can log in via Keycloak AND see the admin dashboard AND see my tools listed."

### Pattern B: Env Var Name ≠ Actual Scope
| Env Var | What the name implies | What it actually does |
|---------|----------------------|----------------------|
| `MCP_CLIENT_AUTH_ENABLED` | Controls MCP client auth only | Gates ALL JWT auth including admin SSO |
| `AUTH_REQUIRED` | Requires auth globally | Also controls whether MCP endpoints need tokens |
| `TRUST_PROXY_AUTH` | Trusts proxy headers | Only provides identity; doesn't satisfy AUTH_REQUIRED |
| `ALLOWED_ORIGINS` | CORS origins | Also controls SSO redirect_uri validation |

**Prevention:** Before setting ANY env var, `grep -rn "varname" /app/` in the container to see every code path that reads it.

### Pattern C: The Same Bug Returns
| Bug | v3 | v4 | v5 |
|-----|----|----|-----|
| Guessed config instead of reading docs | Apollo config | Keycloak feature flags | MCP_CLIENT_AUTH scope |
| Double-auth / conflicting auth layers | auth-proxy + ContextForge HMAC | Same (re-introduced) | SSO cookie vs MCP_CLIENT_AUTH |
| Deploy before local test | 5+ Cloud Builds | 15 deploys | Multiple Cloud Run updates |

**Prevention:** Search the failure log before implementing. If a failure matches a previous pattern, apply the documented fix directly.

### Pattern D: Skills Listed But Not Invoked
- v4: 15+ skills in plan, ZERO invoked
- v5: 5 rules mandating skills, partially followed

**Prevention:** Skills must be checkboxed TASKS in plans, not comment headers. The executing agent must treat them as blocking prerequisites.

---

## PART 5: The v6 Implementation Playbook

### Phase 0: ContextForge with Email Auth Only (30 min)
```yaml
# docker-compose.yml — TWO services only
services:
  postgres:
    image: postgres:16-alpine
  contextforge:
    image: ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2
    environment:
      AUTH_REQUIRED: "true"
      MCP_CLIENT_AUTH_ENABLED: "true"       # ← MUST be true
      MCPGATEWAY_UI_ENABLED: "true"
      MCPGATEWAY_ADMIN_API_ENABLED: "true"
      PLATFORM_ADMIN_EMAIL: "admin@example.com"
      PLATFORM_ADMIN_PASSWORD: "secure-password"
      HOST: "0.0.0.0"
      PORT: "8080"
      DATABASE_URL: "postgresql+psycopg://..."
```
**Acceptance test:** Open `localhost:8080/admin`, log in with email/password, see dashboard.

### Phase 1: Add Keycloak (1 hour)
```yaml
  keycloak:
    build: ./keycloak
    # Import realm-fluid.json
```
Add to contextforge:
```yaml
      SSO_ENABLED: "true"
      SSO_KEYCLOAK_ENABLED: "true"
      SSO_KEYCLOAK_BASE_URL: "http://keycloak:8080"
      SSO_KEYCLOAK_REALM: "fluid"
      SSO_KEYCLOAK_CLIENT_ID: "fluid-gateway-sso"
      SSO_KEYCLOAK_CLIENT_SECRET: "test-secret"
      SSO_KEYCLOAK_MAP_REALM_ROLES: "true"
      SSO_AUTO_CREATE_USERS: "true"
      ALLOWED_ORIGINS: "http://localhost:8080,http://localhost:8180"
```
**Post-import verification:**
```
[ ] Keycloak Admin UI loads at localhost:8180
[ ] fluid-gateway-sso client has realm-roles in Default Scopes
[ ] fluid-gateway-sso client has http://localhost:8080/* in redirect URIs
[ ] Create test user in Keycloak with platform_admin realm role
[ ] Get test token, decode at jwt.io → verify realm_access.roles present
```
**Acceptance test:** Click "Continue with Keycloak" → log in → see admin dashboard.

### Phase 2: Add External IdP (30 min)
Configure Google or Microsoft IdP in Keycloak Admin UI at localhost:8180.
```
[ ] Add identity provider in Keycloak
[ ] Set client ID and secret from Google/Microsoft console
[ ] Redirect URI in Google/Microsoft console: http://localhost:8180/realms/fluid/broker/google/endpoint
[ ] Create IdP mappers for email, name
```
**Acceptance test:** Click "Continue with Keycloak" → click "Google"/"Microsoft" → complete login → see dashboard.

### Phase 3: Add Sidecars (30 min)
Add apollo, devmcp, sheets to docker-compose. Register via ContextForge Admin UI.

**Acceptance test:** See MCP tools listed in admin panel.

### Phase 4: Deploy to Cloud Run (1 hour)
```
[ ] Build and push all images to Artifact Registry
[ ] Deploy each service
[ ] Update ALLOWED_ORIGINS with BOTH Cloud Run URL formats
[ ] Update Keycloak client redirectUris with Cloud Run callback URL
[ ] Update Keycloak client webOrigins with Cloud Run gateway URL
[ ] Update IdP redirect URIs to use Keycloak Cloud Run URL
```
**Acceptance test:** Complete SSO flow on Cloud Run URL → see admin dashboard → see tools.

### The Golden Rule
**Do NOT proceed to the next phase until the current phase's acceptance test passes in a browser.** Not curl. Not logs. A real browser with a real login.

---

## PART 6: Files to Keep

```
keycloak/Dockerfile                         # Optimized Keycloak build
keycloak/realm-fluid.json                   # Base realm (verify post-import)
sidecars/apollo/Dockerfile                  # Apollo MCP Server build
sidecars/apollo/config.yaml                 # Apollo config
sidecars/apollo/shopify-schema.graphql      # Shopify schema
sidecars/devmcp/Dockerfile                  # dev-mcp build
sidecars/sheets/Dockerfile                  # Sheets build
scripts/init-postgres.sql                   # DB initialization
scripts/init-postgres-wrapper.sh            # DB init wrapper
docker-compose.yml                          # Full stack (FIX env vars per Phase 0-3)
.env.example                               # Env var template
tests/keycloak/test_realm_json.py           # Realm validation tests
docs/specs/v5-contextforge-capabilities.md  # Complete env var reference (95+ vars)
docs/specs/v5-keycloak-capabilities.md      # Keycloak API reference
docs/archive/v5/v5-lessons-learned.md       # v5 specific lessons
docs/archive/v5/v3-to-v5-all-challenges.md  # THIS FILE
```

---

## PART 7: The 3 Things That Would Have Prevented 90% of All Failures

1. **`docker-compose up` + browser test before ANY cloud deploy.**
   Every single deployment failure (v3: 5+, v4: 15, v5: 5+) could have been caught locally in minutes.

2. **`grep -rn "ENV_VAR_NAME" /app/` before setting ANY env var.**
   Every configuration misunderstanding (MCP_CLIENT_AUTH_ENABLED, AUTH_REQUIRED, ALLOWED_ORIGINS) would have been caught by reading 5 lines of source code.

3. **Test each service pair independently before connecting them all.**
   Can Keycloak issue valid tokens? (test alone) Can ContextForge accept those tokens? (test with curl) Does the redirect_uri match? (test the callback URL) Only THEN connect them together.

**Total time for all 3 checks: ~20 minutes per phase.**
**Total time wasted by skipping them: ~15 hours across v3-v5.**
