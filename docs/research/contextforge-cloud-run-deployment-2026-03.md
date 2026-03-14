# IBM ContextForge: Cloud Run Deployment Research

**Date**: 2026-03-14
**Repo**: github.com/IBM/mcp-context-forge (3.4k stars, Apache 2.0)
**Version**: 1.0.0-RC-2
**Image**: `ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2`
**PyPI**: `mcp-contextforge-gateway`

---

## 1. Docker Setup — How the Container Works

ContextForge is a Python FastAPI application served by Gunicorn + Uvicorn (or optionally Granian, a Rust HTTP server). The container uses Red Hat UBI 10 Minimal as base.

**Container files:**
- `Containerfile` — Full build with optional Rust plugins
- `Containerfile.lite` — Lighter build, same runtime (used in docker-compose)
- `Containerfile.scratch` — Minimal variant

**Key architecture:**
- Python 3.12 venv at `/app/.venv`
- Entrypoint: `docker-entrypoint.sh` → selects `run-gunicorn.sh` or `run-granian.sh` based on `HTTP_SERVER` env var
- Port: 4444
- Runs as UID 1001 (non-root)
- No Node.js, no Rust required at runtime (Rust plugins are optional build-time)

**Build command:**
```bash
docker build -f Containerfile.lite -t contextforge .
# Or with Rust plugins:
docker build --build-arg ENABLE_RUST=true -f Containerfile.lite -t contextforge .
```

**ARM64 caveat:** "Currently, arm64 is not supported on production. If you are running on MacOS with Apple Silicon chips (M1, M2, etc), you can run the containers using Rosetta or install via PyPi instead." Cloud Run uses x86_64 so this is fine.

---

## 2. Stdio-to-HTTP Translation (mcpgateway.translate)

The `mcpgateway.translate` module converts stdio-based MCP servers into HTTP endpoints. This is the critical piece for wrapping servers like `@shopify/dev-mcp`.

**How it works:**
1. Spawns the stdio command as a subprocess
2. Wraps stdin/stdout with MCP JSON-RPC protocol handling
3. Exposes the tools/resources/prompts via HTTP endpoints (SSE and/or Streamable HTTP)

**Usage:**
```bash
# Expose a stdio MCP server as SSE
python3 -m mcpgateway.translate \
  --stdio "npx -y @shopify/dev-mcp@latest" \
  --expose-sse \
  --port 8003

# Expose via both SSE and Streamable HTTP
python3 -m mcpgateway.translate \
  --stdio "npx -y @shopify/dev-mcp@latest" \
  --expose-sse \
  --expose-streamable-http \
  --port 8003
# Accessible at /sse (SSE) and /mcp (Streamable HTTP)
```

**Then register with the gateway:**
```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"shopify-dev","url":"http://localhost:8003/sse"}' \
  http://localhost:4444/gateways
```

**For Cloud Run:** The translate process and gateway must run in the same container (or as separate Cloud Run services). Since translate spawns a subprocess (the stdio server), it needs `--no-cpu-throttling` on Cloud Run.

---

## 3. Configuration Format

ContextForge uses **environment variables** exclusively. No YAML or JSON config files. Configuration sources:
- `.env` file (loaded by the app)
- Environment variables passed to Docker/Cloud Run
- Some settings configurable via Admin API at runtime

The `.env.example` file is ~2500 lines with detailed comments for every setting.

---

## 4. Adding Backends

### Adding an HTTP/SSE Backend (like Apollo)

Register via the Admin API:
```bash
# Generate a JWT token first
export TOKEN=$(python3 -m mcpgateway.utils.create_jwt_token \
  --username admin@example.com --exp 10080 --secret $JWT_SECRET_KEY)

# Register Apollo as an SSE gateway
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "apollo-shopify",
    "url": "http://apollo-host:3000/sse",
    "transport": "SSE"
  }' \
  http://localhost:4444/gateways

# Or as Streamable HTTP
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "apollo-shopify",
    "url": "http://apollo-host:3000/mcp",
    "transport": "STREAMABLEHTTP"
  }' \
  http://localhost:4444/gateways
```

### Adding a Stdio Backend (like @shopify/dev-mcp)

Two-step process:
1. Run `mcpgateway.translate` to expose it as HTTP
2. Register the HTTP endpoint with the gateway

