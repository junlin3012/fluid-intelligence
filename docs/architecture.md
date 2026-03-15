# Architecture

Fluid Intelligence is a universal MCP gateway — a single intelligent endpoint that gives AI clients access to any combination of APIs with per-user identity, config-driven backends, and full audit trails.

Shopify is the first vertical. The architecture is designed to support any API backend.

---

## System Overview

```
                          Internet
                             │
                    ┌────────┴────────┐
                    │   Cloud Run     │
                    │   :8080         │
                    │                 │
                    │  ┌───────────┐  │
                    │  │ auth-proxy│  │  ← OAuth 2.1 (Go)
                    │  │  (Go)    │  │     Validates tokens, issues JWTs
                    │  └─────┬─────┘  │
                    │        │        │
                    │  ┌─────┴─────┐  │
                    │  │ContextFor │  │  ← MCP Gateway Core (Python/FastAPI)
                    │  │  ge :4444 │  │     Routes, RBAC, audit, tool catalog
                    │  └──┬──┬──┬──┘  │
                    │     │  │  │     │
                    │  ┌──┘  │  └──┐  │
                    │  │     │     │  │
                    │ :8000 :8003 :8004│
                    │ Apollo dev-  sheets│  ← Backend MCP Servers
                    │ (Rust) mcp  (Py)  │     stdio → SSE bridges
                    │        (Node)     │
                    └──────────────────┘
                             │
                    ┌────────┴────────┐
                    │  Cloud SQL      │
                    │  PostgreSQL     │
                    │  (db-f1-micro)  │
                    └─────────────────┘
```

### Component Responsibilities

| Component | Language | Port | Purpose |
|-----------|----------|------|---------|
| **mcp-auth-proxy** | Go | :8080 | OAuth 2.1 authorization server. DCR, PKCE, Google OAuth, password auth. Front door for all traffic. |
| **ContextForge** | Python | :4444 | IBM's MCP gateway. Tool catalog, virtual servers, audit logging, backend routing. |
| **Apollo MCP** | Rust | :8000 | Shopify GraphQL operations. Validates queries against schema, executes against Shopify Admin API. |
| **dev-mcp** | Node.js | :8003 | Shopify developer docs. Schema introspection, doc search, GraphQL validation. |
| **google-sheets** | Python | :8004 | Google Sheets CRUD. Service account auth. |

---

## Request Flow

```
1. Client sends MCP request (tools/list, tools/call, etc.)
   │
2. auth-proxy (:8080) validates OAuth bearer token
   │  ├── Invalid → 401 Unauthorized
   │  └── Valid → strips auth header, proxies to ContextForge
   │
3. ContextForge (:4444) receives request
   │  ├── tools/list → returns tools from virtual server's tool bundle
   │  ├── tools/call → identifies target backend from tool name prefix
   │  └── routes to backend MCP server via SSE
   │
4. Backend server processes request
   │  ├── Apollo → executes GraphQL against Shopify API
   │  ├── dev-mcp → searches Shopify docs / introspects schema
   │  └── sheets → reads/writes Google Spreadsheets
   │
5. Response flows back: backend → ContextForge → auth-proxy → client
```

---

## Deployment Architecture

### Two-Layer Docker Build

The deployment separates **immutable dependencies** from **frequently-changing code** for fast iteration:

```
┌─────────────────────────────────────────────┐
│  Base Image (rebuild rarely, ~10 min)       │
│  deploy/Dockerfile.base                      │
│  cloudbuild-base.yaml                        │
│                                              │
│  ├── ContextForge 1.0.0-RC-2 (UBI 10)      │
│  ├── Apollo MCP Server (Rust, compiled)     │
│  ├── mcp-auth-proxy v2.5.4 (Go binary)     │
│  ├── tini (PID 1 init process)             │
│  ├── Node.js, npm, curl, jq                │
│  └── uv (Python package manager)           │
│                                              │
│  Registry: asia-southeast1-docker.pkg.dev/  │
│    junlinleather-mcp/junlin-mcp/            │
│    fluid-intelligence-base:latest            │
└─────────────────────────────────────────────┘
                    ▲
                    │ FROM base:latest
                    │
┌─────────────────────────────────────────────┐
│  App Image (rebuild every change, ~5 sec)   │
│  deploy/Dockerfile                           │
│  cloudbuild.yaml                             │
│                                              │
│  ├── scripts/entrypoint.sh                  │
│  ├── scripts/bootstrap.sh                   │
│  ├── config/mcp-config.yaml                 │
│  ├── shopify-schema.graphql (98K lines)     │
│  └── graphql/ (query operations)            │
│                                              │
│  Registry: .../fluid-intelligence:latest     │
└─────────────────────────────────────────────┘
```

