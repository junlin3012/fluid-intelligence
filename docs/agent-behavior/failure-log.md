# Failure Log

> Record design and implementation failures here. Future agents learn from these. Each entry must include root cause analysis and a concrete lesson.

---

## 2026-03-14: Missing User Identity in MCP Gateway Design

- **What happened**: Designed an entire MCP gateway with OAuth 2.1, RS256 JWT, tool aggregation, structured logging — but no concept of user identity. The system couldn't tell humans apart. Logs showed "api_key_hash:abc123" instead of "junlin."
- **Root cause**: Anchored on the current architecture (which has no identity) and improved the plumbing instead of fixing the foundation. Confused better crypto for better security. The agent read the existing `oauth-server/server.js` and designed "a better version of the same broken thing."
- **What was missed**: The Security Fundamentals Checklist — specifically Identity, Authorization, Revocation, and Least Privilege. All four were absent from the design.
- **How it should have been caught**: The user said "I want admin to talk to every detail" and "who accessed my store" — both require identity. The agent should have flagged identity as prerequisite before designing anything else. The 5 WHYs (WHO is this for?) would have caught it immediately.
- **What changed**: Added Module 0: IAM to the spec. Per-user API keys, per-user passphrases, role-based tool filtering. Identity baked into Phase 1, not bolted on later.
- **Lesson**: Identity is not a feature. It is the foundation. Everything else (logging, admin tools, security audit) is useless without it. When designing security, answer WHO before HOW.

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

## 2026-03-15: Misdiagnosed Claude.ai OAuth as Server-Side Bug

- **What happened**: Claude.ai showed "There was an error connecting to the MCP server. Please check your server URL and make sure your server handles auth correctly." Multiple attempts to fix the server-side OAuth flow, including changing EXTERNAL_URL, debugging auth endpoints, testing DCR.
- **Root cause**: NOT a server bug. Claude.ai web/Desktop has a known bug where OAuth DCR succeeds but the auth popup never opens (`step=start_error`). Tracked in GitHub issues #5826, #3515, #11814. The server's OAuth flow works correctly end-to-end (verified manually).
- **What was missed**: Should have searched for known issues FIRST instead of assuming the server was broken. The error message from Claude.ai was misleading — it blamed the server when the bug was in Claude.ai's own OAuth proxy.
- **How it should have been caught**: Before debugging server-side OAuth, search GitHub issues for "Claude.ai MCP OAuth" and "step=start_error". The bug is well-documented with many affected users reporting identical symptoms.
- **What changed**: Documented the known bug and workaround (use Claude Code CLI instead). Verified server OAuth flow manually. Added OAuth flow documentation to system-understanding.md.
- **Lesson**: When a client reports an error, the bug might be in the client, not the server. Always check for known client-side issues before debugging server-side code. Especially for complex multi-party flows like OAuth, trace which component actually fails.
