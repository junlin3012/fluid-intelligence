# MCP Gateway Deep Evaluation — March 2026

> Research conducted 2026-03-14 across 4 conversation sessions.
> Purpose: Evaluate which existing open-source MCP gateway tools fit our needs,
> so we can compose rather than build from scratch.

---

## Our Requirements

1. Aggregate multiple MCP backends (Shopify GraphQL via Apollo, dev-mcp, Google Sheets, future backends)
2. Multi-user authentication (junlin = admin, juntan = operator, future users)
3. Per-user per-backend access control (User A sees Shopify + Sheets, User B sees only Shopify)
4. Deployable on GCP Cloud Run (existing infrastructure, asia-southeast1)
5. Easy to add new backends (config change, not code change)
6. Works with Claude, Cursor, and any MCP-compatible client
7. Architecture that scales without overhaul

---

## Summary Verdict

| Gateway | Fit | Monthly Cost | Complexity | Recommendation |
|---------|-----|-------------|------------|----------------|
| **1MCP** | Best for now | $18-48 | Low (single container) | **Tier 1: Start here** |
| **IBM ContextForge** | Best for enterprise | $55-80 | High (3 GCP services) | **Tier 2: Upgrade path** |
| MetaMCP | Partial | $15-30 | Medium | Skip (declining maintenance) |
| MCPHub | Weak | $20-40 | Medium | Skip (auth has race conditions) |
| Unla | Partial | $10-20 | Medium | Skip (no GraphQL, Chinese community) |
| MCPJungle | Partial | $5-10 | Low | Skip (no OAuth yet) |
| Archestra | Overkill | $65+ | Very High | Skip (AGPL license, K8s-native) |
| Casdoor | Auth only | $7-15 | Medium | **Tier 3: Enterprise auth layer** |

---

## Detailed Evaluations

---

### 1. MetaMCP

**Repo**: https://github.com/metatool-ai/metamcp
**Stars**: 2,107 | **License**: MIT | **Language**: TypeScript
**Created**: 2025-01-22 | **Latest Release**: v2.4.22 (2025-12-19)

#### Architecture

MetaMCP is a fan-out proxy/aggregator with a three-layer model:

- **MCP Servers**: Configs for how to start/connect to upstream servers. Supports stdio (spawn process), SSE (connect to endpoint), and Streamable HTTP.
- **Namespaces**: Logical groupings of servers. Each namespace can enable/disable individual tools, apply middleware, override tool names/descriptions.
- **Endpoints**: Public-facing URLs assigned to a namespace. Each endpoint exposes one namespace's aggregated tools.

**Tech stack**: TypeScript monorepo (pnpm + Turborepo). Express 5.1 backend, Next.js 15 frontend, PostgreSQL 16 (Drizzle ORM), Better Auth for sessions.

**Request flow**:
1. MCP client connects to a MetaMCP endpoint
2. MetaMCP aggregates `list_tools` from all servers in that namespace
3. `call_tool` routes to the correct upstream server
4. Response relayed back

**Process model**: Docker container runs two processes (backend Express on 12009, frontend Next.js on 12008). stdio servers spawned as child processes via `execa`/`cross-spawn`. Pre-allocated idle sessions reduce cold-start latency.

#### Auth Model

- Better Auth (session cookies for web UI)
- API key auth (`Authorization: Bearer sk_mt_...`) for programmatic access
- MCP OAuth (per spec 2025-06-18) for endpoints
- OIDC/SSO integration
- Users bootstrapped via `BOOTSTRAP_USERS` env var
- Resources can be public or private (user-scoped)

**What it lacks**:
- No true multi-tenant isolation (shared database, shared process)
- No RBAC beyond public/private scope
- No per-backend-per-user access rules
- No audit trail (file-based logs only)

#### Cloud Run Compatibility

**Problematic**:
- Requires PostgreSQL (not included in container) — needs Cloud SQL
- Two processes (backend + frontend) via bash entrypoint
- stdio servers spawn child processes — Cloud Run cold starts make this unreliable
- In-memory rate limiting (lost on restart)
- No Cloud Run deployment docs

#### Cost

