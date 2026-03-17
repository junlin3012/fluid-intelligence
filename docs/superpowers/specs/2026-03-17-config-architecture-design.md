# Configuration Architecture for Fluid Intelligence

**Date**: 2026-03-17
**Status**: Proposed
**Author**: Claude + Jun Lin
**Depends on**: Identity forwarding (deployed), hardcoded value elimination (deployed)

---

## Problem

The codebase had 47 hardcoded business-specific values (emails, domains, project IDs, ports, URLs) scattered across scripts and config files. These were mechanically replaced with `${VAR}` references, but the system lacks:

1. **A single source of truth** for what configuration exists
2. **Startup validation** that fails fast with clear messages
3. **Per-environment config** that separates prod/staging/local
4. **A local development story** that doesn't require GCP
5. **A portability test** — can a new customer deploy with zero code changes?

## Solution

A 4-layer configuration architecture with env files per environment, a dedicated validation script, and local development support via docker-compose.

---

## Architecture

### Config Layers (bottom to top, each overrides the one below)

```
┌─────────────────────────────────────────┐
│  Layer 4: GCP Secret Manager            │  Secrets only (rotatable)
│           (--set-secrets in Cloud Run)   │
├─────────────────────────────────────────┤
│  Layer 3: Per-environment config        │  Business values per deployment
│           (config/prod.env, etc.)       │  Loaded via cloudbuild.yaml
├─────────────────────────────────────────┤
│  Layer 2: Structural defaults           │  Non-secret, non-business defaults
│           (config/defaults.env)         │  Ports, versions, tuning params
├─────────────────────────────────────────┤
│  Layer 1: Code                          │  ZERO business values
│           (scripts, Dockerfiles)        │  Only ${VAR} references
└─────────────────────────────────────────┘
```

**Override precedence**: Layer 4 > Layer 3 > Layer 2 > Layer 1. Cloud Run env vars (Layer 3) override defaults (Layer 2). Secrets (Layer 4) override everything.

### Startup Sequence

```
entrypoint.sh starts
  → Cloud Run env vars already in process environment (Layer 3 + 4)
  → source /app/config/defaults.env    (Layer 2: only sets UNSET vars)
  → run /app/validate-config.sh        (fail fast if anything missing)
  → start services
```

**CRITICAL: defaults.env uses conditional assignment (`${VAR:=default}`) syntax.** This means it only sets a variable if it's not already set. Cloud Run env vars (Layer 3) are already in the process environment before entrypoint.sh starts, so they automatically take precedence over defaults. See Section 1 for the exact syntax.

---

## Detailed Design

### 1. config/defaults.env — Structural Defaults (Layer 2)

Single file, checked into git. Baked into the Docker image at `/app/config/defaults.env`. Contains non-secret, non-business defaults shared by ALL deployments.

**CRITICAL: Conditional assignment syntax.** Every variable MUST use the bash `${VAR:=default}` pattern (or the `: "${VAR:=default}"` idiom) so that Cloud Run env vars take precedence:

```bash
# CORRECT — only sets if not already set by Cloud Run
: "${APOLLO_PORT:=8000}"

# WRONG — overwrites Cloud Run env vars, breaks Layer 3 override
APOLLO_PORT=8000
export APOLLO_PORT
```

**Container path**: `/app/config/defaults.env` (Dockerfile copies `config/defaults.env` → `/app/config/defaults.env`)

**Sourcing in entrypoint.sh** (with guard):
```bash
DEFAULTS_FILE="/app/config/defaults.env"
if [ -f "$DEFAULTS_FILE" ]; then
  set -a  # auto-export all assignments
  source "$DEFAULTS_FILE"
  set +a
else
  echo "[fluid-intelligence] WARNING: $DEFAULTS_FILE not found — using Cloud Run env vars only"
fi
```

