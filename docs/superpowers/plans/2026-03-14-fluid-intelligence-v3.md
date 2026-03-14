# Fluid Intelligence v3 Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Fluid Intelligence v3 — a compose-based MCP gateway (ContextForge + mcp-auth-proxy) on Cloud Run, with GitHub-triggered CI/CD.

**Architecture:** mcp-auth-proxy (Go, Google OAuth + password) handles OAuth 2.1 on port 8080, reverse-proxies to IBM ContextForge (Python) on port 4444. ContextForge routes tool calls to Apollo MCP (Rust, port 8000), dev-mcp (stdio, port 8003), and mcp-google-sheets (stdio, port 8004). Cloud SQL PostgreSQL for persistent state. Custom domain: junlinleather.com. Cloud Build auto-deploys on push to main.

**Tech Stack:** Docker multi-stage, Go (mcp-auth-proxy v2.5.4), Python (ContextForge 1.0.0-RC-2, mcp-google-sheets), Rust (Apollo MCP), Node.js (dev-mcp), Cloud Build, Cloud Run, Cloud SQL PostgreSQL, Secret Manager.

**Spec:** `docs/superpowers/specs/2026-03-14-fluid-intelligence-v3-design.md`

---

## File Structure

| File | Responsibility | New/Modify |
|---|---|---|
| `Dockerfile` | Multi-stage build: ContextForge base + Apollo + mcp-auth-proxy + Node.js + tini | New |
| `Dockerfile.base` | Apollo Rust compile (rebuild rarely) | Modify (from existing) |
| `entrypoint.sh` | Start 5 long-running processes + bootstrap | New |
| `bootstrap.sh` | Wait for services, register 3 backends with ContextForge API | New |
| `cloudbuild.yaml` | Build, push, deploy to Cloud Run on push to main | New |
| `cloudbuild-base.yaml` | Build base image on Dockerfile.base change | New |
| `mcp-config.yaml` | Apollo config with updated paths for new container | Modify (from existing) |
| `graphql/**` | 23 Shopify persisted mutations (carried over) | Copy |
| `docs/**` | Research, agent-behavior, specs, plans (carried over) | Copy |
| `CLAUDE.md` | Updated for v3 architecture | Modify |
| `.gitignore` | Standard ignores + .superpowers/ | New |

---

## Chunk 1: Repository Setup & GCP Secrets

### Task 1: Create GitHub repo and clone

- [ ] **Step 1: Create the repo on GitHub**

```bash
gh repo create junlin3012/fluid-intelligence --public --description "Universal MCP Gateway — one endpoint for AI clients to access any API"
```

- [ ] **Step 2: Clone and set up**

```bash
cd ~/Projects/Shopify
git clone git@github.com:junlin3012/fluid-intelligence.git
cd fluid-intelligence
```

- [ ] **Step 3: Copy carried-over files from old repo**

```bash
cp -r ~/Projects/Shopify/junlin-shopify-mcp/graphql/ ./graphql/
cp -r ~/Projects/Shopify/junlin-shopify-mcp/docs/ ./docs/
cp ~/Projects/Shopify/junlin-shopify-mcp/CLAUDE.md ./CLAUDE.md
```

- [ ] **Step 4: Create .gitignore**

```gitignore
# Secrets
.env
*.pem
*.key

# Runtime
data/
*.db

# IDE
.idea/
.vscode/

# Superpowers
.superpowers/

# Node
node_modules/

# OS
.DS_Store
```

- [ ] **Step 5: Initial commit**

```bash
git add -A
git commit -m "Initial commit: carried-over files from junlin-shopify-mcp"
```

### Task 2: Create GCP secrets and Cloud SQL instance

mcp-auth-proxy requires RSA private key, HMAC secret, and Google OAuth credentials. ContextForge needs Cloud SQL PostgreSQL.

- [ ] **Step 1: Generate RSA private key (PKCS8 PEM)**

```bash
openssl genpkey -algorithm RSA -out /tmp/jwt-private-key.pem -pkeyopt rsa_keygen_bits:2048
```

- [ ] **Step 2: Generate HMAC secret (base64-encoded 32 bytes)**

```bash
openssl rand -base64 32 > /tmp/hmac-secret.txt
```

- [ ] **Step 3: Store RSA key and HMAC in Secret Manager**

