# Architecture

Fluid Intelligence is a universal MCP gateway — a single intelligent endpoint that gives AI clients access to any combination of APIs with per-user identity, config-driven backends, and full audit trails.

Shopify is the first vertical. The architecture is designed to support any API backend.

---

## Table of Contents

1. [System Overview](#system-overview)
2. [Service Topology](#service-topology)
3. [Request Flow](#request-flow)
4. [Shopify OAuth Service](#shopify-oauth-service)
5. [Authentication](#authentication)
6. [Tool Catalog](#tool-catalog)
7. [Deployment Architecture](#deployment-architecture)
8. [Startup Sequence](#startup-sequence)
9. [Cloud Run Configuration](#cloud-run-configuration)
10. [Database](#database)
11. [Secrets & Environment Variables](#secrets--environment-variables)
12. [Cost Analysis](#cost-analysis)
13. [Testing](#testing)
14. [Known Limitations](#known-limitations)
15. [Architecture Issues](#architecture-issues)
16. [Risk Register](#risk-register)
17. [V4 Design Directions (Mirror Polish Corrections)](#v4-design-directions-mirror-polish-corrections)
18. [File Reference](#file-reference)

---

## System Overview

```
                          Internet
                             |
              +--------------+----------------+
              |                               |
     +--------v--------+          +----------v-----------+
     |  Cloud Run:     |          |  Cloud Run:          |
     |  fluid-         |          |  shopify-oauth       |
     |  intelligence   |          |  (standalone)        |
     |  :8080          |          |  :8080               |
     |                 |          |                      |
     |  5 processes    |          |  Python/FastAPI      |
     |  in 1 container |          |  OAuth install flow  |
     +--------+--------+          +----------+-----------+
              |                               |
              +-------------------------------+
              |
     +--------v--------+
     |  Cloud SQL      |
     |  PostgreSQL     |
     |  contextforge   |
     |  (db-f1-micro)  |
     +-----------------+
```

Two independent Cloud Run services share a PostgreSQL database:
- **fluid-intelligence**: The MCP gateway (5 processes, handles all AI client traffic)
- **shopify-oauth**: Standalone OAuth service (handles Shopify app install/uninstall flows)

---

## Service Topology

### Gateway Container (fluid-intelligence)

```
Cloud Run container (:8080 exposed)
+-- tini (PID 1, init process, signal forwarding)
    +-- entrypoint.sh (orchestrator)
        |
        +-- 1. Apollo bridge (Rust->stdio->SSE)   :8000
        |      Shopify GraphQL operations
        |
        +-- 2. ContextForge (Python/FastAPI)       :4444
        |      MCP gateway core (IBM open source)
        |
        +-- 3. dev-mcp bridge (Node->stdio->SSE)   :8003
        |      Shopify developer docs & schema
        |
        +-- 4. sheets bridge (Python->stdio->SSE)  :8004
        |      Google Sheets CRUD
        |
        +-- 5. mcp-auth-proxy (Go)                :8080
               OAuth 2.1 front door
```

All inter-process communication is via localhost HTTP/SSE. No external network traffic except to Shopify Admin API, Google APIs, and Cloud SQL.

### Component Responsibilities

| Component | Language | Port | Version | Purpose |
|-----------|----------|------|---------|---------|
| **mcp-auth-proxy** | Go | :8080 | v2.5.4 | OAuth 2.1 authorization server. DCR, PKCE, Google OAuth, password auth. Front door for all traffic. |
| **ContextForge** | Python | :4444 | 1.0.0-RC-2 | IBM's MCP gateway. Tool catalog, virtual servers, backend routing, audit logging. |
| **Apollo MCP** | Rust | :8000 | v1.9.0 | Shopify GraphQL operations. Schema validation, query execution against Shopify Admin API. |
| **dev-mcp** | Node.js | :8003 | v1.7.1 | Shopify developer docs. Schema introspection, doc search, API reference. |
| **google-sheets** | Python | :8004 | v0.6.0 | Google Sheets CRUD. Service account auth. 17 tools. |
| **tini** | C | — | v0.19.0 | PID 1 init process. Forwards signals to process group (-g flag). |

### Shopify OAuth Service (shopify-oauth)

| Component | Language | Port | Purpose |
|-----------|----------|------|---------|
| **shopify-oauth** | Python/FastAPI | :8080 | Handles Shopify OAuth install flow, token storage, webhook handling |

Separate Cloud Run service. Scale-to-zero. Minimal resources (256Mi, 1 vCPU).

### Health Endpoints

| Service | Endpoint | Healthy Response |
|---------|----------|-----------------|
| ContextForge | `GET /health` (NOT `/healthz`) | `{"status": "healthy"}` |
| Apollo | `GET /sse` on :8000 (HTTP, curl exit 0 or 28) | curl rc=0 or rc=28 (28 = SSE stream active) |
| dev-mcp bridge | `GET /healthz` | 200 |
| google-sheets bridge | `GET /healthz` | 200 |
| mcp-auth-proxy | Any request on :8080 | 401 = running (auth required) |
| shopify-oauth | `GET /health` | `{"status": "ok"}` |

### Graceful Shutdown

On SIGTERM (Cloud Run scale-down or redeployment):

1. `entrypoint.sh` trap sends SIGTERM to all 5 managed process PIDs
2. Waits for each process to exit
3. Cleans up temp files (`/tmp/apollo.pid`, `/tmp/devmcp.pid`, `/tmp/sheets.pid`)
4. Exits with code 143 (128 + 15 = SIGTERM)

tini's `-g` flag ensures signals propagate to the entire process group, including grandchild processes (e.g., npx-launched Node.js processes).

### Crash Detection

`entrypoint.sh` runs `wait -n` on all 5 PIDs after startup. If any process exits unexpectedly, it logs the failed PID and exit code, then exits — causing Cloud Run to restart the container.

---

## Request Flow

### MCP Tool Call (Client -> Shopify API)

```
1. AI client sends MCP request (tools/list, tools/call)
   |
2. mcp-auth-proxy (:8080) validates OAuth bearer token
   |  +-- Invalid -> 401 Unauthorized
   |  +-- Valid -> proxies to ContextForge
   |
3. ContextForge (:4444) receives request
   |  +-- tools/list -> returns tools from virtual server bundle
   |  +-- tools/call -> identifies target backend from tool name prefix
   |  +-- routes to backend MCP server via SSE
   |
4. Backend server processes request
   |  +-- Apollo -> executes GraphQL against Shopify Admin API
   |  |     https://junlinleather-5148.myshopify.com/admin/api/2026-01/graphql.json
   |  +-- dev-mcp -> searches Shopify docs / introspects schema
   |  +-- sheets -> reads/writes Google Spreadsheets
   |
5. Response flows back: backend -> ContextForge -> auth-proxy -> client
```

### Token Loading (Startup)

```
1. entrypoint.sh reads encrypted token from Cloud SQL
   |  SELECT access_token_encrypted FROM shopify_installations
   |  WHERE shop_domain = $SHOPIFY_STORE AND status = 'active'
   |
2. Decrypts using SHOPIFY_TOKEN_ENCRYPTION_KEY (AES-256-GCM)
   |
3. Validates token starts with "shp" prefix
   |
4. Exports as SHOPIFY_ACCESS_TOKEN env var
   |  (Used by Apollo via mcp-config.yaml header injection)
   |
5. Fallback: client_credentials OAuth if DB token missing/invalid
   |  POST https://{store}/admin/oauth/access_token
   |  5 attempts with linear backoff (sleep 2s, 4s, 6s, 8s between attempts)
```

---

## Shopify OAuth Service

A standalone Cloud Run service that handles Shopify's OAuth authorization code grant flow. It stores permanent offline access tokens in Cloud SQL. The gateway reads tokens from the database at startup.

### Install Flow

```
Merchant clicks "Install app" in Shopify Admin
    |
    v
GET /auth/install?shop=xxx&hmac=xxx&timestamp=xxx
    |  Validate shop hostname (regex: ^[a-zA-Z0-9][a-zA-Z0-9-]*\.myshopify\.com$)
    |  Validate HMAC (SHA-256, shared secret)
    |  Validate timestamp freshness (<= 5 min)
    |  Generate nonce, store in TWO HttpOnly cookies: shopify_nonce (raw nonce) + shopify_nonce_sig (HMAC-SHA256 signature)
    v
302 -> https://{shop}/admin/oauth/authorize
       ?client_id=f597c0aaa02fac7278a54c617d7b344d
       &scope=read_products%3Awrite_products%3Aread_customers%3A...
       &redirect_uri=https%3A//shopify-oauth-1056128102929.asia-southeast1.run.app/auth/callback
       &state={nonce}
       (Note: both scope and redirect_uri are urllib.parse.quote() encoded;
        ':' becomes '%3A'. Shopify accepts URL-encoded scope params.)
    |
    v
Merchant approves scopes on Shopify consent screen
    |
    v
GET /auth/callback?code=xxx&shop=xxx&hmac=xxx&state=xxx
    |  Validate shop hostname → HMAC → nonce (from cookie)
    |  Exchange code for permanent offline access token
    |  Encrypt token with AES-256-GCM (authenticated encryption)
    |  UPSERT into shopify_installations table
    |  Fetch shop numeric ID via REST API (GET /admin/api/{version}/shop.json)
    |  Register APP_UNINSTALLED webhook (GDPR webhooks configured in Partner Dashboard)
    v
200 "Connected Successfully" page
```

### Webhook Handling

| Route | Event | Action |
|-------|-------|--------|
| `POST /webhooks/app-uninstalled` | APP_UNINSTALLED | Mark shop as `uninstalled`, clear encrypted token |
| `POST /webhooks/gdpr/{topic}` | GDPR (parameterized) | `shop-redact`: mark uninstalled; others: log and acknowledge |

The GDPR route is a single parameterized handler accepting `customers-data-request`, `customers-redact`, and `shop-redact` topics.

All webhooks verify `X-Shopify-Hmac-SHA256` header (HMAC-SHA256 of request body with client secret).

### OAuth Scopes (15 total, colon-separated in config)

```
read_products:write_products:read_customers:write_customers:
read_orders:write_orders:read_draft_orders:write_draft_orders:
read_inventory:write_inventory:read_fulfillments:write_fulfillments:
read_discounts:write_discounts:read_locations
```

Shopify accepts both colon-separated and comma-separated formats in the OAuth authorize URL.

### Service Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/health` | GET | Health check (tests DB connectivity) |
| `/auth/install` | GET | Start OAuth install flow / app home page |
| `/auth/callback` | GET | OAuth callback, token exchange |
| `/webhooks/app-uninstalled` | POST | Handle app uninstall |
| `/webhooks/gdpr/{topic}` | POST | Handle GDPR mandatory webhooks |

---

## Authentication

### OAuth 2.1 Flow (mcp-auth-proxy)

```
Client                        auth-proxy                     Login Page
  |                              |                              |
  | POST /.idp/register          |                              |
  | ---------------------------->|                              |
  | 201 {client_id, secret}      |                              |
  | <----------------------------|                              |
  |                              |                              |
  | GET /.idp/auth?code_challenge|                              |
  | ---------------------------->|                              |
  | 302 -> /.auth/login          |                              |
  | <----------------------------|                              |
  |                              |                              |
  | Authenticate (password       |                              |
  |   or Google OAuth)           |                              |
  | ------------------------------------------------------------->
  |                              |       302 -> callback?code=  |
  | <-------------------------------------------------------------
  |                              |                              |
  | POST /.idp/token             |                              |
  |   (code + PKCE verifier)     |                              |
  | ---------------------------->|                              |
  | 200 {access_token, 86400s}   |                              |
  | <----------------------------|                              |
```

Two authentication methods:
- **Password**: For CLI clients (Claude Code). Simple, headless.
- **Google OAuth**: For browser clients. Allowlist: `ourteam@junlinleather.com`

### auth-proxy Launch Configuration

```
mcp-auth-proxy \
  --listen :8080 \
  --external-url "https://${EXTERNAL_URL:-junlinleather.com}" \
  --google-client-id "$GOOGLE_OAUTH_CLIENT_ID" \
  --google-client-secret "$GOOGLE_OAUTH_CLIENT_SECRET" \
  --google-allowed-users "${GOOGLE_ALLOWED_USERS:-ourteam@junlinleather.com}" \
  --password "$AUTH_PASSWORD" \
  --no-auto-tls \
  --data-path /app/data \
  -- "http://127.0.0.1:${CONTEXTFORGE_PORT}"
```

Key flags:
- `--no-auto-tls`: TLS handled by Cloud Run, not auth-proxy
- `--data-path /app/data`: Session/client registration storage
- `-- "http://127.0.0.1:4444"`: Upstream (ContextForge) specified as positional arg after `--` (uses `127.0.0.1`, not `localhost`)

### mcp-remote (Claude Desktop bridge)

Claude Desktop uses `mcp-remote` npm package to bridge stdio to the remote OAuth MCP server:

```
Claude Desktop
  |  stdio
  v
mcp-remote (Node.js)
  |  1. Dynamic Client Registration (/.idp/register)
  |  2. Opens browser for OAuth login
  |  3. Runs local callback server (port 9302)
  |  4. Exchanges auth code for token
  |  5. Caches token in ~/.mcp-auth/
  |  6. Proxies MCP requests with Bearer token
  v
Gateway (:8080)
```

Cache location: `~/.mcp-auth/mcp-remote-{version}/`

### Key OAuth Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/.well-known/oauth-authorization-server` | GET | OAuth metadata (discovery) |
| `/.well-known/oauth-protected-resource` | GET | Resource server metadata |
| `/.idp/register` | POST | Dynamic Client Registration |
| `/.idp/auth` | GET | Authorization endpoint |
| `/.idp/token` | POST | Token exchange |
| `/.auth/login` | GET/POST | Login page (password + Google) |
| `/.auth/password` | POST | Password authentication endpoint |

---

## Tool Catalog

### Overview

The gateway exposes ~70+ tools from 3 backends, bundled into a single virtual server called "fluid-intelligence". MCP clients see all tools as a flat list with name prefixes indicating the backend.

### Apollo MCP Server — Shopify GraphQL (7 tools active)

Apollo loads predefined `.graphql` operations from configured paths and provides 2 dynamic tools.

**Current config** (`mcp-config.yaml`): Only `/app/graphql/products` is in `operations.paths`. The other 25 operations exist on disk in `graphql/` but are **not loaded** because their directories are not configured (workaround for Apollo file-loading bug that silently drops complex types).

#### Active Operations (5 from files + 2 dynamic = 7 tools)

**Products (5)** — loaded from `/app/graphql/products/`:

| Operation | Type | Description |
|-----------|------|-------------|
| GetProducts | Query | List paginated products with filters, media, variants |
| GetProduct | Query | Get single product by ID with full variants (50 max) |
| CreateProduct | Mutation | Create product with title, description, variants, status |
| UpdateProduct | Mutation | Update product metadata (title, description, status, type, vendor, tags) |
| UpdateProductVariants | Mutation | Bulk update variants with price, compareAtPrice, inventory policy |

#### On-Disk Operations (25 — NOT loaded by Apollo; queries accessible via `execute` tool, mutations not currently accessible)

These `.graphql` files exist in the repo but their directories are not in Apollo's `operations.paths` config. The 5 on-disk queries (GetCustomers, GetCustomer, GetOrders, GetOrder, GetInventoryLevels) are accessible via the `execute` tool. The 20 on-disk mutations are NOT accessible — `execute` rejects mutations when no `mutation_mode` is configured (see Critical Note below and Known Limitation #1).

**Customers (5):**

| Operation | Type | Description |
|-----------|------|-------------|
| GetCustomers | Query | List paginated customers with email, phone, spent amount, tags |
| GetCustomer | Query | Get single customer by ID |
| CreateCustomer | Mutation | Create customer with name, email, phone, note, tags |
| UpdateCustomer | Mutation | Update customer email, phone, note, tags |
| AddCustomerAddress | Mutation | Add mailing address to customer |

**Orders (8):**

| Operation | Type | Description |
|-----------|------|-------------|
| GetOrders | Query | List paginated orders with status, totals, customer, line items |
| GetOrder | Query | Get single order by ID with full line item details |
| CreateDraftOrder | Mutation | Create draft order with line items, optional customer/email |
| CalculateDraftOrder | Mutation | Calculate totals for draft order (preview only, no persistence) |
| CompleteDraftOrder | Mutation | Convert draft order to real order |
| SendDraftOrderInvoice | Mutation | Email invoice for draft order to customer |
| MarkOrderAsPaid | Mutation | Mark order as paid |
| CancelOrder | Mutation | Cancel order with reason, restock, staff note |

**Fulfillments (1):**

| Operation | Type | Description |
|-----------|------|-------------|
| CreateFulfillment | Mutation | Create fulfillment for order with tracking info |

**Inventory (2):**

| Operation | Type | Description |
|-----------|------|-------------|
| GetInventoryLevels | Query | Get inventory by location with quantities |
| AdjustInventory | Mutation | Adjust inventory quantities across items/locations |

**Metafields (2):**

| Operation | Type | Description |
|-----------|------|-------------|
| SetMetafields | Mutation | Create/update metafields on any resource |
| DeleteMetafields | Mutation | Delete metafields by ID/namespace/key |

**Inventory Transfers (6):**

| Operation | Type | Description |
|-----------|------|-------------|
| CreateTransfer | Mutation | Create inventory transfer between locations |
| SetTransferItems | Mutation | Set/update line items in a transfer |
| MarkTransferReadyToShip | Mutation | Mark transfer ready for shipment |
| CreateShipment | Mutation | Create shipment within transfer with tracking |
| MarkShipmentInTransit | Mutation | Mark shipment in transit with date |
| ReceiveShipment | Mutation | Mark shipment received at destination |

**Discount Codes (1 — physically in `graphql/orders/`, logically separate):**

| Operation | Type | Description |
|-----------|------|-------------|
| CreateDiscountCode | Mutation | Create percentage-based discount code with date range |

#### Dynamic Tools (2)

| Tool | Description |
|------|-------------|
| **execute** | Execute arbitrary GraphQL queries at runtime (validated against schema) |
| **validate** | Validate GraphQL syntax without executing |

**Critical note**: The `execute` tool currently **rejects mutations** — it only accepts queries. Combined with only 5 product operations being loaded from files, this means only queries (GetProducts, GetProduct) and the 3 product mutations are accessible as tools. All other operations require either: (a) adding their directories to `mcp-config.yaml` paths, or (b) enabling `overrides.mutation_mode: explicit` for the execute tool.

### Shopify Dev MCP (~50+ tools)

Documentation and schema introspection tools from `@shopify/dev-mcp`:
- Search Shopify developer docs
- Introspect GraphQL schema
- Validate GraphQL queries
- Browse API changelogs
- Component and extension references

### Google Sheets (~17 tools)

CRUD operations via `mcp-google-sheets`:
- Read/write/create spreadsheets
- Append rows, query data
- Manage sheets within spreadsheets
- Service account authentication (headless)

---

## Deployment Architecture

### Two-Layer Docker Build

```
+---------------------------------------------+
|  Base Image (rebuild rarely, ~20 min)        |
|  deploy/Dockerfile.base                      |
|  cloudbuild-base.yaml                        |
|                                              |
|  +-- ContextForge 1.0.0-RC-2 (UBI 10)       |
|  +-- Apollo MCP Server v1.9.0 (Rust binary)  |
|  +-- mcp-auth-proxy v2.5.4 (Go, SHA-256 verified) |
|  +-- tini v0.19.0 (PID 1 init, SHA-256 verified) |
|  +-- Node.js (UBI 10 repo, unpinned), npm    |
|  +-- curl, jq, tar, gzip                    |
|  +-- uv v0.10.10 (Python package manager)    |
|                                              |
|  Registry: asia-southeast1-docker.pkg.dev/   |
|    junlinleather-mcp/junlin-mcp/             |
|    fluid-intelligence-base:latest            |
+---------------------------------------------+
                    ^
                    | FROM base:latest
                    |
+---------------------------------------------+
|  App Image (rebuild every change, ~5 sec)    |
|  deploy/Dockerfile                           |
|  cloudbuild.yaml                             |
|                                              |
|  +-- scripts/entrypoint.sh                   |
|  +-- scripts/bootstrap.sh                    |
|  +-- config/mcp-config.yaml                  |
|  +-- shopify-schema.graphql (98K lines)      |
|  +-- graphql/ (30 operation files)           |
|  +-- services/shopify_oauth/ (crypto module) |
|                                              |
|  Registry: .../fluid-intelligence:latest     |
+---------------------------------------------+
```

**Why two layers?**
- Base image changes: upgrading Apollo, ContextForge, or auth-proxy (~quarterly)
- App image changes: fixing queries, config tweaks, script changes (~daily during dev)
- Build time: 5s for app changes vs ~20 min for base rebuild
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

### CI/CD

- **Gateway**: Cloud Build trigger via GitHub Developer Connect on every push to `main` (runs `deploy/cloudbuild.yaml`)
- **Shopify OAuth**: Deployed manually via `gcloud builds submit --config=deploy/shopify-oauth/cloudbuild.yaml` (no auto-trigger — changes are rare)

---

## Startup Sequence

| Step | Time | What Happens |
|------|------|--------------|
| T+0s | 0s | Validate all required env vars (fail-fast) |
| T+0s | 0s | Shopify token: read from Cloud SQL, decrypt, validate `shp` prefix |
| T+1s | 1s | Apollo starts (:8000), loads schema + operations |
| T+3s | 2s | `start_and_verify` confirms Apollo alive (PID liveness check + 2s sleep) |
| T+5s | 2s | ContextForge starts (:4444), connects to PostgreSQL |
| T+7s | 2s | `start_and_verify` confirms ContextForge process alive |
| T+7s | 2s | dev-mcp (:8003) starts + `start_and_verify` (sequential — completes before sheets) |
| T+9s | 2s | google-sheets (:8004) starts + `start_and_verify` (sequential — waits for dev-mcp) |
| T+11s | 2-5s typical, 120s timeout | ContextForge `/health` poll loop waits for DB + Alembic migrations |
| T+12s | 0s | mcp-auth-proxy starts (:8080), receives EXTERNAL_URL via --external-url flag (already validated by entrypoint.sh at T+0) |
| T+14s | 2s | `start_and_verify` confirms auth-proxy alive |
| T+14s | 1s | Bootstrap: register backends, discover tools, create virtual server |
| T+15-20s | — | Cloud Run TCP startup probe succeeds on :8080 |

**Total cold start: ~15-20s** (with `--cpu-boost`)

### Bootstrap Registration Pipeline

1. Generate JWT token (10 min expiry) via ContextForge Python venv
2. Wait for Apollo bridge (60s timeout, check PID + SSE probe)
3. Delete stale Apollo registration (if any), then register with ContextForge (`POST /gateways`)
4. Wait for dev-mcp bridge (120s timeout — npx install can be slow)
5. Delete stale dev-mcp registration, then register (`POST /gateways`)
6. Wait for google-sheets bridge (60s timeout, healthz only — **note**: lacks SSE probe unlike dev-mcp, see V4 Design Directions)
7. Delete stale google-sheets registration, then register (`POST /gateways`)
8. Poll tool discovery until count stabilizes (3 consecutive equal readings — `stable >= 2` in bootstrap.sh: `stable` increments when TOOL_COUNT equals prev_count and is >0; resets to 0 otherwise. Reaching stable=2 requires two successive matches, i.e. three readings that all agree)
9. Create virtual server "fluid-intelligence" bundling ALL discovered tools

**Without a virtual server, MCP `tools/list` returns empty.**

---

## Cloud Run Configuration

### Gateway (fluid-intelligence)

| Setting | Value | Rationale |
|---------|-------|-----------|
| Region | `asia-southeast1` | Closest to user (Singapore) |
| CPU | 2 vCPU | Handles 5 concurrent processes |
| Memory | **4Gi** | 5 processes + 98K-line schema. 2Gi caused OOM. |
| `--no-cpu-throttling` | Yes | **Required** — background processes freeze without it |
| `--cpu-boost` | Yes | Faster cold starts |
| `--min-instances` | 0 | Scale to zero when idle |
| `--max-instances` | 1 | In-memory auth state prevents horizontal scaling |
| `--allow-unauthenticated` | Yes | Public access — auth handled by mcp-auth-proxy, not Cloud Run IAM |
| Startup probe | TCP :8080, 48x5s | 240s timeout for startup |
| Timeout | 300s | Request timeout |

### OAuth Service (shopify-oauth)

| Setting | Value | Rationale |
|---------|-------|-----------|
| Region | `asia-southeast1` | Same region as gateway |
| CPU | 1 vCPU | Minimal — handles only OAuth flows |
| Memory | 256Mi | Minimal — FastAPI only |
| `--min-instances` | 0 | Scale to zero (used rarely) |
| `--max-instances` | 2 | Stateless — can scale |
| Allow unauthenticated | Yes | Shopify initiates OAuth callbacks |

---

## Database

- **Instance**: Cloud SQL PostgreSQL, `junlinleather-mcp:asia-southeast1:contextforge`
- **Tier**: db-f1-micro (shared vCPU, 0.6GB RAM, ~$8/mo)
- **Connection**: Unix socket via Cloud SQL Proxy (`/cloudsql/...`)
- **User**: `contextforge`, Database: `contextforge`
- **Schema**: ContextForge tables managed by Alembic (auto-migrates on startup, advisory lock prevents concurrent runs)
- **Connection string**: `DB_PASSWORD` is URL-encoded (Python `urllib.parse.quote()`) before interpolation into `DATABASE_URL` to handle special chars (`@`, `?`, `/`, `%`)

### Connection Budget

Cloud SQL db-f1-micro has a **max connection limit of 25**. Two Cloud Run services share this instance:

| Service | Max Instances | Connections per Instance | Max Total |
|---------|--------------|------------------------|-----------|
| Gateway (ContextForge) | 1 | ~6 (1 entrypoint token fetch + 5 `DB_POOL_SIZE`) | ~6 |
| OAuth service | 2 | ~2-4 (raw `psycopg2.connect()` per request, no pool) | ~8 |
| **Total** | | | **~14** |
| **Headroom** | | | **~11** |

**Warning**: Changing `DB_POOL_SIZE`, `max-instances`, or adding new DB-connected services requires re-evaluating this budget. Exceeding 25 connections causes intermittent `too many connections` errors that are hard to diagnose. *(Mirror Polish Batch 10, R98)*

### Custom Tables

**`shopify_installations`** (managed by shopify-oauth service):

| Column | Type | Description |
|--------|------|-------------|
| id | SERIAL | Primary key |
| shop_domain | TEXT UNIQUE | e.g., `junlinleather-5148.myshopify.com` |
| shop_id | BIGINT | Shopify numeric shop ID |
| access_token_encrypted | TEXT | AES-256-GCM encrypted access token |
| scopes | TEXT | Granted OAuth scopes |
| status | TEXT | `active` or `uninstalled` |
| installed_at | TIMESTAMPTZ | First install time |
| updated_at | TIMESTAMPTZ | Last update time |

Indexes on `shop_domain` and `status`.

---

## Secrets & Environment Variables

### GCP Secret Manager Secrets

| Secret Name | Maps To | Purpose |
|-------------|---------|---------|
| `shopify-client-id` | `SHOPIFY_CLIENT_ID` | Shopify app client ID |
| `shopify-client-secret` | `SHOPIFY_CLIENT_SECRET` | Shopify app client secret |
| `mcp-auth-passphrase` | `AUTH_PASSWORD` | Password auth for CLI clients |
| `mcp-jwt-secret` | `JWT_SECRET_KEY` | JWT signing for ContextForge API |
| `google-oauth-client-id` | `GOOGLE_OAUTH_CLIENT_ID` | Google OAuth for browser login |
| `google-oauth-client-secret` | `GOOGLE_OAUTH_CLIENT_SECRET` | Google OAuth secret |
| `google-sheets-credentials` | `CREDENTIALS_CONFIG` | Service account JSON for Sheets |
| `db-password` | `DB_PASSWORD` | Cloud SQL password |
| `shopify-token-encryption-key` | `SHOPIFY_TOKEN_ENCRYPTION_KEY` | AES-256-GCM key (base64-encoded 256-bit) for token encryption. **Caution**: Not validated at startup. If missing or invalid, token decryption raises an exception that IS logged (entrypoint.sh captures the Python stderr and echoes it before falling back). Falls back to client_credentials (24h expiry tokens). *(Mirror Polish Batch 11, R102; corrected Batch 39, R392)* |

### Environment Variables

| Variable | Value | Notes |
|----------|-------|-------|
| `SHOPIFY_STORE` | `junlinleather-5148.myshopify.com` | Shopify store domain |
| `SHOPIFY_API_VERSION` | `2026-01` | Shopify API version |
| `MCG_PORT` | `4444` | ContextForge listen port (NOT `PORT`). Set directly in `cloudbuild.yaml` as `MCG_PORT=4444` AND re-exported by entrypoint.sh from `MCPGATEWAY_PORT`. Both sources agree on value `4444`. |
| `MCG_HOST` | `0.0.0.0` | ContextForge bind address |
| `MCPGATEWAY_PORT` | `4444` | Primary input for ContextForge port; entrypoint.sh reads this and exports `MCG_PORT` and `CONTEXTFORGE_PORT` from it. |
| `EXTERNAL_URL` | `fluid-intelligence-...run.app` | OAuth redirect base |
| `GOOGLE_ALLOWED_USERS` | `ourteam@junlinleather.com` | Google OAuth allowlist |
| `PLATFORM_ADMIN_EMAIL` | `admin@junlinleather.com` | ContextForge admin |
| `GUNICORN_WORKERS` | `1` | Single worker (resource constrained) |
| `AUTH_REQUIRED` | `false` | Disabled — auth-proxy handles externally |
| `CACHE_TYPE` | `database` | PostgreSQL-backed cache |
| `TRANSPORT_TYPE` | `all` | SSE + StreamableHTTP enabled |
| `DB_USER` | `contextforge` | Cloud SQL database user |
| `DB_NAME` | `contextforge` | Cloud SQL database name |
| `DB_POOL_SIZE` | `5` | ContextForge connection pool size |
| `HOST` | `0.0.0.0` | Additional bind address (gunicorn) |
| `HTTP_SERVER` | `gunicorn` | ContextForge ASGI server |
| `MCPGATEWAY_UI_ENABLED` | `false` | Disable admin UI |
| `MCPGATEWAY_ADMIN_API_ENABLED` | `true` | Enable admin API (for bootstrap registration) |
| `SSRF_PROTECTION_ENABLED` | `true` | SSRF protection on (blocks private/localhost access by default; exemptions below re-enable for same-container backends) |
| `SSRF_ALLOW_LOCALHOST` | `true` | Required — backends are on localhost (:8000/:8003/:8004) |
| `SSRF_ALLOW_PRIVATE_NETWORKS` | `true` | Required — Cloud SQL proxy is on private network |
| `PYTHONUNBUFFERED` | `1` | Immediate log output (no buffering) |
| `PORT` | `8080` | Cloud Run injected (not in cloudbuild.yaml), **immutable** |
| `AUTH_ENCRYPTION_SECRET` | (derived) | ContextForge encryption secret. Derived by entrypoint.sh from `JWT_SECRET_KEY` (`export AUTH_ENCRYPTION_SECRET="${JWT_SECRET_KEY}"`). Not set in cloudbuild.yaml — set at runtime only. *(Mirror Polish Batch 45, R452)* |
| `PLATFORM_ADMIN_PASSWORD` | (derived) | ContextForge admin password. Derived by entrypoint.sh from `AUTH_PASSWORD` (`export PLATFORM_ADMIN_PASSWORD="${AUTH_PASSWORD}"`). Not set in cloudbuild.yaml — set at runtime only. *(Mirror Polish Batch 45, R452)* |

### OAuth Service Environment Variables

| Variable | Value | Notes |
|----------|-------|-------|
| `CALLBACK_URL` | `https://shopify-oauth-1056128102929.asia-southeast1.run.app/auth/callback` | OAuth redirect URI |
| `SHOPIFY_SCOPES` | `read_products:write_products:...` (colon-separated) | Requested OAuth scopes |
| `SHOPIFY_API_VERSION` | `2026-01` | API version for shop.json calls |
| `DB_USER` | `contextforge` | Cloud SQL user |
| `DB_NAME` | `contextforge` | Cloud SQL database |

Secrets: `SHOPIFY_CLIENT_ID`, `SHOPIFY_CLIENT_SECRET`, `DB_PASSWORD`, `SHOPIFY_TOKEN_ENCRYPTION_KEY` (same GCP Secret Manager secrets as gateway).

---

## Cost Analysis

### Monthly GCP Costs (Estimated)

Assumes **2-4 hours/day active use** (dev/personal workload). With `min-instances=0`, the gateway scales to zero when idle — no CPU/memory charges during idle periods. `--no-cpu-throttling` means CPU is charged at "always allocated" rates while an instance is active.

| Resource | Configuration | Estimated Cost |
|----------|--------------|----------------|
| Cloud Run (gateway) | 2 vCPU, 4Gi, min=0, no-cpu-throttling | ~$5-15/mo |
| Cloud Run (shopify-oauth) | 1 vCPU, 256Mi, min=0 | ~$0.50/mo |
| Cloud SQL | db-f1-micro (shared vCPU, 0.6GB RAM) | ~$8/mo |
| Artifact Registry | Container images (~2GB) | ~$0.50/mo |
| Cloud Build | ~5 builds/day (app: default e2-medium; base: E2_HIGHCPU_8) | ~$2-5/mo |
| Secret Manager | 9 secrets, ~100 accesses/day | ~$0.10/mo |
| **Total** | | **~$16-29/mo** |

### Cost Red Flags

- **Do NOT** set `max-instances` > 1 unless auth state is externalized
- **Do NOT** use expensive Cloud Build machines unless rebuilding base image
- **Do NOT** rebuild base image for config/script changes
- **Do NOT** enable autoscaling without first externalizing session state

---

## Testing

### End-to-End Tests (`scripts/test-e2e.sh`)

Requires a deployed service. Set `AUTH_PASSWORD` env var or have `gcloud` configured for Secret Manager access.

**Covers**: Service reachability, OAuth 2.1 discovery (`.well-known/oauth-authorization-server`), OAuth authorization flow, auth negative tests (invalid token, no token), MCP protocol handshake (`initialize` → `notifications/initialized` → `tools/list`), virtual server tool listing, tool call execution (Shopify query), MCP negative tests (invalid JSON-RPC), and resources/prompts endpoints.

**Does NOT cover**: Health endpoint testing, SSE transport (tests Streamable HTTP `/mcp` only), graceful shutdown behavior, backend-specific error handling, rate limiting, concurrent connections.

### Unit Tests (`scripts/test-unit.sh`)

Runs locally — no deployed service needed.

**Covers**: Environment variable validation patterns, regex correctness, CloudBuild config syntax, and `.env.example` completeness checks.

**Known gaps**: No tests for `entrypoint.sh` process orchestration logic, `bootstrap.sh` registration flow, or `crypto.py` encryption/decryption. *(Mirror Polish Batch 12, R113)*

---

## Known Limitations

> **Known Limitations** = external constraints or upstream bugs we accept and work around.
> **Architecture Issues** (next section) = design problems we plan to fix.

### 1. Apollo Tool Surface (File-Loading Bug + Query-Only Execute)

Apollo MCP Server v1.9.0 has two compounding issues:

1. **File-loading bug**: Silently drops `.graphql` operations from directories with complex types (Order, Customer, etc.). Only `/app/graphql/products` is configured as a workaround — 5 product tools load, 25 other operations exist on disk but are not loaded.

2. **Execute tool is query-only**: No `mutation_mode` configured, so the `execute` dynamic tool rejects mutations. Only 3 product mutations (CreateProduct, UpdateProduct, UpdateProductVariants) work as individual tools.

**Net effect**: 7 active Apollo tools (5 product operations + execute + validate). AI clients can read any data via `execute` but can only write product data. See Architecture Issue #3 for the planned fix.

### 2. Single Instance Scaling

In-memory auth state in mcp-auth-proxy prevents horizontal scaling. `max-instances` must remain at 1.

**To scale**: Externalize session state to Redis or PostgreSQL.

### 3. ContextForge StreamableHTTP Bug (MCP Protocol Frozen on Legacy SSE)

ContextForge 1.0.0-RC-2 fails the MCP StreamableHTTP initialize handshake. All backends must use SSE transport via stdio->SSE bridges (`mcpgateway.translate`). No migration plan exists for when MCP clients require Streamable HTTP. Protocol version references are inconsistent across the codebase (`2024-11-05` in e2e tests vs `2025-11` in architecture doc prose). *(Consolidated from KL#14, Mirror Polish Batch 4 R31, Batch 14 R132)*

### 4. Claude.ai OAuth Bug

Claude.ai web/Desktop cannot complete OAuth with custom MCP servers (as of March 2026). Use Claude Code CLI or mcp-remote bridge instead. Tracked: [#5826](https://github.com/anthropics/claude-code/issues/5826).

### 5. `uv pip install` Corrupts ContextForge Venv

Installing packages into `/app/.venv/` with `uv pip install` breaks the `mcpgateway` CLI entry point script. Workaround: use direct `main()` invocation.

### 6. No Observability/Tracing Configured

ContextForge supports OpenTelemetry (OTLP) for Cloud Trace integration, but no `OTEL_*` environment variables are configured in the deployment. Logs are plain text to stdout (`PYTHONUNBUFFERED=1`). No structured logging, distributed tracing, or metrics collection is active.

### 7. SSE Session Timeout (5 Minutes)

Cloud Run `--timeout=300` applies to SSE connections. MCP SSE sessions are long-lived HTTP responses — any session open >5 minutes is forcibly terminated by Cloud Run with no warning. **Fix**: Increase to `--timeout=3600` (Cloud Run maximum, 1 hour). AI clients must handle reconnection for sessions >1 hour. *(Mirror Polish Batch 7, R64)*

### 8. Identity Lost at Proxy Boundary (Elevated to Architecture Issue #12)

Elevated to Architecture Issue #12 due to severity — see that entry for full details. In summary: mcp-auth-proxy validates OAuth tokens but does NOT forward user identity to ContextForge. All requests appear anonymous. Directly contradicts the product's "per-user identity" value proposition. *(Mirror Polish Batch 3 R23, Batch 9 R83, consolidated Batch 14 R139)*

### 9. No Inner-Layer Timeouts (Latency Budget Gap)

No timeouts configured at inner layers: auth-proxy→ContextForge, ContextForge→Apollo, Apollo→Shopify. A 30-second Shopify hang propagates silently through the entire chain. Combined with no metrics (Issue #8), this is invisible. Client timeout + retry can create duplicate in-flight mutations. *(Mirror Polish Batch 9, R81)*

### 10. Shopify OAuth Scopes (Resolved)

Previously requested 18 scopes (including `read_reports`, `read_product_listings`, `write_product_listings` with no corresponding operations). Trimmed to 15 scopes in `deploy/shopify-oauth/cloudbuild.yaml` as part of Mirror Polish Batch 7, R62. **Note**: Existing installations retain the originally granted scopes until the app is reinstalled. *(Resolved — Mirror Polish Batch 7 R62, verified Batch 14 R131)*

### 11. CORS Defaults to localhost

ContextForge `APP_DOMAIN` not set — defaults to `http://localhost`. Blocks browser-based MCP clients and admin UI (if enabled). Low priority today (all clients are non-browser). *(Mirror Polish Batch 4, R38)*

### 12. AES-GCM Encryption Without AAD Binding

`crypto.py` uses `AESGCM.encrypt(nonce, plaintext, None)` — the `None` AAD (Associated Authenticated Data) means encrypted tokens are not cryptographically bound to the `shop_domain` they belong to. An attacker with database write access could swap `access_token_encrypted` values between rows, and decryption would succeed without error. Current threat model accepts this: database write access already constitutes a full compromise. Future revision should use `shop_domain` as AAD to bind ciphertext to its row. *(Mirror Polish Batch 10, R92)*

### 13. GDPR Webhook Topic Not Validated

The GDPR webhook handler at `/webhooks/gdpr/{topic}` accepts any string as the `{topic}` path parameter and returns 200. Only `customers-data-request`, `customers-redact`, and `shop-redact` are valid Shopify topics. HMAC verification prevents unauthorized access, but a topic allowlist check would improve defense-in-depth and align code with documented behavior. *(Mirror Polish Batch 10, R97)*

### 14. (Consolidated into Known Limitation #3)

*(Merged — see KL#3 above. Mirror Polish Batch 14, R132)*

---

## Architecture Issues

These are known architectural problems identified during operation. They represent areas where the current design is suboptimal and should be addressed.

### Issue 1: Token Baked at Startup (No Hot-Reload)

**Problem**: `entrypoint.sh` reads the Shopify access token from Cloud SQL once during startup and exports it as `SHOPIFY_ACCESS_TOKEN` env var. Apollo reads this env var once. Any token change (app reinstall, scope change, token rotation) requires a full Cloud Run restart (new revision deployment).

**Impact**: Every Shopify app reinstall requires `gcloud run deploy` to force a cold restart. `gcloud run services update` with env var changes doesn't reliably force a new container.

**Root cause**: Apollo MCP Server reads config at startup — it has no mechanism for env var or config hot-reload.

**Desired state**: Token changes should take effect without gateway restart.

### Issue 2: Connection Fragility (mcp-remote)

**Problem**: Every gateway restart invalidates mcp-remote's cached OAuth tokens. mcp-remote attempts re-authentication but its local callback server (port 9302) often fails due to stale lock files from previous sessions.

**Impact**: Users must manually clear `~/.mcp-auth/` cache and restart Claude Desktop after every gateway restart.

**Root cause**: mcp-remote stores lock files with PID and port information. When the gateway restarts and invalidates the token, mcp-remote tries to re-auth but may conflict with stale processes.

**Desired state**: Token refresh should be transparent. Gateway restarts should not require manual client-side cleanup.

### Issue 3: No Mutation Support Through Gateway

**Problem**: Apollo's `execute` tool rejects mutations. Only 5 product operations are loaded from files (3 of which are mutations), so only product mutations work. The other 25 operations (including 20 mutations) exist on disk but are not in Apollo's config paths.

**Impact**: AI clients can create/update products but cannot create customers, orders, fulfillments, inventory adjustments, etc. — despite having the OAuth scopes.

**Root cause**: (1) Apollo's `execute` tool defaults to query-only when no `mutation_mode` is configured. (2) Only `/app/graphql/products` is in `mcp-config.yaml` paths due to the file-loading bug with complex types.

**Desired state**: AI clients should be able to execute both queries and mutations through the gateway.

### Issue 4: Flat Tool List (No Grouping)

**Problem**: The gateway bundles ~70+ tools from 3 backends into a single flat list. MCP protocol has no native tool categories or namespacing. AI clients see tools like `apollo-shopify-getproducts`, `shopify-dev-search-docs`, `google-sheets-read-sheet` as peers with no hierarchy.

**Impact**: AI clients waste context window listing and reasoning about tools. No way to "browse" tool categories or discover related tools.

**Root cause**: ContextForge's virtual server design bundles ALL tools. MCP protocol spec (2025-11) has no `categories` field on tools.

**Desired state**: Tools should be organized by domain/function with some form of grouping or progressive disclosure.

### Issue 5: No Liveness Probe

**Problem**: Cloud Run only has a startup probe (TCP :8080). No liveness probe configured. If any process deadlocks after startup (ContextForge waiting on DB lock, Apollo hanging on Shopify API timeout), Cloud Run never detects it.

**Impact**: Container appears healthy to Cloud Run indefinitely while being unable to serve requests. Users experience timeouts with no automatic recovery.

**Root cause**: cloudbuild.yaml only configures --startup-probe, not --liveness-probe. Cloud Run supports HTTP liveness probes but none is set.

**Desired state**: HTTP liveness probe that checks auth-proxy responsiveness AND ContextForge /health endpoint.

### Issue 6: No Graceful Degradation (Crash Cascade)

**Problem**: entrypoint.sh uses `wait -n` on all 5 PIDs. If ANY process exits (even google-sheets), the entire container dies and all services restart. A non-critical backend crash takes down the entire gateway.

**Impact**: Google Sheets bridge crash kills Shopify tools. dev-mcp crash kills everything. No partial service — it's all or nothing.

**Root cause**: Single-process-group monitoring with `wait -n` treats all processes as equally critical. No distinction between core services (auth-proxy, ContextForge) and optional backends (sheets, dev-mcp).

**Desired state**: Core services (auth-proxy, ContextForge, Apollo) are critical — their crash restarts the container. Optional backends (sheets, dev-mcp) should be monitored but their crash should log a warning and attempt restart, not kill the gateway.

### Issue 7: Secrets Exposed in /proc/cmdline

**Problem**: mcp-auth-proxy v2.5.4 receives --password and --google-client-secret as CLI arguments. These are visible in /proc/{pid}/cmdline to any process in the container.

**Impact**: Any process (or container introspection tool) can read the auth password and Google OAuth client secret. Risk is bounded by container isolation (all processes run as UID 1001).

**Root cause**: mcp-auth-proxy v2.5.4 only supports secrets via CLI arguments — no env var or config file input.

**Desired state**: Secrets passed via environment variables or mounted files. Requires upstream mcp-auth-proxy support.

### Issue 8: No Application Metrics

**Problem**: No Prometheus endpoint, no custom Cloud Monitoring metrics, no counters or histograms. Zero visibility into tool call rates, error rates, request latencies, or backend health at the application level.

**Impact**: Cannot detect degradation (slow Apollo responses, increased error rates) until users report failures. No data for capacity planning or performance optimization.

**Root cause**: ContextForge supports OpenTelemetry but OTEL_* env vars are not configured. No metrics collection from auth-proxy, Apollo, or bridges.

**Desired state**: OTEL metrics exported to Cloud Monitoring. Key metrics: tool call count, latency percentiles, error rate by backend, active connections.

### Issue 9: Bash Orchestrator Complexity

**Problem**: entrypoint.sh (321 lines) and bootstrap.sh (284 lines) implement process orchestration, health checking, retry logic, JWT generation, HTTP parsing, and error handling in bash. This is untestable, fragile, and hard to extend.

**Impact**: Adding a new backend requires careful PID tracking and signal handling changes across both scripts. No unit tests exist for infrastructure scripts. Debugging requires deploying to Cloud Run.

**Root cause**: Organic growth from POC. Bash was the simplest initial choice for process management.

**Desired state**: Process orchestration in a language with proper testing (Python supervisor, or container-native sidecar pattern). Bootstrap logic as a testable Python module.

### Issue 10: No Encryption Key Rotation

**Problem**: SHOPIFY_TOKEN_ENCRYPTION_KEY is a single static AES-256-GCM key. No mechanism to rotate it without re-encrypting all tokens in the database. JWT_SECRET_KEY rotation instantly invalidates all active sessions with no rollover period.

**Impact**: Key compromise requires emergency rotation affecting all stored tokens. Routine rotation (compliance requirement) has no automated path.

**Root cause**: crypto.py uses a single key with no key versioning. No key ID stored alongside ciphertext.

**Desired state**: Key versioning — store key ID with each encrypted token. Support decrypting with old key, encrypting with new key. Graceful JWT key rollover (accept old + new for a transition period).

### Issue 11: Unpinned Node.js/npm in Base Image (Supply Chain)

**Problem**: Dockerfile.base installs Node.js and npm via `microdnf install -y nodejs npm` with no version pinning. A major Node.js version bump during base image rebuild could break @shopify/dev-mcp compatibility.

**Impact**: Non-reproducible builds. Base image rebuilt today may produce different results than one built last month. Silent breakage if Node.js 22→24 drops APIs that dev-mcp depends on.

**Root cause**: UBI 10 repo provides a single nodejs package; version depends on repo state at build time.

**Desired state**: Pin Node.js major version (e.g., nodejs20) or use multi-stage build with explicit Node.js version.

### Issue 12: Identity Loss at Proxy Boundary

**Problem**: mcp-auth-proxy authenticates users via OAuth but does NOT forward user identity to ContextForge. No `--forward-headers`, `--user-header`, or equivalent flag exists in auth-proxy v2.5.4. `AUTH_REQUIRED=false` means ContextForge sees all requests as anonymous.

**Impact**: Directly contradicts the product's core value proposition — "per-user identity." All audit trail entries are anonymous. RBAC roles exist but have no user to bind to. Per-user rate limiting is impossible. Multi-tenant operations would be unsafe.

**Root cause**: (1) auth-proxy v2.5.4 doesn't expose a user-identity forwarding mechanism. (2) ContextForge's `AUTH_REQUIRED=false` disables all identity-aware features.

**Cascading dependencies**: Identity propagation requires the `http_auth_resolve_user` plugin hook in ContextForge — but plugin stability is uncertain in RC-2, creating a phase dependency inversion (see V4 Design Directions).

**Desired state**: auth-proxy forwards `X-Forwarded-User` header. ContextForge plugin consumes it and maps to internal user. All tool calls have per-user attribution in audit trail.

*(Mirror Polish Batch 3 R23, Batch 9 R83. Elevated to Architecture Issue due to severity.)*

---

## Risk Register

Comprehensive catalog of identified risks beyond the Architecture Issues above. Sorted by severity.

| # | Risk | Severity | Category | Status |
|---|------|----------|----------|--------|
| R1 | No webhook replay protection (HMAC verified, but no timestamp/nonce check on webhook payloads) | Medium | Security | Accepted — Shopify HMAC is sufficient for current threat model |
| R2 | No rate limiting on OAuth endpoints (/auth/install, /auth/callback) | Medium | Security | Accepted — HMAC prevents replay; brute-force is infeasible |
| R3 | No alerting system (silent failures until user reports). Depends on Architecture Issue #8 (no metrics). | Medium | Observability | Open — needs Cloud Monitoring alert policies |
| R4 | JWT 10-min expiry race during slow bootstrap (dev-mcp 120s wait + registration) | Medium | Reliability | Accepted — low probability; bootstrap completes in ~15s typical |
| R5 | Bridge crash after ready-check (SSE returns 200, process dies before tools ready) | Medium | Reliability | Accepted — wait-n catches the crash within seconds |
| R6 | **Structurally unsafe rollback** — Alembic forward-only migrations mean old revision code runs against new schema. If migration adds/renames a column, rollback revision's SQLAlchemy models won't match. No expand-contract migration discipline. ContextForge controls migrations — we can't enforce safety. | **High** | Operational | Open — requires expand-contract migration strategy (add-only, no renames/drops, separate cleanup after confirmed rollforward) |
| R7 | No unit/integration tests for entrypoint.sh and bootstrap.sh. Related: Architecture Issue #9 (bash orchestrator complexity), Testing section known gaps. | Medium | Structural | Open — bash scripts are effectively untestable |
| R8 | Tool discovery race (slow backend's tools missing from virtual server). Convergence check accepts any count ≥1 stable for 2 iterations — no minimum floor. dev-mcp npx install (30-60s) may not finish before convergence stabilizes. Expected: ~74+ tools (Apollo 7 + dev-mcp ~50+ + sheets ~17). | Medium | Reliability | Partially mitigated — convergence check exists but needs minimum tool count floor (~70). Per-backend verification is Phase 2. |
| R9 | ContextForge health timeout budget tight (120s of 240s startup budget) | Medium | Reliability | Accepted — typical health check completes in 2-5s |
| R10 | Plaintext Shopify token in SHOPIFY_ACCESS_TOKEN env var (readable in /proc/environ) | Medium | Security | Accepted — container isolation bounds the risk |
| R11 | Incomplete signal handling (no SIGHUP for config reload) | Low | Structural | Accepted — no config hot-reload mechanism exists yet |
| R12 | Webhook JSON parse errors not logged (returns 400 but no diagnostic log) | Low | Observability | Open — easy fix |
| R13 | GDPR webhook handlers return 200 but perform no actual data operations (erasure, portability). Compliance gap if store processes EU customer data. | **High** | Compliance | Open — implement real data erasure/portability or document exemption rationale *(Batch 5, R48)* |
| R14 | Artifact Registry retains all pushed images indefinitely (~150 images/month). Unbounded cost accumulation. | Low | Cost | Open — configure `gcloud artifacts repositories set-cleanup-policies` to retain last 10 images *(Batch 7, R67)* |
| R15 | Phase dependency inversion: Phase 1 identity propagation and circuit breaker both require ContextForge plugins, but plugins deferred to Phase 3 (RC-2 instability). Phase 2 RBAC and per-user rate limiting also blocked by Phase 3. | **High** | Structural | Open — phases must be restructured around plugin stability boundary *(Batch 9, R90)* |
| R16 | Container exit code always 1 regardless of child process exit code. OOM (137) vs crash distinction lost for Cloud Run alerting. | Low | Observability | Open — capture and propagate first child exit code *(Batch 9, R88)* |
| R17 | No memory budget breakdown by process. 4Gi stable but per-process RSS unknown. Future cost optimization has no safe floor guidance. | Low | Operational | Open — measure steady-state RSS per process *(Batch 9, R89)* |

---

## V4 Design Directions (Mirror Polish Corrections)

> Accumulated corrections from 48 batches of Mirror Polish design review (~480 review angles, ~93+ issues found). These represent verified design gaps that must be addressed in the v4 "Magnum Opus" architecture. Organized by design theme.

### Phase Structure (Critical — R90, R5, R23)

**Problem**: The current Phase 1/2/3 structure has a circular dependency. Phase 1 assigns identity propagation and circuit breaker — both require the ContextForge plugin API. But plugins are explicitly deferred to Phase 3 due to RC-2 instability. Phase 2 RBAC and per-user rate limiting also require plugins. The "plugins are Phase 3" decision invalidates Phase 1 and Phase 2 timelines.

**Resolution**: Restructure phases around the plugin stability boundary:

- **Phase 1** (no plugins needed): ~~X-Forwarded-User~~ (deferred — requires auth-proxy investigation), OTEL env vars **DONE**, ~~VS stability proxy~~ (deferred — Phase 2), tool descriptions (ongoing), bootstrap concurrency lock **DONE**, liveness probe **DONE**, Alembic safety (docs only), nested timeouts **DONE** (Apollo 30s; middle layers deferred), minimum tool count floor **DONE**, AUTH_ENCRYPTION_SECRET decoupled **DONE**, GDPR webhooks implemented **DONE**, Cloud Run timeout 3600s **DONE**, google-sheets SSE probe **DONE**.
- **Phase 2** (after ContextForge 1.0.0 stable OR after testing RC-2 built-in plugins in staging): Identity attribution via plugin, circuit breaker (built-in plugin), per-user rate limiting, PII filter, RBAC enforcement.
- **Phase 3** (multi-tenant): Token proxy, operation-level policy, separate Cloud Run services, custom plugin development.

**Key distinction**: "Enabling existing built-in plugins" (rate limiter, circuit breaker — shipped with ContextForge) is lower risk than "writing custom plugins" (which use the newly decoupled plugin API with 6 breaking changes). Phase 2 enables built-ins; Phase 3 writes custom.

### Identity Propagation (Critical — R23, R83)

**Problem**: User identity is consumed by auth-proxy and NOT forwarded. ContextForge (`AUTH_REQUIRED=false`) sees all requests as anonymous. Audit trail has no per-user attribution. DCR client registrations lost on restart (ephemeral `/app/data`).

**Correction**: Elevated to Architecture Issue #12. Two-phase approach:
1. auth-proxy forwards `X-Forwarded-User` header (investigate v2.5.4 capability)
2. ContextForge consumes header via `http_auth_resolve_user` plugin (blocked on plugin stability)

### Latency Budget (High — R81)

**Problem**: No timeouts at any inner layer. Shopify 30s hangs propagate silently. Client timeout + retry creates duplicate in-flight mutations. No documented latency budget or SLA. No metrics (Issue #8) makes this invisible.

**Correction**: Configure nested timeouts:
- Apollo → Shopify: **30s**
- ContextForge → Apollo: **35s**
- auth-proxy → ContextForge: **40s**
- Cloud Run: **300s** (outer, request timeout)

Expected latency: ~300ms–2s typical, ~30s worst case. Add request-level timeout headers for observability.

### Resilience Strategy (R13, R16, R55)

**Circuit breaker**: Must be a ContextForge built-in plugin (not custom). Test in staging before production. Requires Phase 2.

**Graceful degradation**: Distinguish core (auth-proxy, ContextForge, Apollo) from optional (sheets, dev-mcp) backends. Core crash = container restart. Optional crash = log warning + attempt in-process restart.

**Alembic safety**: All migrations must be backward-compatible (add-only columns, no renames/drops in same migration, separate cleanup migration after confirmed rollforward). This is critical for rollback safety (R6).

### Data Protection (R22, R48)

**PII leakage**: Customer PII (email, phone, address) passes through ContextForge logs, OTEL traces, and tool responses with no filtering. Phase 2: enable PII scrubbing plugin.

**GDPR compliance**: Webhook handlers (`customers/data_request`, `customers/redact`, `shop/redact`) return 200 but perform no actual operations. **v3 production bug** — must either implement real data operations or document exemption rationale.

### Shopify API Quota (R24, R84)

**GraphQL cost explosion**: `execute` tool with no cost guard allows AI to compose expensive queries (e.g., `products(first:250){variants(first:250){...}}`). No cost estimation, no throttle point limit enforcement.

**Rate limit response propagation**: Shopify 429 (throttled) responses are consumed by Apollo and returned as opaque MCP JSON-RPC errors. Retry-After and cost headers are discarded at the stdio/SSE bridge boundary. Client cannot distinguish 429 from other errors.

**Correction**: Phase 1: Document as known limitation — AI clients should implement conservative retry. Phase 2: Apollo includes cost/throttle info in MCP error details. Phase 3: ContextForge plugin adds retry hints.

### VS & Tool Stability (R17, R82)

**UUID churn**: Bootstrap deletes and re-creates the virtual server and gateway registrations on every container restart. VS UUID and all tool UUIDs change. External references break.

**associated_tools immutability**: ContextForge VS `associated_tools` field cannot be updated via PATCH — must delete and recreate the entire VS to change tool assignments.

**Bootstrap probe gap**: google-sheets bridge wait uses `healthz` only — no SSE endpoint probe (unlike dev-mcp which probes both healthz and SSE). This means the bridge HTTP server can be up while the underlying MCP subprocess is not yet connected. Phase 1: Add SSE probe to google-sheets wait (same pattern as dev-mcp). *(Mirror Polish Batch 14, R135)*

**Correction**: Phase 1: Add minimum expected tool count (~70) to bootstrap convergence check, add SSE probe to google-sheets wait. Phase 2: Implement stable VS endpoint via named routing (proxy layer). Phase 3: Contribute UUID stability upstream.

### Secret Lifecycle (R32, R33)

**Coupling bomb**: 4 secrets are shared between gateway and OAuth service via GCP Secret Manager names (`shopify-client-id`, `shopify-client-secret`, `db-password`, `shopify-token-encryption-key`). Renaming or rotating any of these requires coordinated changes across both services.

**Key rotation**: No automated path for AES-256-GCM key or JWT secret rotation. Key compromise requires emergency rotation affecting all stored tokens.

**Correction**: Key versioning — store key ID alongside ciphertext. Support decrypt-with-old, encrypt-with-new. Graceful JWT rollover (accept old + new during transition).

### Supply Chain Security (R36)

**Current state**: Apollo is **NOT SHA-256 verified** — it is compiled from source (`git clone --depth 1 --branch v1.9.0` + `cargo build --release --locked`; no checksum check). tini SHA-256 verified. auth-proxy SHA-256 verified. But: ContextForge installed via pip (hash-checking mode not used), Node.js/npm unpinned, dev-mcp from npm without integrity check.

**Correction**: Phase 1: Pin Node.js major version. Phase 2: Enable pip `--require-hashes` for ContextForge. Phase 3: npm integrity checks for dev-mcp.

### Client Experience (R18, R19, R20)

**Tool descriptions**: Generic and unhelpful for AI reasoning. Each tool needs a clear description of what it does, expected inputs, and when to use it.

**Error messages**: MCP error responses are opaque JSON-RPC. No actionable guidance for retry, scope issues, or rate limiting.

**Client startup**: No "welcome" or capability summary on connection. Client must discover capabilities by trial.

### Plugin Pipeline (R85)

**Problem**: ContextForge plugin pipeline has zero documentation of: execution order, priority semantics, pre-invoke failure behavior (session break vs error response), conditional execution by VS/user/tool. Rate limiter rejection behavior is unknown.

**Correction**: Before enabling ANY plugin, document: execution order, failure semantics, error response format. Test rate limiting plugin in isolation before production. This blocks Phase 2 circuit breaker deployment.

### Idempotency (R41)

**Problem**: No idempotency key header on mutation tool calls. Retry after timeout can create duplicate orders, customers, or fulfillments. MCP protocol has no native idempotency mechanism.

**Correction**: Phase 2: ContextForge plugin that generates/tracks idempotency keys per mutation tool call. Phase 1 (workaround): Document as known limitation — AI clients should implement their own dedup logic.

### Error Response Policy (R84)

**Problem**: Shopify error details (rate limits, validation errors, cost info) are stripped at the Apollo→stdio→SSE bridge boundary. MCP protocol wraps everything in JSON-RPC body (HTTP 200). Client gets generic errors with no retry guidance.

**Correction**: Phase 1: Document as known limitation. Phase 2: Apollo includes Shopify's cost/throttle extensions in MCP error details field. Phase 3: ContextForge error enrichment plugin.

### Backup & Disaster Recovery (R50)

**Problem**: No documented DR procedure. Cloud SQL automated backups exist but recovery hasn't been tested. No backup of ContextForge configuration (VS definitions, gateway registrations, RBAC policies).

**Correction**: Phase 1: Document DR procedure. Test Cloud SQL restore. Phase 2: Export ContextForge config as code (bootstrap already handles re-registration, but RBAC policies and custom settings need backup).

### Admin Access Control (R37)

**Problem**: ContextForge admin API (`MCPGATEWAY_ADMIN_API_ENABLED=true`) has no access restriction beyond container network isolation. Any authenticated user with access to the MCP endpoint could potentially hit admin API routes.

**Correction**: Phase 1: Verify auth-proxy blocks admin API routes from non-admin users. Phase 2: ContextForge RBAC restricts admin API to platform admin role.

### ContextForge Upgrade Path (R130)

**Problem**: ContextForge 1.0.0-RC-2 is used throughout. V4 Design Directions reference "after ContextForge 1.0.0 stable" as a gate for Phase 2, but there is zero documentation of the upgrade procedure, expected breaking changes, or compatibility risks.

**Risks**: (1) RC-2 → stable may include Alembic migrations that are backward-incompatible (see Risk R6). (2) Plugin API had 6 breaking changes in the RC series — stable may change again. (3) Base image rebuild required (`Dockerfile.base` FROM tag change). (4) `mcpgateway.translate` bridge API may change. (5) `mcpgateway.cli.main()` import path (used to work around entry point corruption, line 200 of entrypoint.sh) may change.

**Correction**: Before upgrading: (1) Review ContextForge changelog for breaking changes in CLI, plugin API, and REST API. (2) Test in a staging Cloud Run service with the same Cloud SQL instance (read-only — do NOT run Alembic against production). (3) Verify `mcpgateway.translate`, `mcpgateway.cli.main()`, and `/gateways` REST API still work. (4) Rebuild base image with new version tag. (5) Deploy app image against new base. Document rollback: keep previous base image tag, revert `Dockerfile.base` FROM line. *(Mirror Polish Batch 13, R130)*

---

## File Reference

| File | Purpose |
|------|---------|
| `deploy/Dockerfile` | Thin app image (scripts, config, queries) |
| `deploy/Dockerfile.base` | Fat base image (all binaries and deps) |
| `deploy/cloudbuild.yaml` | App deploy pipeline |
| `deploy/cloudbuild-base.yaml` | Base image build pipeline |
| `deploy/shopify-oauth/Dockerfile` | Shopify OAuth service image |
| `deploy/shopify-oauth/cloudbuild.yaml` | OAuth service deploy pipeline |
| `scripts/entrypoint.sh` | Process orchestrator (starts all 5 services) |
| `scripts/bootstrap.sh` | Backend registration with ContextForge |
| `scripts/test-e2e.sh` | End-to-end test suite |
| `scripts/test-unit.sh` | Unit test suite |
| `config/mcp-config.yaml` | Apollo MCP Server configuration |
| `shopify-schema.graphql` | Shopify Admin API schema (98K lines) |
| `graphql/` | GraphQL operation files (organized by domain) |
| `services/shopify_oauth/` | Shopify OAuth service source code. **Note**: `crypto.py` is dual-deployed — copied into both the gateway container (for token decryption at startup) and the OAuth service container. Changes to `crypto.py` affect both services. |
| `tests/shopify_oauth/` | OAuth service tests |
| `docs/agent-behavior/` | Agent learning system (failures, insights, patterns) |
| `docs/specs/` | Design specifications |
| `docs/research/` | Market research and technical evaluation |
| `.env.example` | Environment variable reference template |
| `deploy/shopify-oauth/requirements.txt` | OAuth service Python dependencies |
