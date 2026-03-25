# Architecture

> v6.2 — Last updated 2026-03-25.
> This is the single source of truth for how Fluid Intelligence works.

---

## System Topology

8 Cloud Run services + 1 Cloud SQL PostgreSQL instance:

```
                        ┌─────────────────────────────┐
                        │   Cloud SQL PostgreSQL      │
                        │   Instance: contextforge    │
                        │   IP: 34.124.134.166        │
                        │   max_connections: 50       │
                        │   (budget: 29 used)         │
                        │                             │
                        │   ┌─────────┐ ┌──────────┐ │
                        │   │contextforge│ │keycloak │ │
                        │   │  DB      │ │  DB      │ │
                        │   └─────────┘ └──────────┘ │
                        │   + oauth_credentials table │
                        └──────┬──────────┬──────┬────┘
                               │          │      │
┌──────────────────────────────┼──────────┼──────┼───────────────┐
│  Cloud Run Services          │          │      │               │
│                              │          │      │               │
│  ┌───────────────────────────┴──┐  ┌────┴──────┴───────────┐  │
│  │ contextforge (patched)       │  │ keycloak              │  │
│  │ IBM ContextForge 1.0.0-RC-2 │  │ Keycloak 26.1.4       │  │
│  │ + PR #3715 (JWKS verify)    │◄─┤ Identity broker        │  │
│  │ :8080                       │  │ Google + Microsoft IdPs│  │
│  └──────┬──────────┬───────────┘  │ :8080                  │  │
│         │          │              └─────────┬──────────────┘  │
│         │          │                        │                  │
│  ┌──────┴───────────────────────┐  ┌───────┴───┐              │
│  │ apollo (3-container)         │  │oauth-proxy│              │
│  │ ┌────────┐┌───────┐┌──────┐│  │ Caddy     │              │
│  │ │auth-   ││apollo ││cred- ││  │ bug #82   │              │
│  │ │proxy   ││v1.10.0││proxy ││  │ workaround│              │
│  │ │:8000   ││:8001  ││:8080 ││  └───────────┘              │
│  │ │Keycloak││       ││      ││                              │
│  │ │JWT ✓   ││       ││      ││  ┌──────────┐  ┌──────────┐ │
│  │ └────────┘└───────┘└──┬───┘│  │ devmcp   │  │ sheets   │ │
│  └───────────────────────┼────┘  │ :8003    │  │ :8004    │ │
│                          │       │ ⚠ NO AUTH│  │ ⚠ NO AUTH│ │
│  ┌───────────────────────┴────┐  └──────────┘  └──────────┘ │
│  │ token-service              │                              │
│  │ Credential lifecycle mgr   │                              │
│  │ :8000 (min-instances=1)    │                              │
│  └────────────────────────────┘                              │
└──────────────────────────────────────────────────────────────┘
```

**token-service** is the only always-on service (`min-instances=1`, `--cpu-always-allocated`). All others scale to zero.

**Apollo** is a 3-container Cloud Run service: auth-proxy (Keycloak JWT validation) + Apollo MCP Server (Rust binary) + credential-proxy (Shopify token injection). Requests flow: auth-proxy validates the Keycloak JWT → Apollo processes the MCP request → credential-proxy injects the Shopify access token → Shopify API. Apollo never holds credentials or handles auth.

**ContextForge** is patched with PR #3715 (JWKS verification for IdP-issued tokens). However, Claude Code crashes when using ContextForge tools due to multi-line tool descriptions triggering an Anthropic API bug (`cache_control cannot be set for empty text blocks`). ContextForge is deployed and working but **not currently usable from Claude Code**.

**oauth-proxy** is a Caddy reverse proxy that works around Claude.ai bug #82 (hardcoded OAuth paths). It routes `/authorize`, `/token`, `/register`, and `/realms/*` to Keycloak while passing everything else to ContextForge. However, Claude.ai's OAuth client skips the authorization step entirely, so it does not work yet.

ContextForge connects to the backends via their public Cloud Run URLs, registered through the admin UI.

