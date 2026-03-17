# Config Architecture Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement 4-layer config architecture so the codebase has zero hardcoded business values, validates all config at startup, and supports per-environment deployment with zero code changes.

**Architecture:** Structural defaults in `config/defaults.env` (conditional assignment syntax), per-environment business config in `config/prod.env`, startup validation in `scripts/validate-config.sh`, local dev via `docker-compose.yml`. entrypoint.sh sources defaults then validates before starting services.

**Tech Stack:** Bash (validate-config.sh, entrypoint.sh), Docker Compose (local dev), Cloud Build YAML (deploy config)

**Spec:** `docs/superpowers/specs/2026-03-17-config-architecture-design.md`

---

## File Map

### Files to Create

| File | Container path | Purpose |
|------|---------------|---------|
| `config/defaults.env` | `/app/config/defaults.env` | Layer 2: structural defaults using `${VAR:=default}` syntax |
| `config/prod.env` | Not in image | Layer 3: JunLinLeather production business config |
| `scripts/validate-config.sh` | `/app/validate-config.sh` | Startup validation — collect all errors, report, fail fast |
| `docker-compose.yml` | Not in image | Local development with PostgreSQL |

### Files to Modify

| File | Change |
|------|--------|
| `scripts/entrypoint.sh` | Source defaults.env (with guard), call validate-config.sh, remove scattered `:?` guards and inline defaults |
| `deploy/Dockerfile` | COPY defaults.env and validate-config.sh into image |
| `deploy/cloudbuild.yaml` | Add `_CLOUDSQL` substitution, reduce `--set-env-vars` to business values only |

---

## Task 1: Create config/defaults.env

**Context:** This is the single source of truth for structural defaults. Every variable uses `${VAR:=default}` conditional assignment — only sets if not already set by Cloud Run env vars (Layer 3). This file is baked into the Docker image.

**Files:**
- Create: `config/defaults.env`

- [ ] **Step 1: Create the defaults file**

```bash
# config/defaults.env — Structural defaults for all deployments
# CRITICAL: Use ${VAR:=default} syntax (conditional assignment).
# This only sets a variable if it's NOT already set by Cloud Run env vars.
# Plain VAR=value would overwrite Cloud Run config — DO NOT USE.

# --- Service Ports ---
: "${APOLLO_PORT:=8000}"
: "${DEVMCP_PORT:=8003}"
: "${SHEETS_PORT:=8004}"
: "${MCPGATEWAY_PORT:=4444}"

# --- Tool Versions ---
: "${DEVMCP_VERSION:=1.7.1}"
: "${SHEETS_VERSION:=0.6.0}"

# --- Database ---
: "${DB_USER:=contextforge}"
: "${DB_NAME:=contextforge}"
: "${DB_POOL_SIZE:=5}"

# --- ContextForge Tuning ---
: "${GUNICORN_WORKERS:=1}"
: "${HTTP_SERVER:=gunicorn}"
: "${CACHE_TYPE:=database}"
: "${FEDERATION_TIMEOUT:=60}"
: "${PYTHONUNBUFFERED:=1}"
: "${MCPGATEWAY_UI_ENABLED:=false}"
: "${MCPGATEWAY_ADMIN_API_ENABLED:=true}"
: "${TRANSPORT_TYPE:=all}"

# --- Security (non-acknowledgment defaults) ---
: "${SSRF_PROTECTION_ENABLED:=true}"
: "${SSRF_ALLOW_LOCALHOST:=true}"
: "${SSRF_ALLOW_PRIVATE_NETWORKS:=true}"
: "${PROXY_USER_HEADER:=X-Authenticated-User}"
: "${SSO_AUTO_CREATE_USERS:=true}"

# --- Observability ---
: "${OTEL_EXPORTER_OTLP_ENDPOINT:=https://cloudtrace.googleapis.com}"
: "${OTEL_TRACES_EXPORTER:=otlp}"
: "${OTEL_METRICS_EXPORTER:=none}"

# --- Bootstrap ---
: "${MIN_TOOL_COUNT:=70}"
: "${VIRTUAL_SERVER_NAME:=fluid-intelligence}"

# --- Bind addresses (container defaults) ---
: "${HOST:=0.0.0.0}"
: "${MCG_HOST:=0.0.0.0}"
```

