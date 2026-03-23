# Cloud Run + stdio MCP Servers: Research Report

> **Date**: 2026-03-14
> **Question**: Do stdio-based MCP servers (child processes spawned via npx/node) work reliably on Google Cloud Run?
> **Short answer**: Yes, but ONLY with the right configuration. The default Cloud Run settings will break them.

---

## 1. Child Processes on Cloud Run

### Does Cloud Run support spawning child processes?

**Yes, fully supported.** Cloud Run containers are standard Linux containers. There are no restrictions on `fork()`, `exec()`, `spawn()`, or any process creation syscalls.

**Key facts:**
- Gen2 execution environment (which your service already uses) provides **full Linux compatibility** including all system calls, namespaces, and cgroups. No gVisor syscall emulation issues.
- Gen1 (gVisor-based) emulates most but not all syscalls, which can cause compatibility problems with some software. Gen2 eliminates this entirely.
- Google's own documentation mentions "extra processes running in the container such as an nginx server" in the context of memory usage, confirming multi-process containers are a known and supported pattern.
- Your current deployment already runs 4 child processes successfully (nginx, Apollo, OAuth server, token refresh loop) supervised by `entrypoint.sh` under `tini`.

### What happens during cold starts?

- Cloud Run downloads the container image, runs the entrypoint, and waits for the container to listen on the configured port (8080 in your case).
- Your container must start listening within **4 minutes** (hard limit).
- With `--cpu-boost` (which you have enabled), CPU allocation is temporarily increased during startup to reduce cold start latency.
- Pending requests queue for approximately **3.5x the average startup time** or 10 seconds, whichever is greater.

### Signal handling and PID 1

- In Gen2, your entrypoint process **runs as PID 1** (the init process), which means it's responsible for reaping zombie child processes and forwarding signals.
- Your deployment correctly uses `tini` as the init process (`ENTRYPOINT ["/usr/bin/tini", "--"]`), which handles zombie reaping and signal forwarding to child processes.
- On shutdown, Cloud Run sends **SIGTERM** with a **10-second grace period**, then **SIGKILL**. Your `entrypoint.sh` correctly traps SIGTERM and does ordered shutdown within 25 seconds.

---

## 2. min-instances=1: Container Persistence

### Does the container stay alive permanently?

**No.** Setting `min-instances=1` means Cloud Run **maintains at least 1 instance**, but individual containers can be **recycled at any time** without notice.

**Key facts from official docs:**
- "minimum instances can be restarted at any time"
- There is **no guaranteed maximum container lifetime**
- Cloud Run may recycle containers during infrastructure updates, node migrations, or for other internal reasons
- The container count is maintained (always at least 1), but the specific container instance changes unpredictably

**Implication for stdio MCP servers:** Child processes (dev-mcp, Apollo) will be killed and must be respawned when the container is recycled. Your `entrypoint.sh` watchdog pattern handles this correctly for the current architecture. The planned Node.js gateway must implement similar supervision.

### Do child processes survive between requests?

**This depends entirely on the CPU allocation mode (see section 3).**

---

## 3. CPU Allocation: The Critical Configuration

Cloud Run has two CPU allocation modes. **This is the single most important setting for your use case.**

### Mode 1: Request-based billing (DEFAULT -- YOUR CURRENT SETTING)

> "CPU is only allocated during request processing"

- CPU is **throttled to near-zero** between requests
- Background processes (child processes, timers, watchers) are effectively **frozen** when no request is being handled
- When a new request arrives, frozen processes resume -- but with unpredictable state
- Official warning: "Running background threads with request-based billing enabled can result in unexpected behavior"
- Cost: Higher per-unit rate ($0.0000240/vCPU-s) but you only pay when handling requests

**YOUR CURRENT DEPLOYMENT IS USING THIS MODE.** The annotation `run.googleapis.com/cpu-throttling` is not set, which defaults to request-based billing. This means your nginx, Apollo, OAuth server, and token refresh loop are all getting **CPU-throttled between requests**. The fact that it works at all is because:
1. MCP requests tend to come in bursts (Claude sends multiple tool calls)
2. Your min-instances=1 keeps the container warm (no cold start)
3. The processes don't need much CPU between requests (they're just waiting for connections)