**What belongs here:**
- Service ports (APOLLO_PORT, DEVMCP_PORT, SHEETS_PORT, MCPGATEWAY_PORT)
- Tool versions (DEVMCP_VERSION, SHEETS_VERSION)
- Database defaults (DB_USER, DB_NAME, DB_POOL_SIZE)
- ContextForge tuning (GUNICORN_WORKERS, HTTP_SERVER, CACHE_TYPE, FEDERATION_TIMEOUT)
- Security defaults (SSRF settings)
- Bootstrap config (MIN_TOOL_COUNT, VIRTUAL_SERVER_NAME)
- OTEL defaults (OTEL_TRACES_EXPORTER, OTEL_METRICS_EXPORTER)
- Non-controversial ContextForge flags (PYTHONUNBUFFERED, MCPGATEWAY_UI_ENABLED, TRANSPORT_TYPE)

**What does NOT belong here (must be in per-environment config):**
- Any value that differs between customers (SHOPIFY_STORE, emails, domains)
- Any secret (passwords, API keys, tokens)
- Any GCP-specific value (project IDs, Cloud SQL instances, Cloud Run URLs)
- Security acknowledgment flags (`TRUST_PROXY_AUTH_DANGEROUSLY=true` — each deployment must explicitly opt in)
- Service identity (`OTEL_SERVICE_NAME` — differs per deployment)

### 2. config/prod.env — Per-Environment Config (Layer 3)

One file per environment/customer. Checked into git (secrets excluded). Values set via `cloudbuild.yaml --set-env-vars` at deploy time.

```bash
# config/prod.env — JunLinLeather production
SHOPIFY_STORE=junlinleather-5148.myshopify.com
SHOPIFY_API_VERSION=2026-01
EXTERNAL_URL=fluid-intelligence-1056128102929.asia-southeast1.run.app
GOOGLE_ALLOWED_USERS=ourteam@junlinleather.com
PLATFORM_ADMIN_EMAIL=admin@junlinleather.com
CLOUDSQL_INSTANCE=junlinleather-mcp:asia-southeast1:contextforge
SSO_GOOGLE_ADMIN_DOMAINS=junlinleather.com
OTEL_SERVICE_NAME=fluid-intelligence

# Security acknowledgments (explicit per deployment)
TRUST_PROXY_AUTH=true
TRUST_PROXY_AUTH_DANGEROUSLY=true
MCP_CLIENT_AUTH_ENABLED=false
AUTH_REQUIRED=true

# PRIMARY_USER_EMAIL is optional — defaults to first email in GOOGLE_ALLOWED_USERS
# PRIMARY_USER_EMAIL=ourteam@junlinleather.com
```

**New customer example** (`config/acme.env`):
```bash
SHOPIFY_STORE=acme-store.myshopify.com
SHOPIFY_API_VERSION=2026-01
EXTERNAL_URL=acme-gateway.run.app
GOOGLE_ALLOWED_USERS=admin@acme.com
PLATFORM_ADMIN_EMAIL=admin@acme.com
CLOUDSQL_INSTANCE=acme-project:us-central1:gateway-db
SSO_GOOGLE_ADMIN_DOMAINS=acme.com
OTEL_SERVICE_NAME=acme-gateway
TRUST_PROXY_AUTH=true
TRUST_PROXY_AUTH_DANGEROUSLY=true
MCP_CLIENT_AUTH_ENABLED=false
AUTH_REQUIRED=true
```

**Zero code changes between the two.**

### 3. scripts/validate-config.sh — Startup Validation

Runs before any service starts. Checks every required variable exists and has valid format. Prints a clear report.