**Why two layers?**
- Base image changes: upgrading Apollo, ContextForge, or auth-proxy (~quarterly)
- App image changes: fixing queries, config tweaks, script changes (~daily during dev)
- Build time: 5s for app changes vs 10 min for base rebuild
- Total deploy time: ~3 min (mostly Cloud Run infrastructure)

### Build Commands

```bash
# Rebuild base (rare — only when upstream deps change)
gcloud builds submit --config=deploy/cloudbuild-base.yaml \
  --project=junlinleather-mcp --region=asia-southeast1

# Deploy app changes (frequent — scripts, config, queries)
gcloud builds submit --config=deploy/cloudbuild.yaml \
  --project=junlinleather-mcp --region=asia-southeast1
```

---

## Startup Sequence

| Step | Time | What Happens |
|------|------|--------------|
| T+0s | 0s | Shopify token exchange (client_credentials, 5 retries) |
| T+1s | 1s | Apollo starts (:8000), loads schema + operations |
| T+3s | 2s | `start_and_verify` confirms Apollo alive |
| T+5s | 2s | ContextForge starts (:4444), connects to PostgreSQL |
| T+7s | 2s | `start_and_verify` confirms ContextForge alive |
| T+7s | 0s | dev-mcp (:8003) + google-sheets (:8004) start in parallel |
| T+9-12s | 2-5s | ContextForge health check passes (`/health`) |
| T+12s | 0s | auth-proxy starts (:8080) |
| T+14s | 2s | `start_and_verify` confirms auth-proxy alive |
| T+14s | 1s | Bootstrap registers all backends with ContextForge |
| T+15-20s | — | Cloud Run TCP probe succeeds on :8080 |

**Total cold start: ~15-20s** (with `--cpu-boost`)

---

## Cloud Run Configuration

| Setting | Value | Rationale |
|---------|-------|-----------|
| Region | `asia-southeast1` | Closest to user (Singapore) |
| CPU | 2 vCPU | Handles 5 concurrent processes |
| Memory | **4Gi** | 5 processes + 98K-line schema. 2Gi caused OOM. |
| `--no-cpu-throttling` | Yes | **Required** — background processes freeze without it |
| `--cpu-boost` | Yes | Faster cold starts |
| `--min-instances` | 1 | Avoids cold starts entirely |
| `--max-instances` | 1 | In-memory auth state prevents horizontal scaling |
| Startup probe | TCP :8080, 48x5s | 240s timeout for startup |

---

## Cost Analysis

### Monthly GCP Costs (Estimated)

| Resource | Configuration | Estimated Cost |
|----------|--------------|----------------|
| Cloud Run | 2 vCPU, 4Gi, min-instances=1, no-cpu-throttling | ~$55-70/mo |
| Cloud SQL | db-f1-micro (shared vCPU, 0.6GB RAM) | ~$8/mo |
| Artifact Registry | Container images (~2GB) | ~$0.50/mo |
| Cloud Build | ~5 builds/day, e2-standard-4 | ~$2-5/mo |
| Secret Manager | 12 secrets, ~100 accesses/day | ~$0.10/mo |
| **Total** | | **~$65-85/mo** |

### Cost Optimization Strategies

1. **min-instances=1**: Prevents cold starts ($0 additional cost vs min-instances=0 + frequent cold starts)
2. **max-instances=1**: Caps maximum cost. Horizontal scaling not needed for single-tenant use.
3. **db-f1-micro**: Smallest Cloud SQL instance. Upgrade to db-g1-small if query latency becomes an issue.
4. **Two-layer Docker**: Avoids rebuilding base image (which uses expensive e2-highcpu-8 machines) unless truly needed.
5. **No egress costs**: All traffic stays within asia-southeast1 (except Shopify API calls).

### Cost Red Flags to Watch