- [ ] **Step 2: Verify syntax is correct**

```bash
# Test: sourcing with a pre-set var should NOT overwrite it
APOLLO_PORT=9999 bash -c 'source config/defaults.env; echo $APOLLO_PORT'
# Expected: 9999 (not 8000)

# Test: sourcing without pre-set var should set the default
bash -c 'source config/defaults.env; echo $APOLLO_PORT'
# Expected: 8000
```

---

## Task 2: Create config/prod.env

**Context:** Per-environment business config for JunLinLeather production. This file is NOT baked into the image — values are passed via `cloudbuild.yaml --set-env-vars`. The file exists in git as documentation and for local reference.

**Files:**
- Create: `config/prod.env`

- [ ] **Step 1: Create the prod config file**

```bash
# config/prod.env — JunLinLeather production
# These values are set via cloudbuild.yaml --set-env-vars at deploy time.
# This file exists for documentation and local development reference.
# SECRETS ARE NOT IN THIS FILE — they come from GCP Secret Manager.

# Business config
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
```

---

## Task 3: Create scripts/validate-config.sh

**Context:** Runs at startup before any service. Validates ALL required vars, collects errors, reports everything at once, then crashes if anything is missing. Replaces scattered `:?must be set` guards.

**Files:**
- Create: `scripts/validate-config.sh`

- [ ] **Step 1: Create the validation script**

```bash
#!/bin/bash
# Validate all required environment variables before starting services.
# Collects ALL errors and reports them at once — don't stop at the first failure.
# Exit 0 = all validated. Exit 1 = missing/invalid vars.

ERRORS=0

# --- Helpers ---
require() {
  local var_name="$1" description="$2" format="${3:-}"
  local value="${!var_name:-}"
  if [ -z "$value" ]; then
    echo "[config] ✗ $var_name — MISSING (required: $description)"
    ERRORS=$((ERRORS + 1))
    return
  fi
  if [ -n "$format" ]; then
    if ! [[ "$value" =~ $format ]]; then
      echo "[config] ✗ $var_name — INVALID format (got: $value, expected: $description)"
      ERRORS=$((ERRORS + 1))
      return
    fi
  fi
  # Don't print secrets, just confirm they're set
  if [[ "$var_name" =~ SECRET|PASSWORD|KEY|CREDENTIALS ]]; then
    echo "[config] ✓ $var_name (set, ${#value} chars)"
  else
    echo "[config] ✓ $var_name=$value"
  fi
}

require_unless() {
  local condition_var="$1" var_name="$2" description="$3" format="${4:-}"
  if [ -n "${!condition_var:-}" ]; then
    echo "[config] ○ $var_name — skipped ($condition_var is set)"
    return
  fi
  require "$var_name" "$description" "$format"
}

warn_if_equal() {
  local var1="$1" var2="$2" msg="$3"
  if [ -n "${!var1:-}" ] && [ "${!var1}" = "${!var2:-}" ]; then
    echo "[config] ⚠ WARNING: $var1 equals $var2 — $msg"
  fi
}

echo "[config] Validating environment..."

# --- Required business config ---
require "SHOPIFY_STORE" "your-store.myshopify.com" '^[a-zA-Z0-9._-]+\.myshopify\.com$'
require "SHOPIFY_API_VERSION" "YYYY-MM (e.g., 2026-01)" '^[0-9]{4}-[0-9]{2}$'
require "EXTERNAL_URL" "public hostname (no https://)" '^[a-zA-Z0-9][a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$'
require "GOOGLE_ALLOWED_USERS" "comma-separated emails" '.*@.*'
require "PLATFORM_ADMIN_EMAIL" "admin email address" '.*@.*'

# CLOUDSQL_INSTANCE only required if DATABASE_URL is not set (Cloud Run mode)
require_unless "DATABASE_URL" "CLOUDSQL_INSTANCE" "project:region:instance" '^[a-zA-Z0-9_-]+:[a-zA-Z0-9_-]+:[a-zA-Z0-9_-]+$'

# --- Required secrets ---
require "SHOPIFY_CLIENT_ID" "Shopify app client ID"
require "SHOPIFY_CLIENT_SECRET" "Shopify app client secret"
require "JWT_SECRET_KEY" "JWT signing key (20+ chars)"
require "AUTH_PASSWORD" "CLI auth password"
require "GOOGLE_OAUTH_CLIENT_ID" "Google OAuth client ID"
require "GOOGLE_OAUTH_CLIENT_SECRET" "Google OAuth client secret"
require "SHOPIFY_TOKEN_ENCRYPTION_KEY" "Shopify token encryption key"
require "CREDENTIALS_CONFIG" "Google Sheets service account JSON"

# AUTH_ENCRYPTION_SECRET — required but warn if same as JWT_SECRET_KEY
require "AUTH_ENCRYPTION_SECRET" "DB encryption key (must differ from JWT_SECRET_KEY)"
warn_if_equal "AUTH_ENCRYPTION_SECRET" "JWT_SECRET_KEY" "rotating JWT will corrupt stored data"

# DB_PASSWORD only required if DATABASE_URL is not set
require_unless "DATABASE_URL" "DB_PASSWORD" "database password"

# --- Report ---
if [ "$ERRORS" -gt 0 ]; then
  echo "[config] FATAL: $ERRORS required variable(s) missing or invalid. Cannot start."
  exit 1
fi

echo "[config] All required variables validated."
```

