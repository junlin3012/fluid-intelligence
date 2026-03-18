# ContextForge Capabilities Relevant to Fluid Intelligence

> IBM ContextForge 1.0.0-RC-2 — the gateway engine powering Fluid Intelligence.
> This doc catalogs features we use, features available but unused, and gaps we need to build around.

## 1. Admin Web UI

ContextForge ships a built-in admin dashboard (HTMX + Alpine.js).

| Setting | Value | Notes |
|---------|-------|-------|
| Enable | `MCPGATEWAY_UI_ENABLED=true` | Disabled in current v3 deployment |
| Framework | HTMX + Alpine.js | Lightweight, no React/Vue dependency |
| Auth | Same JWT/basic auth as API | Admin credentials required |

**What admins can do through the UI:**
- View system health and status dashboard
- Browse and search the tool catalog (all discovered tools across backends)
- Manage gateways (register/remove backends)
- Create and configure virtual servers (compose tool bundles)
- Manage users and teams (RBAC)
- Configure roles and permissions
- Set up SSO/OIDC providers (GitHub, Google, Okta, Keycloak, Microsoft Entra ID)

**Current state in Fluid Intelligence:** UI is disabled (`MCPGATEWAY_UI_ENABLED=false`). We use the Admin REST API via bootstrap.sh instead. Enabling the UI is a config toggle — no code change needed.

---

## 2. REST Admin API

Enabled via `MCPGATEWAY_ADMIN_API_ENABLED=true` (currently enabled).

### Core Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `POST /gateways` | Register | Add a new backend (auto-discovers its tools) |
| `GET /gateways` | List | Show all registered backends |
| `DELETE /gateways/<id>` | Remove | Unregister a backend |
| `GET /tools` | Catalog | List all tools with UUIDs, schemas, descriptions |
| `POST /servers` | Create | Create a virtual server (bundle specific tools) |
| `GET /servers` | List | Show all virtual servers |
| `DELETE /servers/<id>` | Remove | Delete a virtual server |
| `GET /servers/<id>/mcp` | MCP | Streamable HTTP endpoint for MCP clients |
| `GET /servers/<id>/sse` | MCP | SSE endpoint for MCP clients |
| `GET /healthz` | Health | Health check |

All endpoints require `Authorization: Bearer <JWT>` when `AUTH_REQUIRED=true`.

---

## 3. Virtual Servers (Tool Composition)

The key primitive for Option D (composable bundles).

**How it works:**
1. Backends register via `POST /gateways` — ContextForge auto-discovers their tools
2. All tools get UUIDs in a central catalog (`GET /tools`)
3. Admin creates virtual servers via `POST /servers` with an `associated_tools` array
4. Each virtual server exposes ONLY the whitelisted tools
5. MCP clients connect to `/servers/<UUID>/mcp` and see only those tools

```bash
# Create a virtual server with specific tools
POST /servers
{
  "server": {
    "name": "ops-team",
    "description": "Shopify orders + Google Sheets read-only",
    "associated_tools": ["uuid-1", "uuid-3", "uuid-7"]
  }
}
```

**Capabilities:**
- Multiple virtual servers can exist simultaneously
- Same tool can appear in multiple virtual servers
- Each virtual server gets its own UUID and MCP endpoint
- Virtual server definitions persist in database (survive restarts)
- Tool list is static per virtual server (set at creation time)

**Current state:** One virtual server ("fluid-intelligence") bundles ALL ~70+ tools. Created at bootstrap.

**Potential:** Create multiple virtual servers — one per team/role/persona — each with curated tool subsets.

---

## 4. RBAC (Role-Based Access Control)

Built-in but currently unused in Fluid Intelligence v3.

### Two-Layer Model

1. **Teams** — control visibility (which gateways/tools a user can see)
2. **Roles** — control actions (what operations a user can perform)

### Built-in Roles

| Role | Permissions |
|------|-------------|
| `platform_admin` | Full system access — manage everything |
| `team_admin` | Manage teams and users within their team |
| `developer` | Execute tools (the primary user role) |
| `viewer` | Read-only access to tool catalog |
| `platform_viewer` | Read system status only |

Custom roles can be bootstrapped from JSON configuration.

### Team-Based Tool Scoping

```
Team "shopify-ops" → sees only: apollo-shopify gateway tools
Team "sheets-team" → sees only: google-sheets gateway tools
User A (member of both) → sees all tools
User B (shopify-ops only) → sees only Shopify tools
```

### User Management
- Email-based accounts
- Role assignments per user per team
- Multi-tenant isolation at team level
- SSO/OIDC integration (no password management needed)

**Current state:** RBAC is available but not configured. Deferred in v3 spec: "Enable when team grows beyond 5 users."

**Potential:** Wire RBAC teams to virtual servers for per-group tool composition.

---

## 5. Authentication & SSO

### User Login (SSO/OIDC Providers)