## Auth Flow

Keycloak acts as an **identity broker**. Users never authenticate directly with Google/Microsoft — they go through Keycloak, which delegates to the configured identity providers.

```
User (browser)
  → https://contextforge-apanptkfaq-as.a.run.app
  → Click "Continue with Keycloak"
  → Redirect to Keycloak login page
  → Click "Google" (or "Microsoft")
  → Google/Microsoft login
  → Redirect back to Keycloak with identity
  → Keycloak issues JWT (email, realm_access.roles)
  → Redirect back to ContextForge with JWT
  → ContextForge validates JWT via JWKS
  → ContextForge maps realm roles to RBAC
  → User sees admin dashboard
```

### Key auth config

- **ContextForge SSO**: `SSO_KEYCLOAK_ENABLED=true` — native integration, no custom code
- **Keycloak client**: `fluid-gateway-sso` (confidential, client secret shared with ContextForge)
- **Keycloak realm**: `fluid` (imported from `realm-fluid.json` at image build time)
- **Identity providers**: Google OAuth + Microsoft Entra ID (configured in Keycloak Admin UI)
- **Role mapping**: `SSO_KEYCLOAK_MAP_REALM_ROLES=true` — Keycloak realm roles → ContextForge RBAC
- **User auto-creation**: `SSO_AUTO_CREATE_USERS=true` — first SSO login creates ContextForge user
- **Trusted domains**: `SSO_TRUSTED_DOMAINS=["junlinleather.com"]` — auto-promotes matching domain users
- **Fallback auth**: `SSO_PRESERVE_ADMIN_AUTH=true` — keeps email/password login during dev

### What Keycloak does NOT do

- Keycloak is NOT in the hot path for MCP requests — after initial JWKS fetch, JWT validation is local (cached keys)
- Keycloak does NOT store Shopify/API credentials — those live on the backend services
- Keycloak does NOT handle MCP protocol — it only handles human login

## Service Details

### ContextForge (gateway) — PARTIALLY WORKING

| | |
|---|---|
| **Purpose** | MCP gateway core — tool aggregation, RBAC, admin UI, SSO |
| **Image** | `ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2` + PR #3715 patch (JWKS verification) |
| **Cloud Run URL** | `https://contextforge-apanptkfaq-as.a.run.app` |
| **Port** | 8080 |
| **Database** | `contextforge` on Cloud SQL |
| **Custom code** | `services/platform/contextforge/Dockerfile` — patches 2 Python files for PR #3715 |
| **Key config** | See `config-reference.md` (25+ env vars) |
| **Status** | Auth works (JWKS verification verified). **Blocked for Claude Code** — tool descriptions with multi-line text trigger Anthropic API bug (`cache_control cannot be set for empty text blocks`). **Blocked for Claude.ai** — bug #82 (OAuth client skips authorize step). |

### Keycloak (identity)

| | |
|---|---|
| **Purpose** | Identity broker — Google/Microsoft SSO, user management, realm roles |
| **Image** | Custom Dockerfile based on `quay.io/keycloak/keycloak:26.1.4` |
| **Cloud Run URL** | `https://keycloak-apanptkfaq-as.a.run.app` |
| **Port** | 8080 |
| **Database** | `keycloak` on Cloud SQL |
| **Custom code** | `services/keycloak/Dockerfile` — bakes `realm-fluid.json` into image |
| **Admin UI** | `https://keycloak-apanptkfaq-as.a.run.app/admin/master/console/#/fluid` |

### Apollo (Shopify GraphQL) — 3-container, Keycloak-authenticated