- **Do NOT** set `max-instances` > 1 unless auth state is externalized to Redis/DB
- **Do NOT** use `e2-highcpu-32` for Cloud Build (quota issues + expensive). Use `e2-highcpu-8`.
- **Do NOT** rebuild base image for config/script changes — that's what the thin layer is for
- **Do NOT** enable Cloud Run autoscaling without first moving session state to the database

---

## Authentication

### OAuth 2.1 Flow

```
Client                        auth-proxy                     Login Page
  │                              │                              │
  │ POST /.idp/register          │                              │
  │ ─────────────────────────────>│                              │
  │ 201 {client_id, secret}      │                              │
  │ <─────────────────────────────│                              │
  │                              │                              │
  │ GET /.idp/auth?code_challenge│                              │
  │ ─────────────────────────────>│                              │
  │ 302 → /.auth/login           │                              │
  │ <─────────────────────────────│                              │
  │                              │                              │
  │ POST /.auth/login (password) │                              │
  │ ──────────────────────────────────────────────────────────────>│
  │                              │       302 → callback?code=... │
  │ <──────────────────────────────────────────────────────────────│
  │                              │                              │
  │ POST /.idp/token (code + verifier)                          │
  │ ─────────────────────────────>│                              │
  │ 200 {access_token, 86400s}   │                              │
  │ <─────────────────────────────│                              │
```

Two authentication methods:
- **Password**: For CLI clients (Claude Code). Simple, headless.
- **Google OAuth**: For browser clients. Allowlist via `GOOGLE_ALLOWED_USERS`.

### Key Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/.well-known/oauth-authorization-server` | GET | OAuth metadata (discovery) |
| `/.well-known/oauth-protected-resource` | GET | Resource server metadata |
| `/.idp/register` | POST | Dynamic Client Registration |
| `/.idp/auth` | GET | Authorization endpoint |
| `/.idp/token` | POST | Token exchange |
| `/.auth/login` | GET/POST | Login page (password + Google) |

---

## Database

- **Instance**: Cloud SQL PostgreSQL, `junlinleather-mcp:asia-southeast1:contextforge`
- **Connection**: Unix socket via Cloud SQL proxy (`/cloudsql/...`)
- **User**: `contextforge`, Database: `contextforge`
- **Schema**: Managed by Alembic (auto-migrates on startup, advisory lock prevents races)
- **Stores**: Gateway registrations, tool cache, virtual server config, session state, audit logs

---

## Known Limitations

### Apollo File-Loading Bug
Apollo MCP Server v1.9.0 silently drops valid query operations when loading from `.graphql` files. Only simple queries (GetProducts, GetProduct) load successfully; complex queries against Order/Customer types fail.

**Workaround**: Enable `introspection.execute` in `mcp-config.yaml`. The AI dynamically composes and executes queries via the `execute` tool — this is more powerful than predefined operations because it allows unlimited query flexibility.

### Single Instance Only
In-memory auth state in mcp-auth-proxy prevents horizontal scaling. `max-instances` must remain at 1. To scale: externalize session state to Redis or Cloud SQL.

### Claude.ai OAuth Bug
Claude.ai web/Desktop cannot complete OAuth with custom MCP servers (as of March 2026). Use Claude Code CLI instead. Tracked: [#5826](https://github.com/anthropics/claude-code/issues/5826).

### ContextForge StreamableHTTP Bug
ContextForge 1.0.0-RC-2 fails the StreamableHTTP initialize handshake. All backends must use SSE transport via stdio→SSE bridges.

---

## File Reference

| File | Purpose |
|------|---------|
| `deploy/Dockerfile` | Thin app image (scripts, config, queries) |
| `deploy/Dockerfile.base` | Fat base image (all binaries and deps) |
| `deploy/cloudbuild.yaml` | App deploy pipeline |
| `deploy/cloudbuild-base.yaml` | Base image build pipeline |
| `scripts/entrypoint.sh` | Process orchestrator (starts all 5 services) |
| `scripts/bootstrap.sh` | Backend registration with ContextForge |
| `scripts/test-e2e.sh` | End-to-end test suite (13 tests) |
| `config/mcp-config.yaml` | Apollo MCP Server configuration |
| `shopify-schema.graphql` | Shopify Admin API schema (98K lines) |
| `graphql/` | GraphQL query operations for Apollo |
| `docs/agent-behavior/` | Agent learning system (failure log, insights, patterns) |
