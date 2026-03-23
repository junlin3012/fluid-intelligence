# Fluid Intelligence v6 — Design Spec

> **Architecture is identical to v5. Implementation is completely different.**
> v5 failed because 7 interacting config bugs created a chain of failures that took 8 hours to diagnose.
> v6 adds ONE integration at a time, with a browser acceptance test between each.

---

## Goal

Local SSO login via Google and Microsoft (through Keycloak) + MCP tools visible in ContextForge admin panel. Then deploy to Cloud Run.

## Architecture

6 services, added incrementally:

| Service | Image | Phase |
|---------|-------|-------|
| postgres | `postgres:16-alpine` | 0 |
| contextforge | `ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2` | 0 |
| keycloak | Custom Dockerfile (v5 cherry-pick) | 1 |
| apollo | Custom Dockerfile (latest Apollo + GraphOS) | 3 |
| devmcp | Custom Dockerfile (v5 cherry-pick) | 3 |
| sheets | Custom Dockerfile (v5 cherry-pick) | 3 |

## Constraints (from v3-v5 lessons)

1. **Zero custom application code.** Only docker-compose.yml, .env, and UI configuration.
2. **One integration per phase.** Each phase adds exactly one new thing.
3. **Browser acceptance test between phases.** Not curl, not logs — a real browser with a real login.
4. **Contract test before browser test.** Verify each service pair with curl before testing the full flow.
5. **`grep -rn "ENV_VAR" /app/` before setting any env var.** Verify actual scope, not assumed scope.
6. **Skills are checkboxed tasks, not comments.** Every skill invocation is a tracked task.

## Mandatory Pre-Reading

- `docs/archive/v5/v3-to-v5-all-challenges.md` — 25 challenges across 3 versions
- `docs/archive/v5/v5-lessons-learned.md` — 7 bugs that blocked SSO
- `docs/specs/v5-contextforge-capabilities.md` — 95+ env vars reference
- `docs/specs/v5-keycloak-capabilities.md` — Keycloak Admin API reference

---

## Cherry-Pick Inventory

Files carried from v5 worktree (all proven clean):

| File | Lines | Action |
|------|-------|--------|
| `keycloak/Dockerfile` | 49 | As-is |
| `keycloak/realm-fluid.json` | 1898 | Modified: added `platform_admin` role, `secret` field, `directAccessGrantsEnabled: true`, `defaultClientScopes`, removed stale v5 Cloud Run URLs |
| `sidecars/apollo/Dockerfile` | 67 | Update COMMIT_HASH to latest Apollo release + update config.yaml transport |
| `sidecars/apollo/config.yaml` | 20 | Update `transport.type` from `streamable_http` to `sse` (v3-C4: RC-2 StreamableHTTP broken) |
| `sidecars/apollo/shopify-schema.graphql` | ~98K | As-is |
| `sidecars/devmcp/Dockerfile` | 52 | As-is |
| `sidecars/devmcp/package.json` | — | As-is (required by Dockerfile `npm ci`) |
| `sidecars/devmcp/package-lock.json` | — | As-is (required by Dockerfile `npm ci`) |
| `sidecars/sheets/Dockerfile` | 50 | As-is |
| `sidecars/sheets/requirements.txt` | — | As-is (required by Dockerfile `pip install`) |
| `scripts/init-postgres.sql` | 53 | As-is |
| `scripts/init-postgres-wrapper.sh` | 16 | As-is |
| `tests/keycloak/test_realm_json.py` | 249 | As-is |
| `tests/keycloak/__init__.py` | 0 | As-is (required for pytest discovery) |
| `docs/specs/v5-contextforge-capabilities.md` | 150 | As-is |
| `docs/specs/v5-keycloak-capabilities.md` | 222 | As-is |
| `docs/archive/v5/*` | ~750 | As-is |

**Note on .dockerignore files:** Cherry-pick any `.dockerignore` found in `keycloak/`, `sidecars/apollo/`, `sidecars/devmcp/`, `sidecars/sheets/`. These prevent unnecessary files from entering Docker build context.

**Note on Apollo version:** The v5 Dockerfile pins Apollo to v1.8.2 (commit `e85ba28`). The user wants the latest version. When updating, change the `COMMIT_HASH` arg in the Dockerfile and verify the new version's config schema still accepts `config.yaml`. Since the user has a GraphOS account, `APOLLO_GRAPH_REF` and `APOLLO_KEY` are available.

