# Insights Log

> Record what worked well here. Future agents should learn from successes, not just failures.

---

## 2026-03-14: Source-Verify Before Speccing

- **Context**: The v3 spec assumed mcp-auth-proxy had `--port`, `--upstream`, `--jwt-secret` flags. Source verification found the actual flags are completely different: `--listen`, positional upstream after `--`, RSA JWT (not HMAC). Every assumption was wrong.
- **Insight**: Never spec CLI flags, API endpoints, or startup commands without reading the actual source code or `--help` output. "Probably works like X" is a trap.
- **Pattern**: For any external dependency, launch a research agent to verify exact interfaces before writing them into the spec. One iteration of "assume → review → fix" costs more than one upfront verification.

## 2026-03-14: Visual Companion Needs Brand Context

- **Context**: Created architecture diagrams using generic dark-mode tech colors. User called it "distasteful." After fetching junlinleather.com, rebuilt with the actual brand aesthetic (warm cream, Proza Libre, rustic luxury) and it landed well.
- **Insight**: Always check the user's actual brand/website before generating visuals. Don't guess the aesthetic from hex codes alone — see how they're actually used.
- **Pattern**: Fetch the user's website before creating branded visuals. The palette tells you WHAT colors; the website tells you HOW to use them.

## 2026-03-14: User Wants To Think In Conversations, Not Read Specs

- **Context**: During gateway design brainstorming, the user engaged deeply when shown architecture diagrams in markdown, role comparison tables, and "what Claude sees" examples. They asked sharp questions ("how will Claude know these are dev-mcp endpoints?", "will this fuck my context?", "how does Google IAM play a role?") that drove the design forward.
- **Insight**: The user thinks through dialogue, not documentation. Present designs as conversations with examples, not as spec documents. The spec is the output, not the medium.
- **Pattern**: Show concrete examples first (what the user will see/experience), then explain the architecture behind it.

## 2026-03-14: Payload Size Testing Before Integration

- **Context**: Before designing the dev-mcp integration, we tested all 7 tools to measure actual payload sizes (1-30KB). This gave confidence that the integration wouldn't blow up the context window like Apollo's 341KB introspection.
- **Insight**: Test assumptions with real data before designing around them. "Will this fit?" is an empirical question, not a theoretical one.
- **Pattern**: When integrating a new system, measure its actual behavior first. Don't guess.

## 2026-03-14: Agent Behavior Is Infrastructure

- **Context**: The user pushed back on static agent instructions and demanded a self-improving system. This led to the reflection loop, failure log, and insights log.
- **Insight**: Agent behavior docs are not documentation — they are infrastructure. They need the same rigor as code: versioning, iteration, feedback loops, and continuous improvement.
- **Pattern**: Treat agent instructions as code: read them, challenge them, update them, commit changes.

## 2026-03-14: 10-Iteration Deep Review Catches Real Gaps

- **Context**: User requested "true magnum opus, iterate 10 times." Each iteration focused on a different angle: first principles, module challenge, multi-instance analysis, security red team, process model, integration details, UX, checklist, hostile reviewer, final gap analysis. Found 10 concrete gaps that the previous review cycle missed.
- **Insight**: Structured multi-pass review with different lenses (security, UX, scaling, hostile reviewer) catches gaps that a single pass — even a thorough one — misses. The multi-instance contradiction (max-instances=3 but in-memory auth state) would have caused real production failures.
- **Pattern**: For critical architecture specs, use themed iterations: (1) first principles, (2) per-module challenge, (3) scaling analysis, (4) security red team, (5) process model, (6) integration edge cases, (7) user experience, (8) checklist, (9) hostile review, (10) final gap sweep.

## 2026-03-14: Be Honest About Scale

- **Context**: The original spec claimed "scales to ~50 users easily" for a JSON blob in Secret Manager. During the 10-iteration review, this was identified as aspirational BS. Editing JSON in GCP console for 50 users is miserable.
- **Insight**: Be honest about the system's actual scale. "Designed for 2-5 users" with a documented upgrade path to Identity Platform is better than "scales to 50" which no one will test or validate.
- **Pattern**: State the honest scale, then document the upgrade path. Don't claim scale you haven't tested.

