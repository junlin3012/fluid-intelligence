# Failure Log

> Record design and implementation failures here. Future agents learn from these. Each entry must include root cause analysis and a concrete lesson.

---

## 2026-03-19: Designed Observability Without Checking ContextForge Capabilities

- **What happened**: During v4 brainstorming, asked the user "Cloud Trace vs Grafana?" for observability — framing it as a new problem to solve. ContextForge already ships OpenTelemetry tracing (4 exporters), Prometheus metrics (12+ metrics), structured logging with correlation IDs, rate limiting, circuit breakers, caching, 42 plugins, and admin UI with flame graphs. Cloud Run provides automatic request metrics, error reporting, and logging. Combined, ~90% of observability needs are already free.
- **Root cause**: Defaulted to "what should we build?" instead of "what do we already have?" The "compose don't build" principle was applied to the big architectural decision (keep ContextForge) but NOT to feature-level decisions (observability, traffic management). This is the same failure pattern as v3's config-without-reading-source-code (failure-log entries 6, 7, 8) — just at a higher abstraction level.
- **The cognitive pattern**: When presented with a design question, the agent's default reasoning is to propose solutions. The correct default should be to inventory existing capabilities first. This pattern has now appeared at three levels: (1) config values — guessed instead of checked, (2) tool interfaces — assumed instead of verified, (3) feature design — proposed instead of inventoried.
- **How it should have been caught**: The agent had already read `project_contextforge_capabilities.md` and `project_contextforge_plugins_deep.md` earlier in the session. The information was available in context. The failure was not lack of data but lack of process discipline.
- **What changed**: Established a mandatory reasoning order for ALL v4 design questions: (1) What does ContextForge already do? (2) What does Cloud Run already do? (3) What's left? (4) Is there an existing tool? (5) Only then: design and build.
- **Lesson**: "Compose don't build" is not just an architectural principle — it is a reasoning discipline that must be applied at every level of design, from high-level architecture down to individual features. The default question is never "what should we build?" It is always "what already exists?"

## 2026-03-14: Missing User Identity in MCP Gateway Design

- **What happened**: Designed an entire MCP gateway with OAuth 2.1, RS256 JWT, tool aggregation, structured logging — but no concept of user identity. The system couldn't tell humans apart. Logs showed "api_key_hash:abc123" instead of "junlin."
- **Root cause**: Anchored on the current architecture (which has no identity) and improved the plumbing instead of fixing the foundation. Confused better crypto for better security. The agent read the existing `oauth-server/server.js` and designed "a better version of the same broken thing."
- **What was missed**: The Security Fundamentals Checklist — specifically Identity, Authorization, Revocation, and Least Privilege. All four were absent from the design.
- **How it should have been caught**: The user said "I want admin to talk to every detail" and "who accessed my store" — both require identity. The agent should have flagged identity as prerequisite before designing anything else. The 5 WHYs (WHO is this for?) would have caught it immediately.
- **What changed**: Added Module 0: IAM to the spec. Per-user API keys, per-user passphrases, role-based tool filtering. Identity baked into Phase 1, not bolted on later.
- **Lesson**: Identity is not a feature. It is the foundation. Everything else (logging, admin tools, security audit) is useless without it. When designing security, answer WHO before HOW.

## 2026-03-17: Hardcoded Business Values Throughout Codebase

- **What happened**: During the identity forwarding implementation, the agent hardcoded `ourteam@junlinleather.com` directly into `bootstrap.sh` (line 447), wrote conditional logic around a specific user email, and treated team names ("admin", "viewer") as string literals. The user caught this and flagged it as a fundamental anti-pattern.
- **Root cause**: The agent followed the POC code (which also had hardcoded emails) without questioning the pattern. It optimized for "get it working" over "get it right." The identity spec itself used specific emails as examples, and the implementation copied them literally into code.
- **Scope of the problem**: An audit found **47 hardcoded business-specific values** across the codebase: emails, domain names, GCP project IDs, Cloud SQL instance names, port numbers, service versions, Cloud Run URLs, and GitHub repo paths.
- **How it should have been caught**: The agent should have asked: "If someone forks this repo for a different business, what would they need to change?" The answer should be "only env vars and secrets" — but instead it was "grep for junlinleather across 15 files."
- **What changed**: Added ZERO HARDCODED BUSINESS VALUES rule to `patterns.md`. All business-specific values must come from environment variables or config files. Scripts must be completely portable.
- **Lesson**: Hardcoded business values are like HIV in software — they don't kill immediately, they destroy the immune system over time. When you need to scale, change domains, onboard a second customer, or hand off to another team, every hardcoded value becomes a landmine. The cost of parameterizing is 30 seconds per value. The cost of not parameterizing is hours of grep-and-pray debugging months later. **Agents: if you write a hardcoded business value, you have introduced a bug.**