- [ ] **Step 2: Test validation locally**

```bash
# Test: missing vars should report all errors
chmod +x scripts/validate-config.sh
env -i HOME="$HOME" PATH="$PATH" bash scripts/validate-config.sh 2>&1 | head -20
# Expected: multiple ✗ lines, then FATAL

# Test: with all vars set should pass
source config/defaults.env
export SHOPIFY_STORE=test.myshopify.com SHOPIFY_API_VERSION=2026-01 \
  EXTERNAL_URL=test.run.app GOOGLE_ALLOWED_USERS=test@test.com \
  PLATFORM_ADMIN_EMAIL=admin@test.com CLOUDSQL_INSTANCE=proj:region:inst \
  SHOPIFY_CLIENT_ID=x SHOPIFY_CLIENT_SECRET=x JWT_SECRET_KEY=xxxxxxxxxxxxxxxxxxxx \
  AUTH_PASSWORD=x GOOGLE_OAUTH_CLIENT_ID=x GOOGLE_OAUTH_CLIENT_SECRET=x \
  SHOPIFY_TOKEN_ENCRYPTION_KEY=x CREDENTIALS_CONFIG=x AUTH_ENCRYPTION_SECRET=y \
  DB_PASSWORD=x
bash scripts/validate-config.sh
# Expected: all ✓, "All required variables validated."
```

---

## Task 4: Modify entrypoint.sh

**Context:** Source defaults.env at the top (with guard), call validate-config.sh, remove scattered `:?` guards and inline `:-default` patterns that are now handled by defaults.env.

**Files:**
- Modify: `scripts/entrypoint.sh`

- [ ] **Step 1: Add defaults sourcing and validation at the top (after bash version check)**

After line 11 (`elapsed() { ... }`), before the "Starting services" echo, add:

```bash
# --- Load structural defaults (Layer 2) ---
# Uses ${VAR:=default} syntax — only sets vars not already set by Cloud Run (Layer 3).
DEFAULTS_FILE="/app/config/defaults.env"
if [ -f "$DEFAULTS_FILE" ]; then
  set -a
  source "$DEFAULTS_FILE"
  set +a
else
  echo "[fluid-intelligence] WARNING: $DEFAULTS_FILE not found — using environment vars only"
fi

# --- Validate all config before starting anything ---
VALIDATE_SCRIPT="/app/validate-config.sh"
if [ -f "$VALIDATE_SCRIPT" ]; then
  bash "$VALIDATE_SCRIPT" || exit 1
else
  echo "[fluid-intelligence] WARNING: $VALIDATE_SCRIPT not found — skipping validation"
fi
```

