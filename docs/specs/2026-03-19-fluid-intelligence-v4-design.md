# Fluid Intelligence v4 — Architecture Design Spec

> Status: DRAFT
> Date: 2026-03-19
> Authors: junlin + Claude
> Supersedes: `docs/superpowers/specs/2026-03-14-fluid-intelligence-v3-design.md`

---

## 1. Vision

A universal MCP gateway that gives AI clients a single endpoint to access any API — MCP servers, REST APIs, GraphQL, gRPC, A2A agents — with per-user identity, role-based access, config-driven backends, and full audit trails.

Shopify is the first vertical. It is not the last.

## 2. Design Principles

Each principle traces to a specific v3 failure (see `docs/v3-retrospective.md`).

| Principle | From v3 failure |
|-----------|----------------|
| **Separate processes = separate containers.** Each component has its own health check, lifecycle, and fault isolation. | Monolith-in-a-container: one crash killed everything |
| **Auth is a dedicated service.** Persistent sessions, industry-standard, never write auth code. | Double-Auth Problem (twice), in-memory sessions, fosite sub claim gap |
| **Configure, don't build.** Use ContextForge's native capabilities. Only build what doesn't exist. | Proposed building observability, plugin layers, and config wrappers that ContextForge already provides |
| **Direct effort toward unsolved problems.** If something is already solved well, use it. | Repeated pattern of designing solutions before inventorying existing capabilities |
| **Pin everything, hash everything.** Every dependency locked at build time. Nothing fetched at runtime. | npx fetching fresh, unpinned Node.js, no pip lock files |
| **Observable from day one.** Metrics, traces, alerts ship with v4.0. | OTEL disabled by default, no custom metrics, no alerting |
| **Lean → production via infra knobs, not code changes.** Same containers, different deployment config. | v3 required code changes to scale |
| **Source-verify before integrating.** Read actual source code, `--help`, and test suites of every external component before writing integration code. | Config written without reading source code (3 times in v3) |
| **Zero hardcoded business values.** Every email, domain, project ID, URL must come from env vars or config. | 47 hardcoded values found in v3 codebase |

## 3. Architecture

### 3.1 Topology

Two Cloud Run services. One for auth, one for the gateway.

```
Cloud Run Service 1: Keycloak
  └── Keycloak container → PostgreSQL

Cloud Run Service 2: Fluid Intelligence Gateway
  ├── ContextForge (main container)
  ├── Apollo MCP Server (sidecar)
  ├── dev-mcp via supergateway (sidecar)
  └── Google Sheets via supergateway (sidecar)
  → PostgreSQL (same Cloud SQL instance, different database)
```

### 3.2 Why this topology

**Keycloak is separate** because:
- Auth has a different lifecycle (rarely changes, needs high availability)
- Auth state must persist independently (tokens, sessions, clients)
- Auth must survive gateway restarts
- Keycloak manages its own database schema

**Backends are sidecars** (not separate services) because:
- They are meaningless without ContextForge — tightly coupled by purpose
- Sidecar containers share localhost networking — no service-to-service auth needed
- Cloud Run manages per-container health checks — one crash doesn't kill the others
- Up to 10 containers per instance — room to grow
- Cost: one Cloud Run service bill, not four
- Same code works as sidecars (lean) or separate services (production) — infra knob, not code change

### 3.3 Request flow

```
AI Client
  → HTTPS → Cloud Run (:443)
  → ContextForge receives request with Bearer JWT
  → ContextForge validates JWT via Keycloak JWKS endpoint
  → ContextForge resolves user → checks RBAC → selects tool
  → Routes to backend:
      MCP server (sidecar, localhost) → response
      REST API (direct passthrough) → response
      A2A agent (direct) → response
  → ContextForge applies post-processing plugins (PII filter, audit, cache)
  → Response to AI Client
```

### 3.4 Port map

| Container | Port | Protocol | Exposed externally? |
|-----------|------|----------|-------------------|
| ContextForge | 8080 (Cloud Run PORT) | HTTP | Yes (Cloud Run ingress) |
| Apollo | 8000 | Streamable HTTP or SSE | No (localhost only) |
| dev-mcp | 8003 | SSE (via supergateway) | No (localhost only) |
| Google Sheets | 8004 | SSE (via supergateway) | No (localhost only) |
| Keycloak | 8080 | HTTP | Yes (own Cloud Run service) |

### 3.5 Auth flow

```
AI Client
  → GET /.well-known/oauth-authorization-server (Keycloak metadata)
  → POST /realms/fluid/clients-registrations/openid-connect (DCR)
  → GET /realms/fluid/protocol/openid-connect/auth?code_challenge=...&code_challenge_method=S256 (PKCE)
  → User authenticates (Google login or username/password)
  → Keycloak issues JWT with sub, email, roles, tenant claims
  → AI Client sends Bearer token on every request
  → ContextForge validates token (Keycloak JWKS endpoint)
  → ContextForge resolves identity from JWT claims
```

## 4. Components

### 4.1 Keycloak (Auth Service)

**What:** Red Hat Keycloak — open-source identity and access management server.
**Version:** Pin exact version at implementation time (e.g., `26.1.4`). Record digest in `.digests` file. Do NOT use "latest."
**License:** Apache 2.0
**Why Keycloak over alternatives:**

| Alternative | Why not |
|------------|---------|
| mcp-auth-proxy | v3 pain: Double-Auth Problem (twice), no DCR, no persistent sessions, fosite sub claim gap. It's a fork we'd maintain forever. |
| Ory Hydra | Token server only — needs Kratos + custom login UI = 3 services. Overengineered for our scale. |
| Build custom | Violates "configure, don't build." Auth is a solved problem. |

**Keycloak provides natively:**
- OAuth 2.1 with PKCE S256
- Dynamic Client Registration (RFC 7591) — required by MCP spec
- Authorization Server Metadata (RFC 8414) — required by MCP spec. **Note:** Keycloak natively serves `/.well-known/openid-configuration`, NOT `/.well-known/oauth-authorization-server`. MCP spec expects the latter. Resolution required: ALB path rewrite, Keycloak SPI extension, or ContextForge proxy endpoint. This is a **blocker** — without it, no MCP client can discover the authorization server. The metadata response must include at minimum: `issuer`, `authorization_endpoint`, `token_endpoint`, `registration_endpoint`, `response_types_supported` (= `["code"]`), `grant_types_supported` (= `["authorization_code", "refresh_token"]`), `code_challenge_methods_supported` (= `["S256"]`), `token_endpoint_auth_methods_supported` (must include `"none"`), `jwks_uri`, `revocation_endpoint`
- Google/GitHub social login
- Username/password login
- User management and admin console
- Persistent sessions in PostgreSQL
- JWT issuance with custom claims (tenant ID, roles)
- Token introspection and revocation
- Multi-realm support (one realm per tenant, or shared realm)
- CNCF Incubating project, 26k stars, 11 years, Red Hat backed