```bash
gcloud secrets create mcp-jwt-private-key --project=junlinleather-mcp \
  --data-file=/tmp/jwt-private-key.pem

gcloud secrets create mcp-auth-hmac-secret --project=junlinleather-mcp \
  --data-file=/tmp/hmac-secret.txt
```

- [ ] **Step 4: Create Google OAuth client ID (manual — GCP Console)**

Go to GCP Console → APIs & Services → Credentials → Create OAuth 2.0 Client ID:
- Application type: Web application
- Name: `Fluid Intelligence MCP`
- Authorized redirect URIs: `https://junlinleather.com/.auth/google/callback`

Store the credentials:
```bash
echo -n "YOUR_CLIENT_ID" | gcloud secrets create google-oauth-client-id \
  --project=junlinleather-mcp --data-file=-

echo -n "YOUR_CLIENT_SECRET" | gcloud secrets create google-oauth-client-secret \
  --project=junlinleather-mcp --data-file=-
```

- [ ] **Step 5: Create Google Sheets service account and store credentials**

```bash
# Create service account
gcloud iam service-accounts create google-sheets-mcp \
  --display-name="Google Sheets MCP" --project=junlinleather-mcp

# Create key and store as base64 secret
gcloud iam service-accounts keys create /tmp/sheets-sa-key.json \
  --iam-account=google-sheets-mcp@junlinleather-mcp.iam.gserviceaccount.com

base64 -i /tmp/sheets-sa-key.json | gcloud secrets create google-sheets-credentials \
  --project=junlinleather-mcp --data-file=-
```

Enable the Sheets and Drive APIs:
```bash
gcloud services enable sheets.googleapis.com drive.googleapis.com \
  --project=junlinleather-mcp
```

- [ ] **Step 6: Create Cloud SQL PostgreSQL instance**

```bash
# Enable Cloud SQL API
gcloud services enable sqladmin.googleapis.com --project=junlinleather-mcp

# Create instance (db-f1-micro, ~$8/mo)
gcloud sql instances create contextforge \
  --database-version=POSTGRES_15 \
  --tier=db-f1-micro \
  --region=asia-southeast1 \
  --project=junlinleather-mcp

# Create database
gcloud sql databases create contextforge \
  --instance=contextforge --project=junlinleather-mcp

# Create user and set password
DB_PASSWORD=$(openssl rand -base64 24)
gcloud sql users create contextforge \
  --instance=contextforge --password="$DB_PASSWORD" \
  --project=junlinleather-mcp

echo -n "$DB_PASSWORD" | gcloud secrets create db-password \
  --project=junlinleather-mcp --data-file=-
```

- [ ] **Step 7: Grant Cloud Run SA access to Cloud SQL**

```bash
gcloud projects add-iam-policy-binding junlinleather-mcp \
  --member="serviceAccount:1056128102929-compute@developer.gserviceaccount.com" \
  --role="roles/cloudsql.client" --quiet
```

- [ ] **Step 8: Verify all 9 secrets exist**

```bash
gcloud secrets list --project=junlinleather-mcp --format="value(name)"
```

Expected:
- `shopify-access-token` (existing)
- `mcp-auth-passphrase` (existing)
- `mcp-jwt-secret` (existing)
- `mcp-jwt-private-key` (new)
- `mcp-auth-hmac-secret` (new)
- `google-oauth-client-id` (new)
- `google-oauth-client-secret` (new)
- `google-sheets-credentials` (new)
- `db-password` (new)

- [ ] **Step 9: Clean up local key files**

```bash
rm /tmp/jwt-private-key.pem /tmp/hmac-secret.txt /tmp/sheets-sa-key.json
```

- [ ] **Step 10: Commit (nothing to commit — secrets and infra are in GCP only)**

Verify: No `.pem`, `.json` key, or secret files in repo.

---

## Chunk 2: Dockerfile & Container Scripts

### Task 3: Write Dockerfile.base (Apollo Rust compile)

- [ ] **Step 1: Write Dockerfile.base**

```dockerfile
# Dockerfile.base — Apollo MCP Server (Rust compile)
# Rebuild rarely: only when Apollo version changes
# Build time: ~18 min

FROM rust:1.77-slim AS builder

RUN apt-get update && apt-get install -y \
    pkg-config libssl-dev git \
    && rm -rf /var/lib/apt/lists/*

# Clone and build Apollo MCP Server
RUN git clone https://github.com/anthropics/anthropic-quickstarts.git /src
WORKDIR /src/mcp/apollo-mcp-server
RUN cargo build --release

# Output: just the binary
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y libssl3 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /src/mcp/apollo-mcp-server/target/release/apollo-mcp-server /usr/local/bin/apollo
```