| | |
|---|---|
| **Purpose** | Executes Shopify GraphQL queries and mutations |
| **Image** | Custom Dockerfile — compiles Apollo MCP Server v1.10.0 from Rust source |
| **Cloud Run URL** | `https://apollo-apanptkfaq-as.a.run.app` |
| **Containers** | auth-proxy (:8000, ingress) + Apollo (:8001) + credential-proxy (:8080) |
| **Transport** | Streamable HTTP (`/mcp` endpoint) — NOT SSE (dropped in v1.10.0) |
| **Auth** | Keycloak JWT validated by auth-proxy sidecar via JWKS. RFC 9728 metadata served for `mcp-remote` OAuth discovery. |
| **Custom code** | `services/verticals/shopify/apollo/Dockerfile` + `config.yaml`, `services/platform/credential-proxy/`, `services/platform/auth-proxy/` |
| **Credentials** | **None** — Apollo holds no credentials. The credential-proxy sidecar injects `X-Shopify-Access-Token` per-request by fetching from token-service. |
| **Tools** | `execute` (run GraphQL), `validate` (check query against schema) |
| **Service YAML** | `apollo-service-authenticated.yaml` (3-container spec) |

### token-service (credential lifecycle)

| | |
|---|---|
| **Purpose** | Enterprise credential lifecycle manager — manages OAuth token refresh for all API providers |
| **Image** | Custom Dockerfile — Python 3.12 + FastAPI |
| **Cloud Run URL** | `https://token-service-apanptkfaq-as.a.run.app` |
| **Port** | 8000 |
| **Database** | `oauth_credentials` table in `contextforge` DB (AES-256-GCM encrypted) |
| **Custom code** | `services/token-service/` (~400 lines Python) — first application code in the system |
| **Key features** | Proactive refresh (every 45 min) + lazy refresh on-demand, single-flight locking, HMAC-SHA256 CSRF nonce, multi-provider schema |
| **Config** | `min-instances=1`, `--cpu-always-allocated` (background refresh loop needs always-on CPU) |
| **DB pool** | `pool_size=2, max_overflow=2` (4 connections max, within 50-connection budget) |

### credential-proxy (sidecar)

| | |
|---|---|
| **Purpose** | Injects fresh API credentials into outbound requests — services never hold third-party tokens |
| **Image** | Custom Dockerfile — Python 3.12 + FastAPI (~80 lines) |
| **Runs as** | Sidecar container inside Apollo's Cloud Run service |
| **Port** | 8080 |
| **Custom code** | `services/credential-proxy/proxy.py` |
| **Behavior** | On each request: fetches token from token-service (30s cache), injects `X-Shopify-Access-Token`, forwards to Shopify API |

### auth-proxy (Keycloak JWT sidecar)

| | |
|---|---|
| **Purpose** | Validates Keycloak JWT tokens via JWKS before forwarding to upstream services |
| **Image** | Custom Dockerfile — Python 3.12 + FastAPI (~70 lines) |
| **Runs as** | Sidecar container inside Apollo's Cloud Run service (ingress) |
| **Port** | 8000 |
| **Custom code** | `services/platform/auth-proxy/proxy.py` |
| **Behavior** | On each request: extracts Bearer token → verifies JWT signature against Keycloak JWKS → forwards authenticated requests to upstream. Serves RFC 9728 metadata for `mcp-remote` OAuth discovery. Health checks return 200 without auth. |

### oauth-proxy (Claude.ai bug #82 workaround)

| | |
|---|---|
| **Purpose** | Routes OAuth paths to Keycloak for Claude.ai which hardcodes `/authorize`, `/token` on the MCP domain |
| **Image** | `caddy:2-alpine` + custom Caddyfile |
| **Cloud Run URL** | `https://oauth-proxy-apanptkfaq-as.a.run.app` |
| **Port** | 8080 |
| **Custom code** | `services/platform/oauth-proxy/Caddyfile` (~50 lines, zero application code) |
| **Status** | Deployed and working (DCR, metadata, path routing all verified). **Blocked** — Claude.ai's OAuth client skips the authorize step entirely (bug #82). Remove when Anthropic fixes the bug. |

### devmcp (Shopify docs)

| | |
|---|---|
| **Purpose** | Shopify developer documentation, schema introspection, query building |
| **Image** | Custom Dockerfile — ContextForge base + `@shopify/dev-mcp` via npm |
| **Cloud Run URL** | `https://devmcp-apanptkfaq-as.a.run.app` |
| **Port** | 8003 |
| **Transport** | SSE via `mcpgateway.translate` bridge (stdio → SSE) |
| **Custom code** | `services/devmcp/Dockerfile` — installs dev-mcp into ContextForge base image |