```bash
# Step 1: Translate stdio to HTTP (run as sidecar or in same container)
python3 -m mcpgateway.translate \
  --stdio "npx -y @shopify/dev-mcp@latest" \
  --expose-sse \
  --port 8003

# Step 2: Register with gateway
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"shopify-dev-mcp","url":"http://localhost:8003/sse"}' \
  http://localhost:4444/gateways
```

### Adding OAuth-Protected Backends

```json
{
  "name": "GitHub MCP",
  "url": "https://github-mcp.example.com/sse",
  "auth_type": "oauth",
  "oauth_config": {
    "grant_type": "authorization_code",
    "client_id": "your_app_id",
    "client_secret": "your_app_secret",
    "authorization_url": "https://github.com/login/oauth/authorize",
    "token_url": "https://github.com/login/oauth/access_token",
    "redirect_uri": "https://gateway.example.com/oauth/callback",
    "scopes": ["repo", "read:user"]
  }
}
```

### Listing All Registered Backends

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:4444/gateways | jq
```

---

## 5. Auth Options

### Built-in Auth

| Method | Details |
|--------|---------|
| JWT Bearer | HS256/RS256 tokens, configurable expiry, JTI for revocation |
| Basic Auth | Disabled by default (`API_ALLOW_BASIC_AUTH=false`) |
| Custom Headers | `X-Upstream-Authorization` for legacy APIs |

### SSO / OAuth Login to Gateway

Supports GitHub, Google, Okta, Keycloak, Microsoft Entra ID for user login to the gateway admin UI.

### OAuth 2.0 for Upstream Backends

ContextForge can authenticate to upstream MCP servers using OAuth:
- **Client Credentials** flow (machine-to-machine)
- **Authorization Code** flow with PKCE (user-delegated)
- Tokens stored per-gateway + per-user, encrypted at rest
- Auto-refresh using refresh tokens

### Can It Do OAuth 2.1 for Claude.ai?

**Partially.** ContextForge implements:
- OAuth 2.0 Dynamic Client Registration (RFC 7591)
- PKCE (RFC 7636) automatically for all Authorization Code flows
- Standard OAuth 2.0 Authorization Code flow

The gateway exposes `/oauth/callback` as the redirect URI. However, **the MCP spec requires OAuth endpoints at the server's domain root** (`/.well-known/oauth-authorization-server`, `/authorize`, `/token`, `/register`). ContextForge's OAuth is designed for the gateway authenticating TO upstream backends, not for the gateway BEING an OAuth provider for Claude.ai.

**To use with Claude.ai Remote MCP**, you would need:
- ContextForge to serve as the MCP endpoint (it does this via `/servers/UUID/mcp`)
- Claude.ai authenticates to ContextForge using JWT Bearer tokens (via `mcpgateway.wrapper` or direct HTTP)
- For OAuth 2.1 from Claude.ai web client, you'd still need a custom OAuth layer or proxy in front

**Key env vars for auth:**
```bash
JWT_SECRET_KEY=your-secret-key
AUTH_REQUIRED=true
AUTH_ENCRYPTION_SECRET=your-encryption-key
PLATFORM_ADMIN_EMAIL=admin@example.com
PLATFORM_ADMIN_PASSWORD=changeme
REQUIRE_JTI=true
REQUIRE_TOKEN_EXPIRATION=true
PUBLIC_REGISTRATION_ENABLED=false
```

---

## 6. Minimum Viable Deployment

### Option A: SQLite + No Redis (Simplest, BUT Being Deprecated)

SQLite is still supported as of 1.0.0-RC-2 but there is an open issue (#2612) to deprecate it and require PostgreSQL 18+. The deprecation has NOT happened yet.

```bash
# Minimal Cloud Run deploy with SQLite (ephemeral - data lost on restart)
gcloud run deploy contextforge \
  --image=ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2 \
  --region=asia-southeast1 \
  --platform=managed \
  --allow-unauthenticated \
  --port=4444 \
  --cpu=1 \
  --memory=512Mi \
  --max-instances=1 \
  --min-instances=1 \
  --no-cpu-throttling \
  --set-env-vars="\
JWT_SECRET_KEY=your-secret,\
BASIC_AUTH_PASSWORD=changeme,\
AUTH_REQUIRED=true,\
HOST=0.0.0.0,\
GUNICORN_WORKERS=1,\
MCPGATEWAY_UI_ENABLED=true,\
MCPGATEWAY_ADMIN_API_ENABLED=true,\
PLATFORM_ADMIN_EMAIL=admin@example.com,\
PLATFORM_ADMIN_PASSWORD=changeme,\
CACHE_TYPE=database,\
SSRF_ALLOW_LOCALHOST=true,\
SSRF_ALLOW_PRIVATE_NETWORKS=true"
```

**Problem:** SQLite in Cloud Run is ephemeral. Every new instance starts fresh. For persistence, you need Cloud SQL.

### Option B: Cloud SQL PostgreSQL (Production Minimum)

```bash
# 1. Create Cloud SQL instance
gcloud sql instances create mcpgw-db \
  --database-version=POSTGRES_17 \
  --edition=ENTERPRISE \
  --tier=db-f1-micro \
  --region=asia-southeast1