Written fresh (NOT carried from v5):

| File | Lines | Why fresh |
|------|-------|-----------|
| `docker-compose.yml` | ~220 | v5 had wrong env vars — rewrite with correct config |
| `.env.example` | ~35 | Match new docker-compose |

**Total cherry-picked: ~2,900 lines + 98K schema**
**Total written fresh: ~255 lines of YAML/env**
**Custom application code: 0**

### .env.example Template

```bash
# === Required Secrets (generate each with: openssl rand -base64 32) ===
POSTGRES_PASSWORD=          # PostgreSQL superuser password
CONTEXTFORGE_DB_PASSWORD=   # contextforge_user DB password
KEYCLOAK_DB_PASSWORD=       # keycloak_user DB password
KC_ADMIN_PASSWORD=          # Keycloak admin console password
SSO_CLIENT_SECRET=          # fluid-gateway-sso client secret (from Keycloak Credentials tab)
JWT_SECRET_KEY=             # ContextForge JWT signing key (min 32 chars for HS256)
AUTH_ENCRYPTION_SECRET=     # ContextForge DB encryption key (min 32 chars)
PLATFORM_ADMIN_PASSWORD=    # ContextForge admin password (email/password fallback)

# === Optional (have safe defaults) ===
PLATFORM_ADMIN_EMAIL=admin@example.com
LOG_LEVEL=INFO
POSTGRES_USER=postgres
KC_ADMIN_USER=admin

# === Phase 3: Sidecars (fill when you reach Phase 3) ===
SHOPIFY_STORE=placeholder.myshopify.com
SHOPIFY_API_VERSION=2026-01
SHOPIFY_ACCESS_TOKEN=       # From Shopify Partners dashboard
APOLLO_GRAPH_REF=           # From Apollo GraphOS (e.g., shopify-fluid-intelligence@current)
APOLLO_KEY=                 # From Apollo GraphOS (starts with service:)
```

---

## Phase 0: ContextForge + Email Auth

**Services:** postgres, contextforge (2 services)
**Purpose:** Prove ContextForge's auth pipeline works in isolation.

### docker-compose.yml (Phase 0)

```yaml
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-postgres}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?required}
      CONTEXTFORGE_DB_PASSWORD: ${CONTEXTFORGE_DB_PASSWORD:?required}
      KEYCLOAK_DB_PASSWORD: ${KEYCLOAK_DB_PASSWORD:?required}  # Needed by init script even in Phase 0
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./scripts/init-postgres-wrapper.sh:/docker-entrypoint-initdb.d/00-init.sh:ro
      - ./scripts/init-postgres.sql:/docker-entrypoint-initdb.d/init-postgres.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-postgres}"]
      interval: 5s
      timeout: 5s
      retries: 10
    networks:
      - fluid-net

  contextforge:
    image: ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2
    environment:
      HOST: "0.0.0.0"
      PORT: "8080"
      MCG_HOST: "0.0.0.0"
      MCG_PORT: "8080"
      WORKERS: "2"
      DB_POOL_SIZE: "5"
      DB_MAX_OVERFLOW: "5"
      DATABASE_URL: "postgresql+psycopg://contextforge_user:${CONTEXTFORGE_DB_PASSWORD}@postgres:5432/contextforge"
      AUTH_REQUIRED: "true"
      MCP_CLIENT_AUTH_ENABLED: "true"
      PLATFORM_ADMIN_EMAIL: "${PLATFORM_ADMIN_EMAIL:-admin@example.com}"
      PLATFORM_ADMIN_PASSWORD: "${PLATFORM_ADMIN_PASSWORD:?required}"
      JWT_SECRET_KEY: "${JWT_SECRET_KEY:?required}"
      JWT_ALGORITHM: "HS256"  # Must match JWT_SECRET_KEY type (HMAC). Default is RS256 which needs a keypair.
      AUTH_ENCRYPTION_SECRET: "${AUTH_ENCRYPTION_SECRET:?required}"  # DB-level encryption for stored tokens
      MCPGATEWAY_UI_ENABLED: "true"
      MCPGATEWAY_ADMIN_API_ENABLED: "true"
      ALLOWED_ORIGINS: "http://localhost:8080"
      TRUST_PROXY_AUTH: "false"
      TRUST_PROXY_AUTH_DANGEROUSLY: "false"
      SSRF_ALLOW_LOCALHOST: "true"
      SSRF_ALLOW_PRIVATE_NETWORKS: "true"
      LOG_LEVEL: "${LOG_LEVEL:-INFO}"
    ports:
      - "8080:8080"
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080/health > /dev/null || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 15s
    networks:
      - fluid-net

volumes:
  pgdata:

networks:
  fluid-net:
    driver: bridge
```

