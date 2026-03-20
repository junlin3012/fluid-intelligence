# Fluid Intelligence v3 — Full Retrospective

> Written 2026-03-19. This document captures every lesson from v3 to inform v4 design.
> It is the single source of truth for "what we learned."

---

## 1. What v3 Achieved

v3 is a working MCP gateway deployed on Cloud Run with:
- 27 tools across 3 backends (Apollo Shopify, dev-mcp, Google Sheets)
- OAuth 2.1 with Google login and password fallback
- Identity forwarding (X-Authenticated-User header)
- RBAC foundations (teams, roles, auto-create users)
- Cloud Trace via OTLP
- Security hardening (rate limiting, PKCE S256, 1h tokens, error sanitization)
- 176 unit tests, 26 E2E tests passing

This is real. An AI client can authenticate, discover 27 tools, and execute Shopify GraphQL queries with full audit trails. The BI test proved the full chain: tool discovery → product search → API docs → dynamic query → business insights.

## 2. What v3 Got Wrong

### 2.1 Monolith-in-a-Container

**The core architectural mistake.** Five independent processes (Apollo, ContextForge, dev-mcp bridge, sheets bridge, auth-proxy) crammed into one Cloud Run container, orchestrated by a 600+ line bash script.

**Why it happened:** Cloud Run charges per container, and stdio-based MCP servers (dev-mcp, google-sheets) need a local process to talk to. Putting everything in one container was the cheapest option.

**Consequences:**
- `max-instances=1` — in-memory auth state can't be shared across instances
- 4Gi memory for one container (5 processes + 98K-line schema)
- One deadlocked process = entire gateway down (no per-process liveness)
- No independent scaling — Apollo and auth-proxy have very different resource profiles
- Bash orchestration is fragile — process group signals, PID tracking, race conditions on SIGTERM
- Cold start ~15-20s (all 5 processes must start sequentially)

**Lesson for v4:** Separate concerns into independent services. Accept higher cost for reliability. If a component needs stdio, run it as a sidecar or translate it at build time, not runtime.

### 2.2 Auth Bolted On, Not Integrated

**mcp-auth-proxy sits in front as a reverse proxy** — it authenticates, strips the Authorization header, injects X-Authenticated-User, and forwards to ContextForge. This created:

- **The Double-Auth Problem** (hit twice): ContextForge has its own auth. `AUTH_REQUIRED=true` + auth-proxy = 401. Had to disable ContextForge auth entirely.
- **TRUST_PROXY_AUTH_DANGEROUSLY=true** — the setting name tells you this is a hack, not a design.
- **Password auth has no `sub` claim** — fosite (the Go OAuth library) doesn't set Subject for password flows. Password users are anonymous.
- **In-memory session state** — DCR registrations vanish on container restart. Every client re-authenticates.
- **Header coupling** — X-Authenticated-User is hardcoded in Go, read from env var in Python. Change one, forget the other = silent identity loss.

**Lesson for v4:** Auth must be a first-class component with persistent state, not a reverse proxy that strips and injects headers. Either use ContextForge's native auth (if it's capable enough) or build auth as a shared service with a database.

### 2.3 No Query Cost Control

**Apollo's `execute` tool accepts any GraphQL query** and sends it to Shopify. There is:
- No query cost estimation before execution
- No complexity limit (nested `products(first:250){variants(first:250)}` = 62,500 nodes)
- No budget per user
- No rate limit header forwarding (Shopify 429 headers dropped by the bridge)

An AI client can accidentally (or maliciously) hammer Shopify's API with expensive queries. The gateway provides power without guardrails.

**Lesson for v4:** A gateway without a control plane is a liability. Query cost estimation, per-user budgets, and upstream rate limit forwarding are not nice-to-haves — they're the difference between a gateway and an open pipe.

### 2.4 No Dependency Integrity

| Component | Integrity Check | Gap |
|-----------|----------------|-----|
| tini | SHA256 verified | Good |
| mcp-auth-proxy | SHA256 verified | Good |
| Apollo | `git clone` + `cargo build` | **No commit signature verification** |
| ContextForge | Base Docker image tag | **No digest pin** |
| Node.js/npm | `microdnf install` | **Unpinned version** |
| uv | GitHub release download | **No hash verification** |
| dev-mcp | `npx` at runtime | **Fresh download every start** |
| pip packages | No lock file | **No transitive dependency locks** |

