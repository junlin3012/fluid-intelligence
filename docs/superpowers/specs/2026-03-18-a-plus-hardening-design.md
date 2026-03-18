# A+ Hardening Design — Security, Reliability, Observability

**Date**: 2026-03-18
**Status**: Polished (Mirror Polish: 30 dimensions, 18 fixes applied)
**Target**: Bring Security (B+→A+), Reliability (B→A+), Observability (C→A+)
**Principle**: ContextForge-first. Configure before building. Zero redundant code.

---

## Design Philosophy

ContextForge v1.0.0-RC2 is a feature-rich platform with 95+ config settings, 16 plugin hooks, built-in OTEL, audit trails, circuit breakers, and session health checks. **Most of the A+ work is configuration, not code.**

Before building anything:
1. Check if ContextForge already has it (capabilities doc)
2. Check if it can be enabled via config/env vars
3. Check if a plugin hook handles it
4. If truly not available, propose an external repo with **justification**
5. Only then design custom code

---

## 1. Security B+ → A+

### 1.1 Remove Secrets from /proc/cmdline

**Problem**: auth-proxy passes `--password` and `--google-client-secret` via CLI args, visible in `/proc/cmdline`.

**ContextForge relevance**: None — this is auth-proxy (Go), not ContextForge.

**Fix**: auth-proxy (Cobra-based) already reads env vars via `getEnvWithDefault()` for ALL flags. **No Go code changes needed.** Just remove the CLI args from entrypoint.sh and map env var names:

```bash
# Current (exposed in /proc):
mcp-auth-proxy --password "$AUTH_PASSWORD" --google-client-secret "$GOOGLE_OAUTH_CLIENT_SECRET" ...

# Fixed (env vars, invisible in /proc):
export PASSWORD="$AUTH_PASSWORD"
export GOOGLE_CLIENT_SECRET="$GOOGLE_OAUTH_CLIENT_SECRET"
mcp-auth-proxy ...  # reads PASSWORD and GOOGLE_CLIENT_SECRET from env
```

**Files changed**:
- `scripts/entrypoint.sh`: remove `--password` and `--google-client-secret` CLI args, add env var exports (~4 lines)

**No base image rebuild needed. No Go fork changes.**

**Risk**: Low. Verify env var names match auth-proxy's `getEnvWithDefault()` keys.

### 1.2 Ephemeral Client Registrations (DCR) — Accepted Tradeoff

**Problem**: OAuth DCR data is stored at `--data-path /app/data` on ephemeral Cloud Run storage. Cold starts wipe all registered clients.

**ContextForge relevance**: None — this is auth-proxy's fosite storage.

**Decision**: **Accept ephemeral.** MCP clients (Claude Code, Claude.ai) handle re-registration transparently via the standard OAuth 2.1 flow (discover → register → authenticate). The only user-visible impact is a ~2-3 second delay on first reconnect after cold start while the OAuth dance completes.

**Why not persist**: Adding persistent storage for a component that works fine with ephemeral storage is over-engineering. The real users re-register automatically.

### 1.3 ContextForge Token Scoping (Already Built-in)

**Leverage**: ContextForge already supports scoped tokens with:
- `server_id` restriction (limit to specific virtual servers)
- Permission restrictions (read-only tokens)
- IP restrictions, time windows, usage limits

**Action**: Token scoping is a **runtime operation**, not a bootstrap operation. When a viewer user first logs in via SSO, their scoped token is created then. Bootstrap cannot create tokens for users that don't exist yet. For now, `SSO_GOOGLE_ADMIN_DOMAINS` auto-promotes domain users to admin. Viewer token scoping will be implemented when multi-user support is needed.

**Files changed**: None for now. Document the pattern for future use.

---

## 2. Reliability B → A+

### 2.1 Subprocess Health Monitoring

**Problem**: If dev-mcp or sheets subprocess (npx/uv child) crashes after bootstrap, the translate bridge process stays alive but tool calls fail silently.

**ContextForge relevance**: ContextForge's session pool has a **circuit breaker** (5 consecutive failures → 60s cooldown) and **health checks** (ping before session reuse). This handles the **user-facing impact** — tool calls return errors immediately (not hang), and after 5 failures the circuit breaker trips. These are hardcoded defaults in ContextForge's MCPSessionPool class (not configurable via env vars).

**What ContextForge can't do**: Restart the dead subprocess or trigger container restart.

**Fix**: Add a lightweight health watchdog to entrypoint.sh that probes bridge health. The watchdog catches **bridge process death** (translate bridge crashes). For **subprocess death** (npx/uv child dies behind a living bridge), rely on ContextForge's circuit breaker for detection + the watchdog's healthz probe as a secondary signal.