- [ ] **Step 2: Remove scattered validation guards**

Remove or simplify the existing validation block (lines 37-70) that does individual `:?` checks. The validate-config.sh script now handles all of this with better error messages.

Keep only the format validation for `SHOPIFY_STORE`, `MCPGATEWAY_PORT`, `EXTERNAL_URL`, `DB_USER`, `DB_NAME` as defense-in-depth (these protect against injection, not just missing values).

Remove:
- `${SHOPIFY_API_VERSION:?...}` (validated by validate-config.sh)
- `${DB_PASSWORD:?...}` (validated by validate-config.sh)
- `${SHOPIFY_CLIENT_ID:?...}` (validated by validate-config.sh)
- `${SHOPIFY_CLIENT_SECRET:?...}` (validated by validate-config.sh)
- `${JWT_SECRET_KEY:?...}` (validated by validate-config.sh)
- `${AUTH_PASSWORD:?...}` (validated by validate-config.sh)
- `${SHOPIFY_STORE:?...}` (validated by validate-config.sh)
- `${GOOGLE_OAUTH_CLIENT_ID:?...}` (validated by validate-config.sh)
- `${GOOGLE_OAUTH_CLIENT_SECRET:?...}` (validated by validate-config.sh)
- `${CLOUDSQL_INSTANCE:?...}` (validated by validate-config.sh)
- `${EXTERNAL_URL:?...}` (validated by validate-config.sh)
- `${GOOGLE_ALLOWED_USERS:?...}` (validated by validate-config.sh)
- `${PLATFORM_ADMIN_EMAIL:?...}` (validated by validate-config.sh)

- [ ] **Step 3: Remove inline defaults that are now in defaults.env**

Replace patterns like `${APOLLO_PORT:-8000}` with just `$APOLLO_PORT` since defaults.env has already set them. Remove the duplicated env var setup block that sets `CONTEXTFORGE_PORT`, `MCG_PORT`, `MCG_HOST`, service ports, and tool versions — these are now in defaults.env.

Keep the `DATABASE_URL` construction (it derives from other vars) and the `AUTH_ENCRYPTION_SECRET` fallback logic.

---

## Task 5: Modify Dockerfile

**Context:** COPY the new files into the image.

**Files:**
- Modify: `deploy/Dockerfile`

- [ ] **Step 1: Add COPY for defaults.env and validate-config.sh**

After the existing `COPY config/mcp-config.yaml` line, add:

```dockerfile
# Config defaults (Layer 2 — structural defaults for all deployments)
COPY config/defaults.env /app/config/defaults.env

# Startup validation
COPY scripts/validate-config.sh /app/validate-config.sh
```

Update the chmod line to include validate-config.sh:

```dockerfile
RUN chmod 755 /app/entrypoint.sh /app/bootstrap.sh /app/validate-config.sh && \
```

---

## Task 6: Simplify cloudbuild.yaml

**Context:** Move structural defaults out of `--set-env-vars` (now in defaults.env baked into image). Only keep business-specific values. Add `_CLOUDSQL` substitution.

**Files:**
- Modify: `deploy/cloudbuild.yaml`

- [ ] **Step 1: Add _CLOUDSQL substitution and simplify env vars**

Replace the current `--set-env-vars` line (34 vars) with only business-specific values (~12 vars). Add `_CLOUDSQL` substitution for `--add-cloudsql-instances`.

The new `--set-env-vars` should contain ONLY values from `config/prod.env` plus any that override defaults:

```
SHOPIFY_STORE, SHOPIFY_API_VERSION, EXTERNAL_URL, GOOGLE_ALLOWED_USERS,
PLATFORM_ADMIN_EMAIL, CLOUDSQL_INSTANCE, SSO_GOOGLE_ADMIN_DOMAINS,
OTEL_SERVICE_NAME, TRUST_PROXY_AUTH, TRUST_PROXY_AUTH_DANGEROUSLY,
MCP_CLIENT_AUTH_ENABLED, AUTH_REQUIRED, PRIMARY_USER_EMAIL
```

