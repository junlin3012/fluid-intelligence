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
    ├── 1. Apollo (Rust, streamable_http)    :8000  — Shopify GraphQL ops
    ├── 2. ContextForge (Python/FastAPI)    :4444  — MCP gateway core
    ├── 3. dev-mcp bridge (Node→stdio→SSE)  :8003  — Shopify docs
    ├── 4. sheets bridge (Python→stdio→SSE) :8004  — Google Sheets
    └── 5. mcp-auth-proxy (Go)             :8080  — OAuth 2.1 front door
```

Apollo runs natively with `streamable_http` transport on port 8000 (no bridge).
dev-mcp and sheets run as stdio processes bridged to SSE via `mcpgateway.translate`.

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
| `AUTH_REQUIRED` | false | **Set to `false`** — auth-proxy handles ALL external auth. ContextForge trusts internal traffic. With `true`, ContextForge rejects requests where auth-proxy stripped the Authorization header (the "Double-Auth Problem" from failure-log.md). |
| `TRUST_PROXY_AUTH` | false | When `true` + `TRUST_PROXY_AUTH_DANGEROUSLY=true` + `MCP_CLIENT_AUTH_ENABLED=false`, ContextForge trusts the identity header from auth-proxy |
| `PROXY_USER_HEADER` | X-Authenticated-User | Header name that auth-proxy sets with the user's email after JWT validation |
| `SSO_AUTO_CREATE_USERS` | false | When `true`, auto-creates EmailUser on first request from unknown user |
| `SSO_GOOGLE_ADMIN_DOMAINS` | — | Users from this domain auto-promoted to admin (set to `junlinleather.com`) |
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
| Apollo | `/mcp` on :8000 | Any HTTP response = up (404/405 expected on GET) |
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

## Identity Forwarding (v2.5.4-identity fork)

mcp-auth-proxy is a fork of `sigbit/mcp-auth-proxy` v2.5.4 with a 14-line patch:

1. **Defense-in-depth**: Strips any pre-existing `X-Authenticated-User` header from incoming requests BEFORE JWT validation (prevents spoofing)
2. **Identity extraction**: After JWT validation succeeds, extracts `sub` claim (user email) and sets `X-Authenticated-User` header
3. **Fallback**: If no `sub` claim, tries `client_id` claim
4. **No identity = no header**: If JWT has neither claim, request proxies without identity header — ContextForge with `AUTH_REQUIRED=true` rejects it

**ContextForge proxy auth activation** (all three required):
- `MCP_CLIENT_AUTH_ENABLED=false`
- `TRUST_PROXY_AUTH=true`
- `TRUST_PROXY_AUTH_DANGEROUSLY=true`

**End-to-end flow:**
```
Client → auth-proxy validates JWT → extracts sub=ourteam@junlinleather.com
       → sets X-Authenticated-User header → strips Authorization header
       → ContextForge reads header → resolves EmailUser → checks RBAC
       → routes to backend → audit trail records user_email