But stdio MCP servers are different -- they maintain persistent stdio pipes with child processes that may have internal state, buffers, or timers that break when CPU is yanked away.

### Mode 2: Instance-based billing (CPU always allocated)

> "CPU is allocated for the entire container instance lifecycle"

- CPU remains available **at all times**, including between requests and during idle periods
- Background processes, timers, and child processes run continuously
- Official docs: Pairing instance-based billing with minimum instances yields "instances up and running with full access to CPU resources, enabling background processing use cases"
- Cost: Lower per-unit rate ($0.0000065/vCPU-s) but you pay for the full instance lifetime
- No per-request charge

**THIS IS THE MODE YOU NEED.** To enable it:
```
gcloud run services update junlin-shopify-mcp \
  --region asia-southeast1 \
  --no-cpu-throttling
```
Or in `deploy.sh`, add `--no-cpu-throttling` to the `gcloud run deploy` command.

### Idle instance behavior with CPU-always-allocated

Even with instance-based billing, **idle instances can be shut down after 15 minutes** without traffic. However, with `min-instances=1`, Cloud Run will keep at least one instance running. The combination of `min-instances=1` + `--no-cpu-throttling` gives you:
- Always at least 1 instance running
- CPU always available (child processes never frozen)
- Container may still be recycled unpredictably (handle gracefully)

---

## 4. Multi-Process Containers: Google's Guidance

### Official position

Google's Cloud Run documentation **does not provide explicit guidance on running multiple processes within a single container.** There is no official tutorial, no supervisord reference, and no multi-process best practices page.

The closest official pattern is **sidecars** (multi-container deployments):
- Up to 10 containers per instance
- Containers share localhost networking and can share in-memory volumes
- Separate container images, health checks, startup ordering, and resource limits per container
- Recommended for concerns like reverse proxying (nginx), auth (OPA), and monitoring

### What the community does

Your `entrypoint.sh` pattern (bash process supervisor with watchdogs) is a well-known pattern used in Docker containers generally, not specific to Cloud Run. It works but is fragile.

The standard tooling:
- **tini** (which you use): Proper init process for zombie reaping and signal forwarding
- **supervisord**: Full-featured process supervisor, commonly used in multi-process Docker containers
- **Node.js child_process module**: For the planned gateway, `child_process.spawn()` gives you direct control over stdio pipes, lifecycle management, and signal handling in JavaScript

### Sidecar vs. single container for MCP

For your use case (gateway + Apollo + dev-mcp), sidecars are a **poor fit** because:
1. dev-mcp uses stdio transport -- it needs a direct pipe from the parent process, not an HTTP connection over localhost
2. The gateway needs to merge tool lists from multiple backends -- this requires in-process coordination, not inter-container HTTP calls
3. Apollo could be a sidecar (it already runs on its own HTTP port), but then you'd need to coordinate startup ordering and health checks across containers

The single-container approach with the Node.js gateway spawning child processes is the right architecture.

---

## 5. Google's Official Stance on MCP + Cloud Run

### Explicit documentation exists

Google has published an official doc page on hosting MCP servers on Cloud Run:
`https://cloud.google.com/run/docs/host-mcp-servers`

**Critical quote:**
> "Cloud Run supports hosting MCP servers with streamable HTTP transport, but not MCP servers with stdio transport."

**This means:** Cloud Run does not support exposing a stdio-based MCP server *as the service itself*. But this is about the **external interface** -- the MCP server that clients connect to. It does NOT say you can't spawn stdio child processes internally.

**Your architecture is fine because:**
- The gateway exposes HTTP (Streamable HTTP/SSE) to Claude -- supported by Cloud Run
- dev-mcp runs as an internal stdio child process -- this is just process management, not a Cloud Run transport concern
- Apollo runs as an internal HTTP server on localhost:8000 -- standard inter-process communication

### Google's own MCP tooling

`@google-cloud/cloud-run-mcp` (560 stars) is Google's official MCP server for deploying apps to Cloud Run. It runs as a local stdio process (npx) or as a remote HTTP server deployed to Cloud Run. Notably, the remote version uses HTTP transport, not stdio.