**Configuration (not code):**
- Realm: `fluid`
- Client: one per AI client (via DCR)
- Identity Provider: Google OAuth
- Custom JWT mapper: inject `tenant_id` claim from user attributes
- Token lifetime: 1 hour access, 24 hours refresh (with rotation)
- JWT algorithm: RS256 only (pinned, reject all others)
- JWT claims: `sub`, `email`, `roles`, `tenant_id`, `aud` (audience = fixed resource-server identifier), `azp`
- **Audience mapper (REQUIRED for DCR model):** With DCR, each client gets a unique `client_id`. Keycloak sets `aud` to the requesting client's `client_id` by default. ContextForge cannot validate `aud` against a single value without a fixed audience. **Fix:** Configure a Keycloak "Audience" protocol mapper at the realm level that adds a fixed audience value (e.g., `fluid-gateway`) to ALL tokens. ContextForge validates `aud` contains `fluid-gateway`. Without this, ContextForge either skips `aud` validation (accepting any realm JWT) or breaks with DCR.
- PKCE enforcement: Client Policy requiring `pkce.code.challenge.required=true` AND `pkce.code.challenge.method=S256`. Both are needed — RFC 7636 §4.3 says if `code_challenge_method` is omitted by the client, the server MUST default to `plain`. Requiring the method prevents this downgrade.
- Refresh token rotation: enabled (one-time use, revoke-on-reuse for theft detection)

**DCR security:**
- Open registration (MCP spec requires anonymous DCR)
- Rate limited: max 10 registrations per IP per hour. **Implementation:** Keycloak has no native DCR rate limiting — implement via Cloud Armor WAF rule or ALB rate limit policy on the `/clients-registrations/` path
- Redirect URI policy: allowlist for CLI clients: `http://localhost:*`, `http://127.0.0.1:*`, `http://[::1]:*` (per RFC 8252 §7.3, native apps use `http://` not `https://` for loopback — TLS on localhost causes cert issues). For web clients: exact-match registered URIs only (no wildcards, no pattern matching)
- All DCR clients are **public clients** (no client_secret, PKCE mandatory)
- Maximum client count per IP: 50