```

**Fork repo**: `junlin3012/mcp-auth-proxy` (branch: `identity-forwarding`, tag: `v2.5.4-identity`)

**Known gaps (as of 2026-03-18):**
- **E2E verification pending**: The identity chain has been deployed but never verified end-to-end with a real Google OAuth login. Verify by: (1) logging in via Google OAuth, (2) checking auth-proxy logs for `sub` claim in JWT, (3) checking ContextForge logs for X-Authenticated-User resolution, (4) checking audit trail for user_email.
- **Header name coupling**: The `X-Authenticated-User` header name is hardcoded in the auth-proxy Go fork (proxy.go). ContextForge reads it from `PROXY_USER_HEADER` env var. Changing the header name requires updating both — they are not dynamically linked.
- **PLATFORM_ADMIN_EMAIL vs GOOGLE_ALLOWED_USERS**: Bootstrap uses `admin@junlinleather.com` as the admin identity, but only `ourteam@junlinleather.com` can authenticate via Google OAuth. The bootstrap admin is a phantom identity that works internally but can never log in. Consider aligning `PLATFORM_ADMIN_EMAIL` with the actual admin user.

## Security Protocols

### 1. Network Boundary
- **Only port 8080 is exposed** to the internet (via Cloud Run)
- mcp-auth-proxy on :8080 is the ONLY externally reachable process
- ContextForge on :4444, Apollo on :8000, dev-mcp on :8003, sheets on :8004 are **internal only**
- All inter-process communication is over `127.0.0.1` (localhost within the container)
- Cloud Run provides TLS termination — all external traffic is HTTPS

### 2. Authentication Flow
- **OAuth 2.1 with PKCE** — mcp-auth-proxy handles the full OAuth flow
- **Google OAuth** primary auth (--google-client-id, --google-allowed-users)
- **Password fallback** for CLI clients (--password)
- **RSA-signed JWTs** issued by auth-proxy (RS256, not HS256)
- **JWT validation** on every request — RSA signature check, expiry check

### 3. Identity Header Security (X-Authenticated-User)
Three layers of defense prevent identity spoofing:

| Layer | What | Where |
|-------|------|-------|
| **Strip incoming** | `c.Request.Header.Del("X-Authenticated-User")` at top of `handleProxy()` | proxy.go:61 |
| **Set only after validation** | Header set ONLY after RSA JWT validation succeeds | proxy.go:84-90 |
| **Block proxyHeaders override** | `proxyHeaders` loop explicitly skips `X-Authenticated-User` | proxy.go:99-101 |

**Why this is safe:**
- External clients cannot inject the header (stripped before auth)
- Only valid RSA-signed JWTs can set the header (auth-proxy is the only RSA key holder)
- Static `--proxy-headers` config cannot override the validated value
- ContextForge on :4444 is not exposed — only auth-proxy can reach it

### 4. ContextForge Proxy Auth Mode
When all three conditions are met, ContextForge trusts the identity header:
- `MCP_CLIENT_AUTH_ENABLED=false` — disables ContextForge's own JWT validation
- `TRUST_PROXY_AUTH=true` — enables proxy auth pipeline
- `TRUST_PROXY_AUTH_DANGEROUSLY=true` — acknowledges the security implications

**TRUST_PROXY_AUTH_DANGEROUSLY is safe here** because:
- ContextForge on :4444 is NOT exposed to the internet
- Only auth-proxy (same container, localhost) can reach it
- Auth-proxy validates and sets the header correctly
- If :4444 were ever exposed directly, this would be a critical vulnerability

### 5. Secrets Management
| Secret | Storage | Access |
|--------|---------|--------|
| SHOPIFY_CLIENT_SECRET | GCP Secret Manager | `--set-secrets` in Cloud Run |
| JWT_SECRET_KEY | GCP Secret Manager | Used for ContextForge bootstrap JWTs (HS256) |
| AUTH_PASSWORD | GCP Secret Manager | CLI password fallback |
| GOOGLE_OAUTH_CLIENT_SECRET | GCP Secret Manager | OAuth flow |
| AUTH_ENCRYPTION_SECRET | GCP Secret Manager | ContextForge DB encryption (separate from JWT) |
| DB_PASSWORD | GCP Secret Manager | PostgreSQL connection |

**Secrets**: auth-proxy reads `PASSWORD` and `GOOGLE_CLIENT_SECRET` from environment variables (set via `export` in entrypoint.sh). No secrets are passed via CLI args — `/proc/cmdline` is clean.

### 6. Binary Integrity
All downloaded binaries are SHA256-verified in Dockerfile.base:
- **mcp-auth-proxy**: `sha256sum -c -` check against pinned hash
- **tini**: same pattern
- **Apollo**: compiled from source (Rust cargo build)

Updating a binary requires: recompile → record new hash → update Dockerfile.base → rebuild base image.

### 7. RBAC (Role-Based Access Control)
- **Teams**: admin (full access), viewer (read-only Shopify)
- **Roles**: platform_admin, developer, viewer (ContextForge built-in)
- **Auto-create users**: `SSO_AUTO_CREATE_USERS=true` on first request
- **Auto-promote admins**: `SSO_GOOGLE_ADMIN_DOMAINS=junlinleather.com`
- **Bootstrap**: teams/roles set up at container start before any user login

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
- **Note on StreamableHTTP**: Earlier failure-log entries reference `Protocols: SSE=True, StreamableHTTP=False` — this was a ContextForge translate bridge limitation. Apollo now serves native streamable_http (no bridge), and ContextForge connects to it directly via STREAMABLEHTTP transport. The limitation only affected the stdio→SSE bridge path.

### 3. Cloud Run PORT is immutable
- Cloud Run injects `PORT=8080` — you cannot override it
- ContextForge must use `MCG_PORT` (not `PORT`) for its internal port
- mcp-auth-proxy binds to :8080 (matching Cloud Run's PORT)

### 4. Bootstrap registration: gateways vs servers
- `POST /gateways` registers backends and triggers tool auto-discovery into the catalog
- `POST /servers` creates virtual servers that bundle subsets of discovered tools
- MCP clients connect to `/servers/<UUID>/mcp` — without a virtual server, `tools/list` returns empty
- Transport values: `STREAMABLEHTTP` for Apollo, `SSE` for dev-mcp and sheets
- JWT token generated via `mcpgateway.utils.create_jwt_token` in ContextForge venv
- Gateway body: `{"name":"...","url":"...","transport":"SSE|STREAMABLEHTTP"}`
- Server body: `{"server":{"name":"...","description":"...","associated_tools":[...]}}`

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