Three components are properly verified. Five are not. A supply chain attack on any of the unverified components would compromise the gateway silently.

**Lesson for v4:** Pin everything. Hash everything. Lock everything. `npx` at runtime is never acceptable for production. Pre-install at build time with locked dependencies.

### 2.5 Observability Gaps

- **OTEL disabled by default** — `OTEL_ENABLE_OBSERVABILITY=false` in defaults.env
- **No custom metrics** — zero Cloud Monitoring metrics (tool call count, latency, error rate)
- **No liveness probe** — deadlocked process passes startup probe but is never detected
- **No request correlation** — auth-proxy, ContextForge, and Apollo logs use different request IDs
- **No alerting** — no Cloud Monitoring alert policies

The system is flying blind. We know it's running (health checks pass) but not how well.

**Lesson for v4:** Observability is not optional. Ship with metrics, traces, and alerts from day one. If you can't measure it, you can't operate it.

### 2.6 Secrets Coupling

Four secrets are shared between the gateway and auth proxy:
- `shopify-client-id` / `shopify-client-secret`
- `db-password`
- `shopify-token-encryption-key`

Rotating any secret requires coordinated changes to both services. There's no key versioning — compromise means "rotate everything at once and hope."

**Lesson for v4:** Each service should own its secrets independently. Key versioning (store key ID with encrypted data, support old+new keys during rotation) is table stakes for production.

### 2.7 Build System Assumptions

Spent 13+ Cloud Build iterations ($6-13 total, 1+ hour) on issues that could have been caught locally:
- Config written without reading source code (3 times)
- One-at-a-time error fixing instead of reading ALL logs
- `uv pip install` corrupting the ContextForge venv
- Wrong health endpoints, wrong port variables, wrong host defaults

**Lesson for v4:** Every external dependency must be source-verified before integration. Every build failure must be fully analyzed before the next build. Local validation > production deploys.

## 3. What v3 Got Right

### 3.1 Compose, Don't Build

Choosing ContextForge + Apollo + mcp-auth-proxy instead of building from scratch was the right call. We got:
- Full MCP protocol compliance for free
- OpenTelemetry integration for free
- RBAC foundations for free
- OAuth 2.1 server for free
- GraphQL execution for free

The compose strategy delivered 27 tools in 2 days. Building from scratch would have taken months.

**Carry forward to v4:** Keep composing. But choose components with cleaner integration points.

### 3.2 Two-Layer Docker Build

Fat base image (rebuild rarely, ~20 min) + thin app image (rebuild fast, ~5 sec). This made iteration tolerable despite Cloud Build's 3-5 minute deploy cycles.

**Carry forward to v4:** Keep this pattern. It's universally applicable.

### 3.3 Execute Tool > Predefined Operations

Apollo's `execute` tool is superior to predefined `.graphql` files:
- AI composes queries dynamically based on what it learns from dev-mcp
- No deploy cycle to add new queries
- Schema introspection validates before execution
- Handles any complexity the AI can compose

**Carry forward to v4:** Default to dynamic execution with guardrails (cost limits), not predefined operations.

### 3.4 dev-mcp + Apollo Symbiosis

The two-backend pattern (dev-mcp for learning, Apollo for executing) is the killer feature:
1. AI discovers it needs order data
2. dev-mcp teaches the correct GraphQL syntax and filters
3. Apollo validates and executes the query
4. AI analyzes results and refines

This chain produces genuinely intelligent Shopify interactions that neither tool achieves alone.

**Carry forward to v4:** This is the product differentiator. Protect and optimize this pattern.

### 3.5 Systematic Debugging & Mirror Polish

When applied correctly, systematic debugging (read ALL logs, fix ALL issues, one commit) and Mirror Polish (20 angles, iterative batches) caught real bugs that surface-level review missed. The fix curve (6→4→0→2→1→0) shows genuine convergence.

**Carry forward to v4:** These are process wins, not architecture wins. Apply them from the start.

### 3.6 Agent Self-Improvement Loop

The failure-log, insights, patterns, and system-understanding docs accumulated 25+ entries that prevented repeat mistakes. Each session left the system smarter.

