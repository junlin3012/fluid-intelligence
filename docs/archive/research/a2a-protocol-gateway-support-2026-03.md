# A2A Protocol Support in MCP Gateways — Research Report

**Date:** 2026-03-24
**Author:** Research for Fluid Intelligence architectural decision
**Sources:** GitHub source code, official docs, MCP spec repo, Google A2A repo

---

## 1. What is A2A?

Google's **Agent-to-Agent (A2A) protocol** (v1.0.0, released March 12, 2026) is an open standard under the Linux Foundation for agent-to-agent communication. It reached production status with SDKs in Python, Go, JavaScript, Java, and .NET.

### How it works

- **Transport:** JSON-RPC 2.0 over HTTP(S)
- **Discovery:** Agents expose "Agent Cards" at `/.well-known/agent-card.json` (v0.3.0+) or `/.well-known/agent.json` (older)
- **Interaction modes:** Synchronous request/response, SSE streaming, async push notifications
- **Core method:** `tasks/send` — the primary RPC method for sending messages to agents
- **Messages:** Structured with `role` (user/agent), `parts` (text, forms, media), and `messageId`
- **Task lifecycle:** Tasks have states (working, completed, failed) with context tracking

### MCP vs A2A — Complementary, Not Competing

| Dimension | MCP | A2A |
|-----------|-----|-----|
| **Purpose** | Connect AI clients to tools/data | Connect AI agents to each other |
| **Metaphor** | "Hands" — how an agent uses tools | "Voice" — how agents talk to agents |
| **Discovery** | Tool/resource/prompt lists via initialize | Agent Cards at well-known endpoints |
| **Statefulness** | Session-based (session-id header) | Task-based (task IDs, context IDs) |
| **Transport** | Streamable HTTP, SSE, stdio | HTTP(S) only |
| **Opacity** | Tools expose schemas, agents see internals | Agents are opaque — no internal state sharing |
| **Maturity** | Spec 2025-11-25 (4th revision), wide adoption | v1.0.0 (March 2026), early adoption |

**Why both matter for Fluid Intelligence:** MCP connects Claude/Cursor to your Shopify tools. A2A would let your gateway expose its capabilities as an "agent" to other organizations' agents, or orchestrate multi-agent workflows (e.g., a procurement agent talking to a fulfillment agent).

---

## 2. Gateway A2A Support Matrix

### Tier 1: Full A2A Implementation

#### agentgateway (Linux Foundation)

- **Repo:** github.com/agentgateway/agentgateway
- **Stars:** 2,129 | **Forks:** 345 | **Contributors:** 30+ | **Language:** Rust
- **Latest release:** v1.0.1 (2026-03-20)
- **Backing:** Linux Foundation project with formal TSC charter
- **A2A maturity: PRODUCTION-READY**

**Source code reviewed:**
- `crates/agentgateway/src/a2a/mod.rs` — Full A2A request handler
  - Classifies requests: Agent Card (GET), JSON-RPC Call (POST), Unknown
  - Rewrites agent card URLs to route through the gateway
  - Inspects JSON-RPC method names from request bodies
  - Handles both `agent.json` and `agent-card.json` (v0.3.0 compatibility)
- `crates/agentgateway/src/proxy/httpproxy.rs` — A2A integrated into main proxy pipeline
  - A2A is a `BackendPolicy` alongside MCP, HTTP, TCP, TLS, LLM
  - Request/response interception with full observability (logging, metrics)
  - A2A method extraction for access log enrichment
- `controller/pkg/agentgateway/plugins/a2a_plugin.go` — Kubernetes-native A2A
  - Auto-discovers A2A services via `appProtocol: kgateway.dev/a2a` annotation
  - Generates routing policies from K8s Service specs
- `controller/pkg/agentgateway/translator/testdata/backends/a2a.yaml` — K8s backend config
- `controller/test/e2e/features/agentgateway/a2a/` — Full E2E test suite
- `examples/a2a/` — Working example with Strands Agents (Python)

**What it does:**
- Routes A2A traffic (JSON-RPC POST + Agent Card GET) to backend A2A agents
- Rewrites agent card URLs so discovery works through the gateway
- Full RBAC system that covers both MCP and A2A
- Kubernetes Gateway API integration for A2A service discovery
- Access logging with A2A method extraction