### sheets (Google Sheets)

| | |
|---|---|
| **Purpose** | Google Sheets read/write access |
| **Image** | Custom Dockerfile — ContextForge base + `mcp-google-sheets` via pip |
| **Cloud Run URL** | `https://sheets-apanptkfaq-as.a.run.app` |
| **Port** | 8004 |
| **Transport** | SSE via `mcpgateway.translate` bridge (stdio → SSE) |
| **Custom code** | `services/sheets/Dockerfile` — installs mcp-google-sheets into ContextForge base image |
| **Status** | Deployed but no Google service account credentials configured yet |

## Inter-Service Communication

### ContextForge → Backends

Backends are registered in the ContextForge **Admin UI** (not via API or scripts):

| Backend | Registration URL | Transport |
|---------|-----------------|-----------|
| Apollo Shopify | `https://apollo-apanptkfaq-as.a.run.app/mcp` | Streamable HTTP |
| Shopify Dev MCP | `https://devmcp-apanptkfaq-as.a.run.app/sse` | SSE |
| Google Sheets | `https://sheets-apanptkfaq-as.a.run.app/sse` | SSE |

### ContextForge → Keycloak

- JWKS fetch: `https://keycloak-apanptkfaq-as.a.run.app/realms/fluid/protocol/openid-connect/certs`
- Cached for ~5 minutes — Keycloak is NOT in the hot path after initial fetch

### Cloud Run → Cloud SQL

- ContextForge connects via public IP: `postgresql+psycopg://contextforge_user:...@34.124.134.166:5432/contextforge`
- Keycloak connects via JDBC: `jdbc:postgresql://34.124.134.166:5432/keycloak`
- Both use authorized networks (Cloud Run egress IP whitelisted)

## Custom Code Inventory

**Mostly configuration, with one exception:** token-service and credential-proxy are the only application code in the system (~500 lines Python total). This is justified because no existing component in the stack handles OAuth token lifecycle — it's the one concern that can't be solved with config alone.

### Configuration (no application logic)

| File | Lines | Purpose |
|------|-------|---------|
| `services/keycloak/Dockerfile` | ~50 | Bakes realm JSON into stock Keycloak image |
| `services/keycloak/realm-fluid.json` | ~1900 | Realm config: client, roles, scopes, mappers |
| `services/apollo/Dockerfile` | ~65 | Multi-stage Rust build of Apollo MCP Server |
| `services/apollo/config.yaml` | ~20 | Endpoint → credential-proxy, no credentials |
| `services/apollo/config-local.yaml` | ~20 | Local dev override (Docker service name) |
| `services/apollo/apollo-service.yaml` | ~35 | Cloud Run multi-container spec |
| `services/apollo/shopify-schema.graphql` | ~98K | Shopify Admin API schema (baked into image) |
| `services/devmcp/Dockerfile` | ~50 | ContextForge base + npm install @shopify/dev-mcp |
| `services/sheets/Dockerfile` | ~50 | ContextForge base + pip install mcp-google-sheets |
| `services/contextforge/db/init.sql` | ~20 | Creates contextforge DB + user |
| `services/keycloak/db/init.sql` | ~20 | Creates keycloak DB + user |
| `services/token-service/db/init.sql` | ~30 | Creates oauth_credentials table + user |
| `services/db-init.sh` | ~15 | Wrapper script for docker-compose postgres init |
| `docker-compose.yml` | ~280 | Local dev stack (all 8 services) |

### Application code (token lifecycle only)