## 2026-03-14: Static Agent Instructions

- **What happened**: Created `introspect.md` as a static instruction document. It told agents how to think but didn't tell them to update the document itself when they learned something. No mechanism for storing reflections, recording insights, or improving the process.
- **Root cause**: Treated the introspection protocol as a one-time deliverable instead of a living system. Designed instructions for agents but not a feedback loop.
- **How it should have been caught**: The user asked a simple question: "does your behaviour md teach the agent how to reiterate reflect and store reflection?" The answer was no.
- **What changed**: Rewrote introspect.md with the Self-Improvement Rule, Reflection Loop, and supporting files (failure-log.md, insights.md, patterns.md). Agents must now read AND write to these files.
- **Lesson**: Instructions without feedback loops are dead documents. Every system that teaches must also learn. If agents can't update their own instructions, the instructions will become outdated and wrong.

## 2026-03-15: Brute-Force Cloud Build Iteration (5+ wasted builds)

- **What happened**: Fixed deployment issues one at a time across 5+ Cloud Build submissions, each taking 5-10 minutes and costing ~$1-2. Missing `tar` → fix → missing `pip` → fix → PORT conflict → fix → still broken. User called it out: "this is not effective."
- **Root cause**: Never read the FULL Cloud Run logs from a single failure. Each time, read only the most obvious error, fixed it, and submitted another build — revealing the next error in sequence. Classic symptom-chasing instead of root cause analysis.
- **What was missed**: One thorough reading of all logs would have revealed all 6 issues simultaneously: venv corruption from `uv pip install`, Apollo CLI syntax, PORT env var conflict, missing crash detection, health endpoint mismatch, and trap placement.
- **How it should have been caught**: After the FIRST Cloud Build failure, should have used systematic debugging: read ALL logs chronologically, trace every process's startup sequence, verify each component has log entries, identify all that are missing or erroring. Then fix everything in ONE commit.
- **What changed**: Applied systematic debugging skill. Read full logs, traced all 6 root causes, fixed all in one commit with build-time verification step in Dockerfile.
- **Lesson**: Cloud Build iteration is expensive (time + money + user frustration). NEVER submit a "let's see if this works" build. Read the full failure logs, identify ALL issues, fix everything at once. One analyzed build > five guess-and-check builds.

## 2026-03-15: `uv pip install` Corrupts Existing Python Venvs

- **What happened**: ContextForge ships a working Python venv at `/app/.venv/`. Running `uv pip install --python /app/.venv/bin/python psycopg2-binary` to add PostgreSQL support caused `ModuleNotFoundError: No module named 'mcpgateway'` — the ContextForge CLI entry point broke.
- **Root cause**: `uv pip install` into a foreign venv can regenerate/corrupt entry point scripts and `.pth` files. The `mcpgateway` module was still importable via `python3 -m mcpgateway.translate`, but the CLI entry point script at `/app/.venv/bin/mcpgateway` broke. This was especially insidious because the module import works but the entry point doesn't.
- **What was missed**: ContextForge already ships psycopg2 for PostgreSQL support (confirmed by translate processes successfully using `QueuePool`). The install was both redundant and destructive.
- **What changed**: Removed `uv pip install` entirely. Added Dockerfile verification: `RUN /app/.venv/bin/python -c "from mcpgateway.cli import main; print('OK')"` to catch any future venv corruption at build time.
- **Lesson**: Never `pip install` or `uv pip install` into a third-party Docker image's venv unless you've verified (a) the package isn't already included, and (b) the install doesn't break existing entry points. Always add a build-time verification step after modifying a venv.

## 2026-03-15: Wrong Health Endpoint, Wrong Port Variable, Wrong Host Default