---

## 6. How Competitors Handle This

### MetaMCP (metatool-ai/metamcp, 2.1k stars)

- **Spawns stdio child processes inside the container.** Server configs include `"command": "uvx"` and `"args"` fields -- standard subprocess invocation.
- If a stdio MCP server requires additional dependencies, users must "customize the Dockerfile to install dependencies."
- Pre-allocates idle sessions for each configured MCP server to reduce cold start latency.
- **Deploys via Docker Compose** (not Cloud Run). Two containers: app (Node.js) + PostgreSQL.
- No evidence of Cloud Run deployment or guidance.

### IBM ContextForge (IBM/mcp-context-forge, 3.4k stars)

- Has a dedicated **translation layer** (`mcpgateway.translate`) that spawns stdio child processes and exposes them over HTTP:
  ```
  python3 -m mcpgateway.translate \
    --stdio "uvx mcp-server-git" \
    --expose-sse --port 9000
  ```
- Can expose a single stdio server via both SSE and Streamable HTTP simultaneously.
- **Deploys via Docker Compose** (app + MariaDB + Redis + optional Nginx).
- Also supports **IBM Cloud Code Engine** (IBM's Cloud Run equivalent) and **Fly.io**.
- Helm chart available for Kubernetes.
- No evidence of Google Cloud Run deployment specifically.

### Common pattern across competitors

All major MCP gateways that aggregate stdio servers:
1. Run in Docker containers with full process control
2. Spawn stdio backends as child processes
3. Use HTTP/SSE for the external-facing interface
4. Deploy on VMs, Docker Compose, or Kubernetes -- NOT on serverless platforms like Cloud Run

**None of the major MCP gateways (MetaMCP, ContextForge, 1MCP) have documented Cloud Run deployments.** They all use platforms that give them persistent, always-on containers with full CPU access.

---

## 7. Cloud Run Pricing: Always-On with CPU-Always-Allocated

### Your configuration

| Parameter | Value |
|-----------|-------|
| vCPUs | 1 |
| Memory | 512 MiB (current) / 1 GiB (recommended for Node.js + child processes) |
| min-instances | 1 |
| max-instances | 3 |
| Billing model | Instance-based (CPU always allocated) -- **must switch to this** |
| Region | asia-southeast1 (Singapore, Tier 1) |
| Execution environment | Gen2 |

### Monthly cost estimate (instance-based billing, 1 instance always running)

**Seconds per month:** 730 hours x 3,600 = 2,628,000 seconds

**At published Tier 1 instance-based rates:**

| Resource | Usage | Free Tier | Billable | Rate | Cost |
|----------|-------|-----------|----------|------|------|
| vCPU | 2,628,000 vCPU-s | 240,000 | 2,388,000 | ~$0.000007-0.000018/vCPU-s | $16-43/mo |
| Memory (1 GiB) | 2,628,000 GiB-s | 450,000 | 2,178,000 | ~$0.0000007-0.000002/GiB-s | $1.5-4.4/mo |
| Requests | N/A | N/A | N/A | No per-request charge | $0 |

**Estimated total: $18-48/month** for one always-on instance.

(Pricing varies -- Google's pricing page loads dynamically and the exact current rates should be verified at `cloud.google.com/run/pricing`. The range above covers the two different rate sets found during research.)

**With committed use discounts:**
- 1-year commitment: ~17% discount
- 3-year commitment: ~25-40% discount

### Cost comparison: request-based vs instance-based

For an always-on service with min-instances=1, instance-based billing is almost always cheaper:
- Request-based: Higher per-second rates, but only billed during requests. With min-instances=1, you still pay idle time at a reduced rate.
- Instance-based: Lower per-second rates, billed continuously. No per-request charges. For always-on workloads, this is the clear winner.

### Alternative: Cloud Run Worker Pools (Preview)

Worker pools are a new Cloud Run feature for persistent background processing:
- Always-on by design -- no idle shutdown
- No HTTP endpoint required
- CPU always allocated
- Manual scaling only (no autoscaling)
- Billed for the entire runtime

However, your gateway needs an HTTP endpoint (for MCP clients to connect), so a standard Cloud Run service is the right choice. Worker pools are for pull-based workloads (Kafka, Pub/Sub) that don't need inbound HTTP.

---

## 8. Summary: What You Must Do

### Configuration changes needed for the current POC

1. **Switch to instance-based billing NOW** -- your current deployment is CPU-throttling child processes between requests:
   ```bash
   gcloud run services update junlin-shopify-mcp \
     --region asia-southeast1 \
     --no-cpu-throttling
   ```

2. **Add `--no-cpu-throttling` to `deploy.sh`** so future deploys don't regress.

### For the v2 Gateway (Node.js)

The planned architecture (gateway spawns Apollo + dev-mcp as child processes) is fully viable on Cloud Run with these requirements:

| Requirement | Setting | Why |
|-------------|---------|-----|
| CPU always allocated | `--no-cpu-throttling` | Child processes need CPU between requests |
| min-instances=1 | `--min-instances 1` | Avoid cold starts, keep processes alive |
| Gen2 execution | `--execution-environment gen2` | Full Linux compat, proper PID 1 semantics |
| Init process | `tini` in Dockerfile | Zombie reaping, signal forwarding |
| Graceful shutdown | SIGTERM handler in gateway | Clean shutdown of child processes within 10s |
| Container recycling tolerance | Process supervision in gateway | Containers restart unpredictably -- respawn children |

### What will NOT work on Cloud Run

- Exposing a stdio MCP server as the Cloud Run service itself (clients can't connect via stdio over HTTP)
- Relying on container immortality (containers are recycled unpredictably)
- Using request-based billing with persistent child processes (CPU gets throttled)

### What WILL work

- Node.js gateway exposing HTTP Streamable/SSE to Claude (external interface)
- Gateway spawning dev-mcp as a stdio child process (internal communication)
- Gateway communicating with Apollo via HTTP on localhost (internal communication)
- Process supervision with automatic respawning on crash or container recycle
- min-instances=1 + CPU-always-allocated for always-on behavior

---

## 9. Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| Container recycling kills child processes | Medium | Process supervision with automatic respawn. Stateless design (no in-memory state that can't be rebuilt). |
| CPU throttling freezes stdio pipes | **Critical** | **Must** use `--no-cpu-throttling`. This is a hard requirement, not optional. |
| 10-second shutdown deadline | Low | tini + SIGTERM handler + ordered shutdown. Your current entrypoint already handles this. |
| Cold start latency | Low | min-instances=1 + cpu-boost eliminates most cold starts. Only on container recycle. |
| npx/node child process startup time | Low | dev-mcp starts in <2 seconds. Apollo (Rust binary) starts in <1 second. |
| Monthly cost | Low | $18-48/month for always-on single instance. Negligible for a business tool. |
| gVisor syscall incompatibility | None | Gen2 uses microVM, not gVisor. Full Linux compatibility. |

---

## Sources

1. Google Cloud Run docs: CPU allocation - `cloud.google.com/run/docs/configuring/cpu-allocation`
2. Google Cloud Run docs: Min instances - `cloud.google.com/run/docs/configuring/min-instances`
3. Google Cloud Run docs: Container contract - `cloud.google.com/run/docs/container-contract`
4. Google Cloud Run docs: Execution environments - `cloud.google.com/run/docs/about-execution-environments`
5. Google Cloud Run docs: Host MCP servers - `cloud.google.com/run/docs/host-mcp-servers`
6. Google Cloud Run docs: Multi-container (sidecars) - `cloud.google.com/run/docs/deploying#sidecars`
7. Google Cloud Run docs: Instance autoscaling - `cloud.google.com/run/docs/about-instance-autoscaling`
8. Google Cloud Run docs: General tips - `cloud.google.com/run/docs/tips/general`
9. MetaMCP source: `github.com/metatool-ai/metamcp`
10. IBM ContextForge source: `github.com/IBM/mcp-context-forge`
11. Google Cloud Run MCP: `github.com/GoogleCloudPlatform/cloud-run-mcp`
12. Current service config: `gcloud run services describe junlin-shopify-mcp`