- [ ] **Step 2: Verify it builds locally (optional — takes 18 min)**

```bash
docker build -f Dockerfile.base -t fluid-intelligence-base .
```

- [ ] **Step 3: Commit**

```bash
git add Dockerfile.base
git commit -m "feat: add Dockerfile.base for Apollo Rust compile"
```

### Task 4: Write mcp-config.yaml

- [ ] **Step 1: Write Apollo MCP config**

```yaml
# mcp-config.yaml — Apollo MCP Server configuration
server:
  name: apollo-shopify
  transport:
    type: streamable_http
    port: 8000
  health_check:
    path: /health
    port: 8000

shopify:
  store: ${SHOPIFY_STORE}
  api_version: ${SHOPIFY_API_VERSION}
  access_token: ${SHOPIFY_ACCESS_TOKEN}

operations:
  paths:
    - /app/graphql/customers
    - /app/graphql/orders
    - /app/graphql/products
    - /app/graphql/inventory
    - /app/graphql/fulfillments
    - /app/graphql/discounts
```

- [ ] **Step 2: Commit**

```bash
git add mcp-config.yaml
git commit -m "feat: add Apollo MCP config with container paths"
```

### Task 5: Write entrypoint.sh

- [ ] **Step 1: Write entrypoint.sh**

```bash
#!/bin/bash
set -euo pipefail

echo "[fluid-intelligence] Starting services..."

# Construct DATABASE_URL for ContextForge (Cloud SQL PostgreSQL via Unix socket)
export DATABASE_URL="postgresql://${DB_USER:-contextforge}:${DB_PASSWORD}@/${DB_NAME:-contextforge}?host=/cloudsql/junlinleather-mcp:asia-southeast1:contextforge"
export AUTH_ENCRYPTION_SECRET="${JWT_SECRET_KEY}"
export PLATFORM_ADMIN_PASSWORD="${AUTH_PASSWORD}"

# 1. Apollo MCP Server (Rust, Shopify GraphQL, Streamable HTTP)
apollo --config /app/mcp-config.yaml &
APOLLO_PID=$!

# 2. IBM ContextForge (Python, gateway)
# Start via `mcpgateway` CLI (console_scripts entry point)
mcpgateway &
CONTEXTFORGE_PID=$!

# 3. mcpgateway.translate #1 (stdio→HTTP bridge for dev-mcp)
python3 -m mcpgateway.translate \
  --stdio "npx -y @shopify/dev-mcp@latest" \
  --expose-sse \
  --port 8003 &
TRANSLATE_DEVMCP_PID=$!

# 4. mcpgateway.translate #2 (stdio→HTTP bridge for google-sheets)
python3 -m mcpgateway.translate \
  --stdio "uvx mcp-google-sheets@latest --transport stdio" \
  --expose-sse \
  --port 8004 &
TRANSLATE_SHEETS_PID=$!

# 5. mcp-auth-proxy (Go, OAuth 2.1 front door)
# Google OAuth as primary auth, password as CLI fallback
mcp-auth-proxy \
  --listen :8080 \
  --external-url "https://${EXTERNAL_URL:-junlinleather.com}" \
  --google-client-id "$GOOGLE_OAUTH_CLIENT_ID" \
  --google-client-secret "$GOOGLE_OAUTH_CLIENT_SECRET" \
  --google-allowed-users "${GOOGLE_ALLOWED_USERS:-ourteam@junlinleather.com}" \
  --password "$AUTH_PASSWORD" \
  --no-auto-tls \
  --data-path /app/data \
  -- http://localhost:4444 &
AUTHPROXY_PID=$!

# 6. Bootstrap: register backends with ContextForge (runs once)
/app/bootstrap.sh &

echo "[fluid-intelligence] All services started"
echo "  Apollo MCP:       PID=$APOLLO_PID  port=8000"
echo "  ContextForge:     PID=$CONTEXTFORGE_PID  port=4444"
echo "  dev-mcp bridge:   PID=$TRANSLATE_DEVMCP_PID  port=8003"
echo "  sheets bridge:    PID=$TRANSLATE_SHEETS_PID  port=8004"
echo "  mcp-auth-proxy:   PID=$AUTHPROXY_PID  port=8080"

# Exit if any long-running process dies → Cloud Run restarts container
wait -n $APOLLO_PID $CONTEXTFORGE_PID $TRANSLATE_DEVMCP_PID $TRANSLATE_SHEETS_PID $AUTHPROXY_PID
echo "[fluid-intelligence] A process exited, shutting down"
kill $APOLLO_PID $CONTEXTFORGE_PID $TRANSLATE_DEVMCP_PID $TRANSLATE_SHEETS_PID $AUTHPROXY_PID 2>/dev/null || true
exit 1
```

