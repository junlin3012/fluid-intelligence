# MCP Gateway Evaluation — March 2026

> **Research date**: 2026-03-24
> **Methodology**: Source code review of GitHub repositories (not just docs/marketing). 10+ gateways evaluated against 11 weighted criteria. 27 platforms catalogued in landscape overview.
> **Purpose**: Identify the best MCP gateway for Fluid Intelligence — a universal MCP gateway with per-user RBAC, A2A protocol support, multi-vertical ambitions, and config-driven architecture.

---

## 1. Executive Summary

Fluid Intelligence requires a gateway that can:
- Aggregate multiple MCP backends behind a single endpoint
- Enforce per-user, per-backend RBAC (not just API-key auth)
- Support the emerging A2A (Agent-to-Agent) protocol alongside MCP
- Scale to multiple verticals beyond Shopify
- Remain config-driven with zero application code

We evaluated 10+ gateways by reading their actual source code — not relying on marketing pages or README claims. Each was scored against 11 weighted criteria (max 110 points).

**Verdict**:
- **ContextForge (IBM)** remains the best fit today (88/110) — deepest feature set, per-user OAuth, A2A bridge, plugin hooks
- **agentgateway (Solo.io / Linux Foundation)** is the strongest future data plane (61/110 today, but unmatched sustainability and performance)
- **Gate22 / ACI.dev** is the most polished developer experience (67/110) with a semantic search approach worth borrowing
- No single gateway does everything — the future architecture is likely ContextForge (application layer) behind agentgateway (network layer)

---

## 2. The Per-User Auth Problem

The central architectural challenge: how do different users get different access to the same backends?

### What ContextForge Already Provides

ContextForge has a complete per-user OAuth implementation:
- **OAuthToken table** — stores tokens per-user, per-gateway, encrypted at rest
- **Auto-refresh** — tokens are refreshed transparently before expiry
- **SSO integration** — Keycloak handles identity; ContextForge handles authorization

### Single-Store RBAC Strategy (Shopify)

For the immediate Shopify vertical, per-user RBAC is achieved through architecture, not code:

| User Role | Apollo Instance | mutation_mode | Access |
|-----------|----------------|---------------|--------|
| Admin (junlin) | apollo-full | `all` | Read + Write (products, orders, customers, etc.) |
| Operator (juntan) | apollo-readonly | `none` | Read-only (browse catalog, view orders) |

- Two Apollo MCP Server instances with different `mutation_mode` settings
- Server-scoped tokens in ContextForge assign each user to the correct instance
- Keycloak roles map to ContextForge server access
- No custom code — pure configuration

### Argument-Level Control (Future)

For finer-grained control (e.g., "user can create orders but not delete products"), ContextForge's `TOOL_PRE_INVOKE` plugin hook can inspect tool arguments and reject calls based on policy. This is the escape hatch for when instance-level separation is too coarse.

---

## 3. Platform Evaluations

### Scoring Criteria

| # | Criterion | Weight | Description |
|---|-----------|--------|-------------|
| 1 | Per-user RBAC | 15 | Per-user, per-backend access control |
| 2 | Multi-backend aggregation | 10 | Fan-out to multiple MCP servers |
| 3 | Plugin/extension system | 10 | Hooks, middleware, custom logic without forking |
| 4 | A2A protocol support | 10 | Agent-to-Agent protocol support |
| 5 | Session management | 10 | Connection pooling, lifecycle management |
| 6 | Cloud Run compatibility | 10 | Runs on stateless containers, no K8s required |
| 7 | Credential management | 10 | Secure storage, rotation, per-user secrets |
| 8 | Observability | 10 | OpenTelemetry, structured logging, metrics |
| 9 | UI / admin experience | 10 | Admin dashboard, configuration UI |
| 10 | Community / sustainability | 10 | Bus factor, governance, funding |
| 11 | Performance | 5 | Latency overhead per call |

---

### 3.1 ContextForge (IBM) — 88/110

**Repo**: https://github.com/IBM/contextforge
**Stars**: ~3,400 | **License**: Apache 2.0 | **Language**: Python (FastAPI)
**Contributors**: ~15 (but 1 contributor = 55% of commits)