| Provider | Status |
|----------|--------|
| GitHub OAuth | Supported |
| Google OAuth | Supported |
| Okta | Supported |
| Keycloak | Supported |
| Microsoft Entra ID | Supported |
| Custom OIDC | Supported |

### API Authentication

| Method | Details |
|--------|---------|
| JWT Bearer | Primary — HS256 or RS256 signing |
| Basic Auth | Disabled by default (`API_ALLOW_BASIC_AUTH=false`) |
| Token revocation | Via JTI (JWT ID) tracking |
| Token expiration | Mandatory, configurable lifetime |
| Refresh tokens | Supported |

**Current state:** JWT auth via bootstrap-generated tokens. No SSO configured (auth handled by mcp-auth-proxy).

**Potential:** Replace mcp-auth-proxy with ContextForge's native SSO. Users authenticate directly with ContextForge, get JWT, connect to their assigned virtual server.

---

## 6. Backend Registration & Management

### Supported Transports

| Transport | Use Case | Example |
|-----------|----------|---------|
| SSE | Streaming MCP servers | Apollo at `http://localhost:8000/sse` |
| Streamable HTTP | Native MCP HTTP | ContextForge-to-ContextForge |
| HTTP | Generic REST | Any HTTP API |
| stdio | Local processes | Via `mcpgateway.translate` bridge |

### OAuth-Protected Backends

ContextForge can authenticate TO upstream backends using OAuth:

```json
{
  "name": "github-mcp",
  "url": "https://github-mcp.example.com/sse",
  "auth_type": "oauth",
  "oauth_config": {
    "grant_type": "authorization_code",
    "client_id": "...",
    "client_secret": "...",
    "authorization_url": "https://github.com/login/oauth/authorize",
    "token_url": "https://github.com/login/oauth/access_token",
    "scopes": ["repo", "read:user"]
  }
}
```

Supports:
- Client Credentials flow (machine-to-machine)
- Authorization Code flow with PKCE (user-delegated)
- Tokens encrypted at rest in database
- Auto-refresh using refresh tokens

**Current state:** Backends registered without OAuth (all local in same container).

**Potential:** Register remote MCP servers (external APIs) with per-backend OAuth credentials.

---

## 7. stdio-to-HTTP Bridge (`mcpgateway.translate`)

Converts stdio-based MCP servers into HTTP endpoints.

```bash
python3 -m mcpgateway.translate \
  --stdio "npx -y @shopify/dev-mcp@latest" \
  --expose-sse \
  --expose-streamable-http \
  --port 8003
```

**Features:**
- Spawns stdio command as subprocess
- Bridges stdin/stdout to MCP JSON-RPC protocol
- Exposes at `/sse` and `/mcp` endpoints
- Health check at `/healthz`
- Configurable port

**Currently used for:**
- `@shopify/dev-mcp` (Node.js, port 8003)
- `mcp-google-sheets` (Python, port 8004)

**Cloud Run requirement:** `--no-cpu-throttling` needed for child processes.

---

## 8. Middleware Plugins (47 Available)

Plugins are middleware — they intercept and modify requests/responses. They do NOT add backends.

### Security Plugins

| Plugin | Purpose |
|--------|---------|
| PII filter | Detect/redact personally identifiable information |
| Secrets detection | Catch API keys, passwords in responses |
| Content moderation | Filter inappropriate content |
| SQL injection sanitizer | Sanitize tool inputs |
| Encoded exfiltration detection | Prevent data exfiltration via encoding |

### Infrastructure Plugins

| Plugin | Purpose |
|--------|---------|
| Rate limiting | Per-user, per-endpoint, per-backend throttling |
| Circuit breaker | Fail-fast for down backends |
| Automatic retry | Retry with backoff on transient failures |
| Response caching | Cache tool responses |
| Webhook support | Event notifications |

### Auth Plugins

| Plugin | Purpose |
|--------|---------|
| JWT claims extraction | Map JWT claims to user identity |
| Unified PDP | Policy Decision Point for RBAC enforcement |
| HashiCorp Vault | External secret management |
| Token validation | Validate and refresh tokens |

**Current state:** No plugins enabled in v3 deployment.

**Potential:** Rate limiting (protect Shopify API quotas), PII filtering (prevent leaking customer data), circuit breaker (handle backend failures gracefully).

---

## 9. Observability

### OpenTelemetry (Built-in)

| Feature | Details |
|---------|---------|
| Tracing | Automatic instrumentation, OTLP export |
| Trace propagation | Through tool calls to backends |
| Spans | HTTP request/response, tool routing, backend latency |
| GCP integration | Cloud Trace via OTLP |

### Metrics

| Type | Details |
|------|---------|
| Request counts | Per endpoint |
| Response times | Latency distribution |
| Error rates | Per backend |
| Tool call success/failure | Per tool |

### Logging & Audit

- Application logs via Python logging
- Request/response logging (configurable)
- Audit trail in database (user, tool, timestamp)
- GCP Cloud Logging integration

**Current state:** OTEL env vars not configured. No metrics collection enabled.

**Potential:** Enable Cloud Trace + Cloud Monitoring for full observability stack.