**What it does NOT do:**
- No MCP-to-A2A protocol translation (routes each protocol natively)
- `A2aPolicy` struct is empty — no A2A-specific policy configuration yet
- No A2A response inspection (comment: "We don't currently inspect A2A responses")

**Verdict:** agentgateway treats A2A as a first-class routing protocol alongside MCP. It is a transparent proxy — it routes A2A traffic correctly but does not translate between protocols. This is architecturally clean.

---

#### IBM ContextForge

- **Repo:** github.com/IBM/mcp-context-forge
- **Stars:** 3,457 | **Forks:** 591 | **Contributors:** 30+ | **Language:** Python
- **Latest release:** v1.0.0-RC2 (2026-03-09)
- **Backing:** IBM
- **A2A maturity: PRODUCTION-READY (different approach)**

**Source code reviewed:**
- `mcpgateway/services/a2a_service.py` — 1,500+ line A2A service
  - Full CRUD for A2A agents (create, read, update, delete, toggle active)
  - Agent invocation with auth forwarding
  - Comprehensive metrics (per-agent, hourly aggregates)
  - Team/visibility/ownership management
  - OAuth config storage with encryption
  - Pagination, search, filtering
- `mcpgateway/alembic/versions/` — 6 database migrations for A2A
  - `add_a2a_agents_and_metrics.py`
  - `merge_a2a_and_custom_name_changes.py`
  - `add_tool_id_to_a2a_agents.py`
  - `fix_a2a_agents_auth_value.py`
  - `add_auth_query_params_to_a2a_agents.py`
  - `add_oauth_config_to_a2a_agents.py`
- `docs/docs/architecture/modular-runtime/a2a-module.md` — Architecture docs
- `docs/docs/using/agents/a2a.md` — User-facing docs
- `a2a-agents/go/a2a-echo-agent/` — Reference implementation

**What it does (CRITICAL — protocol bridge):**
- Registers external A2A agents and **exposes them as MCP tools**
- `tool_service.create_tool_from_a2a_agent()` — converts A2A agent to MCP tool
- `tool_service.update_tool_from_a2a_agent()` — syncs changes
- `tool_service.delete_tool_from_a2a_agent()` — cleanup
- MCP clients can invoke A2A agents via standard `tools/call` JSON-RPC
- Supports agent types: jsonrpc, openai, anthropic, custom
- Admin UI for A2A agent management (register, test, monitor)
- Per-agent auth (API key, bearer token, OAuth)
- Team-based visibility and RBAC
- Feature-flagged: `MCPGATEWAY_A2A_ENABLED=true`

**Architecture doc notes:**
- A2A module owns: request parsing, discovery surface, invoke envelope, outbound transport
- Core owns: agent CRUD, auth normalization, RBAC, cross-protocol bridge
- "If an A2A agent is exposed as an MCP tool, the core still mediates that cross-protocol bridge"

**Verdict:** ContextForge does actual MCP-to-A2A protocol translation. This is the ONLY gateway that bridges the protocols — MCP clients (Claude, Cursor) can call A2A agents as if they were MCP tools. This is extremely relevant for Fluid Intelligence since it means ContextForge can expose any A2A agent to Claude Code without Claude needing to speak A2A.

---

### Tier 2: MCP Only (No A2A)

#### Docker MCP Gateway
- **Stars:** 1,317 | **Forks:** 232 | **Language:** Go
- **A2A support: NONE** — Focused purely on MCP server lifecycle management via Docker
- **Strength:** Deep Docker integration, secrets management, OAuth flows
- **Client tested:** VS Code, Cursor, Claude Desktop mentioned in docs

#### Envoy AI Gateway
- **Stars:** 1,449 | **Forks:** 197 | **Language:** Go
- **A2A support: NONE** — Has MCP gateway support but no A2A
- **Strength:** Envoy-native architecture, leverages battle-tested networking
- **MCP approach:** Detailed proposal (006-mcp-gateway) with session aggregation, notification merging
- **Notable:** Supports distributed tracing via `_meta` field, multi-upstream session encoding

#### Grafbase Nexus
- **Stars:** 487 | **Forks:** 25 | **Language:** Rust
- **A2A support: NONE**
- **Strength:** LLM provider routing (OpenAI/Anthropic/Google/Bedrock), context-aware tool search
- **Weakness:** Small contributor base (7), MPL-2.0 license