```bash
# Health watchdog (runs after bootstrap completes)
health_watchdog() {
  while true; do
    sleep 30
    for pidfile in /tmp/apollo.pid /tmp/devmcp.pid /tmp/sheets.pid; do
      pid=$(cat "$pidfile" 2>/dev/null)
      if [ -n "$pid" ] && [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
        name=$(basename "$pidfile" .pid)
        echo "[watchdog] FATAL: $name (PID $pid) died"
        exit 1  # watchdog exit triggers wait -n → container restart
      fi
    done
  done
}
health_watchdog &
WATCHDOG_PID=$!
```

**Note**: The watchdog uses `exit 1` (not `kill $$`) to avoid a race condition with the existing cleanup trap. The watchdog's death is detected by `wait -n` which monitors all child PIDs including the watchdog.

**Files changed**: `scripts/entrypoint.sh` — add ~15 lines after bootstrap wait, add `$WATCHDOG_PID` to the `wait -n` arguments.

### 2.2 ContextForge Circuit Breaker (Already Active — Verify)

**Leverage**: ContextForge's MCPSessionPool provides:
- Per-URL circuit breaker: 5 consecutive failures → 60s cooldown
- Health check before session reuse (ping or list_tools)
- Session TTL: 300s (stale sessions evicted)
- Max 10 sessions per backend

**These are hardcoded defaults in MCPSessionPool, not configurable via env vars.** They are always active.

**Action**: Verify by behavior — intentionally stop a backend and confirm tool calls fail fast (not hang) and recover after restart. Document in system-understanding.md.

### 2.3 ContextForge Session Health Checks (Already Active)

**Leverage**: Before reusing a cached session, ContextForge sends a `ping` or `list_tools` to verify the backend is alive. If the check fails, the session is evicted and a new one is created.

**Action**: Document in system-understanding.md.

---

## 3. Observability C → A+

### 3.1 Distributed Tracing via Cloud Trace

**Problem**: OTEL traces are disabled (exporter set to `none`).

**ContextForge relevance**: ContextForge has **built-in OpenTelemetry** instrumentation generating spans for HTTP requests, tool invocations, backend connections, and database queries. The traces exist — they just need a working exporter.

**Prerequisite (BLOCKER)**: Grant `roles/cloudtrace.agent` to the compute service account:
```bash
gcloud projects add-iam-policy-binding junlinleather-mcp \
  --member="serviceAccount:1056128102929-compute@developer.gserviceaccount.com" \
  --role="roles/cloudtrace.agent"
```
Without this role, the exporter silently fails.

**Fix**: Install the GCP trace exporter.

```bash
# Dockerfile.base — add after psycopg2 install
RUN uv pip install --python /app/.venv/bin/python opentelemetry-exporter-gcp-trace

# Build-time verification (prevent silent failures)
RUN /app/.venv/bin/python -c "from opentelemetry.exporter.cloud_trace import CloudTraceSpanExporter; print('✓ gcp-trace OK')"
RUN /app/.venv/bin/python -c "from mcpgateway.cli import main; print('✓ mcpgateway OK')"  # regression guard — uv pip can corrupt venv
```

```env
# defaults.env — keep safe default for local dev (no GCP credentials)
OTEL_TRACES_EXPORTER=none

# cloudbuild.yaml --set-env-vars — override for Cloud Run only
OTEL_TRACES_EXPORTER=gcp_trace
# OTEL_SERVICE_NAME is already set in cloudbuild.yaml — do NOT add OTEL_RESOURCE_ATTRIBUTES (redundant)
```

**Note**: The exporter MUST be set in `cloudbuild.yaml` (environment-specific), NOT in `defaults.env` (baked into image). defaults.env keeps `none` as the safe default for non-GCP environments. This follows the existing pattern where `OTEL_SERVICE_NAME` and `STRUCTURED_LOGGING` are set in cloudbuild.yaml.

**Rollback**: If Cloud Trace exporter crashes ContextForge, revert by deploying previous thin image. Cloud Run keeps previous revisions — use `gcloud run services update-traffic` to shift traffic back.