- [ ] **Step 2: Make executable**

```bash
chmod +x entrypoint.sh
```

- [ ] **Step 3: Commit**

```bash
git add entrypoint.sh
git commit -m "feat: add entrypoint.sh process supervisor"
```

### Task 6: Write bootstrap.sh

- [ ] **Step 1: Write bootstrap.sh**

```bash
#!/bin/bash
set -euo pipefail

echo "[bootstrap] Waiting for ContextForge to be healthy..."
MAX_WAIT=60; WAITED=0
until curl -sf http://localhost:4444/healthz > /dev/null 2>&1; do
  WAITED=$((WAITED + 1))
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "[bootstrap] FATAL: ContextForge not healthy after ${MAX_WAIT}s"
    exit 1
  fi
  sleep 1
done
echo "[bootstrap] ContextForge is healthy"

# Generate admin JWT token for backend registration
TOKEN=$(python3 -m mcpgateway.utils.create_jwt_token \
  --username "$PLATFORM_ADMIN_EMAIL" \
  --exp 10080 \
  --secret "$JWT_SECRET_KEY")

echo "[bootstrap] Registering Apollo MCP (Shopify GraphQL)..."
curl -sf -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"apollo-shopify","url":"http://localhost:8000/mcp","transport":"STREAMABLEHTTP"}' \
  http://localhost:4444/gateways

echo "[bootstrap] Waiting for dev-mcp bridge..."
MAX_WAIT=90; WAITED=0
until curl -sf --connect-timeout 2 --max-time 3 http://localhost:8003/healthz > /dev/null 2>&1; do
  WAITED=$((WAITED + 1))
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "[bootstrap] FATAL: dev-mcp bridge not ready after ${MAX_WAIT}s"
    exit 1
  fi
  sleep 1
done

echo "[bootstrap] Registering dev-mcp (Shopify docs)..."
curl -sf -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"shopify-dev-mcp","url":"http://localhost:8003/sse","transport":"SSE"}' \
  http://localhost:4444/gateways

echo "[bootstrap] Waiting for google-sheets bridge..."
MAX_WAIT=60; WAITED=0
until curl -sf --connect-timeout 2 --max-time 3 http://localhost:8004/healthz > /dev/null 2>&1; do
  WAITED=$((WAITED + 1))
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "[bootstrap] FATAL: google-sheets bridge not ready after ${MAX_WAIT}s"
    exit 1
  fi
  sleep 1
done

echo "[bootstrap] Registering google-sheets..."
curl -sf -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"google-sheets","url":"http://localhost:8004/sse","transport":"SSE"}' \
  http://localhost:4444/gateways

echo "[bootstrap] All 3 backends registered"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x bootstrap.sh
```

- [ ] **Step 3: Commit**

```bash
git add bootstrap.sh
git commit -m "feat: add bootstrap.sh for 3-backend registration on cold start"
```

### Task 7: Write Dockerfile

- [ ] **Step 1: Write Dockerfile**