#### MCPJungle
- **Stars:** 921 | **Forks:** 118 | **Language:** Go
- **A2A support: NONE**
- **Strength:** Simple self-hosted gateway, tested with Claude/Cursor/Copilot
- **Weakness:** No A2A, no protocol translation

#### Gate22 (ACI.dev)
- **Stars:** 170 | **Forks:** 21 | **Language:** TypeScript
- **A2A support: NONE**
- **Strength:** Governance focus — function-level allow lists, per-user credentials, audit
- **Weakness:** Last updated Dec 2025, small community

#### Obot
- **Stars:** 656 | **Forks:** 143 | **Language:** Go
- **A2A support: NONE**
- **Strength:** Full MCP platform (hosting, registry, gateway, chat client), OAuth 2.1 built-in
- **Weakness:** Platform play, not a composable gateway component

#### mcp-gateway-registry (Agentic Community)
- **Stars:** 512 | **Forks:** 115 | **Language:** Python
- **A2A support: EXAMPLE ONLY** — Has A2A example agents (travel booking) but no gateway-level A2A
- **A2A approach:** Uses AWS Bedrock AgentCore + Strands framework for agent-to-agent via A2A

#### Kong / Traefik
- **A2A support: NONE** in core products
- Kong has community examples (kong-mcp-gateway-examples, kong-a2a-prototype) but no official support
- Traefik has no MCP or A2A support

---

## 3. Protocol Translation Deep Dive

Only **two gateways** handle both protocols. Their approaches differ fundamentally:

| Capability | agentgateway | ContextForge |
|------------|-------------|-------------|
| **Approach** | Transparent proxy | Protocol bridge |
| **MCP routing** | Native (full MCP proxy with session mgmt) | Native (full MCP gateway) |
| **A2A routing** | Native (transparent proxy, URL rewriting) | Invoke-based (wraps A2A calls) |
| **MCP-to-A2A bridge** | No | Yes — A2A agents become MCP tools |
| **A2A-to-MCP bridge** | No | No |
| **Client needs to speak** | Both protocols | MCP only (gateway handles A2A) |
| **Best for** | Multi-protocol infrastructure | Making A2A agents accessible to MCP clients |

**For Fluid Intelligence:** ContextForge's approach is more immediately useful — Claude Code speaks MCP, and ContextForge can make A2A agents callable via MCP. agentgateway's approach is better if you need to serve A2A-native clients alongside MCP clients.

---

## 4. MCP Spec Evolution — What's Coming

### Current: 2025-11-25 (4th revision)

Key changes from 2025-06-18:
- OIDC Discovery support for auth server discovery
- Incremental scope consent via `WWW-Authenticate`
- URL-mode elicitation (SEP-1036)
- Tool calling in sampling (SEP-1577)
- OAuth Client ID Metadata Documents (SEP-991)
- **Experimental tasks** — durable requests with polling (SEP-1686)
- JSON Schema 2020-12 as default dialect
- Icon metadata for tools/resources/prompts

### Draft (next revision)

Minimal changes so far:
- `extensions` field in capabilities for optional protocol extensions
- OpenTelemetry trace context propagation conventions in `_meta`

### Critical In-Progress SEPs

**SEP-1442: Make MCP Stateless (88 comments, "in-review")**
- Authors include Google engineers (Mark Roth)
- Proposes removing the initialization handshake
- Would make MCP dramatically easier to proxy/gateway
- If accepted, this is the biggest breaking change since MCP's creation
- **Impact on gateways:** Session management code becomes optional/simplified

**SEP-2322: Multi Round-Trip Requests ("accepted-with-changes")**
- From the Transports Working Group
- Breaking change to request/response patterns
- **Impact on gateways:** Request routing logic needs updating

**SEP-2243: HTTP Standardization ("approved")**
- Incorporates standard HTTP features (routing, tracing, prioritization)
- Gated by protocol version (non-breaking)
- **Impact on gateways:** Better compatibility with standard HTTP infrastructure

**Auth-related SEPs (6+ open):**
- SEP-1488: securitySchemes in Tool Metadata (mixed-auth servers)
- SEP-1932: DPoP Profile for MCP
- SEP-1933: Workload Identity Federation
- SEP-2350/2351/2352: Authorization clarifications
- SEP-2385: Tool Auth Manifest
- **Impact:** Auth story is still evolving. OAuth 2.1 is already mandatory for remote servers.