### Skill Invocations (Phase 0)
- [ ] Invoke `context7` — verify ContextForge env var names against docs
- [ ] Run `grep -rn "MCP_CLIENT_AUTH_ENABLED\|AUTH_REQUIRED\|PLATFORM_ADMIN" /app/` in container — verify scope
- [ ] Run `docker-compose up` and wait for healthy
- [ ] Invoke `claude-in-chrome` — browser test

### Acceptance Test (Phase 0)
```
[ ] Open http://localhost:8080/admin
[ ] Log in with PLATFORM_ADMIN_EMAIL / PLATFORM_ADMIN_PASSWORD (values from your .env)
[ ] See the admin dashboard
[ ] Navigate to Gateways, Servers, Tools — all empty but accessible
```

### Phase Gate
**Do NOT add Keycloak until all 4 checkboxes above are checked.**

---

## Phase 1: Add Keycloak SSO

**Services:** postgres, contextforge, keycloak (3 services)
**Purpose:** SSO login via Keycloak local user. No external IdP yet.

### Changes to docker-compose.yml

**All Phase 0 env vars remain unchanged. The changes below are ADDITIONS, not replacements.**

Add `keycloak` service:
```yaml
  keycloak:
    build:
      context: ./keycloak
      dockerfile: Dockerfile
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak_user
      KC_DB_PASSWORD: ${KEYCLOAK_DB_PASSWORD:?required}
      KC_BOOTSTRAP_ADMIN_USERNAME: ${KC_ADMIN_USER:-admin}
      KC_BOOTSTRAP_ADMIN_PASSWORD: ${KC_ADMIN_PASSWORD:?required}
      KC_HOSTNAME: "http://localhost:8180"
      KC_HTTP_ENABLED: "true"
      KC_HTTP_PORT: "8080"
    ports:
      - "8180:8080"
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "exec 3<>/dev/tcp/localhost/8080 && echo -e 'GET /realms/fluid HTTP/1.1\\r\\nHost: localhost\\r\\n\\r\\n' >&3 && timeout 2 cat <&3 | grep -q fluid"]
      interval: 10s
      timeout: 10s
      retries: 12
      start_period: 30s
    networks:
      - fluid-net
```

Add SSO env vars to `contextforge`:
```yaml
      SSO_ENABLED: "true"
      SSO_KEYCLOAK_ENABLED: "true"
      SSO_KEYCLOAK_BASE_URL: "http://keycloak:8080"
      SSO_KEYCLOAK_REALM: "fluid"
      SSO_KEYCLOAK_CLIENT_ID: "fluid-gateway-sso"
      SSO_KEYCLOAK_CLIENT_SECRET: "${SSO_CLIENT_SECRET:?required}"
      SSO_KEYCLOAK_MAP_REALM_ROLES: "true"
      SSO_AUTO_CREATE_USERS: "true"
      SSO_TRUSTED_DOMAINS: '["junlinleather.com"]'
      SSO_PRESERVE_ADMIN_AUTH: "true"  # Keep email/password as fallback during dev
      ALLOWED_ORIGINS: "http://localhost:8080,http://localhost:8180"
```

**CRITICAL: You MUST update `ALLOWED_ORIGINS` to include `http://localhost:8180` (Keycloak). Forgetting this causes silent redirect_uri rejection (see v5-C2).** The Phase 0 value of `http://localhost:8080` is insufficient once Keycloak is added.

### Phase 1 Startup Sequence

The realm JSON now includes `"secret": "dev-test-secret-change-in-prod"` on the `fluid-gateway-sso` client. Set `SSO_CLIENT_SECRET=dev-test-secret-change-in-prod` in `.env`. Both sides agree from the start — no circular dependency.

**For production (Phase 5):** Rotate the client secret in Keycloak Admin UI and store the new value in GCP Secret Manager.