## 2026-03-14: MetaMCP Deep Competitive Analysis

- **Context**: Deep-dived into MetaMCP (metatool-ai/metamcp, 2.1k stars) -- the leading open-source MCP aggregator. Read every key source file: database schema, auth middleware, proxy logic, server pool, Dockerfile, bootstrap service, tests.
- **Insight**: MetaMCP is a strong product for its niche (multi-MCP aggregation for individual developers/small teams) but has clear gaps for enterprise/production use. Key observations:
  1. **Config is DB-driven, not file-driven.** PostgreSQL stores everything. No YAML/JSON config file for backends. Config-as-code is not native.
  2. **Multi-user exists but is shallow.** Public/private scoping exists (user owns MCP servers, namespaces, endpoints). But access control is binary: you own it or it's public. No RBAC, no "User A sees backends X+Y while User B sees only Y" without creating separate namespaces per user.
  3. **No per-user per-backend identity delegation.** MetaMCP authenticates the *client* to MetaMCP, but does NOT pass per-user credentials *to the backend MCP servers*. All users share the same backend credentials. This is the critical gap for Fluid Intelligence.
  4. **Test coverage is minimal.** Found exactly 1 test file (tools-sync-cache.test.ts, ~150 lines). No integration tests, no auth tests, no E2E tests.
  5. **Maintainer bandwidth is limited.** Author posted that development is slow, was looking for funding, joined a startup as co-founder. Suggests the project may stagnate.
  6. **Architecture is monolithic.** Next.js frontend + Express backend + PostgreSQL, all in one Docker container. No horizontal scaling (in-memory session pool, rate limit counters).
- **Pattern**: When analyzing competitors, read the actual source code, not just the README. READMEs describe aspirations; code reveals reality.

## 2026-03-14: Cloud Run Default CPU Throttling Breaks Child Processes

- **Context**: Researched whether stdio MCP servers (child processes) work on Cloud Run. Discovered the current deployment (`junlin-shopify-mcp`) is using the DEFAULT request-based billing, meaning CPU is throttled to near-zero between requests. This means nginx, Apollo, OAuth server, and the token refresh loop are all getting frozen between requests. It "works" only because MCP requests come in bursts and the processes are mostly idle between them.
- **Insight**: Cloud Run's default mode is hostile to background/child processes. The `--no-cpu-throttling` flag (instance-based billing) is a hard requirement for any architecture that spawns persistent child processes. Google's own docs explicitly say: "Cloud Run supports hosting MCP servers with streamable HTTP transport, but not MCP servers with stdio transport" -- but this refers to the external interface, not internal child processes.
- **Pattern**: When deploying multi-process containers to Cloud Run, ALWAYS set `--no-cpu-throttling`. Verify with `gcloud run services describe` that the annotation is set. The default will silently freeze your background processes.
- **Action**: Add `--no-cpu-throttling` to `deploy.sh` immediately.

## 2026-03-14: Compose, Don't Build — Evaluate Before Committing

- **Context**: User explicitly said "I don't feel like building a product. The bigger it is the more likely I am going to fail." Shifted strategy from building custom gateway to evaluating 8 existing open-source tools and composing them.
- **Insight**: Deep-evaluated 8 MCP gateways by reading actual source code, Dockerfiles, config formats, auth middleware, and deployment guides. Found that marketing claims often diverge from code reality:
  - MCPHub claims multi-user but has a global singleton `UserContextService` (race condition)
  - MetaMCP claims "zero-config" but requires PostgreSQL and has no config file for backends
  - ContextForge claims "easy Cloud Run" but requires 3 GCP services ($55-80/mo)
  - 1MCP has the cleanest architecture but no user identity beyond OAuth clientId
- **Pattern**: Before recommending any external tool, read the actual source code. Check auth middleware for race conditions, check deployment docs for hidden dependencies, check test coverage for quality signals. READMEs are marketing.