**Required variables — Cloud Run mode** (crash if missing):
| Variable | Format validation |
|----------|-------------------|
| SHOPIFY_STORE | Must match `*.myshopify.com` |
| SHOPIFY_API_VERSION | Must match `YYYY-MM` pattern |
| EXTERNAL_URL | Must be valid hostname (no https://) |
| GOOGLE_ALLOWED_USERS | Must contain at least one `@` |
| PLATFORM_ADMIN_EMAIL | Must contain `@` |
| CLOUDSQL_INSTANCE | Must match `project:region:instance` — **SKIP if DATABASE_URL is set** (local mode) |
| SHOPIFY_CLIENT_ID | Must be non-empty |
| SHOPIFY_CLIENT_SECRET | Must be non-empty |
| JWT_SECRET_KEY | Must be non-empty, 20+ chars |
| AUTH_PASSWORD | Must be non-empty |
| GOOGLE_OAUTH_CLIENT_ID | Must be non-empty |
| GOOGLE_OAUTH_CLIENT_SECRET | Must be non-empty |
| DB_PASSWORD | Must be non-empty — **SKIP if DATABASE_URL is set** (local mode) |
| SHOPIFY_TOKEN_ENCRYPTION_KEY | Must be non-empty |
| AUTH_ENCRYPTION_SECRET | Must be non-empty (warn if equals JWT_SECRET_KEY) |
| CREDENTIALS_CONFIG | Must be non-empty (Google Sheets service account JSON) |

**Conditional logic (local vs Cloud Run):**
```bash
# If DATABASE_URL is already set, we're in local mode (docker-compose).
# Skip Cloud SQL-specific requirements.
if [ -n "${DATABASE_URL:-}" ]; then
  echo "[config] Local mode detected (DATABASE_URL set) — skipping CLOUDSQL_INSTANCE check"
  SKIP_CLOUDSQL=true
else
  SKIP_CLOUDSQL=false
fi
```

**Optional variables with documented fallbacks:**
| Variable | Fallback behavior |
|----------|-------------------|
| PRIMARY_USER_EMAIL | Defaults to first email from `GOOGLE_ALLOWED_USERS` (split on comma) |
| PROXY_USER_HEADER | Defaults to `X-Authenticated-User` |
| SSO_AUTO_CREATE_USERS | Defaults to `true` |
| All Layer 2 vars | From `config/defaults.env` |

**Key behavior:**
- Validates ALL vars before crashing (collect all errors, report at end)
- Shows what's missing AND what the expected format is
- Replaces scattered `:?must be set` guards throughout entrypoint.sh
- Returns exit code 0 on success, 1 on failure

### 4. cloudbuild.yaml — Simplified Deployment

Currently, `cloudbuild.yaml` has a 700-character `--set-env-vars` line with 34 variables. With the config layers, only per-environment business values need to be in `--set-env-vars` (the other 22 structural defaults are baked into the image via `config/defaults.env`).

**Delimiter solution:** Keep the current comma-delimited `--set-env-vars` format. This works because `GOOGLE_ALLOWED_USERS` contains `@` but not commas when there's a single user. For multiple users, escape with double quotes or use separate `--update-env-vars` calls. This is a pragmatic choice — the alternative (`--env-vars-file` flag) is not supported by `gcloud run deploy` in Cloud Build steps.

**Cloud SQL instance parameterization:** The `--add-cloudsql-instances` flag in cloudbuild.yaml is also business-specific and currently hardcoded. Move it to a Cloud Build substitution variable:

```yaml
substitutions:
  _IMAGE: 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence:latest'
  _CLOUDSQL: 'junlinleather-mcp:asia-southeast1:contextforge'

# In the deploy step:
- '--add-cloudsql-instances=${_CLOUDSQL}'
```

New customers create their own `deploy/cloudbuild-<customer>.yaml` referencing their substitution values. Or override at submit time: `gcloud builds submit --substitutions=_CLOUDSQL=acme:us-central1:db`.

### 5. docker-compose.yml — Local Development

```yaml
services:
  gateway:
    build:
      context: .
      dockerfile: deploy/Dockerfile
    env_file:
      - config/defaults.env      # Layer 2 structural defaults
      - .env                     # Layer 3 local overrides (gitignored)
    environment:
      # Override DATABASE_URL to use local postgres (skips CLOUDSQL_INSTANCE)
      DATABASE_URL: postgresql://contextforge:localdev@postgres:5432/contextforge
    ports:
      - "8080:8080"
    depends_on:
      postgres:
        condition: service_healthy

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: contextforge
      POSTGRES_PASSWORD: localdev
      POSTGRES_DB: contextforge
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U contextforge"]
      interval: 2s
      timeout: 5s
      retries: 10
```

**Local .env must include:**
- All REQUIRED business vars (SHOPIFY_STORE, EXTERNAL_URL, etc.)
- All REQUIRED secrets (SHOPIFY_CLIENT_ID, JWT_SECRET_KEY, etc.)
- CREDENTIALS_CONFIG (Google Sheets service account JSON)
- CLOUDSQL_INSTANCE is NOT required (DATABASE_URL is set by docker-compose)
- DB_PASSWORD is NOT required (DATABASE_URL includes credentials)

**Cold start note:** First `docker compose up` builds the full image including Rust compilation (~20 min). Subsequent starts are fast. The `npx -y @shopify/dev-mcp` download happens at container runtime (~30s on first start). This is by design — same as Cloud Run cold starts.

### 6. Portability Test (Success Criteria)

The configuration architecture passes the portability test when:

1. **New customer deployment**: `git clone` → create `config/<customer>.env` → create `deploy/cloudbuild-<customer>.yaml` with customer's GCP substitutions → create GCP secrets → `gcloud builds submit` → working gateway. **Zero code changes.**
2. **Local development**: `cp .env.example .env` → fill values → `docker compose up` → working gateway with local PostgreSQL.
3. **Startup crash clarity**: Remove any required env var → container crashes with a message listing ALL missing vars and their expected formats. Not just the first one.
4. **Config audit**: `cat config/defaults.env config/prod.env` shows the complete non-secret configuration of a deployment in two readable files.
5. **Smoke test before deploy**: `docker compose up` with a new customer's `.env` is the portability smoke test. If it starts locally, it will start on Cloud Run.

---

## File Changes

### Files to Create
| File | Container path | Purpose |
|------|---------------|---------|
| `config/defaults.env` | `/app/config/defaults.env` | Structural defaults using `${VAR:=default}` syntax |
| `config/prod.env` | Not in image | JunLinLeather production business config |
| `scripts/validate-config.sh` | `/app/validate-config.sh` | Startup validation — fail fast with clear messages |
| `docker-compose.yml` | Not in image | Local development environment |

### Files to Modify
| File | Change |
|------|--------|
| `scripts/entrypoint.sh` | Source defaults.env (with guard), call validate-config.sh, remove scattered `:?` guards |
| `deploy/cloudbuild.yaml` | Add `_CLOUDSQL` substitution, simplify `--set-env-vars` to business values only |
| `deploy/Dockerfile` | `COPY config/defaults.env /app/config/defaults.env` and `COPY scripts/validate-config.sh /app/validate-config.sh` |

### Files Unchanged
| File | Why |
|------|-----|
| `deploy/Dockerfile.base` | No config changes needed |
| `scripts/bootstrap.sh` | Already parameterized (previous commit) |
| `.env.example` | Already rewritten (previous commit) |

---

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| defaults.env uses wrong syntax (`VAR=x` instead of `${VAR:=x}`) — inverts precedence | Medium | High | Document syntax rule prominently; validate in code review |
| defaults.env file missing from image | Low | Medium | Guard in entrypoint.sh (WARNING, not crash — Cloud Run vars still work) |
| Multi-user GOOGLE_ALLOWED_USERS breaks comma delimiter | Medium | Medium | Document: for multi-user, use separate `--update-env-vars` calls |
| Local docker-compose cold build takes 20 min (Rust) | Certain | Low | Document in README; only happens once; pre-built images could be published |
| validate-config.sh adds startup latency | Very Low | Low | Pure bash, no network calls, < 100ms |

---

## What We're NOT Building

- External config service (Vault, Runtime Configurator) — graduate to this later if needed
- Config UI/dashboard — manage via git + Cloud Build
- Feature flags — not needed at current scale
- Config encryption at rest — secrets are in Secret Manager, config files have no secrets
- Dynamic config reload — restart to pick up changes (acceptable for current scale)
- Multi-tenant routing — each customer gets a separate deployment (Option A)
