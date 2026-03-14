# Fluid Intelligence v3 — ContextForge + mcp-auth-proxy Design Spec

> **Product**: Fluid Intelligence — Universal MCP Gateway
> **Date**: 2026-03-14 | **Revised**: 2026-03-14 (6 deep iterations, source-verified)
> **Status**: APPROVED
> **Supersedes**: v2 spec (custom gateway design), POC (nginx + bash supervisor + custom OAuth)
> **Strategy**: Compose best-in-class open-source tools. Don't build from scratch.
> **First vertical**: Shopify (junlinleather-5148). Architecture supports any API backend.

---

## Vision

One endpoint for AI clients (Claude, Codex, Cursor) to access any API — with identity, observability, and role-based access. Shopify is the first vertical, not the last.

```
Any AI Client → Fluid Intelligence → Any API
                     │
                     ├── Shopify GraphQL (Apollo MCP)
                     ├── Shopify Docs (dev-mcp)
                     ├── Google Workspace (future P0)
                     ├── Slack notifications (future P1)
                     ├── Xero accounting (future P1)
                     └── Any MCP server (config-driven)
```

---

## Strategy: Compose, Don't Build

93+ MCP gateways evaluated. 20+ deep-evaluated. Decision: compose existing tools.

| Layer | Tool | Version | Stars | License | Backing |
|---|---|---|---|---|---|
| **OAuth** | mcp-auth-proxy | v2.5.4 | 74 | MIT | Open source (Go) |
| **Gateway** | IBM ContextForge | 1.0.0-RC-2 | 3,300 | Apache 2.0 | IBM, 100+ contributors |
| **Shopify ops** | Apollo MCP Server | v1.9.0 | — | MIT | Anthropic |
| **Shopify docs** | @shopify/dev-mcp | latest | — | — | Shopify |
| **Google Sheets** | xing5/mcp-google-sheets | latest | 737 | MIT | Open source (Python) |
| **Database** | Cloud SQL PostgreSQL | — | — | — | Google Cloud |
| **CI/CD** | Cloud Build + GitHub | — | — | — | Google Cloud |

**Why these tools:**

- **mcp-auth-proxy** (v2.5.4): OAuth 2.1 proxy with BoltDB persistence, DCR, PKCE, RSA JWT. Supports Google/GitHub/OIDC login with per-user allowlists. ~5MB Go binary.
- **ContextForge** (1.0.0-RC-2): Only IBM-backed gateway. OpenTelemetry built-in. RBAC for when team grows. `mcpgateway.translate` for stdio→HTTP bridging. Cloud SQL PostgreSQL for persistent state.
- **Apollo MCP**: Proven Rust binary. Handles Shopify GraphQL with persisted mutations.
- **dev-mcp**: Official Shopify MCP server. Docs, schema introspection, code validation.
- **mcp-google-sheets**: Google Sheets MCP server. Service account auth via base64 env var (headless-friendly). 17 focused tools.
- **Cloud SQL PostgreSQL**: Persistent database (db-f1-micro, ~$8/mo). Eliminates ephemeral SQLite, enables multi-instance scaling.

**What we build**: ~150 lines (Dockerfile + entrypoint + cloudbuild configs). Everything else is config.

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│          Claude.ai / Claude Code / Cursor         │
└────────────────────────┬────────────────────────┘
                         │ HTTPS + OAuth 2.1
                         ▼
