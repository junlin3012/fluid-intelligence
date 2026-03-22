# Config Reference

> Every environment variable across all 5 Cloud Run services.
> Last verified against live Cloud Run: 2026-03-22.

---

## ContextForge

The gateway has the most configuration. Stock image, all behavior controlled via env vars.

### Server

| Env Var | Value | Source | Description |
|---------|-------|--------|-------------|
| `HOST` | `0.0.0.0` | env | Gunicorn bind address |
| `MCG_HOST` | `0.0.0.0` | env | ContextForge bind address (must match HOST) |
| `MCG_PORT` | `8080` | env | ContextForge listen port |
| `WORKERS` | `2` | env | Gunicorn worker count. Default 16 exhausts DB pool. |
| `DB_POOL_SIZE` | `5` | env | SQLAlchemy pool size. Default 200 is way too many. |
| `DB_MAX_OVERFLOW` | `5` | env | Extra connections beyond pool size |
| `LOG_LEVEL` | `INFO` | env | Python logging level |
| `SECURE_COOKIES` | `true` | env | Set Secure flag on cookies (required for HTTPS) |

### Database

| Env Var | Value | Source | Description |
|---------|-------|--------|-------------|
| `DATABASE_URL` | `postgresql+psycopg://...@34.124.134.166:5432/contextforge` | env | SQLAlchemy connection string. **Contains credential — should move to Secret Manager.** |

### Authentication

| Env Var | Value | Source | Description | Dangerous? |
|---------|-------|--------|-------------|------------|
| `AUTH_REQUIRED` | `false` | env | Requires auth on all endpoints. **Currently `false` on Cloud Run — review needed.** | **YES** — `false` allows anonymous access |
| `MCP_CLIENT_AUTH_ENABLED` | `false` | env | Enables JWT auth for MCP endpoints. **Currently `false` on Cloud Run — review needed.** | **YES** — `false` disables ALL JWT auth including admin SSO cookies |
| `JWT_ALGORITHM` | `HS256` | env | JWT signing algorithm. Must match key type. | RS256 default with HMAC key = silent failure |
| `JWT_SECRET_KEY` | — | Secret Manager (`mcp-jwt-secret`) | JWT signing key |
| `AUTH_ENCRYPTION_SECRET` | — | Secret Manager (`auth-encryption-secret`) | DB-level encryption for stored tokens |
| `PLATFORM_ADMIN_EMAIL` | `admin@junlinleather.com` | env | Bootstrap admin email |
| `PLATFORM_ADMIN_PASSWORD` | — | Secret Manager (`mcp-auth-passphrase`) | Admin email/password fallback |
| `TRUST_PROXY_AUTH` | `false` | env | Trust X-Authenticated-User header from proxy | **YES** if `true` — any client can impersonate |
| `TRUST_PROXY_AUTH_DANGEROUSLY` | `false` | env | Explicit acknowledgment of proxy auth risk |

### SSO (Keycloak)

| Env Var | Value | Source | Description |
|---------|-------|--------|-------------|
| `SSO_ENABLED` | `true` | env | Enable SSO login |
| `SSO_KEYCLOAK_ENABLED` | `true` | env | Enable Keycloak as SSO provider |
| `SSO_KEYCLOAK_BASE_URL` | `https://keycloak-apanptkfaq-as.a.run.app` | env | Keycloak server URL |
| `SSO_KEYCLOAK_REALM` | `fluid` | env | Keycloak realm name |
| `SSO_KEYCLOAK_CLIENT_ID` | `fluid-gateway-sso` | env | Keycloak client ID |
| `SSO_KEYCLOAK_CLIENT_SECRET` | `<redacted>` | env | Client secret. **Should move to Secret Manager.** |
| `SSO_KEYCLOAK_MAP_REALM_ROLES` | `true` | env | Map Keycloak realm roles to ContextForge RBAC |
| `SSO_AUTO_CREATE_USERS` | `true` | env | Auto-create ContextForge user on first SSO login |
| `SSO_TRUSTED_DOMAINS` | `["junlinleather.com"]` | env | Auto-promote users from these domains |
| `SSO_PRESERVE_ADMIN_AUTH` | `true` | env | Keep email/password login as fallback |

### UI & API

| Env Var | Value | Source | Description | Dangerous? |
|---------|-------|--------|-------------|------------|
| `MCPGATEWAY_UI_ENABLED` | `true` | env | Enable admin web UI |
| `MCPGATEWAY_ADMIN_API_ENABLED` | `true` | env | Enable REST API for management | Must be auth-gated |
| `ALLOWED_ORIGINS` | `https://contextforge-...,https://keycloak-...` | env | CORS allowed origins | **YES** — missing URL = silent SSO redirect failure |

### Security

| Env Var | Value | Source | Description | Dangerous? |
|---------|-------|--------|-------------|------------|
| `SSRF_ALLOW_LOCALHOST` | `true` | env | Allow SSRF to localhost | Safe for multi-container; unsafe for separate services |
| `SSRF_ALLOW_PRIVATE_NETWORKS` | `true` | env | Allow SSRF to private networks |

---

## Keycloak

Identity broker. All IdP configuration (Google, Microsoft) is done via the **Admin UI**, not env vars.