## 2026-03-14: Tiered Architecture Beats All-or-Nothing

- **Context**: There's a tension between "don't build big" (user wants simplicity) and "never run into constraints" (user wants scalability). Resolved by recommending a tiered approach: 1MCP now → ContextForge later → Casdoor for enterprise auth.
- **Insight**: Don't force a single tool to cover all future needs. Pick the simplest tool that works now, verify the upgrade path exists (concepts map 1:1), and document when to upgrade. This reduces initial risk while preserving optionality.
- **Pattern**: Present architecture recommendations as tiers with clear upgrade triggers, not as a single monolithic choice.

## 2026-03-14: MCP Gateway OAuth 2.1 Authorization Server Research

- **Context**: Systematically evaluated 15+ MCP gateways/aggregators to find which ones serve as OAuth 2.1 authorization servers (not just OAuth consumers). This is the critical requirement for Claude.ai compatibility: the tool must serve `/.well-known/oauth-authorization-server`, `/authorize`, `/token` at its own domain.
- **Insight**: Only 3 tools genuinely implement a built-in OAuth 2.1 authorization server:
  1. **MetaMCP** (metatool-ai/metamcp, 2.1k stars) — Full OAuth 2.1 authz server with `/oauth/authorize`, `/oauth/token`, `/oauth/register`, `/oauth/userinfo`, `/.well-known/oauth-authorization-server`. PKCE+S256. Source-code verified (`apps/backend/src/routers/oauth/`). Aggregates multiple backends. Supports stdio via mcp-proxy.
  2. **1MCP** (1mcp-app/agent, 396 stars) — OAuth 2.1 with PKCE. Serves `/.well-known/oauth-authorization-server`, `/.well-known/oauth-protected-resource`, `/oauth/authorize`, `/token`. Source-code verified (test file confirms full flow). Aggregates backends. Stdio native.
  3. **atrawog/mcp-oauth-gateway** (50 stars) — Full OAuth 2.1 with DCR (RFC 7591/7592). Serves `/register`, `/authorize`, `/token`, `/.well-known/*`, `/revoke`, `/introspect`. Aggregates via Traefik routing. Stdio via mcp-streamablehttp-proxy. BUT: experimental, "NOT recommended for production."
- **Tools that do NOT serve as OAuth authorization servers** (confirmed):
  - MCPHub: JWT/bcrypt + social login for dashboard, no OAuth authz server
  - Unla: OAuth client only, JWT admin auth
  - deco.cx/mesh: Consumes OAuth via Better Auth, not a provider
  - MCPJungle: Bearer tokens only, no OAuth server
  - Microsoft mcp-gateway: Validates Azure Entra ID tokens, doesn't issue them
  - Docker mcp-gateway: Facilitates OAuth for individual MCP servers, no central authz server
  - hyprmcp/mcp-gateway: OAuth PROXY (rewrites upstream metadata), not an authorization server itself
  - Lasso mcp-gateway: No OAuth at all
  - securemcp-okta-gateway: Delegates to Okta, not standalone
  - oidebrett/mcpauth: Forward auth proxy, delegates to external providers
  - go-mcp-gateway: Passes through Google tokens, not a token issuer
  - agentic-community/mcp-gateway-registry: Keycloak/Entra ID integration, not standalone OAuth
- **Pattern**: "OAuth support" in a README means nothing. You must check: (a) does it serve `/.well-known/oauth-authorization-server`? (b) does it issue its own tokens? (c) does it implement `/authorize` + `/token` + dynamic client registration? Most tools that claim "OAuth" are either consumers, validators, or proxies to external IdPs.

## 2026-03-14: Identity Provider != Authorization Server — Firebase Auth Cannot Do MCP OAuth