**Cost**: Cloud Trace free tier: 2.5M spans/mo. Cloud Run auto-generated spans are non-chargeable (don't count against limit). For a low-traffic dev gateway, cost is effectively $0.

**Files changed**:
- `deploy/Dockerfile.base`: 3 lines (pip install + 2 verification checks)
- `config/defaults.env`: keep `OTEL_TRACES_EXPORTER=none` (safe default, already set)
- `deploy/cloudbuild.yaml`: add `OTEL_TRACES_EXPORTER=gcp_trace` to `--set-env-vars`

### 3.2 Structured Logging (JSON)

**Problem**: entrypoint.sh and bootstrap.sh use plaintext `echo`. Cloud Run auto-parses JSON logs for structured querying.

**ContextForge relevance**: ContextForge (FastAPI/uvicorn) and auth-proxy (zap) already produce structured logs. Only our shell scripts need the upgrade.

**Fix**: Conditional JSON logging — plaintext by default, JSON when `STRUCTURED_LOGGING=true`:

```bash
log() {
  local level="${1:-INFO}" msg="$2"
  if [ "${STRUCTURED_LOGGING:-false}" = "true" ]; then
    jq -nc --arg s "$level" --arg m "$msg" \
      '{severity:$s,message:$m,timestamp:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),component:"entrypoint"}'
  else
    echo "[fluid-intelligence] $msg"
  fi
}
```

Uses `jq` (already installed) for proper JSON escaping — handles double quotes, backslashes, newlines in messages safely. `printf`-based JSON would break on special characters.

**Files changed**:
- `scripts/entrypoint.sh`, `scripts/bootstrap.sh` — add helper, replace key `echo` calls
- `config/defaults.env` — add `: "${STRUCTURED_LOGGING:=false}"`
- `deploy/cloudbuild.yaml` — add `STRUCTURED_LOGGING=true` to env vars

### 3.3 ContextForge Audit Trail (Already Active — Verify)

**Leverage**: ContextForge logs every action with user email, IP, correlation ID, old/new values, and data classification.

**Action**: Verify audit trail is active and queryable. Note: `AUDIT_TRAIL_RETENTION_DAYS` is **not a verified ContextForge config key** — needs source verification. Audit data is stored in PostgreSQL; retention may require a manual cleanup cron or DB policy rather than a config toggle.

### 3.4 Cloud Monitoring Dashboard + Alerting

**Problem**: No dashboard or alerting. A dashboard nobody watches is incomplete observability.

**Fix**: Create dashboard AND alerting policies:

| Widget | Source | Shows |
|--------|--------|-------|
| Request latency (p50/p95/p99) | Cloud Run metrics | Response time distribution |
| Request count by status | Cloud Run metrics | 200/401/500 rates |
| Cold start frequency | Cloud Run metrics | Scale-from-zero events |
| Instance count | Cloud Run metrics | Active instances over time |
| Tool call latency | Cloud Trace spans | Per-tool response times |
| Memory usage | Cloud Run metrics | OOM risk detection |

**Note**: "Circuit breaker trips" widget deferred — needs verification of ContextForge's log format for circuit breaker events before building.

**Alerting policies** (minimum):
- Alert on 5xx error rate > 5% (5 min window)
- Alert on container restart (crash loop detection)
- Alert on memory usage > 3.5Gi (OOM early warning)

**Implementation**: `scripts/create-dashboard.sh` using `gcloud monitoring dashboards create --config-from-file`

**Files changed**: New `scripts/create-dashboard.sh` (~60 lines)

---

## Implementation Priority

| Phase | Items | Effort | Deploys |
|-------|-------|--------|---------|
| **Phase 1: Config + IAM** | 2.2 circuit breaker (verify), 2.3 session health (verify), 3.3 audit trail (verify), 3.1 IAM role grant | 20 min | 0 |
| **Phase 2: Shell scripts** | 1.1 /proc secrets fix (entrypoint only), 2.1 subprocess watchdog, 3.2 structured logging | 45 min | 1 (thin) |
| **Phase 3: Base image** | 3.1 Cloud Trace exporter (pip install + verify) | 30 min | 1 (base + thin) |
| **Phase 4: Dashboard** | 3.4 dashboard + alerting policies | 30 min | 0 |

**Total: ~2 hours, 2 deploys (1 base + 1 thin)**

---

## What We're NOT Building (ContextForge Already Has It)

| Feature | ContextForge | Our action |
|---------|-------------|------------|
| Circuit breaker | MCPSessionPool: 5 failures → 60s cooldown (hardcoded) | Verify by behavior |
| Session health checks | Ping/list_tools before reuse, 300s TTL (hardcoded) | Verify by behavior |
| Audit trail | User, IP, correlation_id, old/new values | Verify active |
| RBAC | 4 built-in roles, team scoping, permission decorators | Already configured |
| Token scoping | server_id, permissions, IP, time windows, usage limits | Runtime operation (not bootstrap) |
| Plugin hooks | 16 hooks (pre/post for HTTP, tools, resources, prompts) | Use for future rate limiting |
| OTEL instrumentation | Built-in spans for HTTP, tools, DB, sessions | Just needs exporter |
| Input validation | 1MB payload max, dangerous pattern detection | Already active |
| SSRF protection | Enabled by default, localhost/private allowed for backends | Already configured |

---

## Scorecard After Implementation

| Dimension | Before | After | Key Changes |
|-----------|--------|-------|-------------|
| Security | B+ | **A+** | Secrets out of /proc (entrypoint-only fix) |
| Reliability | B | **A+** | Subprocess watchdog + circuit breaker (ContextForge built-in) verified |
| Observability | C | **A+** | Cloud Trace spans, structured JSON logs, dashboard + alerting, audit trail verified |
| Scalability | C | C (unchanged) | Not in scope — requires auth state externalization |
| Cost | A | A (unchanged) | Cloud Trace free tier + Cloud Run non-chargeable spans. Dashboard + alerting: free |
