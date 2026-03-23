# ContextForge v1.0.0-RC-2 — Complete Capability Reference

> Phase 0 deliverable. Every env var and feature documented here.
> Source: context7 queries against /ibm/mcp-context-forge (2026-03-21)

---

## SSO Configuration (Keycloak — our use case)

| Env Var | Default | Purpose |
|---------|---------|---------|
| `SSO_ENABLED` | `false` | Master switch for SSO |
| `SSO_KEYCLOAK_ENABLED` | `false` | Enable Keycloak OIDC provider |
| `SSO_KEYCLOAK_BASE_URL` | — | Keycloak server URL (e.g., `https://keycloak.example.com`) |
| `SSO_KEYCLOAK_REALM` | `master` | Keycloak realm name |
| `SSO_KEYCLOAK_CLIENT_ID` | — | OAuth client ID |
| `SSO_KEYCLOAK_CLIENT_SECRET` | — | OAuth client secret |
| `SSO_KEYCLOAK_MAP_REALM_ROLES` | `false` | Map Keycloak realm roles to ContextForge RBAC |
| `SSO_KEYCLOAK_MAP_CLIENT_ROLES` | `false` | Map Keycloak client roles |
| `SSO_KEYCLOAK_USERNAME_CLAIM` | `preferred_username` | JWT claim for username |
| `SSO_KEYCLOAK_EMAIL_CLAIM` | `email` | JWT claim for email |
| `SSO_KEYCLOAK_GROUPS_CLAIM` | `groups` | JWT claim for groups |
| `SSO_AUTO_CREATE_USERS` | `false` | Auto-create user on first SSO login |
| `SSO_PRESERVE_ADMIN_AUTH` | `false` | Keep local admin auth alongside SSO |
| `SSO_TRUSTED_DOMAINS` | `[]` | Restrict SSO to email domains (JSON array) |
| `SSO_REQUIRE_ADMIN_APPROVAL` | `false` | Gate new SSO users behind admin approval |

**SSO login flow:** `/auth/sso/login/{provider_id}?redirect_uri=/docs` → returns JSON `{authorization_url, state}`. Client must redirect to `authorization_url`. Callback: `/auth/sso/callback/{provider_id}`.

**Other SSO providers available:** GitHub (`SSO_GITHUB_ENABLED`), Google (`SSO_GOOGLE_ENABLED`), Microsoft Entra (`SSO_ENTRA_ENABLED`), Generic OIDC (`SSO_GENERIC_ENABLED`).

## Auth Configuration

| Env Var | Default | Purpose |
|---------|---------|---------|
| `AUTH_REQUIRED` | `true` | Require auth on all endpoints |
| `MCP_CLIENT_AUTH_ENABLED` | `true` | Require JWT auth on MCP endpoints |
| `MCP_REQUIRE_AUTH` | inherits `AUTH_REQUIRED` | MCP-specific auth override |
| `TRUST_PROXY_AUTH` | `false` | Trust identity from proxy header |
| `TRUST_PROXY_AUTH_DANGEROUSLY` | `false` | Required with TRUST_PROXY_AUTH |
| `PROXY_USER_HEADER` | `X-Authenticated-User` | Header name for proxy identity |
| `JWT_SECRET_KEY` | — | Secret for HMAC JWT signing (HS256) |
| `JWT_ALGORITHM` | `RS256` | JWT algorithm |
| `REQUIRE_TOKEN_EXPIRATION` | `true` | Reject tokens without exp claim |
| `REQUIRE_JTI` | `true` | Reject tokens without jti |
| `API_ALLOW_BASIC_AUTH` | `false` | Enable basic auth for admin API |
| `BASIC_AUTH_USER` | `admin` | Basic auth username |
| `BASIC_AUTH_PASSWORD` | — | Basic auth password |
| `PLATFORM_ADMIN_EMAIL` | — | Bootstrap admin email |
| `PLATFORM_ADMIN_PASSWORD` | — | Bootstrap admin password |

**For v5 with Keycloak SSO:** Set `SSO_ENABLED=true`, `SSO_KEYCLOAK_ENABLED=true`, `AUTH_REQUIRED=true`. ContextForge handles JWT validation internally via the SSO provider's JWKS. No custom plugin needed.

## UI & Admin