┌─────────────────────────────────────────────────┐
│              Cloud Run Container                 │
│              junlinleather.com                   │
│                                                  │
│  ┌────────────────────────────────────────────┐ │
│  │  mcp-auth-proxy (Go)            :8080      │ │
│  │  OAuth 2.1 — DCR, PKCE, RSA JWT           │ │
│  │  Google OAuth primary + password fallback  │ │
│  │  BoltDB persistence (./data/db)           │ │
│  │  Reverse proxy → ContextForge :4444       │ │
│  └──────────────────┬─────────────────────────┘ │
│                     │ authenticated               │
│  ┌──────────────────▼─────────────────────────┐ │
│  │  IBM ContextForge (Python)      :4444      │ │
│  │  Tool registry, routing, OpenTelemetry     │ │
│  │  RBAC, Cloud SQL PostgreSQL (persistent)   │ │
│  └────┬──────────┬──────────┬─────────────────┘ │
│       │          │          │                    │
│  ┌────▼────┐ ┌───▼────┐ ┌──▼───────────────┐   │
│  │ Apollo  │ │ dev-mcp│ │ google-sheets    │   │
│  │ (Rust)  │ │ bridge │ │ bridge           │   │
│  │ :8000   │ │ :8003  │ │ :8004            │   │
│  │ Shopify │ │ stdio  │ │ stdio            │   │
│  │ GraphQL │ │ →SSE   │ │ →SSE             │   │
│  └─────────┘ └────────┘ └──────────────────┘   │
│                                                  │
│  Cloud SQL PostgreSQL (persistent backends)      │
│  --no-cpu-throttling  min:0  max:3               │
│                                                  │
│  Bootstrap on startup:                           │
│  1. Wait for ContextForge /healthz               │
│  2. Register Apollo at localhost:8000/mcp        │
│  3. Register dev-mcp at localhost:8003/sse       │
│  4. Register google-sheets at localhost:8004/sse │
└──────────────────────────────────────────────────┘
```

**6 processes** in the container:
1. **mcp-auth-proxy** (Go) — OAuth 2.1 front door, port 8080, Google OAuth primary + password fallback, BoltDB at `./data/db`
2. **ContextForge** (Python/Gunicorn) — gateway, port 4444, started via `mcpgateway` CLI, Cloud SQL PostgreSQL
3. **Apollo MCP** (Rust) — Shopify GraphQL, port 8000, Streamable HTTP at `/mcp`
4. **mcpgateway.translate #1** (Python) — wraps dev-mcp stdio → HTTP, port 8003, health at `/healthz`
5. **mcpgateway.translate #2** (Python) — wraps mcp-google-sheets stdio → HTTP, port 8004, health at `/healthz`
6. **bootstrap.sh** — registers backends with ContextForge on startup (runs once, exits)

**Database: Cloud SQL PostgreSQL.** Backend registrations persist across restarts. Bootstrap script still runs on cold start to ensure consistency (idempotent upserts), but the database is durable. This also enables `max-instances > 1`.

**Auth: Google OAuth primary.** Users log in via Google account. `--google-allowed-users` controls who can access. Password kept as CLI/API fallback. Individual users can be revoked by removing their email.

**Scaling: max-instances=3.** PostgreSQL enables multi-instance. BoltDB (mcp-auth-proxy) is still single-process per instance, but each instance has its own BoltDB — DCR state may diverge across instances. For the current scale (1-5 users), this is acceptable. To fully share OAuth state, migrate to `--repository-backend postgres` later.

### Modularity — every layer is independently swappable

| Layer | Current | Future options |
|---|---|---|
| **OAuth** | mcp-auth-proxy (Google OAuth) | Casdoor, any OIDC provider |
| **Gateway** | IBM ContextForge | MetaMCP, 1MCP, custom |
| **Database** | Cloud SQL PostgreSQL | Neon, AlloyDB, any PostgreSQL |
| **Backends** | Apollo + dev-mcp + google-sheets | Any MCP server via bootstrap.sh |
| **CI/CD** | Cloud Build | GitHub Actions, any CI |

---

## Request Flow

### First Connection — OAuth Handshake

1. **Claude.ai** → `GET /.well-known/oauth-authorization-server` → discovers OAuth metadata
2. **Claude.ai** → `POST /.idp/register` → Dynamic Client Registration → receives `client_id`
3. **Claude.ai** → `GET /.idp/auth?client_id=...&code_challenge=...` → redirects to login
4. **mcp-auth-proxy** → shows login at `/.auth/login` → user clicks "Sign in with Google" (or enters password for CLI) → Google OAuth callback at `/.auth/google/callback` → issues auth code → redirects back
5. **Claude.ai** → `POST /.idp/token` → exchanges code for RSA JWT access token (PKCE verified)

**Note**: OAuth endpoints are at `/.idp/*` and `/.auth/*` prefixes (not root `/authorize`, `/token`). The `/.well-known/` discovery endpoints are at their standard RFC 8414 locations. Claude.ai discovers the correct paths via the metadata endpoint.

### Tool Call — e.g. "Create a draft order"

6. **Claude.ai** → `POST /` with `Authorization: Bearer <RSA-JWT>` and `tools/call` JSON-RPC
7. **mcp-auth-proxy** (:8080) → validates RSA JWT → strips auth header → reverse-proxies to `:4444`
8. **ContextForge** (:4444) → looks up tool in registry → routes to Apollo (:8000) → logs OpenTelemetry trace
9. **Apollo** (:8000) → executes Shopify GraphQL mutation → returns result
10. **Response** flows back: Apollo → ContextForge → mcp-auth-proxy → Claude.ai

### Error Handling

| Scenario | Behavior |
|---|---|
| Token expired (24h lifetime) | mcp-auth-proxy returns 401, Claude.ai auto-refreshes via refresh token (30d) |
| Backend down | ContextForge returns MCP error, other backends still work |
| Shopify rate limit | Apollo returns error with retry hint |
| Unknown tool | ContextForge returns MethodNotFound |

### Latency (warm instance)

| Layer | Time |
|---|---|
| OAuth proxy | ~5ms |
| ContextForge routing | ~20ms |
| Apollo + Shopify API | ~200-500ms |
| **Total** | **~225-525ms** |

Cold start adds ~30-45s (Python + Rust init + npx download + bootstrap registration). Mitigated by `--cpu-boost`. First-ever cold start is slower (npx caches dev-mcp after first download).

---

## CI/CD — GitHub-Triggered Cloud Build

No manual deployments. Push to GitHub → Cloud Build → Cloud Run.

### Setup (one-time)

```bash
# 1. Enable APIs
gcloud services enable cloudbuild.googleapis.com \
  artifactregistry.googleapis.com run.googleapis.com \
  developerconnect.googleapis.com secretmanager.googleapis.com \
  sqladmin.googleapis.com \
  --project=junlinleather-mcp

# 2. Create GitHub connection (opens browser for authorization)
gcloud developer-connect connections create fluid-intelligence-github \
  --location=asia-southeast1 --project=junlinleather-mcp

# 3. Link repository
gcloud developer-connect connections git-repository-links create fluid-intelligence-repo \
  --connection=fluid-intelligence-github \
  --clone-uri=https://github.com/junlin3012/fluid-intelligence.git \
  --location=asia-southeast1 --project=junlinleather-mcp

# 4. Grant Cloud Build SA permissions
CB_SA="1056128102929@cloudbuild.gserviceaccount.com"
for role in roles/run.admin roles/iam.serviceAccountUser \
  roles/artifactregistry.writer roles/secretmanager.secretAccessor; do
  gcloud projects add-iam-policy-binding junlinleather-mcp \
    --member="serviceAccount:${CB_SA}" --role="$role"
done

# 5. Create deploy trigger (push to main)
gcloud builds triggers create developer-connect \
  --name=deploy-fluid-intelligence \
  --git-repository-link=projects/junlinleather-mcp/locations/asia-southeast1/connections/fluid-intelligence-github/gitRepositoryLinks/fluid-intelligence-repo \
  --branch-pattern="^main$" --build-config=cloudbuild.yaml \
  --region=asia-southeast1 --project=junlinleather-mcp

# 6. Create base image trigger (only on Dockerfile.base changes)
gcloud builds triggers create developer-connect \
  --name=build-base-image \
  --git-repository-link=projects/junlinleather-mcp/locations/asia-southeast1/connections/fluid-intelligence-github/gitRepositoryLinks/fluid-intelligence-repo \
  --branch-pattern="^main$" --build-config=cloudbuild-base.yaml \
  --included-files="Dockerfile.base" \
  --region=asia-southeast1 --project=junlinleather-mcp
```

### cloudbuild.yaml

```yaml
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', '${_IMAGE}', '.']

  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', '${_IMAGE}']

  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    entrypoint: gcloud
    args:
      - 'run'
      - 'deploy'
      - 'fluid-intelligence'
      - '--image=${_IMAGE}'
      - '--region=asia-southeast1'
      - '--no-cpu-throttling'
      - '--cpu-boost'
      - '--min-instances=0'
      - '--max-instances=3'
      - '--memory=512Mi'
      - '--cpu=1'
      - '--add-cloudsql-instances=junlinleather-mcp:asia-southeast1:contextforge'
      - '--set-secrets=SHOPIFY_ACCESS_TOKEN=shopify-access-token:latest,AUTH_PASSWORD=mcp-auth-passphrase:latest,JWT_PRIVATE_KEY=mcp-jwt-private-key:latest,AUTH_HMAC_SECRET=mcp-auth-hmac-secret:latest,JWT_SECRET_KEY=mcp-jwt-secret:latest,GOOGLE_OAUTH_CLIENT_ID=google-oauth-client-id:latest,GOOGLE_OAUTH_CLIENT_SECRET=google-oauth-client-secret:latest,CREDENTIALS_CONFIG=google-sheets-credentials:latest,DB_PASSWORD=db-password:latest'
      - '--set-env-vars=SHOPIFY_STORE=junlinleather-5148.myshopify.com,SHOPIFY_API_VERSION=2026-01,PLATFORM_ADMIN_EMAIL=admin@junlinleather.com,EXTERNAL_URL=junlinleather.com,GOOGLE_ALLOWED_USERS=ourteam@junlinleather.com,DB_USER=contextforge,DB_NAME=contextforge,HOST=0.0.0.0,PORT=4444,GUNICORN_WORKERS=1,HTTP_SERVER=gunicorn,MCPGATEWAY_UI_ENABLED=false,MCPGATEWAY_ADMIN_API_ENABLED=true,TRANSPORT_TYPE=all,SSRF_PROTECTION_ENABLED=true,SSRF_ALLOW_LOCALHOST=true,SSRF_ALLOW_PRIVATE_NETWORKS=true,AUTH_REQUIRED=true,CACHE_TYPE=database'
      - '--allow-unauthenticated'

substitutions:
  _IMAGE: 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence:${SHORT_SHA}'

images:
  - '${_IMAGE}'
```

### cloudbuild-base.yaml

```yaml
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args:
      - 'build'
      - '-f'
      - 'Dockerfile.base'
      - '-t'
      - 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence-base:latest'
      - '.'
  - name: 'gcr.io/cloud-builders/docker'
    args:
      - 'push'
      - 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence-base:latest'
images:
  - 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence-base:latest'
timeout: '1800s'
```

---

## Container Design

### Dockerfile

ContextForge runs in a Python 3.12 venv at `/app/.venv` with `PATH` including venv bin. Solution: **use ContextForge's image as the runtime base**, preserving the venv. Install Node.js and copy binaries into it.

```dockerfile
# Stage 1: Apollo pre-compiled (from base image, rebuilt rarely)
FROM asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence-base:latest AS apollo-base

# Stage 2: mcp-auth-proxy binary (v2.5.4)
FROM alpine:3.20 AS authproxy
ADD https://github.com/sigbit/mcp-auth-proxy/releases/download/v2.5.4/mcp-auth-proxy-linux-amd64 /mcp-auth-proxy
RUN chmod +x /mcp-auth-proxy

# Stage 3: Runtime — based on ContextForge (Red Hat UBI 10 Minimal)
# Preserves Python 3.12 venv at /app/.venv with PATH already set
FROM ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2

USER root

# Install Node.js (for dev-mcp via npx), curl (for health checks)
RUN microdnf install -y nodejs npm curl && microdnf clean all

# Install uv (for mcp-google-sheets via uvx)
RUN pip install uv

# tini (PID 1 init — not in UBI repos)
ADD https://github.com/krallin/tini/releases/download/v0.19.0/tini-amd64 /usr/local/bin/tini
RUN chmod +x /usr/local/bin/tini

# Copy Apollo binary
COPY --from=apollo-base /usr/local/bin/apollo /usr/local/bin/apollo

# Copy mcp-auth-proxy binary
COPY --from=authproxy /mcp-auth-proxy /usr/local/bin/mcp-auth-proxy

# Copy config and scripts
COPY entrypoint.sh /app/entrypoint.sh
COPY bootstrap.sh /app/bootstrap.sh
COPY mcp-config.yaml /app/mcp-config.yaml
COPY graphql/ /app/graphql/

# Create data directory for mcp-auth-proxy BoltDB
RUN mkdir -p /app/data && chown -R 1001:0 /app/data

RUN chmod +x /app/entrypoint.sh /app/bootstrap.sh

USER 1001
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/tini", "--"]
CMD ["/app/entrypoint.sh"]
```

### entrypoint.sh (source-verified flags)

```bash
#!/bin/bash
set -euo pipefail

echo "[fluid-intelligence] Starting services..."

# Construct DATABASE_URL for ContextForge (Cloud SQL PostgreSQL via Unix socket)
export DATABASE_URL="postgresql://${DB_USER:-contextforge}:${DB_PASSWORD}@/${DB_NAME:-contextforge}?host=/cloudsql/junlinleather-mcp:asia-southeast1:contextforge"
export AUTH_ENCRYPTION_SECRET="${JWT_SECRET_KEY}"
export PLATFORM_ADMIN_PASSWORD="${AUTH_PASSWORD}"

# 1. Apollo MCP Server (Rust, Shopify GraphQL, Streamable HTTP)
apollo --config /app/mcp-config.yaml &
APOLLO_PID=$!

# 2. IBM ContextForge (Python, gateway)
# Start via `mcpgateway` CLI (console_scripts entry point, NOT python -m)
mcpgateway &
CONTEXTFORGE_PID=$!

# 3. mcpgateway.translate #1 (stdio→HTTP bridge for dev-mcp)
python3 -m mcpgateway.translate \
  --stdio "npx -y @shopify/dev-mcp@latest" \
  --expose-sse \
  --port 8003 &
TRANSLATE_DEVMCP_PID=$!

# 4. mcpgateway.translate #2 (stdio→HTTP bridge for google-sheets)
python3 -m mcpgateway.translate \
  --stdio "uvx mcp-google-sheets@latest --transport stdio" \
  --expose-sse \
  --port 8004 &
TRANSLATE_SHEETS_PID=$!

# 5. mcp-auth-proxy (Go, OAuth 2.1 front door)
# Verified flags from v2.5.4 source:
#   --listen            = bind address (default :80)
#   --external-url      = public-facing URL (required)
#   --password          = login password for CLI/API fallback
#   --google-client-id  = Google OAuth client ID
#   --google-client-secret = Google OAuth client secret
#   --google-allowed-users = comma-separated email allowlist
#   --no-auto-tls       = disable ACME (Cloud Run terminates TLS)
#   --data-path         = BoltDB storage directory
#   Positional arg after -- = upstream URL (reverse proxy mode)
mcp-auth-proxy \
  --listen :8080 \
  --external-url "https://${EXTERNAL_URL:-junlinleather.com}" \
  --google-client-id "$GOOGLE_OAUTH_CLIENT_ID" \
  --google-client-secret "$GOOGLE_OAUTH_CLIENT_SECRET" \
  --google-allowed-users "${GOOGLE_ALLOWED_USERS:-ourteam@junlinleather.com}" \
  --password "$AUTH_PASSWORD" \
  --no-auto-tls \
  --data-path /app/data \
  -- http://localhost:4444 &
AUTHPROXY_PID=$!

# 6. Bootstrap: register backends with ContextForge (runs once)
/app/bootstrap.sh &

echo "[fluid-intelligence] All services started"
echo "  Apollo MCP:       PID=$APOLLO_PID  port=8000  (Streamable HTTP at /mcp)"
echo "  ContextForge:     PID=$CONTEXTFORGE_PID  port=4444"
echo "  dev-mcp bridge:   PID=$TRANSLATE_DEVMCP_PID  port=8003  (SSE at /sse)"
echo "  sheets bridge:    PID=$TRANSLATE_SHEETS_PID  port=8004  (SSE at /sse)"
echo "  mcp-auth-proxy:   PID=$AUTHPROXY_PID  port=8080"

# Exit if any long-running process dies → Cloud Run restarts container
wait -n $APOLLO_PID $CONTEXTFORGE_PID $TRANSLATE_DEVMCP_PID $TRANSLATE_SHEETS_PID $AUTHPROXY_PID
echo "[fluid-intelligence] A process exited, shutting down"
kill $APOLLO_PID $CONTEXTFORGE_PID $TRANSLATE_DEVMCP_PID $TRANSLATE_SHEETS_PID $AUTHPROXY_PID 2>/dev/null || true
exit 1
```

### bootstrap.sh (source-verified endpoints)

Registers backends with ContextForge on cold start. With PostgreSQL, registrations persist across restarts, but the bootstrap runs idempotently to ensure consistency.

```bash
#!/bin/bash
set -euo pipefail

echo "[bootstrap] Waiting for ContextForge to be healthy..."
MAX_WAIT=60; WAITED=0
until curl -sf http://localhost:4444/healthz > /dev/null 2>&1; do
  WAITED=$((WAITED + 1))
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "[bootstrap] FATAL: ContextForge not healthy after ${MAX_WAIT}s"
    exit 1
  fi
  sleep 1
done
echo "[bootstrap] ContextForge is healthy"

# Generate admin JWT token for backend registration
TOKEN=$(python3 -m mcpgateway.utils.create_jwt_token \
  --username "$PLATFORM_ADMIN_EMAIL" \
  --exp 10080 \
  --secret "$JWT_SECRET_KEY")

echo "[bootstrap] Registering Apollo MCP (Shopify GraphQL)..."
curl -sf -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"apollo-shopify","url":"http://localhost:8000/mcp","transport":"STREAMABLEHTTP"}' \
  http://localhost:4444/gateways

echo "[bootstrap] Waiting for dev-mcp bridge..."
MAX_WAIT=90; WAITED=0
until curl -sf --connect-timeout 2 --max-time 3 http://localhost:8003/healthz > /dev/null 2>&1; do
  WAITED=$((WAITED + 1))
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "[bootstrap] FATAL: dev-mcp bridge not ready after ${MAX_WAIT}s"
    exit 1
  fi
  sleep 1
done

echo "[bootstrap] Registering dev-mcp (Shopify docs)..."
curl -sf -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"shopify-dev-mcp","url":"http://localhost:8003/sse","transport":"SSE"}' \
  http://localhost:4444/gateways

echo "[bootstrap] Waiting for google-sheets bridge..."
MAX_WAIT=60; WAITED=0
until curl -sf --connect-timeout 2 --max-time 3 http://localhost:8004/healthz > /dev/null 2>&1; do
  WAITED=$((WAITED + 1))
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "[bootstrap] FATAL: google-sheets bridge not ready after ${MAX_WAIT}s"
    exit 1
  fi
  sleep 1
done

echo "[bootstrap] Registering google-sheets..."
curl -sf -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"google-sheets","url":"http://localhost:8004/sse","transport":"SSE"}' \
  http://localhost:4444/gateways

echo "[bootstrap] All backends registered"
```

### contextforge.env

Required ContextForge environment variables (verified against .env.example):

```bash
# Auth
JWT_SECRET_KEY=${JWT_SECRET_KEY}
AUTH_REQUIRED=true
AUTH_ENCRYPTION_SECRET=${JWT_SECRET_KEY}
PLATFORM_ADMIN_EMAIL=admin@junlinleather.com
PLATFORM_ADMIN_PASSWORD=${AUTH_PASSWORD}

# Database (Cloud SQL PostgreSQL — persistent across restarts)
DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@/${DB_NAME}?host=/cloudsql/junlinleather-mcp:asia-southeast1:contextforge
CACHE_TYPE=database

# Server
HOST=0.0.0.0
PORT=4444
GUNICORN_WORKERS=1
HTTP_SERVER=gunicorn

# Features
MCPGATEWAY_UI_ENABLED=false
MCPGATEWAY_ADMIN_API_ENABLED=true
TRANSPORT_TYPE=all

# SSRF — MUST allow localhost for same-container backends
SSRF_PROTECTION_ENABLED=true
SSRF_ALLOW_LOCALHOST=true
SSRF_ALLOW_PRIVATE_NETWORKS=true
```

---

## Repo Structure

```
github.com/junlin3012/fluid-intelligence
├── Dockerfile                  # Multi-stage, ContextForge base (~60s build)
├── Dockerfile.base             # Apollo Rust compile (~18 min, rebuild rarely)
├── cloudbuild.yaml             # Cloud Build: auto-deploy on push to main
├── cloudbuild-base.yaml        # Cloud Build: base image on Dockerfile.base change
├── entrypoint.sh               # Process supervisor (~40 lines)
├── bootstrap.sh                # Registers backends on cold start (~35 lines)
├── mcp-config.yaml             # Apollo config (Shopify endpoint, graphql paths)
├── graphql/                    # 23 Shopify persisted mutations
│   ├── customers/
│   ├── orders/
│   ├── products/
│   ├── inventory/
│   ├── fulfillments/
│   ├── metafields/
│   └── transfers/
├── docs/
│   ├── research/               # Market research
│   ├── agent-behavior/         # Agent instructions
│   └── superpowers/specs/      # Design specs (including this file)
├── .gitignore
└── CLAUDE.md
```

**Your code: ~150 lines total** (Dockerfile + entrypoint + bootstrap + cloudbuild configs). Everything else is configuration.

---

## Migration from POC

| Carry over | Do not carry over |
|---|---|
| `graphql/` — 23 validated mutations | `oauth-server/` — replaced by mcp-auth-proxy |
| `docs/research/` — market research | `nginx.conf.template` — not needed |
| `docs/agent-behavior/` — agent instructions | `token-proxy/` — replaced by ContextForge |
| `docs/superpowers/` — design specs | Old `Dockerfile` — rewritten |
| `CLAUDE.md` — updated for new architecture | Old `deploy.sh` — replaced by Cloud Build |

**Fresh repo (`fluid-intelligence`), clean start.** Old repo (`junlin-shopify-mcp`) stays as historical reference.

---

## Environment Variables & Secrets

All secrets stored in GCP Secret Manager, injected via Cloud Run `--set-secrets`:

| Secret | Purpose | Used by |
|---|---|---|
| `shopify-access-token` | Shopify Admin API token | Apollo |
| `mcp-auth-passphrase` | CLI/API fallback login password | mcp-auth-proxy (`--password`) |
| `mcp-jwt-private-key` | RSA private key (PKCS8 PEM) for signing JWTs | mcp-auth-proxy (`JWT_PRIVATE_KEY`) |
| `mcp-auth-hmac-secret` | Base64-encoded 32-byte HMAC secret | mcp-auth-proxy (`AUTH_HMAC_SECRET`) |
| `mcp-jwt-secret` | ContextForge JWT signing key | ContextForge (`JWT_SECRET_KEY`) |
| `google-oauth-client-id` | Google OAuth client ID | mcp-auth-proxy (`--google-client-id`) |
| `google-oauth-client-secret` | Google OAuth client secret | mcp-auth-proxy (`--google-client-secret`) |
| `google-sheets-credentials` | Base64-encoded service account JSON | mcp-google-sheets (`CREDENTIALS_CONFIG`) |
| `db-password` | Cloud SQL PostgreSQL password | ContextForge (`DB_PASSWORD`) |

**Note**: mcp-auth-proxy uses RSA for JWTs (not HMAC). `JWT_PRIVATE_KEY` and `AUTH_HMAC_SECRET` env vars must be set for stateless Cloud Run deploys — otherwise keys regenerate on restart and invalidate all tokens.

**Note**: Google OAuth client must be created in GCP Console → APIs & Services → Credentials → OAuth 2.0 Client IDs. Set redirect URI to `https://junlinleather.com/.auth/google/callback`.

Non-secret config via environment variables:

| Variable | Value |
|---|---|
| `SHOPIFY_STORE` | `junlinleather-5148.myshopify.com` |
| `SHOPIFY_API_VERSION` | `2026-01` |
| `PLATFORM_ADMIN_EMAIL` | `admin@junlinleather.com` |
| `EXTERNAL_URL` | `junlinleather.com` |
| `GOOGLE_ALLOWED_USERS` | `ourteam@junlinleather.com` |
| `DB_USER` | `contextforge` |
| `DB_NAME` | `contextforge` |

See `contextforge.env` for the full ContextForge configuration.

---

## GCP Resources

| Resource | Details |
|---|---|
| **Project** | `junlinleather-mcp` (asia-southeast1) |
| **Cloud Run** | `fluid-intelligence` service |
| **Artifact Registry** | `junlin-mcp` repo (existing) |
| **Cloud Build** | 2 triggers: deploy (main push) + base image (Dockerfile.base change) |
| **Cloud SQL** | `contextforge` PostgreSQL instance (db-f1-micro, ~$8/mo) |
| **Secret Manager** | 9 secrets (see Secrets table above) |
| **Domain** | `junlinleather.com` → Cloud Run domain mapping (Google-managed SSL) |
| **Developer Connect** | GitHub connection to `junlin3012/fluid-intelligence` |

Cloud Build free tier: 2,500 min/month. At ~60s/deploy, 2-3 deploys/day = ~90-150 min/month.

---

## Cost

| Component | Monthly (scale-to-zero) | Monthly (always-on) |
|---|---|---|
| Cloud Run | MYR 0-30 | MYR 180 |
| Cloud SQL PostgreSQL (db-f1-micro) | MYR 35 | MYR 35 |
| Artifact Registry | MYR 2-5 | MYR 2-5 |
| Secret Manager | < MYR 1 | < MYR 1 |
| Cloud Build | Free (2,500 min/mo) | Free |
| Domain | Already owned | Already owned |
| **Total** | **MYR 38-71** | **MYR 218-221** |

---

## Success Criteria

1. Claude.ai connects via OAuth 2.1 (Google login at `/.auth/google/callback`) and makes tool calls
2. All 23 Shopify mutations work through the gateway
3. dev-mcp tools (docs, introspection) accessible via same endpoint
4. Google Sheets tools accessible via same endpoint
5. Push to `main` auto-deploys in < 5 min
6. OpenTelemetry traces visible in Cloud Trace for every tool call
7. Cold start < 45s with `--cpu-boost`
8. Individual users revocable via `--google-allowed-users` update
9. `junlinleather.com` serves the gateway with Google-managed SSL

---

## Known Risks & Tradeoffs

| Risk | Impact | Mitigation |
|---|---|---|
| **mcp-auth-proxy is small** (74 stars) | Maintainer could abandon | MIT license, fork if needed. Or swap to Casdoor. |
| **BoltDB per-instance** | OAuth DCR state may diverge across instances | Acceptable at 1-5 users. Migrate to `--repository-backend postgres` later. |
| **Cold start ~30-45s** | First request after idle waits | `--cpu-boost` helps. `min-instances=1` for always-fast (+MYR 25/mo). |
| **mcp-auth-proxy token lifetime** | 24h access, 30d refresh (hardcoded) | Acceptable for current use. Fork to customize if needed. |
| **Cloud SQL cost** | ~MYR 35/mo minimum | db-f1-micro is the smallest. Worth it to eliminate 3 architectural constraints. |
| **UBI 10 Node.js package name** | May be `nodejs` not `nodejs20` | Verify with `microdnf search nodejs` during implementation. |
| **Google Sheets service account** | Needs sheets shared with the SA email | Document setup: share target sheets with SA email address. |

---

## Future Backends (researched, ready to add)

All can be added via bootstrap.sh (stdio servers wrapped by mcpgateway.translate):

| Priority | Server | Stars | What it does | Transport |
|---|---|---|---|---|
| **P0** | `taylorwilsdon/google_workspace_mcp` | 1,800 | Gmail, Calendar, Drive, Docs — local Claude Code only (too heavy for gateway) | stdio (local) |
| **P1** | `korotovsky/slack-mcp-server` | 500 | Order notifications, alerts | stdio/SSE |
| **P1** | `XeroAPI/xero-mcp-server` | 206 | Invoicing, expenses, accounting (official) | stdio |
| **P2** | `shipstation/mcp-shipstation-api` | official | Labels, rates, tracking (official) | stdio |
| **P2** | `googleanalytics/google-analytics-mcp` | official | GA4 reports, real-time data (official) | stdio |
| **P3** | `spartanz51/imagegen-mcp` | 50 | Product photo generation (OpenAI) | stdio |
| **P3** | Stripe MCP | official | Payments, refunds, invoices | HTTP (remote) |
| **P3** | `pipeboard-co/meta-ads-mcp` | 50 | Facebook/Instagram ad campaigns | stdio |

Adding a new stdio backend = 3 lines in entrypoint.sh (translate process) + 3 lines in bootstrap.sh (registration).

---

## Future (out of scope for v3)

- **Casdoor**: When team grows to 10+ users and needs 100+ IdPs, MFA, SAML, WebAuthn
- **RBAC**: When team grows beyond 5 users (ContextForge has this built-in)
- **Grafana dashboard**: When Cloud Trace/Monitoring is insufficient for operational needs
- **mcp-auth-proxy postgres backend**: `--repository-backend postgres` to share OAuth state across instances