| Env Var | Value | Source | Description |
|---------|-------|--------|-------------|
| `KC_DB` | `postgres` | env | Database type |
| `KC_DB_URL` | `jdbc:postgresql://34.124.134.166:5432/keycloak` | env | JDBC connection string |
| `KC_DB_USERNAME` | `keycloak_user` | env | Database username |
| `KC_DB_PASSWORD` | — | Secret Manager (`keycloak-db-password`) | Database credential |
| `KC_HTTP_PORT` | `8080` | env | HTTP listen port |
| `KC_BOOTSTRAP_ADMIN_USERNAME` | `admin` | env | Initial admin username |
| `KC_BOOTSTRAP_ADMIN_PASSWORD` | — | Secret Manager (`keycloak-admin-password`) | Initial admin credential |

### Missing (should add for production)

| Env Var | Recommended Value | Why |
|---------|-------------------|-----|
| `KC_PROXY_HEADERS` | `xforwarded` | So Keycloak generates `https://` redirect URIs behind Cloud Run |
| `KC_HOSTNAME` | `https://keycloak-apanptkfaq-as.a.run.app` | Explicit hostname for token issuer |

---

## Apollo

Shopify GraphQL execution. All Shopify credentials are service-level (shared by all users).

| Env Var | Value | Source | Description |
|---------|-------|--------|-------------|
| `SHOPIFY_STORE` | `junlinleather-5148.myshopify.com` | env | Shopify store domain |
| `SHOPIFY_API_VERSION` | `2026-01` | env | Shopify API version |
| `SHOPIFY_ACCESS_TOKEN` | `shpss_...` | env | **Should move to Secret Manager.** Shopify Admin API token. |
| `APOLLO_GRAPH_REF` | `shopify-fluid-intelligence@current` | env | Apollo GraphOS graph reference |
| `APOLLO_KEY` | `service:...` | env | **Should move to Secret Manager.** Apollo GraphOS API key. |
| `FORWARDED_ALLOW_IPS` | `*` | env | Trust Cloud Run X-Forwarded-Proto header |

### Config file (baked into image)

`services/apollo/config.yaml`:
- `transport.type`: `streamable_http` (NOT SSE — dropped in v1.10.0)
- `transport.host_validation.allowed_hosts`: both Cloud Run URL hostnames
- `schema.source`: `local` (baked `shopify-schema.graphql`)
- `introspection.execute.enabled`: `true`

---

## devmcp

Shopify documentation and learning layer. No credentials needed.

| Env Var | Value | Source | Description |
|---------|-------|--------|-------------|
| `FORWARDED_ALLOW_IPS` | `*` | env | Trust Cloud Run X-Forwarded-Proto header |

Port 8003 is hardcoded in the Dockerfile CMD, not configurable via env var.

---

## sheets

Google Sheets access. Currently deployed but **no credentials configured**.

| Env Var | Value | Source | Description |
|---------|-------|--------|-------------|
| `FORWARDED_ALLOW_IPS` | `*` | env | Trust Cloud Run X-Forwarded-Proto header |

Port 8004 is hardcoded in the Dockerfile CMD, not configurable via env var.

### Missing (needs service account)

To make sheets functional, add:
- Google service account JSON key (mount as secret or env var)
- Share target spreadsheets with the service account email

---

## Env Vars That Sound Harmless But Are Dangerous

| Env Var | Dangerous Value | What Actually Happens |
|---------|----------------|----------------------|
| `MCP_CLIENT_AUTH_ENABLED=false` | Disables ALL JWT auth including admin panel SSO cookies |
| `ALLOWED_ORIGINS=*` or unset | CORS wide open (unset defaults to `*`) |
| `ALLOWED_ORIGINS` missing a URL | SSO redirect_uri rejected silently |
| `JWT_SECRET_KEY` (default) | 11-char default, insecure + warning spam |
| `JWT_ALGORITHM` mismatch | RS256 default with HMAC secret = silent JWT validation failure |
| `AUTH_REQUIRED=false` | Anonymous access to everything |
| `TRUST_PROXY_AUTH=true` | Any client can impersonate any user via header |
| `SSO_AUTO_CREATE_USERS=true` + `SSO_TRUSTED_DOMAINS` | Auto-creates AND auto-promotes matching domain users |
| `SSRF_ALLOW_LOCALHOST=true` | Bypasses network isolation for SSRF |
| `RELOAD=true` | Hot-reload watches filesystem — never in production |
| `WORKERS=16` (default) | Exhausts DB connection pool (16 x 200 = 3200 connections) |
| `DB_POOL_SIZE=200` (default) | Way too many for local dev or small Cloud SQL |

---

## Production Hardening TODO

These items from the v6 spec Phase 5 are not yet done:

- [ ] Move `SHOPIFY_ACCESS_TOKEN` to Secret Manager
- [ ] Move `APOLLO_KEY` to Secret Manager
- [ ] Move `SSO_KEYCLOAK_CLIENT_SECRET` to Secret Manager
- [ ] Move `DATABASE_URL` to Secret Manager (or use `--set-secrets`)
- [ ] Set `KC_PROXY_HEADERS=xforwarded` on Keycloak
- [ ] Set `--ingress=internal` on apollo, devmcp, sheets (not publicly accessible)
- [ ] Review `AUTH_REQUIRED` and `MCP_CLIENT_AUTH_ENABLED` — both are `false` on Cloud Run
- [ ] Set `SSRF_ALLOW_LOCALHOST=false` (separate services, not multi-container)
- [ ] Set `RELOAD=false` explicitly
