# System Understanding

> This document captures the accumulated understanding of how the Fluid Intelligence system works at runtime.
> It is NOT incremental — it represents the CURRENT complete understanding.
> Agents MUST update this document as they learn new things about the system.
> When troubleshooting, read this first; when done, update this with what you learned.

---

## Architecture Overview

Fluid Intelligence is a multi-process container running on Google Cloud Run. One container runs 5 processes orchestrated by `entrypoint.sh` with `tini` as PID 1:

```
Cloud Run container (:8080 exposed)
├── tini (PID 1, init process)
└── entrypoint.sh (orchestrator)
    ├── 1. Apollo bridge (Rust→stdio→SSE)   :8000  — Shopify GraphQL ops
    ├── 2. ContextForge (Python/FastAPI)    :4444  — MCP gateway core
    ├── 3. dev-mcp bridge (Node→stdio→SSE)  :8003  — Shopify docs
    ├── 4. sheets bridge (Python→stdio→SSE) :8004  — Google Sheets
    └── 5. mcp-auth-proxy (Go)             :8080  — OAuth 2.1 front door
```

All three backends (Apollo, dev-mcp, sheets) run as stdio processes bridged to SSE
via `mcpgateway.translate`. This is required because ContextForge's MCP client has
a bug with the `streamable_http` transport.

Traffic flow: `Client → :8080 (auth-proxy) → :4444 (ContextForge) → backends`

## Base Image: IBM ContextForge 1.0.0-RC-2

- Built on Red Hat UBI 10 Minimal (NOT Alpine, NOT Debian)
- Package manager: `microdnf` (not apt, not apk)
- Python venv at `/app/.venv/` — DO NOT modify with pip/uv without understanding consequences
- `file` command NOT available (minimal image)
- Entry point: `/app/.venv/bin/python -c "from mcpgateway.cli import main; main()"` — the CLI script and `python -m mcpgateway` are both broken after venv modification

## Critical Environment Variables

### ContextForge reads:
| Variable | Default | Notes |
|----------|---------|-------|
| `MCG_PORT` | 4444 | Listen port. NOT `PORT`, NOT `MCPGATEWAY_PORT` |
| `MCG_HOST` | 127.0.0.1 | Bind address. MUST be `0.0.0.0` for containers |
| `DATABASE_URL` | — | PostgreSQL connection string |
| `AUTH_ENCRYPTION_SECRET` | — | JWT signing secret |
| `PLATFORM_ADMIN_PASSWORD` | — | Admin API password |
| `AUTH_REQUIRED` | true | **Set to `false`** — mcp-auth-proxy handles all external auth; ContextForge's internal auth uses HMAC JWT which conflicts with auth-proxy's RS256 JWT |
| `CACHE_TYPE` | database | `database`, `memory`, or `redis` |
| `HTTP_SERVER` | gunicorn | `gunicorn` or `granian` — only affects ContextForge's own entrypoint, which we bypass |

### Cloud Run injects:
| Variable | Value | Notes |
|----------|-------|-------|
| `PORT` | 8080 | IMMUTABLE. Cannot be overridden by `export`. mcp-auth-proxy listens here. |

## Health Endpoints

| Service | Endpoint | Notes |
|---------|----------|-------|
| ContextForge | `/health` | NOT `/healthz`. Returns `{"status": "healthy"}` |
| Apollo | None confirmed | TCP check on :8000 works |
| dev-mcp bridge | `/healthz` | Standard health endpoint |
| google-sheets bridge | `/healthz` | Standard health endpoint |
| mcp-auth-proxy | Responds on :8080 | 401 = healthy (auth required) |

## Startup Sequence (timed from Cloud Run logs)