- **What happened**: ContextForge started successfully but the health check in entrypoint.sh polled `/healthz` — which doesn't exist. The correct endpoint is `/health`. Additionally, the entrypoint set `MCPGATEWAY_PORT=4444` but ContextForge reads `MCG_PORT`. And `MCG_HOST` defaults to `127.0.0.1` (loopback only), so even if the port was right, ContextForge wouldn't be reachable from outside.
- **Root cause**: Config was written based on assumptions about ContextForge's interface instead of reading its actual source code. Three separate assumptions were all wrong.
- **How it should have been caught**: Read the ContextForge source code (`main.py`, `gunicorn.config.py`) before writing the entrypoint. The health endpoint name, port variable name, and host default are all documented in the codebase.
- **What changed**: Fixed to `/health`, added `MCG_PORT` and `MCG_HOST` exports, increased health check timeout to 180s.
- **Lesson**: Same pattern as "Apollo MCP Server Config Written Without Reading Docs" — ALWAYS read the actual source code for external dependencies. This is now the third time this lesson has appeared. The pattern is clear: every time we interact with a new component, we MUST verify its interface against source/docs, not assume.

## 2026-03-15: Apollo MCP Server Config Written Without Reading Docs

- **What happened**: Created `mcp-config.yaml` with invented fields (`server.name`, `shopify.store`, `shopify.access_token`) that don't exist in Apollo's config schema. Apollo failed: `missing field 'source' for key "default.operations"`.
- **Root cause**: Config was written based on assumptions about Apollo's structure instead of reading the actual docs or source code. The correct format uses `endpoint`, `transport`, `operations.source`, and `headers` at the top level.
- **What changed**: Rewrote config to match Apollo v1.9.0's actual format (verified against repo examples).
- **Lesson**: This is the same lesson from "Source-Verify Before Speccing" (insights.md) but wasn't applied to config files. ALWAYS read the actual `--help`, source code, or example configs before writing configuration for any tool. "Probably works like X" is a trap.

## 2026-03-15: ContextForge StreamableHTTP Client Bug — Apollo Tools Missing

- **What happened**: After switching from `/gateways` to `/servers` endpoint for backend registration, Apollo registration returned HTTP 2xx but its tools never appeared in ContextForge's tool catalog. Only 23 tools visible (17 google-sheets + 6 shopify-dev-mcp), zero from Apollo.
- **Root cause**: ContextForge's MCP Python SDK client (`mcp/client/streamable_http.py`) fails to complete the Streamable HTTP initialize handshake. Error: `Failed to create service: connection closed: initialize notification`. The translate module log confirmed `Protocols: SSE=True, StreamableHTTP=False` — the streamable HTTP protocol was effectively disabled in this ContextForge version (1.0.0-RC-2).
- **What was missed**: The `Protocols: SSE=True, StreamableHTTP=False` log line was present from the start but wasn't noticed. The error appeared on every deployment but was buried among other logs.
- **How it should have been caught**: When switching to `/servers` endpoint, should have verified ALL transport types work — not just assumed. The translate module log clearly stated StreamableHTTP=False.
- **What changed**: Switched Apollo from `streamable_http` to `sse` transport in `mcp-config.yaml`. Updated bootstrap.sh to register Apollo at `/sse` endpoint with `sse` transport. All backends now use the same proven transport.
- **Lesson**: When a platform (ContextForge) claims to support a protocol but it doesn't work, check the platform's own logs for protocol status. Don't fight the platform — use what works. SSE is universally supported; Streamable HTTP is newer and less stable in some implementations.

## 2026-03-15: Double-Auth Problem — ContextForge Rejecting Auth-Proxy JWTs

- **What happened**: MCP requests authenticated through auth-proxy got 401 from ContextForge. Auth-proxy issues RS256 JWTs, but ContextForge has its own auth expecting HMAC JWTs signed with `JWT_SECRET_KEY`.
- **Root cause**: `AUTH_REQUIRED=true` on ContextForge meant it validated JWTs internally using HMAC — incompatible with auth-proxy's RS256 tokens. Two independent auth systems conflicting.
- **What changed**: Set `AUTH_REQUIRED=false` on ContextForge. Auth-proxy handles all external auth; ContextForge trusts internal traffic (all within the same container).
- **Lesson**: When you have a reverse proxy handling auth, the backend should trust the proxy, not double-check with incompatible credentials. This is the standard sidecar auth pattern.