- **Context**: Deep-researched whether Firebase Auth / Google Identity Platform could replace the custom OAuth server for MCP. Investigated across Firebase docs, GCP docs, GitHub, blog posts, npm packages, and community discussions.
- **Insight**: Firebase Auth is an **identity provider** (authenticates users), NOT an **OAuth 2.1 authorization server** (issues tokens to third-party clients). MCP requires the latter. Firebase cannot: serve OAuth metadata at your domain, implement DCR (RFC 7591), issue tokens with custom `aud` claims (RFC 8707), or serve `/authorize`+`/token` endpoints. Using Firebase as login UI behind a proxy saves ~5% of the OAuth code while adding Firebase SDK dependencies, a Firebase project to manage, and token-mapping complexity.
- **Key finding**: The MCP spec (draft, 2025-06-18+) now separates Resource Server from Authorization Server, allowing external auth servers on different domains. But Firebase STILL doesn't qualify because it lacks DCR, RFC 8414 metadata, and custom audience claims.
- **Key finding**: No Google-native service (Firebase, IAP, API Gateway, Cloud Endpoints) can serve as an MCP-compliant OAuth authorization server. The mcp-auth.dev provider list explicitly has no Google providers.
- **Pattern**: Before evaluating an auth service for MCP, check these 5 non-negotiable requirements: (1) `/.well-known/oauth-authorization-server` or OIDC discovery, (2) Dynamic Client Registration or Client ID Metadata Documents, (3) Authorization Code + PKCE as a server, (4) Custom `aud` claim support, (5) Can serve endpoints at your domain or be pointed to via Protected Resource Metadata. If any are missing, the service cannot be an MCP authorization server — only a login backend behind a proxy.

## 2026-03-14: Multi-Agent Review Catches Runtime Failures Before Deploy

- **Context**: Dispatched two parallel review agents (spec reviewer + plan reviewer) against the Fluid Intelligence v3 spec and plan. Found 3 CRITICAL issues that would have caused deployment failure: (1) `uvx` not installed in Dockerfile (Google Sheets bridge crashes), (2) `DATABASE_URL` not constructed anywhere (ContextForge falls back to SQLite), (3) PostgreSQL user `contextforge` never created (only `postgres` exists).
- **Insight**: Parallel spec + plan review catches env var wiring issues, missing package installations, and database setup gaps that are invisible when reading either document alone. The spec defines WHAT env vars exist; the plan defines HOW they're deployed. Mismatches between these two layers are the most dangerous bugs because they're correct in isolation but broken in combination.
- **Pattern**: After writing both spec and plan, dispatch TWO review agents in parallel: one for internal spec consistency, one for spec-plan consistency. The plan reviewer should specifically check: (a) every env var in the spec appears in cloudbuild.yaml, (b) every binary/tool used at runtime is installed in the Dockerfile, (c) every database user/table referenced is created in setup tasks.

## 2026-03-15: Systematic Debugging Beats Brute-Force Cloud Build Iteration

- **Context**: Spent 5+ Cloud Build iterations (~$1-2 each, 5-10 min each) fixing one issue at a time: missing `tar`, missing `pip`, PORT conflict. Each fix revealed the next failure. User correctly called this out as "not effective" and "no strategy."
- **Insight**: One systematic log analysis found ALL 6 root causes at once:
  1. `uv pip install psycopg2-binary` corrupted the ContextForge venv (caused `ModuleNotFoundError`)
  2. Apollo CLI used `--config` flag instead of positional arg
  3. Cloud Run's `PORT=8080` env var is immutable (can't be overridden by `export`)
  4. No early crash detection (background processes crash silently, script waits 60s)
  5. Apollo health endpoint mismatch (`/healthz` vs `/health`)
  6. SIGTERM trap set after processes started (cleanup fails during startup)
- **Key discovery**: `uv pip install` into an existing venv can corrupt entry point scripts while leaving module imports intact. The `mcpgateway` CLI script broke (`ModuleNotFoundError`) but `python3 -m mcpgateway.translate` worked fine.
- **Pattern**: Before submitting ANY Cloud Build: (1) Read ALL logs from the last failure, including stderr and tracebacks, (2) Trace the chronological startup sequence, (3) Identify every process that should start and verify it has a log entry, (4) Fix ALL issues in one commit. One well-analyzed build beats five guess-and-check builds.

## 2026-03-15: Apollo Execute Tool > Predefined Operations