---

## 10. Database & Persistence

### Supported Databases

| Database | Status |
|----------|--------|
| PostgreSQL 17+ | Recommended for production |
| SQLite | Supported (deprecation planned per issue #2612) |
| MariaDB | Fully supported |

### What's Persisted

- Backend registrations (gateways)
- Virtual server definitions (tool bundles)
- User accounts and team memberships
- Role assignments
- OAuth credentials (encrypted at rest)
- Token revocation list (JTI blacklist)
- Audit logs
- Tool metadata

### Scaling

| Strategy | Details |
|----------|---------|
| Connection pooling | Default 200 connections |
| Caching | In-memory, database, or Redis |
| Multi-instance | PostgreSQL enables `max-instances > 1` |
| Stateless design | All state in database |

**Current state:** Cloud SQL PostgreSQL (db-f1-micro, ~$8/mo). Redis not configured.

---

## 11. Configuration

All configuration via environment variables (~2,500 lines of documented settings in `.env.example`).

### Key Variables

| Category | Variable | Purpose |
|----------|----------|---------|
| Auth | `JWT_SECRET_KEY` | JWT signing secret |
| | `PLATFORM_ADMIN_EMAIL` | Bootstrap admin |
| | `AUTH_ENCRYPTION_SECRET` | Encrypt stored OAuth secrets |
| Database | `DATABASE_URL` | PostgreSQL connection |
| | `CACHE_TYPE` | `database`, `memory`, or `redis` |
| | `REDIS_URL` | For distributed caching |
| Server | `HOST`, `PORT` | Bind address (0.0.0.0:4444) |
| | `GUNICORN_WORKERS` | Must be 1 on Cloud Run |
| | `HTTP_SERVER` | `gunicorn` or `granian` (Rust) |
| Features | `MCPGATEWAY_UI_ENABLED` | Web dashboard |
| | `MCPGATEWAY_ADMIN_API_ENABLED` | REST admin API |
| | `AUTH_REQUIRED` | Enforce authentication |
| SSRF | `SSRF_PROTECTION_ENABLED` | SSRF protection |
| | `SSRF_ALLOW_LOCALHOST` | Allow localhost backends |

No YAML or JSON config files — everything is env vars and API calls.

---

## 12. What ContextForge Does NOT Have

Important gaps for Fluid Intelligence's roadmap:

| Gap | Impact | Workaround |
|-----|--------|------------|
| No operation-level tool scoping | Can't allow `getOrders` but block `createOrder` from same backend | Need custom policy layer or separate backends per scope |
| No dynamic virtual servers per request | VS created at config time, not per-user at auth time | Pre-create VS per team, or build dynamic provisioning |
| No GraphQL-specific tooling | Protocol-agnostic — no Shopify domain knowledge | Apollo MCP Server handles GraphQL |
| No REST-to-MCP translation | Can't auto-convert OpenAPI specs to MCP tools | Use separate tools (e.g., openapi-mcp) |
| No tool versioning | Can't track changes to backend tool schemas | Monitor externally |
| No scheduled execution | No cron/task scheduling | Use Cloud Scheduler externally |
| No web-based tool builder | No low-code tool creation UI | Tools come from backends |
| No inbound webhook-to-tool mapping | Can't trigger tools from webhooks | Build custom webhook handler |

---

## 13. Feature Utilization Summary

| Feature | Available | Used in v3 | Priority to Enable |
|---------|-----------|------------|-------------------|
| Admin Web UI | Yes | No | Medium — enable for admin convenience |
| Admin REST API | Yes | Yes | Already active |
| Virtual servers | Yes | Partially (1 VS) | **High — key to Option D** |
| RBAC (teams/roles) | Yes | No | **High — enables per-group access** |
| SSO/OIDC login | Yes | No | Medium — replace mcp-auth-proxy |
| OAuth for backends | Yes | No | Medium — for remote backends |
| stdio bridges | Yes | Yes | Already active (2 bridges) |
| Middleware plugins | Yes (47) | No | Medium — rate limiting, PII filter |
| OpenTelemetry | Yes | No | **High — zero observability today** |
| PostgreSQL | Yes | Yes | Already active |
| Redis caching | Yes | No | Low — single instance for now |
| Token revocation | Yes | No | Medium — security hygiene |

---

## 14. Architecture Implications for Option D

ContextForge provides the composition engine (virtual servers + RBAC). What Fluid Intelligence needs to build ON TOP:

1. **Bundle definition store** — admin defines named bundles mapping to tool subsets
2. **User-to-bundle routing** — after auth, resolve user → bundle → virtual server
3. **Operation-level policy layer** — ContextForge controls tool visibility, but we need finer-grained control (read vs write within same tool)
4. **Dynamic VS lifecycle** — create/update virtual servers as bundles change, not just at bootstrap

ContextForge handles the heavy lifting (tool discovery, MCP protocol, auth, persistence). Fluid Intelligence adds the business logic layer (who gets what, with what permissions).