1. **T+0s**: Shopify token exchange (client_credentials flow)
2. **T+1s**: Apollo starts, loads schema (warns on invalid GraphQL ops)
3. **T+3s**: `start_and_verify` confirms Apollo alive
4. **T+5s**: ContextForge starts (config loading, DB connection, caches)
5. **T+7s**: `start_and_verify` confirms ContextForge alive
6. **T+7s**: dev-mcp + google-sheets bridges start (parallel)
7. **T+9-12s**: ContextForge `/health` returns 200 (DB ready, Alembic done)
8. **T+12s**: mcp-auth-proxy starts on :8080
9. **T+14s**: `start_and_verify` confirms auth-proxy alive
10. **T+14s**: Bootstrap registers backends with ContextForge
11. **T+15-20s**: Cloud Run TCP startup probe succeeds on :8080

Total cold start: ~15-20s (with `--cpu-boost`)

## Known Gotchas

### 1. `uv pip install` corrupts ContextForge venv
- Installing packages into `/app/.venv/` with `uv pip install` breaks the `mcpgateway` CLI entry point script
- Module imports still work (`from mcpgateway.cli import main`)
- Workaround: Bypass entry point with direct `main()` invocation
- This is SAFE as long as you don't need the CLI script

### 2. Apollo file-loading silently drops valid queries
- Apollo v1.9.0 only loads 2 of 7 query operations from `.graphql` files (GetProducts, GetProduct)
- All 5 dropped queries (GetOrders, GetOrder, GetCustomers, GetCustomer, GetInventoryLevels) pass Apollo's own `validate` tool and execute successfully via the `execute` tool
- Root cause: Unknown bug in Apollo's file-loading/schema-tree-shaking pipeline, likely related to the complexity of Order/Customer type graphs (55+ dependent types)
- **Workaround**: Enable `introspection.execute` and `introspection.validate` in `mcp-config.yaml`. The AI dynamically composes and executes queries via the `execute` tool — this is MORE powerful than predefined operations
- Mutations are also skipped by default; can be enabled with `overrides.mutation_mode: explicit`