**SEP-2433: Transfer Descriptors (out-of-band data)**
- Negotiation for large data transfers outside the JSON-RPC channel

---

## 5. Multi-Client Compatibility

Based on docs, issues, and README mentions:

| Gateway | Claude Desktop | Claude Code | Cursor | Codex/OpenAI | Gemini | Custom |
|---------|---------------|-------------|--------|-------------|--------|--------|
| **ContextForge** | Documented | Tested (FI v6) | Via wrapper | Via OpenAI SDK docs | Not mentioned | Yes (MCP) |
| **agentgateway** | Likely (std MCP) | Likely (std MCP) | Likely (std MCP) | Not mentioned | Not mentioned | Yes |
| **Docker MCP GW** | Mentioned | Implied | Mentioned | Not mentioned | Not mentioned | Via profiles |
| **MCPJungle** | Documented | Implied | Documented | Not mentioned | Not mentioned | Yes |
| **Envoy AI GW** | Not mentioned | Not mentioned | Not mentioned | Not mentioned | Not mentioned | Generic MCP |
| **Obot** | Documented | Not mentioned | Not mentioned | ChatGPT mentioned | Not mentioned | n8n, LangGraph |

**Key finding:** No gateway has been explicitly tested with Codex or Gemini as MCP clients. ContextForge has the broadest documented client support through its wrapper mechanism and OpenAI SDK integration docs.

---

## 6. Future-Proofing Signals

| Signal | agentgateway | ContextForge | Envoy AI GW | Docker MCP GW | Obot |
|--------|-------------|-------------|-------------|---------------|------|
| **Backing** | Linux Foundation | IBM | Envoy/CNCF | Docker Inc | SUSE (Acorn Labs) |
| **Stars** | 2,129 | 3,457 | 1,449 | 1,317 | 656 |
| **Contributors** | 30+ | 30+ | 30+ | 30+ | 30+ |
| **Release cadence** | Active (v1.0.1, Mar 20) | Active (RC2, Mar 9) | Slower (v0.5, Jan 23) | Active | Active |
| **A2A support** | Yes (routing) | Yes (bridge) | No | No | No |
| **Governance** | TSC, charter, community meetings | IBM-led OSS | CNCF project | Docker-led | SUSE-led |
| **Language** | Rust | Python | Go | Go | Go |
| **K8s native** | Yes (Gateway API) | Docker-compose focused | Yes (Envoy) | Docker Desktop | Yes |

**Strongest future signals:**
1. **agentgateway** — Linux Foundation, both protocols, Kubernetes-native, Rust performance, formal governance
2. **ContextForge** — IBM backing, most features, protocol bridge, but Python (performance ceiling)
3. **Envoy AI Gateway** — CNCF pedigree, but slower MCP adoption and no A2A

---

## 7. Recommendations for Fluid Intelligence

### Short-term (current architecture with ContextForge)

ContextForge already supports A2A. To enable:
1. Set `MCPGATEWAY_A2A_ENABLED=true`
2. Register A2A agents via Admin UI or API
3. A2A agents automatically become MCP tools — Claude Code can call them

This is the path of least resistance. No code changes needed.

### Medium-term (watch agentgateway)

agentgateway is the most architecturally sound project for a multi-protocol gateway:
- Rust performance for high-throughput scenarios
- Linux Foundation governance ensures long-term stability
- Both MCP and A2A as first-class protocols
- Kubernetes-native with Gateway API
- But: it's a transparent proxy, not a protocol bridge

Consider agentgateway if Fluid Intelligence needs to:
- Serve A2A-native clients (not just MCP clients)
- Scale to high concurrency (Rust vs Python)
- Deploy on Kubernetes
- Need formal governance/compliance

### Critical MCP spec risks to monitor

1. **SEP-1442 (Stateless MCP)** — If accepted, every gateway's session management changes. Watch closely.
2. **Auth evolution** — 6+ open auth SEPs. The auth story will change at least once more.
3. **SEP-2322 (Multi Round-Trip)** — Accepted with changes, will affect request routing.

### What NOT to do

- Do not build custom A2A support. Both ContextForge and agentgateway handle it.
- Do not build a protocol bridge. ContextForge already does MCP-to-A2A translation.
- Do not build for A2A-first — the protocol is 12 days old at v1.0. MCP has 18 months of ecosystem momentum.