| Env Var | Default | Purpose |
|---------|---------|---------|
| `MCPGATEWAY_UI_ENABLED` | `false` | Enable admin web UI |
| `MCPGATEWAY_ADMIN_API_ENABLED` | `false` | Enable admin REST API |
| `MCPGATEWAY_BULK_IMPORT_ENABLED` | `false` | Enable bulk import |
| `MCPGATEWAY_BULK_IMPORT_MAX_TOOLS` | `200` | Max tools per import |

## Database

| Env Var | Default | Purpose |
|---------|---------|---------|
| `DATABASE_URL` | `sqlite:///./mcp.db` | Database connection string |
| `DB_POOL_SIZE` | `200` | Connection pool size |
| `DB_MAX_OVERFLOW` | `5` | Max overflow connections |
| `DB_POOL_TIMEOUT` | `60` | Pool timeout (seconds) |
| `DB_POOL_RECYCLE` | `3600` | Connection recycle interval |
| `DB_PREPARE_THRESHOLD` | `5` | PostgreSQL prepared statement threshold |

**PostgreSQL format:** `postgresql+psycopg://user:pass@host:5432/dbname`
**Cloud SQL Unix socket:** `postgresql+psycopg://user:pass@/dbname?host=/cloudsql/INSTANCE`

**CRITICAL:** Use `psycopg` driver (not `asyncpg`). v4 failed with `asyncpg` import error.

## Server & Network

| Env Var | Default | Purpose |
|---------|---------|---------|
| `HOST` / `MCG_HOST` | `127.0.0.1` | Bind address. **Must be `0.0.0.0` for containers** |
| `PORT` / `MCG_PORT` | `4444` | Listen port. **Use 8080 for Cloud Run** |
| `RELOAD` | `false` | Hot-reload for development |

## Security

| Env Var | Default | Purpose |
|---------|---------|---------|
| `SECURITY_HEADERS_ENABLED` | `true` | Add security headers to responses |
| `CORS_ENABLED` | `true` | Enable CORS |
| `CORS_ALLOW_CREDENTIALS` | `true` | Allow credentials in CORS |
| `ALLOWED_ORIGINS` | `*` | Comma-separated allowed origins |
| `SSRF_ALLOW_LOCALHOST` | varies | Allow SSRF to localhost |
| `SSRF_ALLOW_PRIVATE_NETWORKS` | varies | Allow SSRF to private IPs |

## Observability

| Env Var | Default | Purpose |
|---------|---------|---------|
| `OTEL_ENABLE_OBSERVABILITY` | `false` | Enable OpenTelemetry |
| `OTEL_TRACES_EXPORTER` | `none` | Trace exporter (otlp, jaeger, console) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | — | OTLP endpoint URL |
| `ENABLE_METRICS` | `false` | Enable Prometheus metrics |
| `LOG_LEVEL` | `INFO` | Logging level |

## Backend Registration

**POST /gateways** — Register a backend MCP server:
```json
{"name": "server-name", "url": "http://host:port/sse", "transport": "SSE"}
```
Transport options: `SSE`, `STREAMABLEHTTP`
Auto-discovers tools after registration.

**POST /servers** — Create virtual server bundling tools:
```json
{"server": {"name": "virtual-name", "description": "...", "associated_tools": ["tool-id-1"]}}
```

**No config-file-based registration.** Backends MUST be registered via API (bootstrap script).

## Plugin System

| Env Var | Default | Purpose |
|---------|---------|---------|
| `PLUGINS_ENABLED` | `false` | Enable plugin framework |
| `PLUGIN_CONFIG_FILE` | `plugins/config.yaml` | Plugin config path |

16 hook types available. For v5: **plugins NOT needed** — SSO handles auth, built-in handles everything else.

## RBAC

Built-in roles: `platform_admin`, `team_admin`, `developer`, `viewer`
When `SSO_KEYCLOAK_MAP_REALM_ROLES=true`, Keycloak realm roles are mapped to ContextForge roles.

## Audit

| Env Var | Default | Purpose |
|---------|---------|---------|
| `AUDIT_TRAIL_RETENTION_DAYS` | `90` | Audit log retention |

Built-in audit trail logs every action with user, IP, correlation ID.

## What ContextForge Does NOT Do (requires custom code or external tools)

1. **Backend auto-registration from config file** — must use API (bootstrap.py justified)
2. **Browser redirect on 401** — SSO login is API-based (returns JSON authorization_url), not auto-redirect
3. **Tenant context injection** — credentials per-tenant per-request (v6 scope)