Replace `--add-cloudsql-instances=junlinleather-mcp:asia-southeast1:contextforge` with `--add-cloudsql-instances=${_CLOUDSQL}`.

Add to substitutions:
```yaml
_CLOUDSQL: 'junlinleather-mcp:asia-southeast1:contextforge'
```

---

## Task 7: Create docker-compose.yml

**Context:** Local development without GCP. Uses local PostgreSQL, skips CLOUDSQL_INSTANCE via DATABASE_URL override.

**Files:**
- Create: `docker-compose.yml`

- [ ] **Step 1: Create docker-compose.yml**

```yaml
# Local development — run gateway with local PostgreSQL (no GCP required)
# Usage: cp .env.example .env → fill values → docker compose up
services:
  gateway:
    build:
      context: .
      dockerfile: deploy/Dockerfile
    env_file:
      - config/defaults.env
      - .env
    environment:
      # Local PostgreSQL (overrides CLOUDSQL_INSTANCE requirement)
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
    volumes:
      - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
```

---

## Task 8: Test, Commit, Deploy

**Context:** All changes are batched. Test locally first, commit once, deploy once.

- [ ] **Step 1: Test validate-config.sh locally (missing vars)**

```bash
chmod +x scripts/validate-config.sh
env -i HOME="$HOME" PATH="$PATH" bash scripts/validate-config.sh
# Expected: all ✗, FATAL with count
```

- [ ] **Step 2: Test validate-config.sh locally (all vars set)**

```bash
# Source defaults + prod config + fake secrets
set -a; source config/defaults.env; source config/prod.env; set +a
export SHOPIFY_CLIENT_ID=test SHOPIFY_CLIENT_SECRET=test \
  JWT_SECRET_KEY=test-key-at-least-20-chars AUTH_PASSWORD=test \
  GOOGLE_OAUTH_CLIENT_ID=test GOOGLE_OAUTH_CLIENT_SECRET=test \
  SHOPIFY_TOKEN_ENCRYPTION_KEY=test CREDENTIALS_CONFIG=test \
  AUTH_ENCRYPTION_SECRET=different-from-jwt DB_PASSWORD=test
bash scripts/validate-config.sh
# Expected: all ✓, "All required variables validated."
```

- [ ] **Step 3: Test defaults.env precedence**

```bash
# Cloud Run var should override default
APOLLO_PORT=9999 bash -c 'source config/defaults.env; echo "APOLLO_PORT=$APOLLO_PORT"'
# Expected: APOLLO_PORT=9999

# Without Cloud Run var, default should apply
bash -c 'source config/defaults.env; echo "APOLLO_PORT=$APOLLO_PORT"'
# Expected: APOLLO_PORT=8000
```

- [ ] **Step 4: Commit all changes**

```bash
git add config/defaults.env config/prod.env scripts/validate-config.sh \
  docker-compose.yml scripts/entrypoint.sh deploy/Dockerfile deploy/cloudbuild.yaml
git commit -m "feat: 4-layer config architecture — defaults, validation, per-env, local dev"
```

- [ ] **Step 5: Deploy**

```bash
git push origin main
gcloud builds submit --config=deploy/cloudbuild.yaml --project=junlinleather-mcp
```

- [ ] **Step 6: Verify via Cloud Run logs**

```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="fluid-intelligence" AND textPayload=~"config"' \
  --project=junlinleather-mcp --limit=20 --format='value(textPayload)' --freshness=5m
```

Look for:
- `[config] ✓` lines for all required vars
- `[config] All required variables validated.`
- `[fluid-intelligence] All services running`
- No `FATAL` messages

---

## Dependency Graph

```
Task 1 (defaults.env) ────┐
Task 2 (prod.env) ────────┤
Task 3 (validate-config) ─┼→ Task 4 (entrypoint.sh) → Task 5 (Dockerfile) → Task 6 (cloudbuild)
Task 7 (docker-compose) ──┘                                                       ↓
                                                                              Task 8 (test + deploy)
```

Tasks 1-3 and 7 are independent. Task 4 depends on 1+3. Task 5 depends on 4. Task 6 depends on 5. Task 8 depends on all.