### 3. Cloud Run PORT is immutable
- Cloud Run injects `PORT=8080` — you cannot override it
- ContextForge must use `MCG_PORT` (not `PORT`) for its internal port
- mcp-auth-proxy binds to :8080 (matching Cloud Run's PORT)

### 4. Bootstrap server registration format
- ContextForge API uses `POST /servers` endpoint (NOT `/gateways`)
- `/servers` auto-discovers tools; `/gateways` only stores metadata
- Transport values: lowercase `sse` (NOT uppercase, NOT `streamablehttp`)
- ContextForge's MCP client has a bug with `streamablehttp` transport — the initialize handshake fails with "connection closed: initialize notification". Use `sse` for all backends.
- JWT token generated via `mcpgateway.utils.create_jwt_token` in ContextForge venv
- Registration body: `{"server":{"name":"...","url":"...","transport":"sse"}}`

### 5. Binary permissions in multi-stage Docker builds
- `COPY --from=stage` preserves permissions from source stage
- But verify with `chmod 755` explicitly after COPY
- UBI Minimal has no `file` command for binary type checking

## Two-Layer Docker Architecture

The deployment uses a fat base image + thin app image for fast iteration:

```
deploy/Dockerfile.base (rebuild rarely, ~10 min)
├── FROM rust:1.82-slim-bookworm  → Apollo Rust compile
├── FROM alpine:3.20              → mcp-auth-proxy binary
├── FROM ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2  → Base image
│   ├── microdnf install nodejs npm curl jq tar gzip
│   ├── uv install (Python package manager)
│   ├── tini (PID 1 init)
│   ├── COPY apollo binary
│   └── COPY mcp-auth-proxy binary
└── Push to: asia-southeast1-docker.pkg.dev/.../fluid-intelligence-base:latest

deploy/Dockerfile (rebuild every change, ~5 sec build)
├── FROM fluid-intelligence-base:latest
├── COPY scripts/entrypoint.sh, bootstrap.sh
├── COPY config/mcp-config.yaml
├── COPY shopify-schema.graphql
└── COPY graphql/ (query operations)
```

Build commands:
- Base: `gcloud builds submit --config=deploy/cloudbuild-base.yaml`
- App: `gcloud builds submit --config=deploy/cloudbuild.yaml`

## Memory Configuration

- Cloud Run memory: **4Gi** (was 2Gi, caused OOM with 5 processes + 98K-line schema)
- CPU: 2 vCPU
- `--no-cpu-throttling` required for background processes
- `--cpu-boost` for faster cold starts

## Database

- Cloud SQL PostgreSQL (asia-southeast1, instance: `contextforge`)
- Connected via Unix socket: `/cloudsql/junlinleather-mcp:asia-southeast1:contextforge`
- User: `contextforge`, DB: `contextforge`
- Alembic manages schema migrations on startup
- Uses advisory lock to prevent concurrent migration runs

## Troubleshooting Checklist

When the container fails to start:

1. **Read ALL logs** — `gcloud logging read 'resource.labels.revision_name="fluid-intelligence-XXXXX-xxx"'`
2. **Trace the startup sequence** — Every service should have a log entry. Missing = crashed silently.
3. **Check for "FATAL" messages** — entrypoint.sh logs these before exiting
4. **Check process liveness** — `start_and_verify` catches crashes within 2s
5. **Check ContextForge health** — `/health` (not `/healthz`)
6. **Check auth-proxy** — 401 = working, connection refused = crashed
7. **Check bootstrap** — HTTP 422 = wrong request format, not auth issue

When diagnosing, fix ALL issues before deploying. One analyzed build > five guess-and-check builds.

## OAuth 2.1 Flow (mcp-auth-proxy v2.5.4)

### How it works
```
Client → POST / → 401 (no WWW-Authenticate header)
Client → GET /.well-known/oauth-protected-resource → 200 (resource + auth server URL)
Client → GET /.well-known/oauth-authorization-server → 200 (all OAuth endpoints)
Client → POST /.idp/register → 201 (DCR, returns client_id)
Client → opens browser to /.idp/auth?response_type=code&client_id=...&state=...&code_challenge=...
  → 302 to /.idp/auth/{session-id}
  → 302 to /.auth/login (with session cookie)
  → 200 login page (Google OAuth + password options)
User authenticates → redirect to callback with auth code
Client → POST /.idp/token (exchange code for access token)
Client → POST / with Bearer token → proxied to ContextForge
```

### OAuth metadata endpoints
| Endpoint | Returns |
|----------|---------|
| `/.well-known/oauth-protected-resource` | `resource`, `authorization_servers` |
| `/.well-known/oauth-authorization-server` | `issuer`, `authorization_endpoint`, `token_endpoint`, `registration_endpoint`, supported methods |
| `/.idp/register` | DCR — `client_id`, `redirect_uris`, `registration_client_uri` |
| `/.idp/auth` | Authorization endpoint — redirects to login page |
| `/.idp/token` | Token endpoint — exchanges code for access/refresh tokens |
| `/.auth/login` | Login page (Google + password) |
| `/.auth/password` | Password-only auth endpoint |

### Claude.ai OAuth bug (as of March 2026)
- **Known bug**: Claude.ai web + Claude Desktop fail to connect to custom OAuth MCP servers
- **Symptom**: DCR succeeds (201) but auth popup never opens; Claude.ai returns `step=start_error`
- **Tracked**: [#5826](https://github.com/anthropics/claude-code/issues/5826), [#3515](https://github.com/anthropics/claude-code/issues/3515), [#11814](https://github.com/anthropics/claude-code/issues/11814)
- **Workaround**: Use Claude Code CLI (`claude mcp add --transport http`)
- **Our server is NOT broken** — full OAuth flow verified manually
- Claude.ai callback URL: `https://claude.ai/api/mcp/auth_callback`

### Auth configuration flags (entrypoint.sh)
```
mcp-auth-proxy \
  --listen :8080 \
  --external-url "https://${EXTERNAL_URL}" \
  --google-client-id "$GOOGLE_OAUTH_CLIENT_ID" \
  --google-client-secret "$GOOGLE_OAUTH_CLIENT_SECRET" \
  --google-allowed-users "${GOOGLE_ALLOWED_USERS}" \
  --password "$AUTH_PASSWORD" \
  --no-auto-tls \
  --data-path /app/data \
  -- http://localhost:${CONTEXTFORGE_PORT}
```