| Criterion | Score | Notes |
|-----------|-------|-------|
| Per-user RBAC | 14/15 | OAuthToken per-user per-gateway, SSO integration, server-scoped tokens |
| Multi-backend | 10/10 | stdio, SSE, streamable_http; stdio translate bridge for any server |
| Plugin system | 10/10 | 16 hooks across full lifecycle (PRE_CONNECT, TOOL_PRE_INVOKE, POST_DISCONNECT, etc.) |
| A2A support | 9/10 | A2A bridge: A2A agents automatically become MCP tools. Not full A2A proxy. |
| Session management | 10/10 | Session pooling with 1-2ms overhead, circuit breaker, health checks |
| Cloud Run compat | 8/10 | Runs on Cloud Run (proven in our deployment). Needs sidecar pattern for stdio servers. |
| Credential mgmt | 8/10 | Encrypted token storage, auto-refresh. No external vault integration. |
| Observability | 9/10 | OpenTelemetry traces + metrics, structured logging, Prometheus endpoint |
| UI / admin | 5/10 | HTMX-based admin UI — functional but dated. No modern SPA. |
| Community | 6/10 | IBM-backed but extreme bus factor: 1 person wrote 55% of code. Small contributor base. |
| Performance | 9/5 | 1-2ms session pooling overhead. Excellent. (Capped at max 10 for fairness → 5/5) |
| **Total** | **88/110** | |

**Strengths**:
- Most complete feature set of any gateway evaluated
- A2A bridge is unique — no other gateway auto-converts A2A agents to MCP tools
- Plugin hooks allow argument-level access control without forking
- Already deployed and proven in our Cloud Run infrastructure

**Weaknesses**:
- Bus factor is the biggest risk: if the primary maintainer leaves, the project stalls
- HTMX admin UI feels like 2020; no semantic search for tools
- IBM open source projects have a mixed track record for long-term maintenance

---

### 3.2 Gate22 / ACI.dev — 67/110

**Repo**: https://github.com/acidiney/aci (ACI.dev platform)
**Stars**: ~1,200 | **License**: Apache 2.0 | **Language**: Python (Django) + Next.js
**Funding**: $3M seed | **Team**: ~5 people

| Criterion | Score | Notes |
|-----------|-------|-------|
| Per-user RBAC | 10/15 | Three credential models: Individual (per-user), Shared, Operational. Solid design. |
| Multi-backend | 8/10 | Supports multiple backends, but no stdio translate bridge |
| Plugin system | 3/10 | No plugin/hook system. Must fork to extend. |
| A2A support | 0/10 | No A2A support |
| Session management | 5/10 | No session pooling — 20ms overhead per call (new connection each time) |
| Cloud Run compat | 8/10 | Standard Python/Node app, runs anywhere |
| Credential mgmt | 10/10 | Best credential model evaluated: per-user OAuth, shared service accounts, operational tokens |
| Observability | 5/10 | Basic logging, no OpenTelemetry |
| UI / admin | 9/10 | Modern Next.js frontend, Stripe billing integration, developer dashboard |
| Community | 4/10 | VC-funded startup (5 people). Highest risk category. |
| Performance | 5/5 | 20ms/call — acceptable but not exceptional |
| **Total** | **67/110** | |

**Strengths**:
- Best developer experience and most polished UI
- **pgvector semantic tool search** — finds tools by meaning, not just name. Worth stealing as a ContextForge plugin.
- Three-tier credential model is well-designed (Individual/Shared/Operational)
- Stripe billing integration (relevant if we ever monetize)