## 2026-03-15: Apollo File-Loading Silently Drops Valid Queries

- **What happened**: Only 2 of 7 GraphQL query operations loaded in Apollo MCP Server (GetProducts, GetProduct). The remaining 5 (GetOrders, GetOrder, GetCustomers, GetCustomer, GetInventoryLevels) were silently dropped — no error, no warning, no log entry.
- **Root cause**: NOT a schema validation issue. All 5 queries pass both Shopify dev-mcp validation AND Apollo's own `validate` tool. The `execute` tool also runs them successfully against the live API. The bug is specifically in Apollo's **file-loading pipeline** — it validates and executes queries fine but fails to register them as MCP tools when loaded from `.graphql` files. Root cause is likely in Apollo's schema tree-shaking algorithm which trims the schema to include only types needed by operations. The Order/Customer types reference 55+ additional types vs Product's simpler type graph.
- **What was missed**: Spent multiple deploy cycles (5+ builds) trying to isolate: separated mutations into query-only dirs, increased memory from 2Gi to 4Gi, enabled debug logging, tested minimal single-field queries. None helped. Should have enabled the `execute` tool earlier.
- **Workaround**: Enable `introspection.execute` and `introspection.validate` in `mcp-config.yaml`. The AI can dynamically compose and execute any query via the `execute` tool — which is actually MORE powerful than predefined operations.
- **Lesson**: When a tool silently drops valid inputs, don't keep testing variations of the input. Enable the tool's diagnostic features (introspection, validate, execute) and bypass the broken pipeline. Apollo's execute tool is the correct long-term approach — it gives the AI unlimited query flexibility rather than being locked to predefined operations.

## 2026-03-18: AUTH_REQUIRED=true Regression — Double-Auth Problem Returned

- **What happened**: E2E tests showed ALL MCP endpoints returning `{"detail":"Authentication required for MCP endpoints"}` (HTTP 401 from ContextForge). OAuth flow worked perfectly — token obtained, auth-proxy validated it — but MCP requests failed.
- **Root cause**: `AUTH_REQUIRED=true` was re-introduced in `cloudbuild.yaml` during the identity forwarding work. This caused the exact same "Double-Auth Problem" documented earlier: auth-proxy strips the Authorization header before forwarding (to prevent HMAC/RS256 conflict), but `AUTH_REQUIRED=true` makes ContextForge reject requests without a Bearer token. The `TRUST_PROXY_AUTH=true` setting provides identity but does NOT satisfy `AUTH_REQUIRED`.
- **How it should have been caught**: The failure-log.md entry "Double-Auth Problem" explicitly documented the fix as `AUTH_REQUIRED=false`. The identity forwarding commits changed it back to `true` without testing the end-to-end flow. E2E tests should have been run after every config change.
- **What changed**: Set `AUTH_REQUIRED=false` in cloudbuild.yaml (again). Updated system-understanding.md to explain WHY it must be false.
- **Lesson**: `AUTH_REQUIRED` and `TRUST_PROXY_AUTH` are independent settings. `AUTH_REQUIRED=true` requires a Bearer token on ALL requests. `TRUST_PROXY_AUTH` only provides identity resolution. When auth-proxy strips the Authorization header, `AUTH_REQUIRED=true` will ALWAYS fail. This is not a "maybe" — it is a logical impossibility. **AUTH_REQUIRED must be false when using auth-proxy with header stripping.**

## 2026-03-15: OAuth Flow Uses Cookie-Based Login, Not HTTP Basic Auth

- **What happened**: E2E test scripts initially used `curl -u user:password` for OAuth authentication. This worked for some MCP auth proxies but the current mcp-auth-proxy v2.5.4 uses a cookie-based login form. The auth endpoint (`.idp/auth`) returns a 302 redirect to a login page (`.auth/login`), which must be POSTed to with `password=...` using a session cookie.
- **Root cause**: The OAuth flow in mcp-auth-proxy is a multi-step browser-like flow: (1) GET auth URL → get session cookie + redirect, (2) POST password to login URL with session cookie, (3) follow redirect to get auth code. HTTP Basic Auth is not supported.
- **Impact**: Token acquisition failed silently (empty token), causing all subsequent MCP calls to fail with "Invalid token."
- **What changed**: Updated test commands to use curl cookie jars (-c/-b flags) and the 3-step login flow.
- **Lesson**: Read the existing E2E test script (`test-e2e.sh`) before writing ad-hoc auth commands. The working flow is already documented in code.