Fully open source (MIT). Self-hosting: ~$15-30/mo (VM + managed PostgreSQL).

#### Limitations

- No cluster scaling (single-node only, noted as "future")
- PostgreSQL required — cannot run standalone
- Patches Next.js source with `sed` to change SSE timeout — fragile
- **Maintenance declining** — latest release Dec 2025, ~3 months gap
- No GraphQL backend support (MCP servers only)
- No config file for backend definition (UI or bootstrap env vars only)
- No per-user-per-backend access control

#### Verdict: SKIP

Declining maintenance, no per-user access, requires PostgreSQL, no config-driven backends.

---

### 2. MCPHub

**Repo**: https://github.com/samanhappy/mcphub
**Stars**: 1,876 | **License**: Apache 2.0 | **Language**: TypeScript
**Created**: 2025-03-31 | **Latest Release**: v0.12.7 (2026-03-08)

#### Architecture

Fan-out aggregation gateway with endpoint routing:

| Endpoint | Behavior |
|---|---|
| `/mcp` | Aggregates all servers |
| `/mcp/{group}` | Routes to a group |
| `/mcp/{server}` | Routes to single server |
| `/mcp/$smart` | AI semantic search across all servers |
| `/mcp/$smart/{group}` | Semantic search scoped to group |

**Four transport types**: Streamable HTTP, SSE, stdio, OpenAPI (converts OpenAPI specs to MCP tools).

**Tool namespacing**: Tools prefixed with server name (e.g., `playwright__screenshot`).

**Database**: PostgreSQL 17 with pgvector (for smart routing), or file-based mode (better-sqlite3/JSON config).

#### Smart Routing (Unique Feature)

MCPHub's standout feature. When tools are registered:
1. Tool name + description + schema is embedded via OpenAI `text-embedding-3-small`
2. Stored in PostgreSQL pgvector with HNSW index
3. On query, cosine similarity search finds relevant tools
4. Dynamic threshold: 0.2 for general queries, 0.4 for specific ones

Supported embedding providers: OpenAI, Azure OpenAI, Google Gemini, HuggingFace local, bag-of-words fallback.

**Limitation**: Requires PostgreSQL + pgvector + an embedding API key.

#### Auth Model — CRITICAL SECURITY ISSUE

MCPHub has **two conflicting user context systems**:

1. `UserContextService` — a **process-global singleton** storing a single `currentUser`. NOT request-scoped. Multiple concurrent requests overwrite each other's user context — **race condition and identity leakage**.
2. `RequestContextService` — uses `AsyncLocalStorage` for proper per-request isolation. Architecturally correct.

The two systems coexist without clean integration. Multi-user security is fundamentally broken.

- User entity has boolean `isAdmin` — no real RBAC
- No per-user per-server access control
- All users share upstream server credentials
- Default credentials: `admin` / `admin123`

#### Cloud Run Compatibility

Not out of the box. Heavy Docker image (Python 3.13 + Node.js 22 + Playwright). Smart routing requires PostgreSQL + pgvector. `synchronize: true` in TypeORM (schema changes on every startup).

#### Cost

Open source (Apache 2.0). Ko-fi donations only. Self-hosting: ~$20-40/mo.

#### Verdict: SKIP

Auth has race conditions, boolean-only RBAC, single maintainer, heavy image, TypeORM `synchronize: true` in production.

---

### 3. Unla (formerly MCP Gateway)

**Repo**: https://github.com/AmoyLab/Unla
**Stars**: 2,057 | **License**: MIT | **Language**: Go + TypeScript
**Created**: 2025-04-15 | **Latest Release**: v0.9.2 (2026-01-21)

#### Architecture

Two-component architecture:

**API Server** (port 5234): Admin CRUD for configs, JWT auth, web UI.
**MCP Gateway** (port 5235): The actual MCP protocol server.

**Two operation modes**:

**Mode A — REST-to-MCP (the "zero code" approach)**:
YAML configs define tools that map to HTTP REST endpoints using Go templates:
```yaml
tools:
  - name: "register_user"
    method: "POST"
    endpoint: "http://localhost:5236/users"
    headers:
      Authorization: "{{.Config.Authorization}}"
    args:
      - name: "username"
        position: "body"
        required: true
    requestBody: '{ "username": "{{.Args.username}}" }'
```