# 2. Set password
gcloud sql users set-password postgres \
  --instance=mcpgw-db \
  --password=mysecretpassword

# 3. Deploy
gcloud run deploy contextforge \
  --image=ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2 \
  --region=asia-southeast1 \
  --platform=managed \
  --allow-unauthenticated \
  --port=4444 \
  --cpu=1 \
  --memory=512Mi \
  --max-instances=1 \
  --min-instances=1 \
  --no-cpu-throttling \
  --set-env-vars="\
JWT_SECRET_KEY=your-secret,\
BASIC_AUTH_PASSWORD=changeme,\
AUTH_REQUIRED=true,\
DATABASE_URL=postgresql+psycopg://postgres:mysecretpassword@<SQL_IP>:5432/mcp,\
HOST=0.0.0.0,\
GUNICORN_WORKERS=1,\
MCPGATEWAY_UI_ENABLED=true,\
MCPGATEWAY_ADMIN_API_ENABLED=true,\
PLATFORM_ADMIN_EMAIL=admin@example.com,\
PLATFORM_ADMIN_PASSWORD=changeme,\
CACHE_TYPE=database"
```

**Cost estimate (asia-southeast1):**
- Cloud Run (1 CPU, 512Mi, min-instances=1): ~$15-25/mo
- Cloud SQL db-f1-micro: ~$8-12/mo
- **Total: ~$23-37/mo** (no Redis)

### Option C: With Redis (Multi-worker/Federated)

Add Memorystore Redis for distributed caching:
```bash
gcloud redis instances create mcpgw-redis \
  --region=asia-southeast1 \
  --tier=BASIC \
  --size=1

# Add to deploy:
# REDIS_URL=redis://<REDIS_IP>:6379/0
# CACHE_TYPE=redis
```

**Additional cost:** ~$30-50/mo for Memorystore Basic

---

## 7. Scale-to-Zero Considerations

**Problem:** ContextForge has cold start issues on Cloud Run.

- The Python app + Gunicorn startup takes time
- Database migrations (Alembic) run on first start
- If using Cloud SQL, connection establishment adds latency

**Recommendations:**
- Use `--min-instances=1` to avoid cold starts ($15-25/mo baseline)
- If you must scale to zero, expect 10-30s cold starts
- `--no-cpu-throttling` is REQUIRED because:
  - `mcpgateway.translate` spawns stdio subprocesses
  - Background health checks need CPU
  - SSE keepalive needs continuous CPU

**Official Cloud Run deploy from their docs:**
```bash
gcloud run deploy mcpgateway \
  --image=us-central1-docker.pkg.dev/$PROJECT_ID/ghcr-remote/ibm/mcp-context-forge:latest \
  --region=us-central1 \
  --platform=managed \
  --allow-unauthenticated \
  --port=4444 \
  --cpu=1 \
  --memory=512Mi \
  --max-instances=1 \
  --set-env-vars=JWT_SECRET_KEY=jwt-secret-key,BASIC_AUTH_USER=admin,BASIC_AUTH_PASSWORD=changeme,AUTH_REQUIRED=true,DATABASE_URL=postgresql+psycopg://postgres:mysecretpassword@<SQL_IP>:5432/mcpgw,REDIS_URL=redis://<REDIS_IP>:6379/0,CACHE_TYPE=redis,HOST=0.0.0.0,GUNICORN_WORKERS=1