## 2026-03-15: JSON Parsing Fails on ContextForge Tool Descriptions

- **What happened**: MCP `tools/list` response from ContextForge contains literal newline characters inside JSON string values (tool descriptions). Python's `json.loads()` with default `strict=True` rejects these as "Invalid control character."
- **Root cause**: ContextForge doesn't escape newlines in tool descriptions when serializing to JSON. This is a ContextForge bug but easy to work around.
- **Workaround**: Use `json.loads(data, strict=False)` to accept control characters in strings.
- **Lesson**: Always use `strict=False` when parsing JSON from MCP servers — tool descriptions may contain unescaped newlines.

## 2026-03-15: Cloud Run Memory OOM at 2Gi

- **What happened**: Cloud Run logs showed "Memory limit of 2048 MiB exceeded with 2070 MiB used." Container running 5 processes with a 98K-line schema file was marginally over the 2Gi limit.
- **Root cause**: Apollo loading and parsing the 98K-line Shopify schema + ContextForge + dev-mcp + google-sheets bridges all share the same 2Gi memory space.
- **What changed**: Increased memory to 4Gi in `cloudbuild.yaml`. Also updated the `gcloud run services update` command for immediate effect.
- **Lesson**: Multi-process containers need generous memory. The Shopify schema alone is ~3.2MB of text. When running 5 processes including a Rust binary that parses large schemas, 4Gi is the minimum.

## 2026-03-15: Excessive Cloud Build Iterations for Apollo Debugging (8+ builds wasted)

- **What happened**: Spent 8+ Cloud Build iterations (~$0.50-1.00 each, 3-5 min each) trying to fix Apollo's query file-loading: separated mutations, created query-only dirs, increased memory, enabled debug logging, created minimal test queries, added test directories. Each iteration revealed the same result: still only 2 tools.
- **Root cause**: Treated a tool-level bug (Apollo's file-loading pipeline) as a configuration problem. Each "fix" was a hypothesis test deployed to production instead of a local analysis. The correct approach was found eventually: enable `introspection.execute` which bypasses the broken file-loading entirely.
- **Cost**: ~$4-8 in Cloud Build costs, ~30 minutes of deploy cycles. User explicitly called out: "make sure there are no performance red flags" and "keep compute cost in mind."
- **How it should have been caught**: After the first 2 deploys showed no change, should have pivoted to: (1) Read Apollo's source code for the file-loading logic, (2) Enable diagnostic tools (validate/execute) to test from inside, (3) Check for known issues. Instead, kept deploying with small variations.
- **Lesson**: After 2 failed deploys testing the same hypothesis, STOP deploying and change strategy. Each Cloud Build costs real money (~$0.50-1.00). Debugging should happen through log analysis and local testing, not through production deploys.

## 2026-03-15: Misdiagnosed Claude.ai OAuth as Server-Side Bug

- **What happened**: Claude.ai showed "There was an error connecting to the MCP server. Please check your server URL and make sure your server handles auth correctly." Multiple attempts to fix the server-side OAuth flow, including changing EXTERNAL_URL, debugging auth endpoints, testing DCR.
- **Root cause**: NOT a server bug. Claude.ai web/Desktop has a known bug where OAuth DCR succeeds but the auth popup never opens (`step=start_error`). Tracked in GitHub issues #5826, #3515, #11814. The server's OAuth flow works correctly end-to-end (verified manually).
- **What was missed**: Should have searched for known issues FIRST instead of assuming the server was broken. The error message from Claude.ai was misleading — it blamed the server when the bug was in Claude.ai's own OAuth proxy.
- **How it should have been caught**: Before debugging server-side OAuth, search GitHub issues for "Claude.ai MCP OAuth" and "step=start_error". The bug is well-documented with many affected users reporting identical symptoms.
- **What changed**: Documented the known bug and workaround (use Claude Code CLI instead). Verified server OAuth flow manually. Added OAuth flow documentation to system-understanding.md.
- **Lesson**: When a client reports an error, the bug might be in the client, not the server. Always check for known client-side issues before debugging server-side code. Especially for complex multi-party flows like OAuth, trace which component actually fails.