| File | Lines | Purpose |
|------|-------|---------|
| `services/token-service/app/main.py` | ~40 | FastAPI app, lifespan, route registration |
| `services/token-service/app/encryption.py` | ~25 | AES-256-GCM encrypt/decrypt |
| `services/token-service/app/services/token_manager.py` | ~150 | Single-flight lock, proactive + lazy refresh |
| `services/token-service/app/services/state_nonce.py` | ~40 | HMAC-SHA256 CSRF nonce |
| `services/token-service/app/providers/shopify.py` | ~70 | Shopify OAuth refresh, exchange, authorize |
| `services/token-service/app/routes/*.py` | ~120 | API endpoints (token, oauth, admin, health) |
| `services/credential-proxy/proxy.py` | ~80 | Token injection proxy (sidecar) |
| **Total application code** | **~525** | |

## Cloud Run Configuration

### Endpoint Security Status (as of 2026-03-25)

| Service | Auth | Method | Status |
|---------|------|--------|--------|
| **apollo** | Keycloak JWT | auth-proxy sidecar validates via JWKS | **Secured** |
| **contextforge** | Keycloak SSO | Native `SSO_KEYCLOAK_ENABLED=true` + PR #3715 | **Secured** (but unusable from Claude Code) |
| **keycloak** | Public | Login pages are public by design | **OK** |
| **oauth-proxy** | Keycloak JWT | Forwards auth to ContextForge/Keycloak | **Secured** |
| **token-service** | API key | `TOKEN_SERVICE_API_KEY` required on all endpoints | **Secured** |
| **devmcp** | **NONE** | `/sse` endpoint is publicly accessible | **NOT SECURED** |
| **sheets** | **NONE** | `/sse` endpoint is publicly accessible | **NOT SECURED** |

**TODO:** Add auth-proxy sidecar to devmcp and sheets (same pattern as Apollo).

### URL Format

Use the **new format**: `*-apanptkfaq-as.a.run.app`

The old format (`*-1056128102929.asia-southeast1.run.app`) still works but is deprecated. All OAuth redirect URIs, ALLOWED_ORIGINS, and SSO config must use a consistent format.

### Secrets in Secret Manager

| Secret name | Used by |
|------------|---------|
| `mcp-jwt-secret` | ContextForge (`JWT_SECRET_KEY`) |
| `auth-encryption-secret` | ContextForge (`AUTH_ENCRYPTION_SECRET`) |
| `mcp-auth-passphrase` | ContextForge (`PLATFORM_ADMIN_PASS`) |
| `keycloak-db-password` | Keycloak (`KC_DB_PASSWORD`) |
| `keycloak-admin-password` | Keycloak (`KC_BOOTSTRAP_ADMIN_PASSWORD`) |

### New secrets needed for token-service

| Secret name | Used by | Status |
|------------|---------|--------|
| `token-encryption-key` | token-service (`TOKEN_ENCRYPTION_KEY`) | Create in Secret Manager |
| `shopify-client-secret` | token-service (`SHOPIFY_CLIENT_SECRET`) | Create in Secret Manager |

### Secrets NOT yet in Secret Manager (plain env vars)

| Env var | Service | Action needed |
|---------|---------|---------------|
| `SSO_KEYCLOAK_CLIENT_SECRET` | ContextForge | Move to Secret Manager |
| `DATABASE_URL` (contains cred) | ContextForge | Move to Secret Manager |

Note: `SHOPIFY_ACCESS_TOKEN` is no longer used — Apollo gets tokens dynamically via credential-proxy → token-service.

## GCP Resources

| Resource | Details |
|----------|---------|
| Project | `junlinleather-mcp` (number: `1056128102929`) |
| Region | `asia-southeast1` |
| Cloud SQL | Instance `contextforge`, tier `db-f1-micro`, IP `34.124.134.166` |
| Artifact Registry | `junlin-mcp` (asia-southeast1) |
| IAM | `allUsers` → `roles/run.invoker` on all Cloud Run services |

## Related Docs

- **Config reference**: `docs/config-reference.md` — every env var across all services
- **Known gotchas**: `docs/known-gotchas.md` — distilled lessons from v3-v6
- **Contributing**: `docs/contributing.md` — how to add backends, deploy, troubleshoot
- **v6 design spec**: `docs/specs/2026-03-21-fluid-intelligence-v6-design.md`