```

**Note:** Their official docs reference pulling through Artifact Registry remote repo since "Cloud Run only accepts container images in Artifact Registry."

---

## 8. Environment Variables Reference

### Required (Must Set)

| Variable | Default | Purpose |
|----------|---------|---------|
| `JWT_SECRET_KEY` | `my-test-key` | JWT signing secret. CHANGE IN PRODUCTION |
| `BASIC_AUTH_PASSWORD` | `changeme` | Admin UI password. CHANGE IN PRODUCTION |
| `AUTH_ENCRYPTION_SECRET` | `my-test-salt` | Encrypts stored OAuth secrets |
| `PLATFORM_ADMIN_EMAIL` | `admin@example.com` | Bootstrap admin email |
| `PLATFORM_ADMIN_PASSWORD` | `changeme` | Bootstrap admin password |
| `HOST` | `127.0.0.1` | Must be `0.0.0.0` for containers |

### Database & Cache

| Variable | Default | Purpose |
|----------|---------|---------|
| `DATABASE_URL` | `sqlite:///./mcp.db` | DB connection string |
| `CACHE_TYPE` | `database` | `database`, `memory`, or `redis` |
| `REDIS_URL` | (none) | Redis URL when `CACHE_TYPE=redis` |
| `GUNICORN_WORKERS` | (auto) | Set to `1` for Cloud Run |
| `DB_POOL_SIZE` | `200` | Connection pool size |

### Feature Toggles

| Variable | Default | Purpose |
|----------|---------|---------|
| `MCPGATEWAY_UI_ENABLED` | `false` | Admin web UI |
| `MCPGATEWAY_ADMIN_API_ENABLED` | `false` | REST admin API |
| `AUTH_REQUIRED` | `false` | Enforce authentication |
| `TRANSPORT_TYPE` | `all` | `sse`, `streamablehttp`, `http`, or `all` |
| `HTTP_SERVER` | `gunicorn` | `gunicorn` or `granian` |
| `SSRF_PROTECTION_ENABLED` | `true` | SSRF protection |
| `SSRF_ALLOW_LOCALHOST` | `false` | Allow localhost in URLs |
| `SSRF_ALLOW_PRIVATE_NETWORKS` | `false` | Allow private IPs |

### Port & Networking

| Variable | Default | Purpose |
|----------|---------|---------|
| `PORT` | `4444` | HTTP server port |
| `APP_DOMAIN` | `http://localhost` | CORS/cookies domain |

---

## 9. Tool Aggregation

Yes, ContextForge aggregates tools from multiple backends into one endpoint. Here's how:

### Step 1: Register Multiple Backends

```bash
# Backend 1: Apollo (Shopify GraphQL)
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"apollo-shopify","url":"http://apollo:3000/sse"}' \
  http://localhost:4444/gateways

# Backend 2: Shopify Dev MCP (via translate)
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"shopify-dev","url":"http://localhost:8003/sse"}' \
  http://localhost:4444/gateways

# Backend 3: Google Sheets MCP (via translate)
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"google-sheets","url":"http://localhost:8004/sse"}' \
  http://localhost:4444/gateways
```

### Step 2: Tools Auto-Discovered

```bash
# List all tools across all backends
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:4444/tools | jq '.[].name'
```

### Step 3: Create Virtual Servers (Optional - Bundle Subsets)

```bash
# Create a virtual server that bundles specific tools
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "server": {
      "name": "shopify-all",
      "description": "All Shopify tools (GraphQL + Dev Knowledge)",
      "associated_tools": ["tool-uuid-1", "tool-uuid-2", "tool-uuid-3"]
    }
  }' \
  http://localhost:4444/servers | jq
```

### Step 4: Connect Clients

```bash
# Claude Desktop / Claude Code config
{
  "mcpServers": {
    "fluid-intelligence": {
      "command": "python3",
      "args": ["-m", "mcpgateway.wrapper"],
      "env": {
        "MCP_AUTH": "Bearer your-token-here",
        "MCP_SERVER_URL": "http://your-cloud-run-url:4444/servers/UUID/mcp",
        "MCP_TOOL_CALL_TIMEOUT": "120"
      }
    }
  }
}
```