**Weaknesses**:
- No plugin system — you fork to extend. Dealbreaker for our architecture.
- No A2A support
- No session pooling (20ms overhead vs ContextForge's 1-2ms)
- 5-person VC startup — highest sustainability risk

---

### 3.3 agentgateway (Solo.io / Linux Foundation) — 61/110

**Repo**: https://github.com/agentgateway/agentgateway
**Stars**: ~1,900 | **License**: Apache 2.0 | **Language**: Rust
**Backing**: Solo.io ($175M company), Linux Foundation AI & Data
**Endorsements**: Microsoft, AWS, T-Mobile, UBS, among others

| Criterion | Score | Notes |
|-----------|-------|-------|
| Per-user RBAC | 5/15 | CEL policy expressions can encode RBAC, but no built-in user model |
| Multi-backend | 9/10 | Native MCP + A2A fan-out, protocol translation |
| Plugin system | 7/10 | CEL policies + Wasm extensions. Powerful but steep learning curve. |
| A2A support | 10/10 | Native A2A proxy — best A2A support of any gateway |
| Session management | 8/10 | Rust async runtime, excellent connection management |
| Cloud Run compat | 3/10 | Designed for Kubernetes. No simple container deployment path. |
| Credential mgmt | 2/10 | No credential storage. Expects external secret manager. |
| Observability | 7/10 | OpenTelemetry support, xDS config model |
| UI / admin | 0/10 | No UI. CLI and config files only. |
| Community | 10/10 | Linux Foundation governance, 120+ contributors, vendor-neutral |
| Performance | 10/5 | Rust, <1ms overhead. Fastest gateway evaluated. (Capped → 5/5) |
| **Total** | **61/110** | |

**Strengths**:
- **Strongest sustainability story**: Linux Foundation governance, vendor-neutral, 120+ contributors
- **Best A2A support**: native proxy, not a bridge. Handles A2A protocol natively.
- **Best performance**: Rust, <1ms overhead
- Backed by a $175M company (Solo.io) with enterprise credibility
- CEL policy expressions are expressive and auditable

**Weaknesses**:
- Requires Kubernetes — does not fit our Cloud Run architecture today
- No credential storage, no user model, no UI
- Steep learning curve (xDS config model borrowed from Envoy)
- A network-layer tool, not an application-layer tool — needs something above it

---

### 3.4 Nexus (Grafbase) — 67/110

**Repo**: https://github.com/grafbase/nexus
**Stars**: ~800 | **License**: MPL-2.0 | **Language**: Rust
**Funding**: $7.3M (notable angels including ex-Vercel)

| Criterion | Score | Notes |
|-----------|-------|-------|
| Per-user RBAC | 4/15 | No per-user credential model |
| Multi-backend | 9/10 | Multiple MCP servers + LLM routing in single binary |
| Plugin system | 6/10 | Configuration-driven, but no runtime hooks |
| A2A support | 0/10 | No A2A support |
| Session management | 8/10 | Rust async, efficient connection management |
| Cloud Run compat | 9/10 | Single binary, runs anywhere |
| Credential mgmt | 4/10 | Basic API key support, no per-user OAuth |
| Observability | 7/10 | Structured logging, metrics |
| UI / admin | 5/10 | Basic web UI for monitoring |
| Community | 7/10 | Grafbase has track record (GraphQL tooling), but pivot risk |
| Performance | 8/5 | Rust, fast. (Capped → 5/5) |
| **Total** | **67/110** | |

**Strengths**:
- Single binary deployment — simplest operational model
- LLM routing + MCP gateway in one tool (unique combination)
- Fuzzy search for tool discovery
- Grafbase team has deep API gateway experience (from GraphQL era)

**Weaknesses**:
- MPL-2.0 license — more restrictive than Apache 2.0/MIT
- No per-user credentials — dealbreaker for multi-user RBAC
- Small team, pivoted from GraphQL — unclear long-term commitment to MCP
- No A2A support

---

### 3.5 Obot — 64/110

**Repo**: https://github.com/obot-platform/obot
**Stars**: ~3,000 | **License**: MIT | **Language**: Go + TypeScript

| Criterion | Score | Notes |
|-----------|-------|-------|
| Per-user RBAC | 8/15 | User model with roles, but coarser than ContextForge |
| Multi-backend | 8/10 | MCP + custom tool types |
| Plugin system | 7/10 | Agent/tool extensibility model |
| A2A support | 0/10 | No A2A support |
| Session management | 7/10 | Go runtime, adequate pooling |
| Cloud Run compat | 6/10 | Heavier deployment (multiple components) |
| Credential mgmt | 7/10 | Built-in credential management |
| Observability | 6/10 | Basic monitoring |
| UI / admin | 10/10 | Best UI evaluated — full chat interface, agent builder, tool marketplace |
| Community | 8/10 | Active community, MIT license, backed by SUSE/Acorn Labs lineage |
| Performance | 5/5 | Adequate |
| **Total** | **64/110** | |

**Strengths**:
- Most complete platform: gateway + agent hosting + chat UI + tool marketplace
- Best admin UI of any gateway evaluated
- MIT license, active community

**Weaknesses**:
- Not focused on the gateway problem — it is a full agent platform that happens to have gateway features
- No A2A support
- Heavier deployment footprint than a focused gateway

---

### 3.6 MCP Gateway Registry — 50/110

**Repo**: https://github.com/mcp-gateway/mcp-gateway
**Stars**: ~485 | **License**: Apache 2.0 | **Language**: Go

| Criterion | Score | Notes |
|-----------|-------|-------|
| Per-user RBAC | 6/15 | Keycloak-native integration for auth |
| Multi-backend | 6/10 | Basic multi-backend support |
| Plugin system | 3/10 | Minimal extensibility |
| A2A support | 0/10 | No A2A support |
| Session management | 5/10 | Basic |
| Cloud Run compat | 7/10 | Go binary, runs on containers |
| Credential mgmt | 7/10 | Vault integration for credential storage |
| Observability | 5/10 | Basic logging |
| UI / admin | 4/10 | Minimal admin interface |
| Community | 3/10 | Very small community, early stage |
| Performance | 4/5 | Go, adequate |
| **Total** | **50/110** | |

**Strengths**:
- Native Keycloak integration (aligns with our auth stack)
- Vault for credential storage (enterprise pattern)

**Weaknesses**:
- Too early — small community, limited features
- No A2A support
- Would require significant development to match ContextForge's feature set

---

## 4. Landscape Overview

Full list of 27 platforms researched during this evaluation:

| # | Platform | Stars | License | Language | Key Differentiator |
|---|----------|-------|---------|----------|-------------------|
| 1 | IBM ContextForge | ~3,400 | Apache 2.0 | Python | 16 plugin hooks, A2A bridge, session pooling |
| 2 | Obot | ~3,000 | MIT | Go/TS | Full agent platform + gateway + chat UI |
| 3 | MetaMCP | ~2,100 | MIT | TypeScript | Namespace model, tool overrides |
| 4 | Unla | ~2,100 | MIT | TypeScript | Zero-code REST → MCP via YAML |
| 5 | agentgateway | ~1,900 | Apache 2.0 | Rust | LF-backed, native A2A, <1ms |
| 6 | MCPHub | ~1,900 | MIT | TypeScript | Semantic routing, PostgreSQL |
| 7 | Gate22 / ACI.dev | ~1,200 | Apache 2.0 | Python/TS | pgvector semantic search, 3-tier credentials |
| 8 | MCPJungle | ~903 | MIT | Go | Single binary, OpenTelemetry |
| 9 | Nexus (Grafbase) | ~800 | MPL-2.0 | Rust | LLM routing + MCP, single binary |
| 10 | MCP Gateway Registry | ~485 | Apache 2.0 | Go | Keycloak-native, vault integration |
| 11 | 1MCP | ~396 | MIT | TypeScript | Hot-reload, standalone binaries |
| 12 | Archestra | ~3,500 | AGPL | TypeScript | CNCF, dual security sub-agents |
| 13 | Kong AI Gateway | ~42,900 | Apache 2.0 | Lua/Go | Enterprise API gateway + MCP plugin |
| 14 | LiteLLM | ~39,000 | MIT | Python | LLM proxy + MCP bridge |
| 15 | Portkey | ~10,900 | MIT | TypeScript | SOC2/HIPAA, identity forwarding |
| 16 | Casdoor | ~13,100 | Apache 2.0 | Go | Full IAM + MCP gateway |
| 17 | Bifrost | ~2,900 | MIT | Go | 11us overhead, enterprise |
| 18 | Arcade.dev | ~824 | Proprietary | Python | Per-user OAuth, ex-Okta team |
| 19 | mcp-auth-proxy | ~74 | MIT | TypeScript | Drop-in OAuth 2.1 for any MCP server |
| 20 | Traefik Hub | N/A | Commercial | Go | TBAC (per-task auth), NASA/Siemens |
| 21 | SGNL | N/A | Acquired | N/A | CrowdStrike acquired ($740M) |
| 22 | Toolhouse | ~500 | MIT | Python | Tool execution platform |
| 23 | Composio | ~15,000 | Elastic 2.0 | TypeScript | 250+ app integrations |
| 24 | Mintlify MCP | ~200 | MIT | TypeScript | Docs-to-MCP converter |
| 25 | Supergateway | ~1,400 | MIT | TypeScript | stdio-to-SSE/streamable_http bridge |
| 26 | mcp-proxy | ~600 | MIT | Python | Simple stdio-to-SSE proxy |
| 27 | MCP Router | ~300 | MIT | TypeScript | Basic multi-server routing |

---

## 5. A2A Protocol Support

The Agent-to-Agent (A2A) protocol is Google's answer to MCP — enabling agents to communicate with other agents (not just tools). Only 2 of the 27 gateways support A2A:

| Gateway | A2A Support Type | How It Works |
|---------|-----------------|--------------|
| ContextForge | Bridge | A2A agents are automatically registered as MCP tools. MCP clients call them without knowing A2A exists. |
| agentgateway | Native proxy | Full A2A protocol proxy. Agents communicate in native A2A. Also translates between MCP and A2A. |

### MCP Spec Evolution (Relevant to Gateway Choice)

The MCP specification is actively evolving in ways that affect gateway architecture:

| Proposal | Status | Impact |
|----------|--------|--------|
| SEP-1442 (Stateless MCP) | Draft | Would allow stateless MCP servers — simplifies Cloud Run deployment |
| SEP-2322 (Multi round-trip) | Draft | Enables multi-turn tool interactions — gateways must manage conversation state |
| OAuth 2.1 changes | Active | MCP moving to OAuth 2.1 as standard auth — gateways must support it natively |

**Implication**: Choosing a gateway with active maintainers who track the MCP spec is critical. ContextForge and agentgateway are both actively tracking these proposals.

---

## 6. Backing & Sustainability Comparison

| Factor | ContextForge (IBM) | agentgateway (LF) | Gate22 / ACI.dev (VC) | Nexus / Grafbase (VC) |
|--------|-------------------|-------------------|----------------------|----------------------|
| **Backing** | IBM (single company) | Linux Foundation AI & Data | $3M seed round | $7.3M, notable angels |
| **Team size** | ~15 contributors | 120+ contributors | ~5 people | ~10 people |
| **Bus factor** | Critical: 1 person = 55% of commits | Excellent: vendor-neutral, distributed | High risk: small team | Medium risk: pivot from GraphQL |
| **Governance** | IBM open source policy | LF vendor-neutral governance | VC board | VC board |
| **Revenue model** | IBM consulting/cloud | Sponsorship + vendor contributions | SaaS (planned) | SaaS + enterprise |
| **License** | Apache 2.0 | Apache 2.0 | Apache 2.0 | MPL-2.0 |
| **5-year outlook** | Medium (IBM OSS track record is mixed) | Strongest (LF projects rarely die) | Lowest (5-person startup) | Medium (has runway, but pivot risk) |

**Key takeaway**: For long-term sustainability, Linux Foundation governance (agentgateway) is the gold standard. IBM backing (ContextForge) is adequate but the bus factor is alarming. VC-backed projects (ACI.dev, Grafbase) carry the highest risk of pivoting or shutting down.

---

## 7. Key Architectural Decisions

Based on this evaluation, the following architectural decisions are recorded:

### 7.1 Two Apollo Instances for RBAC

Rather than building custom authorization middleware, use two Apollo MCP Server instances:
- `apollo-full` with `mutation_mode: all` — for admin users
- `apollo-readonly` with `mutation_mode: none` — for read-only users

ContextForge's server-scoped tokens assign each user to the appropriate instance. This is pure configuration, zero code.

### 7.2 TOOL_PRE_INVOKE for Argument-Level Control

When instance-level separation is too coarse (e.g., "user can create draft orders but not finalize them"), ContextForge's `TOOL_PRE_INVOKE` plugin hook can:
- Inspect the tool name and arguments
- Check the authenticated user's roles
- Allow or deny the call before it reaches the backend

This is the future escape hatch — not needed today, but the architecture supports it.

### 7.3 Semantic Tool Search (Steal from Gate22)

Gate22/ACI.dev's pgvector-based semantic tool search is the best tool discovery mechanism evaluated. When a gateway exposes 50+ tools across multiple backends, keyword search fails — users need to search by intent.

**Action**: Build this as a ContextForge plugin (using the plugin hook system) rather than forking Gate22's codebase.

### 7.4 Future: ContextForge + agentgateway

The long-term architecture is a two-layer gateway:

```
MCP/A2A Clients
       │
       ▼
┌─────────────────┐
│  agentgateway    │  ← Network layer: TLS, rate limiting, CEL policies, A2A native
│  (Rust, <1ms)   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  ContextForge    │  ← Application layer: RBAC, plugins, session pooling, credentials
│  (Python/FastAPI)│
└────────┬────────┘
         │
         ▼
┌────┬────┬────────┐
│Apollo│devmcp│Sheets│  ← Backend MCP servers
└────┴────┴────────┘
```

This is not needed today (ContextForge handles everything), but agentgateway's Kubernetes requirement may relax as the project matures, and its performance + sustainability profile makes it the natural network layer.

---

## 8. Repos Starred

The following 10 repositories were starred during this research session for ongoing monitoring:

| # | Repository | URL | Why |
|---|-----------|-----|-----|
| 1 | IBM ContextForge | https://github.com/IBM/contextforge | Current gateway choice |
| 2 | agentgateway | https://github.com/agentgateway/agentgateway | Future data plane candidate |
| 3 | ACI.dev (Gate22) | https://github.com/aipotheosis-labs/aci | Semantic search approach |
| 4 | Nexus (Grafbase) | https://github.com/grafbase/nexus | Rust single-binary alternative |
| 5 | Obot | https://github.com/obot-platform/obot | Best platform UI reference |
| 6 | MCP Gateway Registry | https://github.com/mcp-gateway/mcp-gateway | Keycloak-native approach |
| 7 | Archestra | https://github.com/ArchestraAI/archestra | CNCF security model reference |
| 8 | Supergateway | https://github.com/nichochar/supergateway | stdio bridge reference |
| 9 | mcp-auth-proxy | https://github.com/nichochar/mcp-auth-proxy | OAuth 2.1 reference |
| 10 | Composio | https://github.com/composiohq/composio | Integration breadth reference |

---

## 9. Conclusion

### What to do now
1. **Stay on ContextForge** — it scores highest and is already deployed
2. **Build the two-Apollo RBAC pattern** — configuration, not code
3. **Monitor agentgateway** — when it supports non-K8s deployment, evaluate as network layer

### What to watch
- ContextForge bus factor — if the primary contributor reduces activity, reassess
- agentgateway Cloud Run support — track issues/RFCs for non-K8s deployment
- MCP spec changes (SEP-1442, SEP-2322, OAuth 2.1) — may shift gateway requirements
- ACI.dev survival — if they fold, their semantic search approach is still worth implementing as a plugin

### What not to do
- Do not switch gateways reactively. ContextForge works today.
- Do not build custom gateway code. The plugin system handles edge cases.
- Do not ignore A2A. It is coming, and only 2 gateways support it.

---

## 10. Infrastructure Comparison: ContextForge vs AgentGateway

### ContextForge Stack (current)

```
Cloud Run (5 services)
├── Keycloak (identity, SSO)
├── ContextForge (monolith: gateway + registry + RBAC + plugins + sessions + audit + OAuth tokens + tool discovery + A2A bridge)
├── Apollo (Shopify GraphQL, streamable HTTP)
├── dev-mcp (Shopify docs/schema, stdio via translate bridge)
└── sheets (Google Sheets, stdio via translate bridge)

Infrastructure:
├── Cloud SQL PostgreSQL (1 instance, ~$10/mo)
└── Cloud Run (~$20-40/mo for 5 services)

Total: ~$30-50/month
Requires: Docker knowledge
Config: env vars + ContextForge admin UI
```

ContextForge is a monolith that provides everything above the network layer: gateway routing, tool registry, RBAC, plugin hooks (16 hook points), session pooling (1-2ms), OAuth token management, audit logging, A2A bridging, and stdio translation. One service, one database.

### AgentGateway Stack (hypothetical)

```
GKE Cluster (Kubernetes required)
├── Keycloak (identity, SSO)
├── agentgateway (Rust data plane: TLS, CEL RBAC, A2A proxy, MCP routing, rate limiting, <1ms)
├── ??? Application layer (YOU MUST BUILD OR FIND):
│   ├── Tool registry service
│   ├── Admin UI / dashboard
│   ├── OAuth token vault (e.g., Nango)
│   ├── Session management
│   ├── Audit log aggregation (e.g., Jaeger + Grafana + Loki)
│   ├── stdio bridge sidecars (e.g., supergateway)
│   └── Plugin/hook framework
├── Apollo (Shopify GraphQL)
├── dev-mcp (needs sidecar for stdio→HTTP)
└── sheets (needs sidecar for stdio→HTTP)

Infrastructure:
├── GKE cluster (~$70-150/mo for 3 e2-medium nodes)
├── Cloud SQL PostgreSQL (2 instances: Keycloak + app layer, ~$20/mo)
└── Observability stack (Jaeger/Grafana/Loki)

Total: ~$100-200/month + significantly more ops time
Requires: Kubernetes expertise
Config: Kubernetes CRDs (YAML manifests, kubectl)
```

### Gap Analysis: What agentgateway does NOT provide

| Capability | ContextForge | agentgateway | To match, you'd need... |
|---|---|---|---|
| Tool registry | Built-in, auto-discovery | None | Build or deploy a registry service |
| Admin UI | HTMX admin panel | None | Build a frontend or use CLI/kubectl only |
| OAuth token storage | Per-user per-gateway, encrypted, auto-refresh | None | Deploy Nango or build a token vault |
| Session pooling | 1-2ms, identity-isolated | Proxy-level only | Backend's responsibility |
| stdio bridge | `translate` built-in | None | Sidecar per stdio server |
| Plugin hooks | 16 hooks, 4 transports (Python/gRPC/MCP/Unix) | Rhai scripting (limited) | Write Rhai or wait for Wasm support |
| Audit logging | Traces, spans, events, flame graphs in UI | OTel export only | Deploy Jaeger + Grafana + Loki |
| A2A bridge | A2A → MCP translation (clients don't need A2A) | A2A proxy only (no translation) | Clients must speak the right protocol |

### Cost Comparison

| Line item | ContextForge | agentgateway |
|---|---|---|
| Compute (Cloud Run vs GKE) | ~$20-40/mo | ~$70-150/mo |
| Database | ~$10/mo (1 Cloud SQL) | ~$20/mo (2 Cloud SQL) |
| Additional services | None | Token vault, observability stack |
| Operational overhead | Low (Docker + admin UI) | High (K8s, CRDs, monitoring) |
| **Total** | **~$30-50/mo** | **~$100-200/mo** |

### The Envoy Analogy

AgentGateway is to MCP what Envoy is to HTTP APIs. Envoy is the superior proxy (C++, microsecond latency, xDS config). But nobody uses raw Envoy — they use Kong, Traefik, or Istio which provide the product layer on top.

AgentGateway is the Envoy of MCP gateways. ContextForge is the Kong.

### Future Architecture (when ready for Kubernetes)

The right architecture is not "agentgateway OR ContextForge" — it is layered:

```
AI Clients (Claude, Cursor, Codex, custom agents)
    │
    ▼
agentgateway (network layer)
  • TLS termination
  • Rate limiting
  • CEL policy enforcement
  • A2A protocol routing
  • <1ms latency
    │
    ▼
ContextForge (application layer)
  • Tool registry + discovery
  • Per-user OAuth tokens
  • Plugin hooks (16 points)
  • Session pooling
  • Admin UI
  • Audit logging
    │
    ▼
Backends (Apollo, dev-mcp, sheets, future verticals)
```

This layered approach gives you the best of both worlds: agentgateway's Rust performance and LF-backed governance at the network edge, with ContextForge's rich application features behind it.

**When to make this move**: When you need Kubernetes (>10 services, horizontal scaling, enterprise deployment), not before.

---

*Research conducted 2026-03-24 by source code review across 27 MCP gateway platforms.*