`KEYCLOAK_DB_PASSWORD` is already in postgres environment from Phase 0 (needed by init script).

### Skill Invocations (Phase 1)
- [ ] Invoke `keycloak` skill — realm config guidance
- [ ] Invoke `oauth2` skill — authorization code flow reference
- [ ] Invoke `configuring-oauth2-authorization-flow` — OAuth checklist
- [ ] Invoke `context7` — verify SSO env var names
- [ ] Run contract test: Keycloak issues token → decode → verify claims
- [ ] Invoke `claude-in-chrome` — browser test

### Post-Import Verification (user does in Keycloak Admin UI)
```
[ ] Keycloak Admin UI loads at http://localhost:8180
[ ] Realm "fluid" exists and is enabled
[ ] Client "fluid-gateway-sso" exists
[ ] Client → Client Scopes tab: realm-roles, fluid-audience, fluid-session in Default Scopes
    (These are set in realm JSON. If missing, add manually: Client Scopes → Add client scope)
[ ] Client → Settings: Valid Redirect URIs contains http://localhost:8080/*
[ ] Client → Settings: Web Origins contains http://localhost:8080
[ ] Client → Credentials tab: Secret matches SSO_CLIENT_SECRET in .env (dev-test-secret-change-in-prod)
[ ] Realm Roles: "platform_admin" exists (imported from realm JSON)
[ ] Create test user: Users → Add user → username: testuser
    → Credentials tab: set password "testpass", Temporary: OFF
    → Role Mapping tab: Assign "platform_admin" realm role
```

### Contract Test (Phase 1)

**Prerequisite:** Create a test user in Keycloak Admin UI first:
1. Open http://localhost:8180 → log in as admin
2. Users → Add user → username: `testuser`
3. Credentials tab → Set password: `testpass`, Temporary: OFF
4. Role Mapping tab → Assign `platform_admin` realm role

```bash
# Test 1: Can Keycloak issue a token?
# Uses password grant (directAccessGrantsEnabled=true set in realm JSON for dev).
TOKEN=$(curl -s -X POST http://localhost:8180/realms/fluid/protocol/openid-connect/token \
  -d "grant_type=password&client_id=fluid-gateway-sso&username=testuser&password=testpass&client_secret=dev-test-secret-change-in-prod" \
  | jq -r '.access_token')

# Verify token has the right claims:
python3 -c "import sys,base64,json; t='$TOKEN'.split('.')[1]; print(json.dumps(json.loads(base64.urlsafe_b64decode(t+'==')),indent=2))"
# Expected: realm_access.roles contains "platform_admin", aud contains "fluid-gateway", sid present

# Test 2: Can ContextForge accept the token?
curl -s -o /dev/null -w "Status: %{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" -H "Accept: application/json" \
  http://localhost:8080/admin/
# Expected: 200
# If 401 "Authentication required but no auth method configured" → MCP_CLIENT_AUTH_ENABLED is false
# If 401 "Invalid authentication credentials" → JWT_SECRET_KEY or JWT_ALGORITHM mismatch
# If 302 to /admin/login → token valid but user has no RBAC role (v5-C6)
# If 403 "Access denied" → user has role but not admin.dashboard permission
```

### Role Mapping Configuration (v5-C5 prevention)

**CRITICAL:** `SSO_KEYCLOAK_MAP_REALM_ROLES=true` only extracts roles from JWTs. You ALSO need role_mappings configured so ContextForge knows which Keycloak role maps to which ContextForge RBAC role. Without this, logs will show "No role mappings configured for provider keycloak, skipping role sync."

After first successful SSO login, configure role mappings. Two options:

**Option A: Via ContextForge Admin UI**
Navigate to Admin panel → look for SSO/Role settings → configure Keycloak provider role mappings.

