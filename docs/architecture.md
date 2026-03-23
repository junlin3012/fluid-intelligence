# Architecture

> v6.1 — Last updated 2026-03-24.
> This is the single source of truth for how Fluid Intelligence works.

---

## System Topology

7 Cloud Run services + 1 Cloud SQL PostgreSQL instance:

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
│  │ contextforge                 │  │ keycloak              │  │
│  │ IBM ContextForge 1.0.0-RC-2 │  │ Keycloak 26.1.4       │  │
│  │ MCP gateway + admin UI      │◄─┤ Identity broker        │  │
│  │ :8080                       │  │ Google + Microsoft IdPs│  │
│  └──────┬──────────┬───────────┘  │ :8080                  │  │
│         │          │              └────────────────────────┘  │
│         │          │                                          │
│  ┌──────┴───────────────┐  ┌──────────┐  ┌──────────┐       │
│  │ apollo (multi-cont.) │  │ devmcp   │  │ sheets   │       │
│  │ ┌─────────┐┌───────┐│  │ translate│  │ translate│       │
│  │ │ apollo  ││ cred- ││  │ bridge   │  │ bridge   │       │
│  │ │ v1.10.0 ││ proxy ││  │ :8003    │  │ :8004    │       │
│  │ │ :8000   ││ :8080 ││  └──────────┘  └──────────┘       │
│  │ └─────────┘└───┬───┘│                                    │
│  └────────────────┼────┘                                    │
│                   │                                          │
│  ┌────────────────┴────────────────┐                        │
│  │ token-service                   │                        │
│  │ Credential lifecycle manager    │                        │
│  │ Proactive + lazy refresh        │                        │
│  │ AES-256-GCM encrypted storage   │                        │
│  │ :8000 (min-instances=1)         │                        │
│  └─────────────────────────────────┘                        │
└─────────────────────────────────────────────────────────────┘
```

**token-service** is the only always-on service (`min-instances=1`, `--cpu-always-allocated`). All others scale to zero.

**Apollo** is a multi-container Cloud Run service: the Apollo MCP Server binary + a credential-proxy sidecar. Apollo sends GraphQL to `localhost:8080` (the proxy), which injects the Shopify access token and forwards to Shopify's API. Apollo never holds credentials.

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

### ContextForge (gateway)

| | |
|---|---|
| **Purpose** | MCP gateway core — tool aggregation, RBAC, admin UI, SSO |
| **Image** | `ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2` (stock, no custom Dockerfile) |
| **Cloud Run URL** | `https://contextforge-apanptkfaq-as.a.run.app` |
| **Port** | 8080 |
| **Database** | `contextforge` on Cloud SQL |
| **Custom code** | None — entirely configured via env vars |
| **Key config** | See `config-reference.md` (25+ env vars) |

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

### Apollo (Shopify GraphQL) — multi-container

| | |
|---|---|
| **Purpose** | Executes Shopify GraphQL queries and mutations |
| **Image** | Custom Dockerfile — compiles Apollo MCP Server v1.10.0 from Rust source |
| **Cloud Run URL** | `https://apollo-apanptkfaq-as.a.run.app` |
| **Port** | 8000 (Apollo) + 8080 (credential-proxy sidecar) |
| **Transport** | Streamable HTTP (`/mcp` endpoint) — NOT SSE (dropped in v1.10.0) |
| **Custom code** | `services/apollo/Dockerfile` + `config.yaml`, `services/credential-proxy/` |
| **Credentials** | **None** — Apollo holds no credentials. The credential-proxy sidecar injects `X-Shopify-Access-Token` per-request by fetching from token-service. |

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