**DCR Client Registration Policy (REQUIRED — Keycloak's default DCR is permissive):**
- Force `token_endpoint_auth_method=none` (public clients only — reject confidential client registration)
- Force `grant_types=["authorization_code"]` (reject `client_credentials`, `implicit`, `password`, device code)
- Force `response_types=["code"]` (reject `token`, `id_token`)
- Restrict scopes to `openid`, `email`, `profile` — strip all others including `offline_access`
- Ignore `software_statement` parameter unless a verification key is configured
- Ignore cosmetic metadata (`logo_uri`, `client_uri`, `policy_uri`) — not rendered, reduces stored XSS surface
- **Registration access token (RFC 7592):** Keycloak returns a `registration_access_token` for client self-management. Either: (a) disable RFC 7592 management endpoint, or (b) restrict to read-only (no scope/redirect changes after registration). Document token lifetime and storage guidance alongside `client_id`.
- **Client cleanup:** Set a Keycloak client policy for DCR client expiration (e.g., 90 days inactive). Without cleanup, the client table grows unbounded.

**Keycloak version pinning:**
- Pin to exact version: `quay.io/keycloak/keycloak:26.1.4@sha256:<digest>`
- Record digest in `.digests` file checked into repo

**Session termination / logout:**
- User-initiated: Keycloak logout endpoint → revokes refresh tokens + sessions
- Admin-initiated: Disable user in Keycloak → existing access tokens remain valid until expiry (up to 1 hour). Refresh tokens: Keycloak rejects refresh grants for disabled users (verify during implementation). JWKS cache TTL (10 min) is irrelevant here — it controls key rotation propagation, not user disablement. For immediate revocation: use Keycloak token revocation API to invalidate specific tokens, or shorten access token lifetime for sensitive operations.
- Emergency: "Logout all sessions" for user + rotate realm signing key
- ContextForge cache invalidation: ContextForge must NOT cache user identity/roles beyond the JWT lifetime. Every request re-reads claims from the JWT.
- DCR client binding: each DCR registration records the authenticated user (if any) or originating IP, enabling "revoke all clients from IP X"

**Keycloak feature hardening:**
- Disable standard token exchange: `--features=token-exchange-standard:disabled` (V2, supported, **enabled by default** in 26.2+ — prevents internal token exchange between clients). Also disable legacy: `--features=token-exchange:disabled` (V1, preview, off by default — belt-and-suspenders)
- Disable impersonation: `--features=impersonation:disabled` (**enabled by default** — must explicitly disable)
- Disable device authorization grant: `--features=device-flow:disabled` (enabled by default — unnecessary attack surface, bypasses PKCE authorization code flow)
- Disable CIBA: `--features=ciba:disabled` (enabled by default — backchannel auth not needed for MCP AI clients)
- Remove `offline_access` from realm default optional client scopes (offline tokens survive logout, never expire by default — bypasses all token lifetime controls)
- DCR client policy: strip `offline_access` from requested scopes for public clients
- If offline tokens are needed later, set offline session idle/max lifespan to match regular policy (7-day absolute cap)
- **Version note:** Feature availability varies by Keycloak version. `token-exchange-standard` was promoted to supported in 26.2. If pinning to 26.1.x, verify which features exist. Use `kc.sh show-config` to confirm disabled features at deploy time.

**Keycloak event logging (REQUIRED — auth has no audit trail without this):**
- Enable login event logging: `--spi-events-listener-jboss-logging-success-level=info`
- Enable event storage: Realm → Events → Save Events = ON, Admin Events = ON
- Include Representation = OFF (avoid PII in event payloads)
- Event expiration: 90 days (match ContextForge audit retention)
- Capture: LOGIN, LOGIN_ERROR, LOGOUT, REGISTER, TOKEN_EXCHANGE, CLIENT_REGISTER, CLIENT_DELETE, IMPERSONATE, GRANT_CONSENT, REVOKE_GRANT
- Add `sid` (session ID) to JWT claims for cross-service correlation with ContextForge audit logs

**Keycloak admin console security:**
- Admin console (`/admin`) MUST NOT be publicly accessible
- Use `KC_HOSTNAME_ADMIN=<internal-url>` to restrict admin console to a separate hostname not routed by Cloud Run public ingress
- Or disable admin console entirely (`KC_FEATURES=admin2:disabled`) and manage via `kcadm.sh` from Cloud Run jobs
- All Keycloak admin accounts must have MFA enabled
- Admin access only via VPN or Cloud IAP

**Identity Provider claim filtering (CRITICAL):**
- Google IdP mapper MUST import ONLY `email` and `name` — block all other attribute imports
- `tenant_id` and `roles` user attributes MUST be admin-only-writable (Keycloak `userProfile` SPI)
- IdP mapper mode: `import` only (not `force`) — never overwrite existing attributes from external claims
- This prevents a Google Workspace admin from injecting arbitrary `tenant_id` or `roles` via custom OIDC claims

**Client implementer guidance (token storage):**
- Access tokens: in-memory only (preferred) or OS keychain
- Refresh tokens: OS keychain or encrypted file, never plaintext
- DCR registration response: persist `client_id` in OS keychain
- Explicitly warn: do NOT store tokens in `~/.config/*.json` or log files in plaintext

**Deployment:**
- Own Cloud Run service
- Own database (same Cloud SQL instance, database: `keycloak`)
- Health: `/health/ready` endpoint
- Scale-to-zero capable (~2-5/mo lean, ~10-15/mo production)

### 4.2 ContextForge (Gateway)

**What:** IBM ContextForge — MCP gateway, registry, and proxy.
**Version:** 1.0.0-GA (releasing ~28 March 2026), pinned by image digest. **Fallback:** if GA is delayed, use 1.0.0-RC-2 (current, proven in v3). Upgrade path to 1.2.0 (GraphQL, ~30 April 2026).
**License:** Apache 2.0

**We use these ContextForge features natively (not rebuild):**

| Category | Features |
|----------|----------|
| **Tool registry** | Backend registration, virtual servers, tool discovery |
| **RBAC** | 4 built-in roles, custom roles, per-permission granularity, SQL-level tool visibility |
| **Rate limiting** | Per-user, per-tenant, per-tool (in-memory, distributed in v1.2.0) |
| **Circuit breakers** | Per-tool, 3-state, configurable thresholds |
| **Observability** | OpenTelemetry tracing (4 exporters), Prometheus metrics (12+), structured logging, correlation IDs |
| **Caching** | Tool result caching (SHA256 key, configurable TTL) |
| **Security** | SSRF protection, input validation, 1MB payload limit, PII filter plugin, secrets detection |
| **Audit** | Every action logged with user, IP, correlation ID, 90-day retention |
| **REST passthrough** | Register REST API endpoints directly as MCP tools |
| **A2A agents** | Register external AI agents (OpenAI, Anthropic, custom) as tools |
| **Plugin system** | 16 hook points, 42+ built-in plugins, native Python + external gRPC/MCP |
| **Session management** | Per-key pool, TTL, health check, affinity |
| **Compression** | GZip/Brotli/Zstd (30-70% bandwidth reduction) |
| **Admin UI** | Built-in web UI for management and observability dashboards |

**What ContextForge does NOT provide (we must solve):**
- Tenant context injection — routing the right API credentials per tenant to backends
- Keycloak integration — configuring ContextForge to trust Keycloak JWTs
- Bootstrap automation — registering backends and configuring RBAC on startup

**Auth integration with Keycloak (CRITICAL — v3 trust model does NOT carry forward):**

v3 used `TRUST_PROXY_AUTH_DANGEROUSLY=true` + `AUTH_REQUIRED=false` because everything was on localhost in one container. **This is unsafe in v4** — sidecars share localhost and can spoof identity headers. All three security audits flagged this as CRITICAL.

v4 approach: **ContextForge validates Keycloak JWTs directly.**
- `AUTH_REQUIRED=true` — ContextForge requires a valid JWT on every request
- `MCP_CLIENT_AUTH_ENABLED=true` — ContextForge validates JWT signatures
- JWKS endpoint: `https://<keycloak-url>/realms/fluid/protocol/openid-connect/certs`
- `TRUST_PROXY_AUTH=false` — no header trust, JWT is the only identity source
- `TRUST_PROXY_AUTH_DANGEROUSLY=false` — explicitly disabled

This avoids the v3 Double-Auth Problem because v4 has ONE JWT issuer (Keycloak) and ONE JWT validator (ContextForge). v3 had two incompatible systems (HMAC vs RS256). v4 has one (RS256 from Keycloak, validated by ContextForge via JWKS).

**JWT validation requirements:**
- Algorithm: accept RS256 only, reject all others
- Clock skew tolerance: 30 seconds (accept tokens within this window of expiry/not-before)
- Header restriction: ignore `jku`, `x5u`, `x5c`, and `x5t` headers in incoming JWTs. Always fetch keys from the configured JWKS endpoint only. Never follow URLs embedded in JWT headers.
- Unknown `kid` refresh rate limit: max 1 JWKS refresh per 60 seconds to prevent cache-busting DoS. `kid` values used only for key matching within the JWKS response — never as input to database queries or filesystem paths.
- Token reuse after logout: access tokens remain valid up to 1 hour after logout (accepted risk — JWT validation is stateless). Mitigations: short lifetime (1 hour), HTTPS-only transport, tokens never logged by ContextForge.
- PII in JWT payload: `email` claim is PII. JWTs are signed but not encrypted (readable if intercepted). Acceptable because: HTTPS-only, short lifetime, auto-masked in structured logs. JWE not used — adds complexity without meaningful gain in this architecture.
- Issuer (`iss`): must match Keycloak realm URL exactly
- Audience (`aud`): must contain the fixed resource-server audience value (e.g., `fluid-gateway`) configured via Keycloak realm-level audience mapper (see Section 4.1 audience mapper)
- JWKS caching: 10-minute TTL, refresh on unknown `kid`
- JWKS fetch failure: **fail closed** (reject all tokens)
- Key rotation: Keycloak keeps old key in JWKS for 1 hour after rotation (matches access token lifetime)

**User identity resolution:**
- ContextForge reads `sub` claim from validated JWT (not from a header)
- Maps to ContextForge user via email claim
- `SSO_AUTO_CREATE_USERS=true` — auto-create on first login as **viewer** role (not admin)
- Admin promotion: explicit allowlist of admin emails, NOT domain-wide (`SSO_GOOGLE_ADMIN_DOMAINS` removed)

### 4.3 Apollo MCP Server (Shopify GraphQL — sidecar)

**What:** Apollo MCP Server — Rust-based MCP server for GraphQL APIs.
**Version:** v1.9.0 (pinned by commit hash, not tag)
**Transport:** Verify whether ContextForge 1.0.0-GA fixes the StreamableHTTP client bug from v3. If not, use SSE transport (proven stable). See open items.
**Port:** 8000
**Lifecycle:** Temporary — ContextForge v1.2.0 (April 2026) ships native GraphQL-to-MCP translation. Apollo can be retired then.

**Key config:**
- `introspection.execute: true` — dynamic query composition (v3 insight: execute tool > predefined operations)
- `introspection.validate: true` — query validation before execution
- Schema: Shopify GraphQL schema (auto-introspected)

**Query cost control (v3 gap — open pipe to Shopify):**
- ContextForge rate limiting counts requests, not query cost. A single `products(first:250){variants(first:250)}` = 62,500 nodes but counts as 1 request.
- Short-term: use ContextForge's per-tool rate limiting + Watchdog plugin (max runtime per tool call) as a blunt guard
- Medium-term: implement a ContextForge `tool_pre_invoke` plugin that estimates GraphQL query cost from the AST and rejects queries exceeding a per-user budget
- Shopify rate limit headers (`X-Shop-Api-Call-Limit`, `Retry-After`) should be forwarded to the client — requires ContextForge plugin or Apollo config to preserve upstream headers

### 4.4 dev-mcp (Shopify Docs — sidecar)

**What:** @shopify/dev-mcp wrapped by supergateway.
**Why sidecar:** stdio-only server, needs HTTP translation.
**Container:** `FROM node:22-slim` + supergateway + dev-mcp

```dockerfile
FROM node:22.14.0-slim AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --production

FROM node:22.14.0-slim
RUN apt-get update && apt-get install -y tini && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/node_modules /app/node_modules
USER node
EXPOSE 8003
ENTRYPOINT ["tini", "--"]
CMD ["node", "/app/node_modules/.bin/supergateway", "--port", "8003", "--", "dev-mcp"]
```

**Hardening requirements (all sidecar containers):**
- Non-root user (`USER node` for Node.js, `USER 1001` for Python)
- Pinned base image by version AND digest
- Dependencies installed at build time with lock file (`npm ci` not `npm install -g`)
- `tini` for signal handling
- Read-only root filesystem (`readOnlyRootFilesystem: true` in Cloud Run config)
- Explicit `.dockerignore` excluding `.git/`, `docs/`, `.env*`, `node_modules/`

### 4.5 Google Sheets MCP (sidecar)

**What:** xing5/mcp-google-sheets wrapped by supergateway.
**Why sidecar:** stdio-only server, needs HTTP translation.
**Auth:** Service account (headless-compatible)
**Container:** Same hardening pattern as dev-mcp — pinned Python base, non-root user, `uv pip install` with `--require-hashes` from locked requirements, tini for signals, read-only rootfs.

### 4.6 PostgreSQL (Cloud SQL)

**What:** Cloud SQL PostgreSQL (existing, db-f1-micro)
**Databases:**
- `keycloak` — Keycloak auth state (sessions, clients, users)
- `contextforge` — ContextForge state (tools, audit, cache, RBAC)

**Separation:** Each service owns its database. No shared tables. Independent schema migrations.
**Database users:** Separate PostgreSQL users per database (`keycloak_user` for keycloak DB, `contextforge_user` for contextforge DB). Each user has access ONLY to its own database. Neither user has DROP DATABASE permissions. Prevents cross-service data access if one is compromised.

**Data protection:**
- Cloud SQL automated backups: enabled, 7-day retention (verify for db-f1-micro tier)
- Point-in-time recovery: enabled
- RPO: 24 hours (lean), 1 hour (production). RTO: 30 minutes (lean), 10 minutes (production).
- Keycloak realm JSON export as secondary backup (version-controlled in repo, importable via `--import-realm`)
- Recovery procedure: restore Cloud SQL from backup → Keycloak auto-imports realm JSON on startup → bootstrap re-registers backends
- Human error mitigation: `keycloak_user` and `contextforge_user` cannot DROP DATABASE or DROP TABLE on critical tables

**Connection pool budget (db-f1-micro max 25 connections):**

| User | Pool size | Purpose |
|------|-----------|---------|
| keycloak_user | 10 | Keycloak sessions, tokens, events (Keycloak production default is ~100 — far too high for db-f1-micro. Configure `KC_DB_POOL_INITIAL_SIZE=5`, `KC_DB_POOL_MAX_SIZE=10`) |
| contextforge_user | 10 | Tool registry, audit, cache, RBAC |
| Reserved | 5 | PostgreSQL system + superuser for maintenance |
| **Total** | **25** | Matches db-f1-micro limit |

Upgrade to db-g1-small (max 50 connections) when connection pool pressure increases.

## 5. Backend Integration Model

ContextForge supports multiple backend types natively. No custom proxy layers.

| Backend type | How to add | Example |
|---|---|---|
| **MCP server (HTTP)** | Add as sidecar container, register in ContextForge | Apollo, any HTTP MCP server |
| **MCP server (stdio)** | Wrap with supergateway, add as sidecar, register | dev-mcp, google-sheets |
| **REST API** | Register directly in ContextForge via REST passthrough | Stripe, Twilio, SendGrid |
| **A2A agent** | Register directly in ContextForge via A2A gateway | External AI agents |
| **gRPC service** | Register directly (experimental, auto-discovery) | Internal microservices |
| **GraphQL API** | Via Apollo sidecar now; native in ContextForge v1.2.0 | Shopify |

### Adding a new REST API vertical (e.g., Stripe)

1. Register REST endpoints in ContextForge Admin API
2. Configure RBAC (who can access)
3. Add tenant's API key to Secret Manager
4. Done — no new container, no code, no deploy

### Adding a new MCP server (e.g., GitHub MCP)

1. Add sidecar container definition to Cloud Run config
2. Register in ContextForge
3. Configure RBAC
4. Deploy — one new sidecar

## 6. Multi-Tenant Design

**Principle:** Modules are tenant-unaware. Tenant context is injected at the edge and flows through as data.

**Keycloak:** Each tenant can be a Keycloak realm (full isolation) or users with a `tenant_id` attribute (shared realm). Start with shared realm, split if needed.

**ContextForge:** Tenant ID flows via JWT claim → user attribute → RBAC team membership. Tool visibility is per-team.

**Backend credentials:** Per-tenant secrets stored in Secret Manager. Injected based on tenant ID in the request.

**What we must build:** A thin layer that reads `tenant_id` from the JWT, resolves the tenant's credentials from Secret Manager, and injects them into backend requests. This is the ONE custom component in the architecture — our unique value-add.

**Backend credential lifecycle (tenant context injection must handle):**
- Credential health checking: validate backend API tokens on first use or periodically
- Distinct error codes: "backend credential invalid/expired" vs "tool execution failed" — so AI clients get actionable errors
- Credential renewal flow: when a tenant's Shopify token expires, surface it clearly (not as a generic tool error)
- Cache invalidation: if a credential is refreshed in Secret Manager, the gateway must pick up the new value (Secret Manager volume mounts auto-refresh on instance startup)

## 7. Observability

All provided natively. Configuration only.

### ContextForge (enable, not build)

| Capability | Config |
|-----------|--------|
| Distributed tracing | `OTEL_ENABLE_OBSERVABILITY=true`, `OTEL_TRACES_EXPORTER=otlp`, `OTEL_EXPORTER_OTLP_ENDPOINT=https://telemetry.googleapis.com` |
| Prometheus metrics | `ENABLE_METRICS=true`, scrape `/metrics/prometheus` |
| Structured logging | `LOG_LEVEL=INFO`, auto-masks secrets, correlation IDs on every request |
| Internal trace viewer | `OBSERVABILITY_ENABLED=true`, Admin UI at `/admin/observability` |
| Tool telemetry | ToolsTelemetryExporter plugin (built-in, priority 200) |

### Cloud Run (automatic, zero config)

- Request count, latency (p50/p95/p99), errors — automatic
- CPU/memory/instance metrics — automatic
- Cold start metrics — automatic
- Error Reporting — automatic (stack traces in stdout)
- Request logging — automatic

### Sidecar logging and trace propagation

- Sidecar containers should write JSON-structured logs to stdout where possible (Cloud Logging auto-parses)
- If sidecar logs are unstructured (Apollo Rust `tracing`, supergateway console.log), accept this — ContextForge's structured logs with correlation IDs are the primary observability source
- **Trace context propagation:** When ContextForge calls sidecars on localhost, HTTP requests MUST include `traceparent` headers (W3C Trace Context). Sidecars should propagate these headers for end-to-end distributed tracing. Without this, sidecar logs use independent request IDs (same v3 problem in new topology).

### Alerting (config-only)

- Cloud Monitoring alert policies:
  - Error rate > 5% for 5 minutes
  - Latency p99 > 5s for 5 minutes
  - Instance restart count > 3 in 10 minutes
- SLO: 99.5% availability, 2s p95 latency

## 8. Security

### Network boundary

- ContextForge (gateway) is directly externally reachable via Cloud Run (`--ingress=all`)
- Keycloak auth endpoints (`/realms/*`, `/.well-known/*`) are externally reachable via Application Load Balancer with path rules. Keycloak Cloud Run service uses `--ingress=internal-and-cloud-load-balancing` — NOT directly public. Admin console (`/admin`) is blocked at ALB level.
- Apollo, dev-mcp, sheets are sidecars on localhost — not exposed externally
- All external traffic is HTTPS (Cloud Run TLS termination + ALB SSL)
- VPC: Direct VPC egress for Cloud SQL private IP access

**Sidecar isolation model (explicitly documented):**
- All sidecars share the instance's service account and network namespace
- A compromised sidecar has the same Secret Manager access and Cloud SQL connectivity as ContextForge
- This is acceptable because sidecars run known code — Apollo (Rust, open-source, Apollo GraphQL team) and supergateway wrappers
- **supergateway trust note:** supergateway is a third-party npm package running in the shared trust boundary with full data visibility. Mitigations: (a) vendor the specific version into Artifact Registry or repo, (b) include in CVE scanning scope, (c) verify maintainer identity and release signing before adoption, (d) consider ContextForge's native `mcpgateway.translate` as a zero-third-party alternative if supergateway provenance is insufficient
- If untrusted MCP servers are added in future, they MUST be separate Cloud Run services with minimal-privilege service accounts

**SSRF protection:**
- `SSRF_ALLOW_LOCALHOST=false` and `SSRF_ALLOW_PRIVATE_NETWORKS=false` as defaults
- ContextForge backend registrations (gateways) have per-tool URL allowlists — registered backends on localhost are permitted through the gateway registration, not through the blanket SSRF flag
- **Open item:** Verify ContextForge's SSRF filter distinguishes between "registered backend URLs" and "user-supplied URLs in tool arguments." If it doesn't, we may need `SSRF_ALLOW_LOCALHOST=true` with the ContextForge SSRF allowlist feature for argument-supplied URLs. Test before implementation.

### GCP IAM model

**Service accounts (per-service, least privilege):**

| SA | Cloud Run Service | Key IAM Roles |
|----|------------------|---------------|
| `gateway-sa@` | Gateway (ContextForge + sidecars) | `roles/secretmanager.secretAccessor` (gateway secrets only), `roles/cloudsql.client`, `roles/run.invoker` (on Keycloak service for JWKS) |
| `keycloak-sa@` | Keycloak | `roles/secretmanager.secretAccessor` (Keycloak secrets only), `roles/cloudsql.client` |
| `cloudbuild-sa@` | Cloud Build | `roles/cloudbuild.builds.builder`, `roles/artifactregistry.writer`, `roles/run.developer`, `roles/iam.serviceAccountUser` (on gateway-sa + keycloak-sa for deploy) |

**Cloud Run invoker bindings:**

| Service | Invoker | Why |
|---------|---------|-----|
| Gateway | `allUsers` (public) | AI clients need direct access. Auth handled by Keycloak JWT. |
| Keycloak | `allUsers` via ALB only | OAuth endpoints must be publicly reachable. Admin console blocked by ALB path rules. |

**SA impersonation policy:** Only `cloudbuild-sa@` may impersonate `gateway-sa@` and `keycloak-sa@` (for deploy). No human accounts may impersonate production SAs. Deny all other `roles/iam.serviceAccountUser` and `roles/iam.serviceAccountTokenCreator` bindings.

**Cloud SQL connection:** Direct VPC Egress from Cloud Run → Cloud SQL private IP. Both SAs need `roles/cloudsql.client`. No Cloud SQL Auth Proxy needed (VPC provides network-level access, PostgreSQL user/password provides app-level auth).

**Post-deployment IAM hygiene:** After 30 days of operation, review GCP IAM Recommender findings and remove unused permissions from all SAs.

**Egress controls:**
- VPC firewall rules restrict outbound traffic to known destinations (Shopify API, Google APIs, Keycloak)
- Consider VPC Service Controls for production tier

### Auth chain

1. AI Client authenticates with Keycloak (OAuth 2.1 + PKCE S256)
2. Keycloak issues JWT with sub, email, roles, tenant_id claims
3. ContextForge validates JWT via Keycloak JWKS endpoint
4. ContextForge resolves user identity from JWT claims
5. RBAC checks per-tool permissions
6. Audit trail records user, action, tool, timestamp

### Secrets management

- All secrets in GCP Secret Manager
- Cloud Run injects via `--set-secrets` (env vars or volume mounts)
- Each service owns its own secrets (no sharing between Keycloak and gateway)
- **Per-service service accounts:** `keycloak-sa@` and `gateway-sa@` with IAM bindings only to their own secrets (least privilege)
- Key rotation: Secret Manager versioning + Keycloak key rotation for JWTs
- **Key versioning scheme:** Store key ID with encrypted data. Support old+new keys simultaneously during rotation window. Never require coordinated downtime for key rotation.
- Refresh token absolute lifetime: 7 days max (chain of rotated tokens cannot exceed this)
- `AUTH_ENCRYPTION_SECRET` must be its own unique secret — NO fallback to `JWT_SECRET_KEY`
- No secret material in COPY'd files — secrets are runtime-only via `--set-secrets`
- CI must run `trufflehog` or `gitleaks` on build context before building

### Container security

- Non-root user in all containers (UID 1001 for ContextForge, `node` for Node.js sidecars)
- Minimal base images (distroless where possible, UBI Minimal for ContextForge)
- All binaries SHA256-verified at build time (including uv)
- All base images pinned by digest, not just tag
- No runtime dependency fetching (everything installed at build time with lock files)
- Dependencies pinned with lock files (`package-lock.json`, pip freeze, `Cargo.lock`)
- Read-only root filesystem on all containers (`readOnlyRootFilesystem: true`)
- Explicit `.dockerignore` in every build context
- Cloud Run Binary Authorization: mandatory for production tier, optional for dev/lean
- Node.js pinned to exact version (`node:22.14.0-slim`)

### RBAC

- **Single authoritative role source: Keycloak.** Keycloak JWT `roles` claim is canonical. ContextForge MUST derive roles from JWT claims on every request, NOT from its DB `is_admin` flag.
- **Implementation:** Use ContextForge's `HTTP_AUTH_RESOLVE_USER` plugin hook to read `roles` from the JWT and set the user's ContextForge role per-request. This overrides the DB-stored role. Keycloak role revocation propagates immediately (next request).
- **Default-deny for missing claims:** If the JWT `roles` claim is absent or empty, the user MUST be treated as having NO role (deny all tool invocations). The `viewer` default applies only at auto-creation time, not as a runtime fallback.
- Role mapping: Keycloak `admin` → ContextForge `platform_admin`, Keycloak `developer` → ContextForge `developer`, Keycloak `viewer` → ContextForge `viewer`. No role claim → deny all.
- New users auto-created as `viewer` — no domain-wide admin promotion
- **Admin promotion:** Explicit admin email list in Keycloak realm config (exported as JSON, version-controlled in repo). Add admin: update realm JSON → `kcadm.sh` or Keycloak Admin API. No env var domain-wide promotion.
- Per-tool visibility via SQL-level WHERE clauses
- Role-scoped virtual servers: `fluid-admin` (all tools), `fluid-viewer` (read-only tools)
- Admin UI and Admin API: disabled by default for external access. Enabled during bootstrap (init container) for backend registration, then access restricted to `platform_admin` role only. The Admin API is always reachable internally for the bootstrap process but protected by JWT auth (`AUTH_REQUIRED=true`).

### Keycloak cold start + auth availability

- If Keycloak is down (cold start, crash), ContextForge MUST reject all requests (fail closed)
- ContextForge startup gate: verify Keycloak JWKS endpoint is reachable before accepting traffic
- For production tier: Keycloak `min-instances=1` (always warm)
- **Startup ordering for lean tier (both scale-to-zero):** Client request hits gateway → gateway tries JWKS → fails → returns 503 → Cloud Run wakes Keycloak → retry succeeds. No circular dependency — gateway can start without Keycloak but won't serve authenticated requests until JWKS is reachable.
- Rate limiting on Keycloak auth endpoints: configure Keycloak's brute force detection (account lockout after 5 failed attempts, unlock after 15 minutes)

### Health probes

**Cloud Run supports HTTP/gRPC for liveness probes, TCP for startup probes only.**

**Startup probes (TCP — verify container started):**
- Apollo: TCP on port 8000
- dev-mcp: TCP on port 8003
- Google Sheets: TCP on port 8004

**Liveness probes (HTTP — detect deadlocks during runtime):**
- ContextForge: HTTP GET `/health` every 30s
- Keycloak: HTTP GET `/health/live` every 30s
- Sidecars: No HTTP liveness (they don't expose health endpoints). Rely on ContextForge's circuit breaker (5 failures → 60s cooldown) to handle degraded sidecars at runtime. If a sidecar crashes, Cloud Run restarts it based on exit code, not liveness probe.
- **Fallback if sidecars need liveness:** Add a `/healthz` endpoint to supergateway wrappers (feature request or thin wrapper). Until then, startup probes + circuit breaker is sufficient.

### Audit log integrity

- PostgreSQL `contextforge_user` must have INSERT-only permission on audit tables (no UPDATE/DELETE)
- ContextForge Admin API must NOT expose audit deletion endpoints
- Export audit records to Cloud Logging as tamper-evident secondary store (separate IAM from gateway SA)
- Acceptance test: verify `DELETE FROM audit_log` fails as `contextforge_user`

### Tool description security

- Tool descriptions from registered backends are forwarded to AI clients in `tools/list` responses
- For trusted sidecars (Apollo, dev-mcp, sheets): descriptions are stable and known — acceptable
- For future untrusted backends: implement a `tool_post_discovery` plugin that sanitizes descriptions — strip instruction-like language, enforce max length, flag prompt injection patterns
- Add to open items when adding first untrusted backend

### Plugin execution order

- Verify ContextForge plugin execution order: `HTTP_AUTH_RESOLVE_USER` (role derivation) must run BEFORE RBAC enforcement, and no plugin hook executes between role resolution and tool-access checks
- Admin-authored plugins only — no user-uploaded plugins
- Add as open item: document plugin priority order relative to RBAC

### Data privacy & compliance

The gateway processes tenant PII (Shopify customer names, emails, addresses, order history). Regulatory requirements:

**GDPR / Australian Privacy Act considerations:**
- **Audit log vs right-to-erasure:** Audit logs are INSERT-only for integrity (Section 8). For GDPR Art. 17 erasure requests: pseudonymize PII fields in audit records (replace email with hash) while preserving the audit chain integrity. Document this as legitimate interest under GDPR Art. 6(1)(f) for security auditing.
- **Data processing:** Gateway acts as data processor for tenant data. Multi-tenant deployment requires a Data Processing Agreement (DPA) template for tenants. Add as implementation deliverable.
- **Cross-border data transfer:** Cloud SQL in asia-southeast1 (Singapore). EU tenants require Standard Contractual Clauses or adequacy decision confirmation. Australian tenants: APP 8 requires reasonable steps for overseas disclosure. Document data residency constraints per tenant tier.
- **Data subject access:** Must be able to query all data associated with a given individual across ContextForge audit logs and Keycloak event logs (correlation via email + `sid` claim).

### Incident response

**Credential compromise playbook:**
1. Rotate compromised credential in Secret Manager (new version)
2. Restart affected Cloud Run service (picks up new secret)
3. Verify backend connectivity with new credential
4. Audit: check tool invocation logs for unauthorized access during compromise window

**Gateway breach containment:**
1. Detect: anomalous audit patterns, unexpected egress, error rate spike
2. Contain: delete active Cloud Run revision, rotate ALL secrets (Shopify tokens, DB passwords, JWT signing keys, Keycloak admin password)
3. Revoke: logout all Keycloak sessions, rotate realm signing key
4. Preserve: lock Cloud Logging retention, export to immutable storage for forensics
5. Notify: GDPR 72-hour notification (if PII accessed), Australian NDB scheme (if serious harm likely)

### Cloud Run revision hygiene

- Post-deploy CI step: delete all revisions except the 2 most recent
- Prevents old (potentially vulnerable) revisions from being accessible via revision-specific URLs
- Service uses `--allow-unauthenticated`, so revision-specific URLs are publicly reachable

### Error sanitization

- ContextForge Pydantic/FastAPI errors must NOT expose framework name, version, or external URLs
- Configure ContextForge error handling to return generic error messages to clients
- Internal error details logged (with correlation ID) but never returned in HTTP responses

### Cloud Run deployment flags

- `--no-cpu-throttling` — REQUIRED for gateway service (sidecars run persistent processes)
- `--cpu-boost` — for faster cold starts
- `--session-affinity` — optional, for session-aware routing

### Sidecar orchestration

**Startup ordering (Cloud Run container dependencies):**
- Sidecars (Apollo, dev-mcp, sheets) start first with `condition: started`
- ContextForge depends on all three sidecars with `condition: healthy` (waits for their startup probes). **Note:** Container dependencies with health conditions are Pre-GA as of March 2026. Fallback: use ContextForge retry logic on backend registration (circuit breaker handles sidecars that aren't ready yet).
- Bootstrap init container depends on ContextForge with `condition: healthy`
- This replaces v3's bash orchestration with Cloud Run-native dependency management

**Graceful shutdown:**
- `terminationGracePeriodSeconds: 30` (Shopify GraphQL queries can take 5-10s)
- On SIGTERM: ContextForge stops accepting new requests, drains in-flight, then exits
- Sidecars must stay alive longer than ContextForge to complete in-flight tool calls
- MCP SSE streams (dev-mcp, sheets) close gracefully on SIGTERM with final event

**Per-container resource limits:**

| Container | CPU | Memory | Notes |
|-----------|-----|--------|-------|
| ContextForge (main) | 1.0 | 2Gi | Gateway brain, largest footprint |
| Apollo | 0.5 | 512Mi | Rust binary, efficient |
| dev-mcp | 0.25 | 512Mi | Node.js + supergateway |
| Google Sheets | 0.25 | 256Mi | Python + supergateway |
| **Total instance** | **2.0** | **~3.3Gi** | Leaves headroom under 4Gi |

**tmpfs mounts (required for read-only rootfs):**

| Container | Mount | Size | Purpose |
|-----------|-------|------|---------|
| All | `/tmp` | 128Mi | General temp files |
| ContextForge | `/app/data` | 64Mi | Alembic temp, OTEL SDK |
| Node.js sidecars | `/.npm` | 64Mi | npm cache (if needed) |
| Python sidecars | `/.cache` | 64Mi | uv/pip cache |
| Keycloak | `/opt/keycloak/data` | 128Mi | JVM class cache, Keycloak data |

**Crash-loop handling:**
- Liveness probes: `failureThreshold: 3` (restart after 3 consecutive failures)
- After repeated restarts, Cloud Run marks the instance unhealthy and replaces it entirely
- ContextForge circuit breaker (5 failures → 60s cooldown) handles degraded sidecar availability
- Sidecar multiplication note: each additional instance (max-instances > 1) duplicates ALL sidecars. Each Apollo instance introspects the Shopify schema independently. Shopify API rate limits are shared across instances via the same access token — budget accordingly.

### Network policy between services

- **Gateway-to-Keycloak JWKS:** Use Direct VPC Egress on the gateway service. Set Keycloak `--ingress=internal-and-cloud-load-balancing`. Gateway calls Keycloak via standard `*.run.app` URL over the VPC network, bypassing public internet. (`*.run.internal` does not exist — use VPC networking instead.)
- Public access to Keycloak: route only `/realms/*` and `/.well-known/*` via public ingress (Application Load Balancer with path rules), blocking `/admin/*`.
- Admin console: accessible only via VPN/IAP or `kcadm.sh` from Cloud Run jobs (see Keycloak admin console security above).

## 9. CI/CD

### Build system

Two-layer Docker build (carried from v3):
- `Dockerfile.base` — immutable upstream dependencies (rebuild rarely, ~10-20 min)
- `Dockerfile` — app config and scripts (rebuild fast, ~5 sec)

### Cloud Build pipeline

1. **Secret scan** — `trufflehog` or `gitleaks` on build context (fail on any finding)
2. Lint + validate config
3. Build container images
4. **CVE scan** — `trivy image` on all built images. Gate: CRITICAL or HIGH with fix available = build fails. Unfixable CVEs tracked in `.cve-allowlist`.
5. **SBOM generation** — `syft` on each image, output CycloneDX JSON, push as Artifact Registry attestation
6. Push to Artifact Registry
7. Deploy to Cloud Run
8. Health check verification (Keycloak JWKS reachable, ContextForge `/health` 200, all sidecars healthy)

### Dependency integrity (v3 gaps fixed)

| Component | v3 | v4 |
|-----------|-----|-----|
| Apollo | git clone, no verification | Pin commit hash + verify |
| ContextForge | Docker tag only | Pin image digest |
| Node.js | Unpinned microdnf | Pin exact version (e.g., `22.14.0-slim`) |
| uv | No hash check | SHA256 verify |
| dev-mcp | npx at runtime | npm install at build time with package-lock.json |
| pip packages | No lock file | pip freeze lock file in image |

## 10. Scaling

Same code, different infra knobs.

| Mode | Keycloak | Gateway | PostgreSQL | Monthly cost |
|------|----------|---------|------------|-------------|
| **Dev** | docker compose | docker compose | docker compose (PostgreSQL) | $0 |
| **Lean** | min=0, scale-to-zero | min=0, scale-to-zero | db-f1-micro | ~$16-21 |
| **Production** | min=1 | min=1 | db-g1-small + HA | ~$40-60 |
| **Enterprise** | min=2, multi-region | min=2, multi-region | regional HA | ~$150+ |

**No code changes between any tier.** Only Cloud Run config and database tier change.

**Dev mode:** A `docker-compose.yml` at repo root that starts all services locally:
- Keycloak container (with imported realm JSON)
- ContextForge container
- Apollo sidecar
- dev-mcp sidecar
- Google Sheets sidecar
- PostgreSQL container
Same images as production, different orchestration.

**Lean mode cold start note:** Keycloak JVM takes 15-30s to start. First request after idle will see auth latency. Acceptable for low-traffic use. For interactive use, set Keycloak `min-instances=1` (production tier).

## 11. Migration from v3

### What stays
- Cloud SQL PostgreSQL (same instance, add `keycloak` database)
- Artifact Registry (same repo)
- Cloud Build (updated configs)
- GitHub repo (same)
- Custom domain (junlinleather.com)
- All existing ContextForge config concepts (gateways, servers, tools)

### What changes
- mcp-auth-proxy → Keycloak (separate service)
- Monolith container → main + sidecars
- Bash orchestration → Cloud Run container management
- In-memory auth state → Keycloak PostgreSQL
- npx runtime fetch → build-time install

### What's new
- Keycloak Cloud Run service
- Sidecar container definitions
- Tenant context injection layer
- CVE scanning in CI/CD
- SBOM generation
- Dependency lock files

## 12. Bootstrap & Backend Registration

v3 used a 300-line `bootstrap.sh` for backend registration. v4 still needs to register backends in ContextForge on startup, but the approach is simpler:

**ContextForge three-tier model (v3 lesson — empty tools/list without this):**
1. `POST /gateways` — register each backend (triggers tool auto-discovery)
2. `POST /servers` — create virtual server that bundles discovered tools
3. MCP clients connect to `/servers/<UUID>/mcp`

**v4 bootstrap approach:**
- A lightweight init container (or ContextForge startup hook) that:
  1. Waits for all sidecar health checks to pass
  2. Registers each sidecar as a gateway in ContextForge
  3. Creates role-scoped virtual servers (`fluid-admin`, `fluid-viewer`)
  4. Configures RBAC teams and role mappings
- This replaces the bash orchestration — it's a single-purpose script, not a process manager
- Bootstrap JWT: 5-minute lifetime (not 30), expires naturally. If bootstrap exceeds 5 minutes (slow sidecar, tool discovery delay), the init container re-authenticates with Keycloak for a fresh JWT and continues (idempotent registrations prevent duplicate state)
- **Bootstrap client scope:** The bootstrap service account in Keycloak must have ONLY the permissions needed for ContextForge Admin API (backend registration, RBAC setup) — NOT full `realm-admin` or `manage-users`. A rogue backend registered within the 5-minute window persists beyond token expiry and receives user data. Acceptance test: verify registered gateways match the expected list after bootstrap
- Tool re-discovery: if a sidecar restarts and its tool list changes (e.g., schema update), re-registering the gateway in ContextForge refreshes the tool list. Bootstrap should be re-runnable, not just init-time. Open item: verify ContextForge gateway re-registration refreshes tool discovery.
- Bootstrap runs as a Cloud Run job or init container, not inside the main container
- **Bootstrap credentials:** Two-phase bootstrap: (1) Keycloak starts first with a pre-configured realm JSON (imported at container start via `--import-realm`). Realm JSON includes a bootstrap service account client. (2) Init container authenticates to Keycloak using this pre-configured client, obtains a JWT, then uses it to register backends in ContextForge. No chicken-and-egg — realm config is version-controlled and imported at startup.
- **Idempotent:** Bootstrap must be safe to re-run (handles "already exists" 409 responses gracefully). If it crashes mid-execution, re-running completes the remaining registrations.

**For REST API backends (no bootstrap needed):**
- Register via ContextForge Admin API or Admin UI
- No sidecar, no container, no deploy

## 13. Terminology

| Term | Definition |
|------|-----------|
| **Sidecar** | A container that runs alongside the main container (ContextForge) in the same Cloud Run instance, sharing network and service account |
| **Virtual server** | A ContextForge concept: a bundle of discovered tools exposed at a single MCP endpoint (`/servers/<UUID>/mcp`). Created via `POST /servers`. |
| **Backend / Gateway** | An MCP server, REST API, or A2A agent registered in ContextForge via `POST /gateways`. Each gateway triggers tool auto-discovery. |
| **Tool** | A single operation discovered from a backend (e.g., `execute`, `validate`, `search_docs`). Tools are what AI clients invoke. |

## 14. Upgrade Strategy

Keycloak and ContextForge both run database migrations on startup (Liquibase and Alembic). Upgrading requires care to avoid old and new revisions running against incompatible schemas.

**Procedure:**
1. Deploy new version with `--no-traffic` (creates revision but sends 0% traffic)
2. New revision starts, runs migration, passes health check
3. Verify via tagged revision URL that new version works
4. Migrate traffic: `gcloud run services update-traffic --to-revisions=NEW=100`
5. Delete old revision after verification

**Rules:**
- Never run two revisions concurrently against the same database during schema migration
- Test upgrade from N to N+1 in dev mode (docker-compose) before production
- Keycloak: use `--optimized` build in production (skip build phase on startup)
- ContextForge: Alembic uses advisory lock to prevent concurrent migrations (existing v3 behavior, carries forward)

## 15. Future (no code changes needed)

| When | What | How |
|------|------|-----|
| ContextForge 1.2.0 (April 2026) | Native GraphQL support | Remove Apollo sidecar, register Shopify GraphQL directly in ContextForge |
| ContextForge 1.2.0 | Distributed rate limiting | Scales beyond max-instances=1 for rate limiting |
| New REST API vertical | Add Stripe, Twilio, etc. | Register REST endpoints in ContextForge. No deploy. |
| New MCP server | Add any MCP server | Add sidecar. One deploy. |
| Scale out | Handle more traffic | Increase max-instances. No deploy. |
| Multi-region | Global availability | Add Cloud Run services in new regions. No code change. |

## 16. Acceptance Criteria (v4.0 MVP)

v4.0 is complete when ALL of these pass:

- [ ] Keycloak issues JWTs via OAuth 2.1 + PKCE S256
- [ ] ContextForge validates Keycloak JWTs via JWKS, rejects invalid/expired tokens
- [ ] RBAC enforced: viewer sees read-only tools, admin sees all tools, no-role gets denied
- [ ] All 3 sidecars registered and discoverable via `tools/list`
- [ ] One user authenticates via Google OAuth and invokes a Shopify tool end-to-end
- [ ] Bootstrap is idempotent and automated (init container)
- [ ] `docker-compose up` works for dev mode
- [ ] Cold start < 45s (lean tier, including Keycloak JVM)
- [ ] CVE scan passes in CI/CD (no unallowed CRITICAL/HIGH)
- [ ] Secret scan passes (no secrets in build context or committed files)
- [ ] All containers run as non-root with read-only rootfs
- [ ] Keycloak admin console is NOT publicly accessible
- [ ] ContextForge rejects requests when Keycloak is down (fail closed)
- [ ] Audit trail records user, tool, timestamp for every tool invocation
- [ ] Load test: 5 concurrent users, p95 latency < 2s, 0 errors (verify SLO targets before production tier)
- [ ] **Security: auth bypass** — request with NO Bearer token returns 401 (verifies `AUTH_REQUIRED=true` is set)
- [ ] **Security: JWT forgery** — JWT signed with wrong key returns 401 (verifies `MCP_CLIENT_AUTH_ENABLED=true`)
- [ ] **Security: PKCE required** — authorization request without `code_challenge` is rejected by Keycloak
- [ ] **Security: PKCE method** — authorization request with `code_challenge` but no `code_challenge_method` is rejected (not defaulted to `plain`)
- [ ] **Security: audience** — JWT with wrong `aud` claim is rejected by ContextForge
- [ ] **Security: feature flags** — token exchange, impersonation, device flow, CIBA endpoints all return 400/501
- [ ] **Security: DCR restrictions** — DCR with `grant_types=["client_credentials"]` or `token_endpoint_auth_method=client_secret_basic` is rejected
- [ ] **Security: bootstrap scope** — registered gateways after bootstrap match expected list exactly (no rogue backends)

## 17. Open items

- [ ] Verify Keycloak supports MCP-spec OAuth metadata at `/.well-known/oauth-authorization-server` (may need path rewrite or SPI extension for RFC 8414 vs OIDC discovery)
- [ ] Design tenant context injection layer (the one custom component)
- [ ] Test Keycloak on Cloud Run with scale-to-zero (cold start latency — JVM may be 15-30s)
- [ ] Evaluate Keycloak memory footprint with db-f1-micro PostgreSQL
- [ ] Plan v3 → v4 migration sequence (zero-downtime or maintenance window?)
- [ ] Verify ContextForge can validate Keycloak RS256 JWTs via JWKS with `AUTH_REQUIRED=true` without re-introducing Double-Auth Problem
- [ ] Test ContextForge role derivation from Keycloak JWT `roles` claim
- [ ] Create per-service service accounts with least-privilege Secret Manager bindings
- [ ] Record all base image digests in `.digests` file
- [ ] Verify Apollo transport type (StreamableHTTP vs SSE) works in ContextForge 1.0.0-GA (v3 had StreamableHTTP=False bug)
- [ ] Verify Keycloak password grant issues JWTs with proper `sub` claim (v3 fosite didn't)
- [ ] Verify Keycloak rejects PKCE `plain` method (may accept both by default)
- [ ] Configure Keycloak brute force detection on token/login endpoints
- [ ] Design bootstrap init container for backend registration
- [ ] Test cold start ordering: both services scale-to-zero, gateway needs JWKS from Keycloak
- [ ] Configure Cloud Run liveness probes per container
- [ ] Implement GraphQL query cost estimation plugin (medium-term)
- [ ] Configure error sanitization to prevent Pydantic framework leakage
- [ ] Use `strict=False` for JSON parsing of ContextForge responses (unescaped newlines in tool descriptions)
- [ ] Pin supergateway version in sidecar Dockerfiles (check latest stable at implementation time)
- [ ] Pin @shopify/dev-mcp version in package-lock.json
- [ ] Pin xing5/mcp-google-sheets version in requirements lock file
- [ ] Pin Apollo to specific commit hash (not just tag v1.9.0)
- [ ] Verify SSRF filter allows registered backend URLs on localhost while blocking user-supplied localhost URLs
- [ ] Create docker-compose.yml for dev mode
- [ ] Export Keycloak realm config as JSON, version-control in repo
- [ ] Define migration sequence (deploy Keycloak first → verify → deploy gateway → decommission v3)
- [ ] Specify Google Sheets sidecar Dockerfile (port 8004, Python base, non-root, tini)
- [ ] Configure Keycloak DCR client policy: Web Origins = empty (no CORS by default for public clients)
- [ ] Verify license for xing5/mcp-google-sheets (must be permissive: MIT/Apache/BSD)
- [ ] Verify supergateway npm package provenance and maintainer — vendor if insufficient
- [ ] Keycloak realm JSON export: use `--no-credentials` flag, replace secrets with placeholders, run gitleaks on realm JSON before committing
- [ ] Define `.cve-allowlist` governance: required fields (CVE ID, justification, approver, date, review-by), CI warns when fix becomes available
- [ ] Implement `HTTP_AUTH_RESOLVE_USER` plugin hook to derive ContextForge roles from JWT claims per-request (not from DB)
- [ ] Configure Keycloak admin console restriction (`KC_HOSTNAME_ADMIN` or `KC_FEATURES=admin2:disabled`)
- [ ] Configure Cloud Run internal URL for JWKS fetch (gateway → Keycloak)
- [ ] Add Shopify rate limit header forwarding to open items tracking
- [ ] Evaluate VPC Service Controls for production tier
- [ ] Set up Cloud Run Binary Authorization for production tier
- [ ] Add DPoP (RFC 9449) support as future enhancement when MCP spec adopts it
- [ ] Add acceptance tests for security properties: fail-closed on JWKS failure, sidecar cannot spoof identity, DB user isolation
- [ ] Configure Keycloak realm-level audience mapper to add fixed `fluid-gateway` audience to all tokens (DCR aud validation — Batch 7 finding)
- [ ] Implement DCR rate limiting via Cloud Armor WAF or ALB (Keycloak has no native DCR rate limiting — Batch 7 finding)
- [ ] Configure Keycloak Client Registration Policy: force public clients, restrict grant/response types, restrict scopes (Batch 7 finding)
- [ ] Resolve OAuth metadata path: Keycloak serves `/.well-known/openid-configuration`, MCP expects `/.well-known/oauth-authorization-server` — design rewrite/proxy solution (Batch 7 — elevated from verification to design decision)
- [ ] Verify `AUTH_REQUIRED` and `MCP_CLIENT_AUTH_ENABLED` upstream defaults in ContextForge source — both may default to `false` (fail-open). Add startup validation (Batch 7 finding)
- [ ] Verify Keycloak `db-pool-max-size` actual default in production mode (spec assumed 20, likely 100 — Batch 7 finding)
- [ ] Verify `AUTH_ENCRYPTION_SECRET` fallback behavior in ContextForge — does it silently fall back to `JWT_SECRET_KEY` if unset? (Batch 7 finding)
- [ ] Configure Keycloak DCR client expiration policy (90 days inactive) to prevent unbounded client table growth (Batch 7 finding)
- [ ] Verify Keycloak rejects refresh grants for disabled users (Batch 7 finding)
- [ ] Define authorization code lifetime explicitly (Keycloak default 60s is appropriate — document it)
- [ ] Verify PKCE Client Policy applies to DCR-created clients (must be bound to default client profile, not just manually created clients)