Or via direct HTTP (no wrapper needed):
```
# SSE endpoint
http://your-cloud-run-url/servers/UUID/sse

# Streamable HTTP endpoint
http://your-cloud-run-url/servers/UUID/mcp
```

---

## 10. Comparison with Current POC Stack

| Aspect | Current POC | ContextForge |
|--------|-------------|--------------|
| Language | Node.js + Rust + Bash | Python (FastAPI) |
| Config format | YAML + env vars | Env vars only |
| Adding backends | Edit YAML, rebuild | API call (hot-reload) |
| Auth | Custom OAuth server | Built-in JWT + OAuth |
| Tool aggregation | Not supported | Built-in virtual servers |
| Admin UI | None | HTMX/Alpine.js web UI |
| Database | None (stateless) | SQLite/PostgreSQL/MariaDB |
| Monitoring | None | OpenTelemetry, Prometheus |
| RBAC | None | Teams, roles, permissions |
| Container size | ~150MB (Rust binary) | ~500MB+ (Python + deps) |
| Cold start | ~2s | ~10-30s |
| Memory | ~50-100MB | ~512MB minimum |

---

## 11. Critical Gotchas for Cloud Run

1. **SSRF Protection blocks localhost by default.** If translate runs in the same container, you MUST set `SSRF_ALLOW_LOCALHOST=true` and `SSRF_ALLOW_PRIVATE_NETWORKS=true`.

2. **Cloud Run requires Artifact Registry.** Cannot pull directly from GHCR. Must set up a remote repository:
   ```bash
   gcloud artifacts repositories create ghcr-remote \
     --repository-format=docker \
     --location=asia-southeast1 \
     --remote-docker-repo=https://ghcr.io
   ```

3. **`--no-cpu-throttling` is essential** for stdio subprocesses and SSE keepalive.

4. **SQLite is ephemeral on Cloud Run.** Data lost on every new instance. Use Cloud SQL for persistence.

5. **SQLite deprecation is coming** (Issue #2612). Plan for PostgreSQL from the start.

6. **GUNICORN_WORKERS must be 1** on Cloud Run with 1 CPU. Multiple workers on 1 CPU cause contention.

7. **Translate processes need management.** In a Cloud Run container, you'd need a supervisor (like the current POC's entrypoint.sh) to run both the gateway and translate processes.

8. **Memory: 512Mi minimum.** Gunicorn uses ~2.7GB at load; for low-traffic 512Mi works.

---

## 12. Proposed Cloud Run Architecture for Fluid Intelligence

```
Cloud Run Container (--no-cpu-throttling)
├── Supervisor (entrypoint.sh)
│   ├── mcpgateway (port 4444, Gunicorn + Uvicorn)
│   ├── mcpgateway.translate --stdio "apollo-mcp-server" --port 8001
│   ├── mcpgateway.translate --stdio "npx @shopify/dev-mcp" --port 8002
│   └── (optional) mcpgateway.translate --stdio "sheets-mcp" --port 8003
│
├── On startup: register backends via /gateways API
│
└── Cloud SQL PostgreSQL (external, persistent)
```

**Client access:**
- Claude Code: `mcpgateway.wrapper` → Cloud Run URL `/servers/UUID/mcp`
- Claude.ai: Needs OAuth proxy (same challenge as current POC)
- Direct HTTP: Bearer token → Cloud Run URL `/servers/UUID/mcp`

---

## Sources

- [ContextForge Official Docs](https://ibm.github.io/mcp-context-forge/)
- [Cloud Run Deployment Guide](https://ibm.github.io/mcp-context-forge/deployment/google-cloud-run/)
- [GitHub Repository](https://github.com/IBM/mcp-context-forge)
- [Architecture Overview](https://ibm.github.io/mcp-context-forge/architecture/)
- [OAuth 2.0 Integration](https://ibm.github.io/mcp-context-forge/manage/oauth/)
- [Quick Start Guide](https://ibm.github.io/mcp-context-forge/overview/quick_start/)
- [SQLite Deprecation Issue #2612](https://github.com/ibm/mcp-context-forge/issues/2612)
- [MCP Inspector Client Docs](https://ibm.github.io/mcp-context-forge/using/clients/mcp-inspector/)