```dockerfile
# Fluid Intelligence v3 — ContextForge + mcp-auth-proxy
# Build time: ~60s (uses pre-built base image + ContextForge image)

# Stage 1: Apollo pre-compiled (from base image, rebuilt rarely)
FROM asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence-base:latest AS apollo-base

# Stage 2: mcp-auth-proxy binary (v2.5.4)
FROM alpine:3.20 AS authproxy
ADD https://github.com/sigbit/mcp-auth-proxy/releases/download/v2.5.4/mcp-auth-proxy-linux-amd64 /mcp-auth-proxy
RUN chmod +x /mcp-auth-proxy

# Stage 3: Runtime — based on ContextForge (Red Hat UBI 10 Minimal)
# Preserves Python 3.12 venv at /app/.venv with PATH already set
FROM ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2

USER root

# Install Node.js (for dev-mcp via npx) and curl (for health checks)
RUN microdnf install -y nodejs npm curl && microdnf clean all

# Install uv (for mcp-google-sheets via uvx)
RUN pip install uv

# tini (PID 1 init — not in UBI repos)
ADD https://github.com/krallin/tini/releases/download/v0.19.0/tini-amd64 /usr/local/bin/tini
RUN chmod +x /usr/local/bin/tini

# Copy Apollo binary
COPY --from=apollo-base /usr/local/bin/apollo /usr/local/bin/apollo

# Copy mcp-auth-proxy binary
COPY --from=authproxy /mcp-auth-proxy /usr/local/bin/mcp-auth-proxy

# Copy config and scripts
COPY entrypoint.sh /app/entrypoint.sh
COPY bootstrap.sh /app/bootstrap.sh
COPY mcp-config.yaml /app/mcp-config.yaml
COPY graphql/ /app/graphql/

# Create data directory for mcp-auth-proxy BoltDB
RUN mkdir -p /app/data && chown -R 1001:0 /app/data /app/entrypoint.sh /app/bootstrap.sh

RUN chmod +x /app/entrypoint.sh /app/bootstrap.sh

USER 1001
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/tini", "--"]
CMD ["/app/entrypoint.sh"]
```

- [ ] **Step 2: Verify Dockerfile syntax**

```bash
docker build --check . 2>&1 || echo "Docker BuildKit check not available — visual review OK"
```

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat: add Dockerfile multi-stage build"
```

---

## Chunk 3: CI/CD & Cloud Build Setup

### Task 8: Write Cloud Build configs

- [ ] **Step 1: Write cloudbuild.yaml**

```yaml
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', '${_IMAGE}', '.']

  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', '${_IMAGE}']

  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    entrypoint: gcloud
    args:
      - 'run'
      - 'deploy'
      - 'fluid-intelligence'
      - '--image=${_IMAGE}'
      - '--region=asia-southeast1'
      - '--no-cpu-throttling'
      - '--cpu-boost'
      - '--min-instances=0'
      - '--max-instances=3'
      - '--memory=512Mi'
      - '--cpu=1'
      - '--add-cloudsql-instances=junlinleather-mcp:asia-southeast1:contextforge'
      - '--set-secrets=SHOPIFY_ACCESS_TOKEN=shopify-access-token:latest,AUTH_PASSWORD=mcp-auth-passphrase:latest,JWT_PRIVATE_KEY=mcp-jwt-private-key:latest,AUTH_HMAC_SECRET=mcp-auth-hmac-secret:latest,JWT_SECRET_KEY=mcp-jwt-secret:latest,GOOGLE_OAUTH_CLIENT_ID=google-oauth-client-id:latest,GOOGLE_OAUTH_CLIENT_SECRET=google-oauth-client-secret:latest,CREDENTIALS_CONFIG=google-sheets-credentials:latest,DB_PASSWORD=db-password:latest'
      - '--set-env-vars=SHOPIFY_STORE=junlinleather-5148.myshopify.com,SHOPIFY_API_VERSION=2026-01,PLATFORM_ADMIN_EMAIL=admin@junlinleather.com,EXTERNAL_URL=junlinleather.com,GOOGLE_ALLOWED_USERS=ourteam@junlinleather.com,DB_USER=contextforge,DB_NAME=contextforge,HOST=0.0.0.0,PORT=4444,GUNICORN_WORKERS=1,HTTP_SERVER=gunicorn,MCPGATEWAY_UI_ENABLED=false,MCPGATEWAY_ADMIN_API_ENABLED=true,TRANSPORT_TYPE=all,SSRF_PROTECTION_ENABLED=true,SSRF_ALLOW_LOCALHOST=true,SSRF_ALLOW_PRIVATE_NETWORKS=true,AUTH_REQUIRED=true,CACHE_TYPE=database'
      - '--allow-unauthenticated'

substitutions:
  _IMAGE: 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence:${SHORT_SHA}'

images:
  - '${_IMAGE}'
```

- [ ] **Step 2: Write cloudbuild-base.yaml**

```yaml
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args:
      - 'build'
      - '-f'
      - 'Dockerfile.base'
      - '-t'
      - 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence-base:latest'
      - '.'
  - name: 'gcr.io/cloud-builders/docker'
    args:
      - 'push'
      - 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence-base:latest'
