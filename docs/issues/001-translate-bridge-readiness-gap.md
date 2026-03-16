# Issue #001: Translate Bridge Reports Ready Before Subprocess Can Handle Messages

**Status**: OPEN — blocking gateway startup
**Severity**: Critical — prevents all backend registration
**Discovered**: 2026-03-16, Live Mode Mirror Polish
**Component**: `mcpgateway.translate` (IBM ContextForge)

## Symptom

Bootstrap registers Apollo with ContextForge via `POST /gateways`. ContextForge opens an SSE connection to the translate bridge at `http://127.0.0.1:8000/sse` (succeeds — HTTP 200), then sends a `POST /message` to discover tools. The `/message` endpoint returns **500 Internal Server Error** with `ConnectionResetError: Connection lost`.

```
INFO:  127.0.0.1:27297 - "POST /message?session_id=... HTTP/1.1" 500 Internal Server Error
ConnectionResetError: Connection lost
  File "/app/mcpgateway/translate.py", line 530, in send
  File "/app/mcpgateway/translate.py", line 1992, in post_message
```

## Root Cause

The `mcpgateway.translate` bridge has a readiness gap:

1. Bridge starts its HTTP server → port 8000 responds → logs "Multi-protocol server ready"
2. Bridge starts the stdio subprocess (`apollo /app/mcp-config.yaml`) in the background
3. Apollo subprocess is still loading the 98K-line GraphQL schema (~10-30s)
4. SSE connections succeed (HTTP server is up), but message forwarding to the subprocess fails because the subprocess stdin/stdout pipes aren't ready for MCP protocol messages

The bridge reports "ready" based on **HTTP server readiness**, not **subprocess readiness**. The SSE endpoint is a transport layer — it doesn't know whether the subprocess can actually handle messages.

## Timeline Evidence

```
14:29:38  translate bridge "Multi-protocol server ready → SSE: http://127.0.0.1:8000/sse"
14:29:51  bootstrap POST /gateways → ContextForge opens SSE + sends /message → 500
14:30:51  bootstrap FATAL (60s timeout on registration)
```

13 seconds between "ready" and registration attempt. Still too early.

## Impact

- Gateway starts all 5 processes successfully
- Liveness probe passes (ContextForge /health on port 4444)
- But zero backends are registered → MCP `tools/list` returns empty
- Service is up but completely non-functional

## Why This Wasn't Caught in Code Review

The code-only Mirror Polish (80 angles, 8 batches) reviewed:
- Bootstrap wait loops and exit code handling (clean)
- SSE probe patterns (fixed curl -sf → accept exit 28)
- PID file races (clean)
- flock advisory lock (fixed missing util-linux)

But the **translate bridge is external code** (IBM ContextForge `mcpgateway.translate`). Code review can verify how we USE it but not its INTERNAL behavior. The readiness gap is inside the bridge's Python code, not in our scripts. This class of bug — **external dependency behavioral assumptions** — requires live testing to discover.

The batch reports noted "R5: Liveness probe hits /health on port 8080 (auth-proxy) — cannot confirm without mcp-auth-proxy source" as an observation. This was prescient — the auth-proxy health endpoint DID cause the liveness crash loop.

## Workaround Options

### A. Pre-registration MCP handshake (recommended)
Before calling `POST /gateways`, send an MCP `initialize` request through the bridge to verify the subprocess is actually responding:
```bash
# Send MCP initialize via the SSE/message endpoint
# If 500 → subprocess not ready, wait and retry
# If 200 → safe to register
```

### B. Longer wait in bootstrap before registration
Add a `sleep 30` after Apollo bridge detection, before registration. Crude but effective.

### C. Patch ContextForge translate bridge
Add subprocess readiness check to the bridge — wait for first successful MCP handshake before logging "ready." Requires upstream PR or fork.

### D. Use streamable_http transport instead of SSE
Apollo v1.9.0 supports `streamable_http`. If ContextForge's client works with it, bypass the translate bridge entirely. Previously noted: "ContextForge's MCP client has a bug with streamable_http."

## Update: Root Cause Refined (2026-03-16 research)

### The Apollo config crash was the PRIMARY cause
The `timeout: 30` key in mcp-config.yaml was unsupported by Apollo v1.9.0, causing immediate crash. The ConnectionResetError was a dead subprocess, not a readiness gap. **FIXED.**

### The registration STILL hangs after Apollo fix
After fixing the config crash, Apollo responds to MCP initialize (our probe succeeds). But ContextForge's `/gateways` POST still hangs for 60+s.

### Root cause: ContextForge uses MCP SSE client, not HTTP POST
Reading ContextForge source (`gateway_service.py:4868-4930`), registration calls:
```python
async with sse_client(url=server_url) as streams:
    async with ClientSession(*streams) as session:
        response = await session.initialize()
        response = await session.list_tools()
```

This is the `mcp.client.sse.sse_client` — it opens a **real SSE event stream**, not our `/message` HTTP POST endpoint. The translate bridge serves both, but they're different code paths. Our curl probe hits `/message` (works), but ContextForge's SSE client opens `/sse` and reads the event stream (may hang).

**The mismatch:** Our bootstrap probe verifies `/message` works, but ContextForge uses the SSE event stream path. These may have different readiness states in the translate bridge.

### Next steps
1. Check if the translate bridge's SSE event stream works correctly when Apollo is alive
2. Check ContextForge's `initialize_timeout` parameter — it may not be set, causing infinite wait
3. Consider setting `FEDERATION_TIMEOUT` env var to bound the hang

## Update: Root Cause CONFIRMED (2026-03-16 research + FEDERATION_TIMEOUT)

After adding `FEDERATION_TIMEOUT=60`, the registration no longer hangs — it fails fast with:

```
Error: Failed to initialize MCP server
Caused by: expect initialized notification, but received: Some(Request(InitializeRequest(...)))
```

**The exact bug:** The translate bridge initializes its stdio subprocess (Apollo) during bridge startup. When ContextForge later opens an SSE session and sends its own `initialize` request, the bridge forwards this to Apollo's stdin. But Apollo already completed its MCP handshake with the bridge and now expects `notifications/initialized` — not a second `initialize` request.

**Protocol violation:** MCP stdio transport is 1:1 (one client per subprocess). The translate bridge acts as the first client (initializes on startup). ContextForge tries to be a second client via SSE. But the bridge multiplexes multiple SSE sessions onto one subprocess stdin/stdout, so the second `initialize` collides with the first session's state.

**This is a ContextForge translate bridge design limitation, not a configuration error.**

## Resolution Plan (Updated)

### Option E: Don't use translate bridge for Apollo (RECOMMENDED)
Apollo v1.9.0 supports `streamable_http` natively. If we can make ContextForge's streamable_http client work (or fix the previously noted bug), we bypass the translate bridge entirely. Apollo would handle its own MCP protocol lifecycle.

### Option F: Register gateway WITHOUT tool discovery
Register the gateway with a `mode` that skips automatic tool discovery, then manually add tools via the API. ContextForge may support a `passive` or `manual` gateway mode.

### Option G: Patch translate bridge to handle re-initialization
The bridge should detect a new SSE session's `initialize` request and either (a) create a new subprocess, or (b) fake the response from cached capabilities without forwarding to the subprocess.

### Option H: Use catalog file instead of /gateways
Bootstrap could write tools to the ContextForge catalog directly via the admin API (`POST /tools`) instead of registering gateways. This bypasses the SSE discovery entirely.