**Carry forward to v4:** Start with these docs from day one. They're infrastructure.

## 4. Architectural Debt Summary

| Debt | Category | Severity | Root Cause |
|------|----------|----------|------------|
| 5 processes in 1 container | Architecture | CRITICAL | Cost optimization over reliability |
| In-memory auth state | Architecture | HIGH | Auth proxy not designed for ephemeral infra |
| No query cost limits | Architecture | HIGH | Missing control plane |
| No dependency locks (pip, npx) | Supply Chain | HIGH | Convenience over reproducibility |
| Apollo not commit-signed | Supply Chain | HIGH | Inconsistent integrity checking |
| No key rotation | Security | HIGH | POC-grade secret management |
| Single shared AUTH_PASSWORD | Security | MEDIUM | "Get it working" shortcut |
| No custom metrics | Observability | HIGH | Not prioritized |
| No liveness probe | Reliability | MEDIUM | Single-container assumption |
| No request correlation | Observability | MEDIUM | Three uncoordinated log streams |
| Double-Auth Problem (hit twice) | Integration | MEDIUM | Auth bolted on, not integrated |
| TRUST_PROXY_AUTH_DANGEROUSLY | Security | MEDIUM | Architecture forces dangerous config |
| ContextForge venv corruption | Build | LOW | `uv pip install` side effect, documented workaround |
| Password auth has no `sub` claim | Identity | MEDIUM | fosite library limitation |
| Rate limit headers lost | Protocol | MEDIUM | stdio→SSE bridge strips metadata |
| Unpinned Node.js/npm | Supply Chain | MEDIUM | Build hygiene gap |
| OTEL disabled by default | Config | LOW | Forgotten after debugging |

## 5. v4 Design Principles (Derived from v3 Lessons)

These are not aspirational. Each one is earned from a specific v3 failure.

1. **Separate processes = separate services.** No more bash orchestration of 5 processes. Each component runs independently with its own health check, scaling, and lifecycle. (From: monolith-in-a-container)

2. **Auth is a service, not a proxy.** Auth state must be persistent. Identity must be first-class across the entire stack, not injected via header hacking. (From: Double-Auth Problem, in-memory sessions, TRUST_PROXY_AUTH_DANGEROUSLY)

3. **Control plane before data plane.** No tool execution without cost estimation, rate limiting, and per-user budgets. The gateway must protect downstream APIs, not just proxy to them. (From: no query cost limits)

4. **Pin everything, hash everything.** Every dependency must be locked, hashed, or digest-pinned at build time. Nothing fetched at runtime. (From: dependency integrity gaps)

5. **Observable from day one.** Metrics, traces, alerts, and request correlation ship with v4.0, not v4.1. (From: observability gaps)

6. **Secrets are per-service.** No shared secrets between services. Key versioning supports rotation without downtime. (From: secrets coupling)

7. **Source-verify before integrating.** Read the actual source code, `--help` output, and test suite of every external component before writing a single line of integration code. (From: 3x wrong config, wrong health endpoints, wrong port variables)

8. **Keep what works.** Compose strategy, two-layer Docker, execute tool, dev-mcp+Apollo symbiosis, agent self-improvement loop — all carry forward. (From: v3 successes)

## 6. Open Questions for v4

1. **Service topology:** Separate Cloud Run services (higher cost, proper isolation) vs. Cloud Run with sidecars (new feature, partial isolation) vs. GKE (full control, highest cost)?
2. **Auth component:** Keep mcp-auth-proxy (fork) vs. build auth into ContextForge vs. external IdP (Keycloak, Ory Hydra)?
3. **stdio problem:** dev-mcp and google-sheets are stdio-only. Translate at build time (pre-build SSE wrapper) vs. sidecar vs. accept the limitation?
4. **ContextForge dependency:** ContextForge 1.0.0-RC-2 is pre-release. Wait for 1.0.0 stable? Or reduce dependency on it?
5. **Cost target:** Is $15-25/mo still realistic with separate services? What's the acceptable cost for production-grade reliability?
6. **Multi-tenant:** Is v4 single-tenant (one Shopify store) or multi-tenant? This changes everything about auth, secrets, and data isolation.