images:
  - 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence-base:latest'
timeout: '1800s'
```

- [ ] **Step 3: Commit**

```bash
git add cloudbuild.yaml cloudbuild-base.yaml
git commit -m "feat: add Cloud Build configs for auto-deploy"
```

### Task 9: Set up Cloud Build GitHub integration

- [ ] **Step 1: Enable required APIs**

```bash
gcloud services enable cloudbuild.googleapis.com \
  artifactregistry.googleapis.com run.googleapis.com \
  developerconnect.googleapis.com secretmanager.googleapis.com \
  sqladmin.googleapis.com \
  --project=junlinleather-mcp
```

- [ ] **Step 2: Grant Cloud Build SA permissions**

```bash
CB_SA="1056128102929@cloudbuild.gserviceaccount.com"
for role in roles/run.admin roles/iam.serviceAccountUser \
  roles/artifactregistry.writer roles/secretmanager.secretAccessor; do
  gcloud projects add-iam-policy-binding junlinleather-mcp \
    --member="serviceAccount:${CB_SA}" --role="$role" --quiet
done
```

- [ ] **Step 3: Create GitHub connection (opens browser)**

```bash
gcloud developer-connect connections create fluid-intelligence-github \
  --location=asia-southeast1 --project=junlinleather-mcp
```

Follow the authorization URL in the output to install the Cloud Build GitHub App.

- [ ] **Step 4: Link repository**

```bash
gcloud developer-connect connections git-repository-links create fluid-intelligence-repo \
  --connection=fluid-intelligence-github \
  --clone-uri=https://github.com/junlin3012/fluid-intelligence.git \
  --location=asia-southeast1 --project=junlinleather-mcp
```

- [ ] **Step 5: Create deploy trigger (push to main)**

```bash
gcloud builds triggers create developer-connect \
  --name=deploy-fluid-intelligence \
  --git-repository-link=projects/junlinleather-mcp/locations/asia-southeast1/connections/fluid-intelligence-github/gitRepositoryLinks/fluid-intelligence-repo \
  --branch-pattern="^main$" --build-config=cloudbuild.yaml \
  --region=asia-southeast1 --project=junlinleather-mcp
```

- [ ] **Step 6: Create base image trigger (Dockerfile.base changes only)**

```bash
gcloud builds triggers create developer-connect \
  --name=build-base-image \
  --git-repository-link=projects/junlinleather-mcp/locations/asia-southeast1/connections/fluid-intelligence-github/gitRepositoryLinks/fluid-intelligence-repo \
  --branch-pattern="^main$" --build-config=cloudbuild-base.yaml \
  --included-files="Dockerfile.base" \
  --region=asia-southeast1 --project=junlinleather-mcp
```

- [ ] **Step 7: Verify triggers**

```bash
gcloud builds triggers list --region=asia-southeast1 --project=junlinleather-mcp
```

Expected: 2 triggers (`deploy-fluid-intelligence`, `build-base-image`).

---

## Chunk 4: Build & Deploy

### Task 10: Build and push base image

- [ ] **Step 1: Build base image via Cloud Build**

```bash
gcloud builds submit --config=cloudbuild-base.yaml \
  --region=asia-southeast1 --project=junlinleather-mcp
```

This takes ~18 min (Rust compile). Wait for completion.

- [ ] **Step 2: Verify base image in Artifact Registry**

```bash
gcloud artifacts docker images list \
  asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp \
  --filter="package:fluid-intelligence-base"
```

Expected: `fluid-intelligence-base:latest` image present.

### Task 11: Push to main and trigger first deploy

- [ ] **Step 1: Push all commits to GitHub**

```bash
git push origin main
```

- [ ] **Step 2: Monitor the Cloud Build**

```bash
gcloud builds list --region=asia-southeast1 --project=junlinleather-mcp --limit=1
```

Wait for status: `SUCCESS`. If it fails, check logs:

```bash
gcloud builds log $(gcloud builds list --region=asia-southeast1 --project=junlinleather-mcp --limit=1 --format="value(id)") --region=asia-southeast1
```

- [ ] **Step 3: Verify Cloud Run service is running**

```bash
gcloud run services describe fluid-intelligence \
  --region=asia-southeast1 --project=junlinleather-mcp \
  --format="value(status.url)"