- **Context**: Apollo file-loading pipeline silently drops valid queries. After enabling `introspection.execute` in config, the AI can dynamically compose any GraphQL query and execute it on the fly.
- **Insight**: The `execute` tool is actually SUPERIOR to predefined `.graphql` files:
  1. **Unlimited flexibility** — AI composes queries dynamically based on what it learns from dev-mcp docs
  2. **No deploy cycle** — adding a new query doesn't require a redeploy
  3. **Schema introspection** — can validate queries before executing
  4. **Complex joins** — AI can build multi-level nested queries on demand
- **Pattern**: For Apollo MCP Server, prefer `introspection.execute` over predefined operations. Keep predefined operations only for common, well-tested queries (like GetProducts). Let the AI compose everything else.

## 2026-03-15: Two-Layer Docker Split — Fast Iteration

- **Context**: User frustrated by 4-5 minute rebuilds for every code change. Implemented a fat base image (ContextForge + Apollo + auth-proxy + all system deps) and thin app image (just scripts + config).
- **Insight**: The thin image builds in ~5 seconds and deploys in ~3 minutes (mostly Cloud Run infrastructure time). The base image takes ~10 minutes but only needs rebuilding when upstream dependencies change.
- **Pattern**: `Dockerfile.base` = immutable upstream dependencies (rebuild rarely). `Dockerfile` = our code (rebuild fast). Use `cloudbuild-base.yaml` for base, `cloudbuild.yaml` for thin.

## 2026-03-15: BI Test Validates End-to-End AI Intelligence

- **Context**: User asked to test if an AI could intelligently answer: "Give me sales of Artemis pricking irons in the past 5 months, analyze repeat customer behavior."
- **Insight**: The test validated the full intelligence chain: tool discovery → product search → API docs research → dynamic query composition → data analysis → business insights. The AI successfully:
  1. Discovered 25 tools via MCP tools/list
  2. Found 16 Artemis products using GetProducts
  3. Learned SKU filter syntax from dev-mcp docs
  4. Composed a complex GraphQL query with nested lineItems, customer, and variant data
  5. Executed via Apollo's execute tool (bypassing the file-loading bug)
  6. Analyzed 49 orders: $8,434 revenue, 147 units, 4 repeat customers (8.9% repeat rate)
- **Pattern**: Complex BI queries require the AI to chain multiple tools together. The dev-mcp docs → introspect schema → compose query → execute pipeline is the gold standard for Shopify intelligence.

## 2026-03-15: ContextForge Two-Tier Model — Gateways vs Servers vs Virtual Servers

- **Context**: MCP tools/list returned empty despite 23 tools in the REST catalog. Root cause: ContextForge has a three-tier model.
- **Insight**:
  1. `/gateways` — registers backends, triggers auto-discovery into the REST tool catalog
  2. `/servers` — NOT the same as gateways. Creates virtual servers that bundle subsets of tools
  3. MCP clients connect to `/servers/<UUID>/mcp`. Without a virtual server, `tools/list` returns empty.
- **Pattern**: After registering all gateways, MUST create a virtual server that bundles all tool IDs. This is done in `bootstrap.sh`. The virtual server is what MCP clients actually interact with.

## 2026-03-14: Gateway Backends — Separate Headless vs Local Tools

- **Context**: User wanted Google Workspace MCP (90 tools, 1.8K stars) for the gateway. Analysis showed it requires browser OAuth (not headless-friendly) and adds 90 tools to context. Recommended `xing5/mcp-google-sheets` (17 tools, service account auth) for the gateway and `taylorwilsdon/google_workspace_mcp` for local Claude Code use.
- **Insight**: Not every MCP server belongs in a gateway. Headless deployments need service account or env-var-based auth, lightweight tool counts, and stdio transport. Browser-based OAuth tools work great locally but break in containers.
- **Pattern**: For each MCP backend, evaluate: (a) can it auth headlessly? (b) how many tools does it expose? (c) does it support stdio transport? If any answer is "no" or "too many," recommend it as a local IDE tool instead of a gateway backend.