**Mode B — MCP Proxy**:
Config defines `mcpServers` (stdio, SSE, streamable-http) to proxy.

Has an **OpenAPI converter** CLI that auto-generates YAML config from OpenAPI specs.

#### Auth Model

- Admin API: JWT tokens, super admin via env vars
- MCP Client: Full OAuth 2.1 with PKCE, dynamic client registration, token revocation
- Multi-tenant: prefix-based routing (`tenant: "default"`)

**Critical limitation**: Multi-tenancy is prefix-based. Everyone connecting to the same prefix sees the same tools with the same credentials. No per-user identity mapping.

#### Cloud Run Compatibility

Challenging. All-in-one image runs supervisord (nginx + apiserver + mcp-gateway). SQLite default needs swap for PostgreSQL on Cloud Run (ephemeral filesystem). Streamable HTTP proxy commented as `# unimplemented for now`.

#### Cost

Fully open source (MIT). Costs: ~$10-20/mo self-hosted.

#### Limitations

- **No GraphQL support** — REST only, gRPC/WebSocket "not yet implemented"
- No per-user per-backend access
- Streamable HTTP proxy unimplemented
- Go template complexity for complex API mappings
- Chinese-language community (release notes, WeChat support)
- Single-config-per-prefix (can't merge backends behind one endpoint)

#### Verdict: SKIP

No GraphQL support is a dealbreaker (we need Shopify GraphQL via Apollo). Prefix-based tenancy insufficient.

---

### 4. 1MCP

**Repo**: https://github.com/1mcp-app/agent
**Stars**: 396 | **License**: Apache 2.0 | **Language**: TypeScript
**Created**: 2025-03-16 | **Latest Release**: v0.30.1 (2026-03-12)
**Releases**: 62 total | **Primary Author**: William Xu (xizhibei, ~500 commits)

#### Architecture

MCP proxy/aggregator that connects to upstream MCP servers and exposes a single endpoint.

**Config format** (`mcp.json`):
```json
{
  "mcpServers": {
    "shopify-api": {
      "command": "/app/apollo-mcp",
      "args": ["--config", "/app/mcp-config.yaml"],
      "tags": ["shopify"],
      "env": { "ACCESS_TOKEN": "${SHOPIFY_ACCESS_TOKEN}" }
    },
    "shopify-docs": {
      "command": "npx",
      "args": ["-y", "@shopify/dev-mcp@latest"],
      "tags": ["shopify"]
    },
    "google-sheets": {
      "type": "http",
      "url": "http://localhost:9000/mcp",
      "tags": ["sheets"],
      "headers": { "Authorization": "Bearer ${SHEETS_TOKEN}" }
    }
  }
}
```

**Transport types**:
- `stdio`: `child_process.spawn()`, communicate via stdin/stdout
- `http` / `streamableHttp`: HTTP client to MCP endpoint
- `sse`: SSE client (legacy MCP transport)

**Transport inference** (from `transportFactory.ts`):
- Has `command` → stdio
- URL ends in `/mcp` → http (Streamable HTTP)
- Other URL → sse

**Hot-reload mechanism** (verified in code):
1. `fs.watch()` on config directory (handles atomic saves)
2. Checks `mtime` for actual modification
3. Debounced reload (configurable `configReload.debounceMs`)
4. `ConfigChangeHandler` computes diffs: ADDED, REMOVED, MODIFIED
5. Additions → `serverManager.startServer()`
6. Removals → `serverManager.stopServer()`
7. Modifications → restart if command/URL changed, metadata-only if just tags changed
8. Sends `listChanged` notifications to all connected MCP clients

**Tested**: e2e test covers 10 rapid toggles across 5 servers completing in <5 seconds.

#### OAuth 2.1 with Tag-Based Scoping

Each server gets `tags`. Tags become OAuth scopes.

**Flow** (verified in `sdkOAuthServerProvider.ts` and `scopeAuthMiddleware.ts`):
1. Client connects to `http://1mcp:3050/mcp?tags=shopify`
2. Redirects to OAuth consent page
3. Consent page shows available tags as checkboxes
4. User grants specific tag groups
5. Token issued with scopes like `tag:shopify`, `tag:sheets`
6. On every request, middleware validates scopes cover requested tags

**Enable with**: `--enable-auth --enable-scope-validation`

**Tag filtering modes**:
- `?tags=shopify,sheets` — simple OR logic
- `?tag-filter=shopify+api-test` — boolean expressions (AND/OR/NOT)
- `?preset=development` — named presets

**Limitations**:
- Scope validation is tag-level, NOT tool-level
- No refresh tokens (`throw new Error('Refresh tokens not supported')`)
- Consent requires browser (no headless/API-only flow)
- File-based token storage (not database)
- No "User" concept beyond OAuth clientId

#### Deployment

**Docker**: Node.js Alpine (~200MB), port 3050. No database needed.
```yaml
services:
  1mcp:
    image: ghcr.io/1mcp-app/agent:latest
    ports: ['3050:3050']
    volumes: ['~/.config/1mcp/:/root/.config/1mcp']
    environment:
      - ONE_MCP_HOST=0.0.0.0
      - ONE_MCP_PORT=3050
```

**Also provides**: Standalone SEA binaries (Linux x64/arm64, macOS x64/arm64, Windows x64), npm package, systemd docs.

**Cloud Run**: Partially compatible. HTTP backends work well. stdio backends need Node.js runtime in container (extended image). File-based sessions lost on container restart.

#### Cost

Free (Apache 2.0). No database needed. Cloud Run only: ~$18-48/mo.

#### Production Readiness

- ~120+ test files (unit + e2e), Vitest, 4-shard CI
- 62 releases, CI all passing (latest 2026-03-12)
- Dependabot enabled, stale issue bot
- MCP SDK v1.25.1 (latest)
- Zero open issues at time of research

**Risk**: Single maintainer (William Xu). Apache 2.0 enables forking.

#### What 1MCP CAN Do for Us

- Aggregate Apollo (HTTP) + dev-mcp (stdio) + Google Sheets (stdio) behind one endpoint
- Tag-based access: junlin gets `tag:shopify,tag:sheets`, juntan gets `tag:shopify`
- Hot-reload: add new backend = add 5 lines to JSON, no restart
- OAuth 2.1 with PKCE
- Boolean tag filter expressions
- Run in single container on Cloud Run

#### What 1MCP CANNOT Do

- Per-user identity (no user profiles, no RBAC beyond tag scopes)
- Non-MCP backends (can't proxy raw GraphQL/REST/SOAP directly)
- Multi-instance deployment (file-based sessions)
- Tool-level access control
- Audit trail
- Web admin UI

#### Verdict: RECOMMENDED (Tier 1)

Best fit for current needs. Simple, declarative, tested, single container. Upgrade to ContextForge when per-user RBAC and audit are needed.

---

### 5. MCPJungle

**Repo**: https://github.com/mcpjungle/MCPJungle
**Stars**: 903 | **License**: MPL-2.0 | **Language**: Go
**Created**: 2025-05-15 | **Latest Release**: 0.3.6 (2026-03-13)

#### Architecture

Centralized MCP gateway with dual binary (server + CLI client). Single `/mcp` endpoint (port 8080).

**Connection modes**:
- **Stateless** (default): New connection per tool call. Simplest.
- **Stateful**: Persistent connections with configurable idle timeout.

**Tool Groups**: Curated subsets exposed on `/v0/groups/<name>/mcp`. Supports include/exclude rules.

**Transport**: Streamable HTTP (primary), stdio (local), SSE (not mature).
**Tool naming**: `<server-name>__<tool-name>` (double underscore).

#### Auth Model

**Development mode** (default): No auth whatsoever.

**Enterprise mode** (`--enterprise`):
- Named MCP clients with explicit server allowlists:
  ```
  mcpjungle create mcp-client cursor-local --allow "calculator, github"
  ```
- Generates bearer tokens per client
- No OAuth (WIP, explicitly listed as "not yet supported")
- Token sources: direct string, file path, or env var

#### Observability

Prometheus metrics at `/metrics`. OpenTelemetry resource attributes configurable.

#### Deployment

Two Docker images:
- `latest`: Minimal Go binary only (for remote MCP servers)
- `latest-stdio`: Includes Node.js + Python runtimes (for npx/uvx stdio servers)

Also: Homebrew, binary downloads (6 platforms), Docker Compose (dev + prod).

#### Cost

Free (MPL-2.0). No SaaS. Discord community.

#### Limitations

- **No OAuth** — static bearer tokens only
- MPL-2.0 copyleft (must share modifications to MCPJungle source)
- No hot-reload (CLI commands for registration, not watched config)
- No web UI
- 3-person team

#### Verdict: SKIP

No OAuth is a dealbreaker. MPL-2.0 copyleft adds constraints. Good tool groups concept worth studying.

---

### 6. IBM ContextForge

**Repo**: https://github.com/IBM/mcp-context-forge
**Stars**: 3,408 | **License**: Apache 2.0 | **Language**: Python (FastAPI)
**Created**: 2025-05-08

#### Architecture

Three-in-one gateway:
- **Tools Gateway**: MCP server federation + REST/gRPC-to-MCP translation
- **Agent Gateway**: A2A protocol support, OpenAI/Anthropic agent routing
- **API Gateway**: Rate limiting, auth, retries, reverse proxy

**Backend registration is IMPERATIVE, not declarative**:
```bash
# Register an upstream MCP server
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -d '{"name":"apollo-shopify","url":"http://localhost:8000/sse"}' \
  http://localhost:4444/gateways
```

No `backends.yaml` or config file — backends are added via API calls at runtime, persisted to database.

**stdio support**: Via translation layer — spawns stdio process, bridges to HTTP:
```bash
python3 -m mcpgateway.translate \
  --stdio "npx @shopify/dev-mcp" \
  --expose-sse --expose-streamable-http --port 9000

# Then register the bridged endpoint
curl -X POST -d '{"name":"dev-mcp","url":"http://localhost:9000/sse"}' ...
```

**Tool namespacing**: `{gateway-slug}{separator}{tool-name}` (separator configurable, default `-`).

**Virtual Servers**: Compose tools from multiple gateways into custom endpoints.

**47 plugins** (middleware, not API connectors):
- Security: PII filter, secrets detection, content moderation, SQL sanitizer, encoded exfil detection
- Infra: rate limiter, circuit breaker, retry, cache, webhook
- Auth: JWT claims extraction, unified PDP, vault integration

#### RBAC (Real, Verified)

Two-layer model:
1. **Teams** control visibility — which gateways/tools a user can see
2. **Roles** control actions — what operations are allowed

Per-user per-backend access works via teams:
- Team "shopify-team" → sees shopify gateway tools
- Team "sheets-team" → sees google sheets tools
- User A in both teams → sees everything
- User B in shopify-team only → sees only Shopify

Built-in roles: `platform_admin`, `team_admin`, `developer` (execute tools), `viewer` (read-only), `platform_viewer`.

Custom roles bootstrappable from JSON.

#### Cloud Run Deployment — VERIFIED

Dedicated deployment guide at `docs/docs/deployment/google-cloud-run.md`.

**Requires 3 GCP services**:
1. **Cloud SQL** (PostgreSQL 17, `db-f1-micro`) — stores 18+ tables
2. **Memorystore** (Redis, Basic 1GiB) — caching and sessions
3. **Cloud Run** — the ContextForge container

**Deployment commands**:
```bash
gcloud sql instances create mcpgw-db \
  --database-version=POSTGRES_17 --tier=db-f1-micro --region=us-central1

gcloud redis instances create mcpgw-redis \
  --region=us-central1 --tier=BASIC --size=1

gcloud run deploy mcpgateway \
  --image=us-central1-docker.pkg.dev/$PROJECT/ghcr-remote/ibm/mcp-context-forge:latest \
  --port=4444 --cpu=1 --memory=512Mi --max-instances=1 \
  --set-env-vars=DATABASE_URL=...,REDIS_URL=...
```

**Docker base image**: Red Hat UBI 10 Minimal. Python 3.12, no Node.js, no Rust. Would need custom image for dev-mcp stdio.

#### Auth

- JWT tokens (primary) with mandatory JTI and expiration
- OAuth 2.0 with Dynamic Client Registration
- SSO/OIDC: tutorials for GitHub, Google, Microsoft Entra, Keycloak, Okta, IBM Security Verify
- RBAC with teams and email-based accounts
- SSRF protection built-in
- Public registration disabled by default

#### Cost

Fully open source (Apache 2.0). IBM-backed but no paid tier.

Self-hosting on GCP:
| Component | Monthly Cost |
|---|---|
| Cloud Run (1 vCPU, 512MB, min-instances=1) | $18-48 |
| Cloud SQL (db-f1-micro PostgreSQL) | $7-10 |
| Memorystore (Redis Basic 1GB) | $35-55 |
| **Total** | **$55-80** |

#### Limitations

- **Imperative backend registration** — API calls, not config file
- Python stack (our team is Node.js/TypeScript)
- Requires PostgreSQL + Redis (cannot run standalone)
- No Node.js in container (need custom image for stdio MCP servers)
- Heavy operational footprint (3 GCP services)
- No Shopify-specific tooling
- 47 plugins are middleware only, not API connectors

#### Verdict: RECOMMENDED (Tier 2 — Enterprise Upgrade)

Real RBAC, real audit, real federation. But heavy (3 GCP services, ~$55-80/mo). Use when you outgrow 1MCP.

---

### 7. Archestra

**Repo**: https://github.com/archestra-ai/archestra
**Stars**: 3,546 | **License**: AGPL-3.0 | **Language**: TypeScript
**Created**: 2025-07-15

#### Architecture

Enterprise AI platform (not just MCP gateway):
- MCP Registry + Orchestrator (Kubernetes-native)
- LLM Proxy (multi-provider: OpenAI, Anthropic, Gemini, etc.)
- A2A support
- Built-in chat interface
- OpenTelemetry, Prometheus metrics

**Unique: Dual LLM security pattern** — quarantined LLM (restricted, integer-only responses) + main LLM (no access to unsafe content). Prevents prompt injection data exfiltration.

#### Auth

- Token-based with `ARCHESTRA_AUTH_SECRET`
- SSO via external IdPs
- Virtual API keys with per-key expiration
- HashiCorp Vault integration
- Kubernetes RBAC and NetworkPolicy (SSRF protection)

#### Cloud Run Compatibility

**Not a natural fit.** K8s-native architecture with Docker socket mounting, operator patterns, multiple ports (3000 + 9000). Possible but requires significant adaptation.

#### Cost

**Open-core** (AGPL-3.0):
- Core: free but AGPL (must release modifications if network-served)
- Knowledge Base: enterprise license required
- Full white-labeling: enterprise license
- Contact `sales@archestra.ai` for pricing

**AGPL-3.0 is a significant constraint** — any modifications served over a network must be released under AGPL.

#### Verdict: SKIP

AGPL license is a poison pill for commercial use. K8s-native doesn't fit Cloud Run. Overkill for our needs. Dual LLM security pattern worth studying conceptually.

---

### 8. Casdoor (Auth Layer, Not Gateway)

**Repo**: https://github.com/casdoor/casdoor
**Stars**: 13,146 | **License**: Apache 2.0 | **Language**: Go (Beego) + React
**Created**: 2020-10-22

#### What It Is

Full IAM platform that has added MCP capabilities. NOT an MCP gateway — it's an auth server that exposes its own admin operations as MCP tools.

**MCP tools**: Application CRUD, User CRUD, Organization CRUD, Permission CRUD, Role CRUD — all for managing Casdoor itself.

#### IAM Features

- OAuth 2.0 / OAuth 2.1 / OIDC provider
- SAML, CAS, LDAP, SCIM support
- WebAuthn, TOTP, MFA, Face ID
- 100+ identity provider integrations
- Dynamic Client Registration
- Per-tool MCP permissions via scopes
- Session management with expiry tracking

#### Cloud Run Compatibility

Architecturally compatible. Single HTTP port (8000), configurable via env vars, ~100MB RAM at runtime. Requires external database (Cloud SQL MySQL/PostgreSQL).

#### Cost

Fully open source (Apache 2.0). Part of CNCF Landscape.

Self-hosting: ~$7-15/mo (Cloud Run + Cloud SQL).

#### Verdict: RECOMMENDED (Tier 3 — Enterprise Auth Upgrade)

Not a gateway competitor — it's the auth layer upgrade path. When ContextForge's built-in auth isn't enough (100+ social logins, MFA, WebAuthn, SAML), put Casdoor in front.

---

## API-to-MCP Bridges (Apollo Alternatives)

### fastapi_mcp
- **Stars**: 11,700 | **License**: MIT | **Language**: Python
- Converts any FastAPI app to MCP server with zero config
- Irrelevant for us (we don't have a FastAPI app)

### mcp-graphql
- **Stars**: 365 | **License**: MIT | **Language**: TypeScript
- Generic GraphQL → MCP via dynamic introspection
- Alternative to Apollo: introspects schema at runtime vs Apollo's persisted operations
- Trade-off: more flexible but less optimized than Apollo's pre-compiled approach

### Apollo MCP Server
- **Stars**: 271 | **License**: MIT | **Language**: Rust
- Our current choice. Persisted operations, type-to-JSON-Schema conversion, Shopify rate limiting
- Best fit for Shopify GraphQL specifically

### openapi-mcp-generator
- **Stars**: 539 | **License**: MIT
- Generates full MCP server code from OpenAPI spec
- Useful for future REST API integrations

### mcp-link
- **Stars**: 603 | **License**: MIT
- Dynamic proxy: any OpenAPI spec → MCP via URL params
- No code generation, just runtime proxying

### anythingmcp
- **Stars**: 6 | **License**: MIT
- Most protocol-comprehensive: REST + SOAP + GraphQL + databases
- Very early stage, not production-ready

### skyline-mcp
- **Stars**: 3
- 17+ protocols including WSDL/SOAP, OData, gRPC
- Too early for production use

---

## Cloud Run + MCP: Critical Findings

### Current Deployment is Misconfigured

**CPU throttling is enabled (default)**. Between HTTP requests, CPU is throttled to near-zero. This means nginx, Apollo, OAuth server, and token refresh loop are all frozen between requests. Works by luck (MCP requests come in bursts).

**Fix required**:
```bash
gcloud run services update junlin-shopify-mcp \
  --region asia-southeast1 \
  --no-cpu-throttling
```

### Cloud Run Requirements for MCP Gateway

| Setting | Value | Why |
|---------|-------|-----|
| CPU allocation | `--no-cpu-throttling` | Child processes need CPU between requests |
| min-instances | 1 | Avoid cold starts, keep processes alive |
| Execution env | Gen2 | Full Linux compat, proper PID 1 |
| Init process | tini | Zombie reaping, signal forwarding |
| Shutdown handler | SIGTERM trap | Clean shutdown within 10s |

### Pricing (Instance-Based, 1 vCPU + 1GB, asia-southeast1)

| Resource | Monthly Cost |
|---|---|
| vCPU (always-on) | $16-43 |
| Memory 1GB (always-on) | $1.5-4.4 |
| Requests | $0 (no per-request charge) |
| **Total Cloud Run** | **$18-48** |

### What Works on Cloud Run

- Node.js gateway exposing HTTP Streamable/SSE to Claude
- Gateway spawning dev-mcp as stdio child process
- Gateway communicating with Apollo via HTTP on localhost
- min-instances=1 + CPU-always-allocated for always-on behavior

### What Does NOT Work

- Exposing stdio MCP server as the Cloud Run service itself
- Relying on container immortality (containers recycled unpredictably)
- Request-based billing with persistent child processes

### Competitor Deployments on Cloud Run

**None of the major MCP gateways have Cloud Run deployments.** All use Docker Compose, VMs, or Kubernetes:
- MetaMCP: Docker Compose + PostgreSQL
- IBM ContextForge: Docker Compose (app + MariaDB + Redis + Nginx). Has Cloud Run guide but needs 3 services.
- 1MCP: Docker / systemd / standalone binary

---

## Recommended Architecture: Tiered Approach

### Tier 1: Now (2 users, 3-5 backends) — 1MCP

```
┌──────────────────────────────────────────┐
│          1MCP Gateway (Node.js)          │
│      Single container on Cloud Run       │
│    OAuth 2.1 + tag-based scope control   │
│            ~$18-48/month                 │
├──────────────────────────────────────────┤
│                                          │
│  stdio: Apollo MCP (Shopify GraphQL)     │
│  stdio: @shopify/dev-mcp (knowledge)    │
│  stdio: Google Sheets MCP (future)      │
│                                          │
└──────────────────────────────────────────┘
         ↑
   Claude / Cursor / any MCP client
```

**Config**:
```json
{
  "mcpServers": {
    "shopify-api": {
      "command": "/app/apollo-mcp",
      "args": ["--config", "/app/mcp-config.yaml"],
      "tags": ["shopify"]
    },
    "shopify-docs": {
      "command": "npx",
      "args": ["-y", "@shopify/dev-mcp@latest"],
      "tags": ["shopify"]
    },
    "google-sheets": {
      "command": "npx",
      "args": ["-y", "@anthropic/mcp-google-sheets"],
      "tags": ["sheets"],
      "env": { "GOOGLE_CREDENTIALS": "${GOOGLE_SA_KEY}" }
    }
  }
}
```

**What 1MCP replaces from current stack**: nginx, bash supervisor, custom OAuth server, planned gateway code.

**What stays**: Apollo MCP Server, GCP infrastructure, Shopify app credentials.

### Tier 2: Enterprise (10+ users) — IBM ContextForge

When you need real RBAC with teams, audit trails, SSO integration. Adds Cloud SQL + Redis (~$55-80/mo total). Backend concepts map 1:1 from 1MCP to ContextForge.

### Tier 3: Enterprise Auth — Add Casdoor

When you need 100+ social login providers, MFA, WebAuthn, SAML, LDAP. Casdoor runs as a separate auth backend (~$7-15/mo additional).

---

## Certainties vs. Uncertainties

### What We're Certain About

1. 1MCP can aggregate Apollo (HTTP) + dev-mcp (stdio) + Google Sheets (stdio) — verified in source
2. Tag-based scoping works — verified `scopeAuthMiddleware.ts`
3. Hot-reload works — verified in code and e2e tests
4. Cloud Run needs `--no-cpu-throttling` — current deployment is throttling processes
5. 1MCP runs as a single container — no database, no Redis
6. Adding Google Sheets is 5 lines of config — no code, no rebuild
7. ContextForge RBAC with teams is real — verified API and data model
8. ContextForge requires 3 GCP services (Cloud Run + Cloud SQL + Redis)
9. All recommended tools are Apache 2.0 or MIT — no license restrictions

### What Needs Testing Before Deployment

1. 1MCP + Apollo (Rust binary) in same container on Cloud Run
2. 1MCP's OAuth flow with Claude.ai (MCP spec compliance)
3. File-based session survival across Cloud Run container recycling
4. ContextForge stdio translation layer with dev-mcp specifically
5. Cold start time with 3 stdio backends spawning simultaneously

---

## Data Sources

All evaluations based on source code review of actual GitHub repositories, not marketing materials:
- MetaMCP: github.com/metatool-ai/metamcp (commit history through 2025-12-19)
- MCPHub: github.com/samanhappy/mcphub (commit history through 2026-03-08)
- Unla: github.com/AmoyLab/Unla (commit history through 2026-01-21)
- 1MCP: github.com/1mcp-app/agent (commit history through 2026-03-12)
- MCPJungle: github.com/mcpjungle/MCPJungle (commit history through 2026-03-13)
- IBM ContextForge: github.com/IBM/mcp-context-forge (Cloud Run deployment guide verified)
- Archestra: github.com/archestra-ai/archestra
- Casdoor: github.com/casdoor/casdoor
- Google Cloud Run docs: cloud.google.com/run/docs/