```

Expected: A Cloud Run URL like `https://fluid-intelligence-XXXXX.asia-southeast1.run.app`

### Task 12: Verify deployment end-to-end

- [ ] **Step 1: Check OAuth discovery endpoint**

```bash
CLOUD_RUN_URL=$(gcloud run services describe fluid-intelligence \
  --region=asia-southeast1 --project=junlinleather-mcp \
  --format="value(status.url)")

curl -s "$CLOUD_RUN_URL/.well-known/oauth-authorization-server" | jq .
```

Expected: JSON with `authorization_endpoint`, `token_endpoint`, `registration_endpoint`.

- [ ] **Step 2: Check ContextForge health (via auth proxy)**

```bash
curl -s "$CLOUD_RUN_URL/.well-known/oauth-protected-resource" | jq .
```

Expected: JSON with `resource` field.

- [ ] **Step 3: Test DCR (Dynamic Client Registration)**

```bash
curl -s -X POST "$CLOUD_RUN_URL/.idp/register" \
  -H "Content-Type: application/json" \
  -d '{"client_name":"test-client","grant_types":["authorization_code"],"response_types":["code"],"redirect_uris":["http://localhost:3000/callback"]}' | jq .
```

Expected: JSON with `client_id`, `client_secret`.

- [ ] **Step 4: Verify all backends are registered (via ContextForge API)**

Access Cloud Run logs to confirm bootstrap output:

```bash
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=fluid-intelligence AND textPayload:bootstrap" \
  --project=junlinleather-mcp --limit=20 --format="value(textPayload)"
```

Expected: Log lines showing "All backends registered".

- [ ] **Step 5: Commit verification notes**

No code changes — just verify everything works. If issues found, fix and push (auto-redeploys).

### Task 12b: Set up custom domain mapping

Must be done AFTER the `fluid-intelligence` Cloud Run service exists (Task 11).

- [ ] **Step 1: Create domain mapping**

```bash
gcloud run domain-mappings create \
  --service fluid-intelligence \
  --domain junlinleather.com \
  --region asia-southeast1 \
  --project=junlinleather-mcp
```

- [ ] **Step 2: Add DNS records**

The command will output CNAME or A records. Add them to your DNS provider (the registrar for junlinleather.com).

- [ ] **Step 3: Verify DNS propagation and SSL**

Wait ~10 min, then:
```bash
curl -sI https://junlinleather.com | head -5
```

Expected: `HTTP/2 200` or `HTTP/2 302` with valid SSL certificate.

---

## Chunk 5: Update CLAUDE.md & Final Cleanup

### Task 13: Update CLAUDE.md for new repo

- [ ] **Step 1: Update CLAUDE.md**

Replace references to old architecture (nginx, bash supervisor, custom OAuth) with v3 architecture. Key changes:
- Cloud Run URL points to new `fluid-intelligence` service
- Architecture section describes ContextForge + mcp-auth-proxy
- Key files section updated for new files
- Remove references to `oauth-server/`, `nginx.conf.template`, `token-proxy/`

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for v3 architecture"
git push origin main
```

### Task 14: Verify Claude.ai connection (manual)

- [ ] **Step 1: Add remote MCP server in Claude.ai settings**

Go to Claude.ai → Settings → MCP Servers → Add server:
- URL: `https://junlinleather.com` (custom domain)
- Auth: OAuth (will auto-discover via `/.well-known/oauth-authorization-server`)

- [ ] **Step 2: Authenticate via Google**

Claude.ai will redirect to the login page. Click "Sign in with Google" and use `ourteam@junlinleather.com`.

- [ ] **Step 3: Test Shopify tool call**

Ask Claude: "List my Shopify products"

Expected: Claude uses the `query_products` tool through the gateway and returns results.

- [ ] **Step 4: Test dev-mcp**

Ask Claude: "Search Shopify docs for draft order creation"

Expected: Claude uses `search_docs_chunks` from dev-mcp and returns documentation.

- [ ] **Step 5: Test Google Sheets**

Ask Claude: "List my Google Sheets spreadsheets"

Expected: Claude uses the `list_spreadsheets` tool from mcp-google-sheets. (Requires at least one spreadsheet shared with the service account email.)

- [ ] **Step 6: Celebrate**

If all three work: v3 is deployed and operational. Update the spec status to `DEPLOYED`.