**Option B: Via database (if UI doesn't expose role mappings)**
The SSO provider metadata in ContextForge's DB needs `role_mappings` added. This may require an Admin API call — check the ContextForge Admin API docs at `/docs` (Swagger UI) for endpoints related to SSO providers.

```
[ ] Configure role_mappings: Keycloak "platform_admin" → ContextForge "platform_admin"
[ ] Verify by logging in via SSO and checking user_roles table
```

Alternatively, the `SSO_TRUSTED_DOMAINS` setting auto-promotes users from `junlinleather.com` to `is_admin=true`, but this alone is NOT sufficient — the user also needs the `platform_admin` RBAC role in the `user_roles` table (v5-C6).

### Acceptance Test (Phase 1)
```
[ ] Click "Continue with Keycloak" on login page
[ ] Redirected to Keycloak login page
[ ] Log in with Keycloak test user
[ ] Redirected back to ContextForge
[ ] See the admin dashboard (not redirected to login again)
[ ] User appears in ContextForge user list with correct role
[ ] Verify RBAC: user has platform_admin role in user_roles table (v5-C6 prevention)
```

### Phase Gate
**Do NOT add external IdPs until all 7 checkboxes above are checked.**

---

## Phase 2: Add External IdPs

**Services:** Same 3 — configuration only, no docker-compose changes.
**Purpose:** Google and Microsoft login via Keycloak identity brokering.

### What the User Configures (Keycloak Admin UI)

**Google IdP:**
```
[ ] Google Cloud Console (console.cloud.google.com):
    → APIs & Services → Credentials → Create OAuth Client ID
    → Application type: Web application
    → Authorized redirect URIs: http://localhost:8180/realms/fluid/broker/google/endpoint
    → Copy Client ID and Client Secret
[ ] Keycloak Admin UI (localhost:8180):
    → Identity Providers → Add provider → Google
    → Paste Client ID and Client Secret
    → Default Scopes: openid email profile
    → Trust Email: ON
    → Save
```

**Microsoft IdP:**
```
[ ] Azure Portal (portal.azure.com):
    → Microsoft Entra ID → App registrations → New registration
    → Name: "Fluid Intelligence Keycloak"
    → Supported account types: Accounts in this organizational directory only
    → Redirect URI (Web): http://localhost:8180/realms/fluid/broker/microsoft/endpoint
    → After creation: Certificates & secrets → New client secret → copy the Value
    → Copy Application (client) ID from Overview page
[ ] Keycloak Admin UI (localhost:8180):
    → Identity Providers → Add provider → Microsoft
    → Paste Client ID and Client Secret
    → Save
```

### Skill Invocations (Phase 2)
- [ ] Invoke `keycloak` skill — identity brokering guidance
- [ ] Invoke `claude-in-chrome` — browser test for each IdP

### Acceptance Test (Phase 2)
```
[ ] Click "Continue with Keycloak" → click "Google" → complete Google login → see dashboard
[ ] Click "Continue with Keycloak" → click "Microsoft" → complete Microsoft login → see dashboard
[ ] Both users appear in ContextForge with correct roles
```

### Phase Gate
**Do NOT add sidecars until both IdP acceptance tests pass.**

---

## Phase 3: Add Sidecars

**Services:** All 6 — postgres, contextforge, keycloak, apollo, devmcp, sheets
**Purpose:** MCP backend tools visible in admin panel.

### Changes to docker-compose.yml

Add 3 sidecar services:
```yaml
  apollo:
    build:
      context: ./sidecars/apollo
      dockerfile: Dockerfile
    environment:
      SHOPIFY_STORE: "${SHOPIFY_STORE:-placeholder.myshopify.com}"
      SHOPIFY_API_VERSION: "${SHOPIFY_API_VERSION:-2026-01}"
      SHOPIFY_ACCESS_TOKEN: "${SHOPIFY_ACCESS_TOKEN:-placeholder}"
      APOLLO_GRAPH_REF: "${APOLLO_GRAPH_REF:-shopify-fluid-intelligence@current}"
      APOLLO_KEY: "${APOLLO_KEY}"
    healthcheck:
      test: ["CMD-SHELL", "exec 3<>/dev/tcp/localhost/8000 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    networks:
      - fluid-net

  devmcp:
    build:
      context: ./sidecars/devmcp
      dockerfile: Dockerfile
    # Note: port 8003 is hardcoded in Dockerfile CMD, not configurable via env var
    healthcheck:
      test: ["CMD-SHELL", "exec 3<>/dev/tcp/localhost/8003 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s
    networks:
      - fluid-net

  sheets:
    build:
      context: ./sidecars/sheets
      dockerfile: Dockerfile
    # Note: port 8004 is hardcoded in Dockerfile CMD, not configurable via env var
    healthcheck:
      test: ["CMD-SHELL", "exec 3<>/dev/tcp/localhost/8004 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s
    networks:
      - fluid-net
```

### What the User Configures (ContextForge Admin UI)

```
[ ] Register Apollo: name=apollo, url=http://apollo:8000/sse, transport=SSE
[ ] Register devmcp: name=devmcp, url=http://devmcp:8003/sse, transport=SSE
[ ] Register sheets: name=sheets, url=http://sheets:8004/sse, transport=SSE
```

### Skill Invocations (Phase 3)
- [ ] Invoke `claude-in-chrome` — verify tools visible in admin panel

### Acceptance Test (Phase 3)
```
[ ] All 6 docker-compose services healthy
[ ] Log in via SSO (Google or Microsoft)
[ ] See admin dashboard
[ ] Navigate to Gateways → all 3 backends shown
[ ] Navigate to Tools → tools from Apollo, devmcp, sheets listed
```

### Phase Gate
**Do NOT proceed to security audit until tools are visible.**

---

## Phase 4: Contract Tests + Security Audit

**Purpose:** Verify every service pair, run security skills.

### Contract Tests
```bash
# 1. Keycloak issues valid token
TOKEN=$(curl -s -X POST http://localhost:8180/realms/fluid/protocol/openid-connect/token \
  -d "grant_type=password&client_id=fluid-gateway-sso&username=testuser&password=testpass&client_secret=dev-test-secret-change-in-prod" \
  | jq -r '.access_token')
echo "Token length: ${#TOKEN}"  # Should be >100 chars, not "null"

# 2. ContextForge accepts token
curl -s -o /dev/null -w "Status: %{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" http://localhost:8080/admin/
# Expected: 200

# 3. ContextForge can reach Apollo (check registered gateways)
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8080/gateways | jq '.[].name'
# Expected: includes "apollo"

# 4. ContextForge has tools from all backends
TOOL_COUNT=$(curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8080/tools | jq 'length')
echo "Tools: $TOOL_COUNT"
# Expected: >0 (Apollo tools + devmcp tools + sheets tools)

# 5. Each sidecar responds to health
curl -sf http://localhost:8080/health && echo "Gateway: OK"
# Sidecars are internal-only, verify via gateway tool count above
```

### Skill Invocations (Phase 4)
- [ ] Invoke `sharp-edges` — dangerous config patterns
- [ ] Invoke `insecure-defaults` — fail-open defaults, weak secrets
- [ ] Invoke `verification-before-completion` — final checklist

### Acceptance Test (Phase 4)
```
[ ] All contract tests pass
[ ] No critical findings from security skills
[ ] All findings addressed or documented as accepted risks
```

---

## Phase 5: Cloud Run Deploy

**Purpose:** Deploy the working local stack to Cloud Run.

### Deployment Checklist
```
[ ] Build and push all custom images to Artifact Registry
[ ] Deploy postgres → Cloud SQL (already exists from v4/v5)
    Keycloak (JDBC): jdbc:postgresql://PUBLIC_IP:5432/keycloak (public IP + authorized networks)
    ContextForge (SQLAlchemy): postgresql+psycopg://user:pass@/dbname?host=/cloudsql/INSTANCE
[ ] Deploy keycloak to Cloud Run
[ ] Deploy contextforge to Cloud Run
[ ] Deploy sidecars (multi-container or separate services)
[ ] Update ALLOWED_ORIGINS with BOTH Cloud Run URL formats
[ ] Update Keycloak client redirectUris with Cloud Run callback URL
[ ] Update Keycloak client webOrigins with Cloud Run gateway URL
[ ] Update Google IdP redirect URI to Cloud Run Keycloak URL
[ ] Update Microsoft IdP redirect URI to Cloud Run Keycloak URL
[ ] Remove stale v5 Cloud Run URLs from realm JSON redirectUris/webOrigins
```

### Security Hardening Checklist (Phase 5)
```
[ ] All secrets via Secret Manager (--set-secrets), NOT --set-env-vars:
    JWT_SECRET_KEY, PLATFORM_ADMIN_PASSWORD, KC_ADMIN_PASSWORD,
    SSO_CLIENT_SECRET, AUTH_ENCRYPTION_SECRET, all DB passwords
[ ] Set KC_PROXY_HEADERS=xforwarded — so Keycloak generates https:// redirect URIs
[ ] Restrict Keycloak admin console (--ingress=internal or KC_HOSTNAME_ADMIN_URL)
[ ] Set --ingress=internal on sidecar services (not publicly accessible)
[ ] Evaluate SSRF settings for Cloud Run topology:
    Multi-container: keep SSRF_ALLOW_LOCALHOST=true
    Separate services: set SSRF_ALLOW_LOCALHOST=false
[ ] Set ALLOWED_ORIGINS to exact Cloud Run URLs (no wildcards, BOTH formats)
[ ] Set RELOAD=false explicitly
[ ] Verify /health endpoint does not leak internal architecture details
[ ] Enable Cloud Audit Logs for Cloud Run services
```

### Skill Invocations (Phase 5)
- [ ] Invoke `hardening-docker-containers-for-production` — CIS benchmark on images
- [ ] Invoke `securing-serverless-functions` — Cloud Run attack surface
- [ ] Invoke `supply-chain-risk-auditor` — dependency audit
- [ ] Invoke `claude-in-chrome` — browser test on Cloud Run URL

### Acceptance Test (Phase 5)
```
[ ] Open Cloud Run gateway URL
[ ] Click "Continue with Keycloak"
[ ] Login via Google or Microsoft
[ ] See admin dashboard
[ ] See MCP tools listed
```

---

## Env Vars That Sound Harmless But Are Dangerous

| Env Var | Dangerous Value | What Actually Happens |
|---------|----------------|----------------------|
| `MCP_CLIENT_AUTH_ENABLED=false` | Disables ALL JWT auth including admin panel SSO cookies |
| `ALLOWED_ORIGINS=*` or unset | Allows any origin — CORS wide open (unset defaults to `*`) |
| `ALLOWED_ORIGINS` missing a URL | SSO redirect_uri rejected silently |
| `JWT_SECRET_KEY` (default) | 11-char default, insecure + warning spam |
| `JWT_ALGORITHM` not matching key type | RS256 default with HMAC secret = silent JWT validation failure |
| `AUTH_REQUIRED=false` | Allows anonymous access to everything |
| `TRUST_PROXY_AUTH=true` | Trusts X-Authenticated-User header — any client can impersonate any user |
| `SSO_AUTO_CREATE_USERS=true` + `SSO_TRUSTED_DOMAINS` | Auto-creates AND auto-promotes matching domain users to admin |
| `SSRF_ALLOW_LOCALHOST=true` | Allows SSRF to localhost — bypasses network isolation |
| `API_ALLOW_BASIC_AUTH=true` | Basic auth credentials sent in cleartext over HTTP |
| `RELOAD=true` | Hot-reload watches filesystem — never enable in production |
| `WORKERS=16` (default) | Exhausts DB connection pool (16 × 200 = 3200 connections) |
| `DB_POOL_SIZE=200` (default) | Way too many for local dev or small Cloud SQL |
| `MCPGATEWAY_ADMIN_API_ENABLED=true` | Exposes REST API for server/tool management — must be auth-gated |

---

## Skills Summary

| Phase | Skills | Count |
|-------|--------|-------|
| 0: Email auth | `context7`, `claude-in-chrome` | 2 |
| 1: Keycloak SSO | `keycloak`, `oauth2`, `configuring-oauth2-authorization-flow`, `context7`, `claude-in-chrome` | 5 |
| 2: External IdPs | `keycloak`, `claude-in-chrome` | 2 |
| 3: Sidecars | `claude-in-chrome` | 1 |
| 4: Security audit | `sharp-edges`, `insecure-defaults`, `verification-before-completion` | 3 |
| 5: Cloud Run | `hardening-docker-containers-for-production`, `securing-serverless-functions`, `supply-chain-risk-auditor`, `claude-in-chrome` (MCP) | 4 |
| **Total** | | **17** |

All skills are checkboxed tasks in the plan. The implementing agent cannot skip them.

**Note:** `context7` and `claude-in-chrome` are MCP tools (invoked via MCP tool calls), not standalone skills. All others are Claude Code skills (invoked via the Skill tool).

### Contingency Skills (invoked on failure)
- **`systematic-debugging`** — invoke after ANY phase acceptance test failure, before attempting fixes
- **`cognitive-reflection`** — invoke at session end to capture what was learned

---

## The Golden Rule

**Do NOT proceed to the next phase until the current phase's acceptance test passes in a browser.**
