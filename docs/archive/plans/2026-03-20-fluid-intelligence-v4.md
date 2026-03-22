# Fluid Intelligence v4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Fluid Intelligence v4 — a multi-container MCP gateway on Cloud Run with Keycloak auth, ContextForge gateway, and three sidecars — replacing the v3 monolith.

**Architecture:** Two Cloud Run services (Keycloak + Gateway with sidecars), shared Cloud SQL PostgreSQL, GCP Secret Manager for secrets via volume mounts, cosign-signed images via Cloud Build.

**Tech Stack:** Keycloak 26.x (Java), ContextForge 1.0.0-GA (Python/FastAPI), Apollo MCP Server v1.9.0 (Rust), mcpgateway.translate (Python), Cloud Run multi-container, Cloud Build, Cloud SQL PostgreSQL

**Spec:** `docs/specs/2026-03-19-fluid-intelligence-v4-design.md` (965 lines, 26-batch mirror-polished)

**Skill map:** `~/.claude/projects/.../memory/project_v4_implementation_skills.md` — MUST READ before each phase

---

## File Structure (v4 — what changes from v3)

### New files to create
```
keycloak/
├── realm-fluid.json              # Keycloak realm config (exported, version-controlled)
├── Dockerfile                    # Keycloak container (official image + realm import)
├── .dockerignore
└── README.md                     # Keycloak-specific operational notes

sidecars/
├── apollo/
│   ├── Dockerfile                # Apollo MCP Server (Rust binary)
│   └── .dockerignore
├── devmcp/
│   ├── Dockerfile                # dev-mcp via mcpgateway.translate
│   ├── package.json              # dev-mcp + dependencies
│   ├── package-lock.json         # Pinned deps
│   └── .dockerignore
└── sheets/
    ├── Dockerfile                # Google Sheets via mcpgateway.translate
    ├── requirements.txt          # Pinned + hashed deps
    └── .dockerignore

bootstrap/
├── bootstrap.py                  # Run-once sidecar: register backends, configure RBAC
├── Dockerfile
├── requirements.txt
└── .dockerignore

deploy/
├── Dockerfile                    # ContextForge gateway (UPDATE from v3)
├── Dockerfile.base               # ContextForge base deps (UPDATE from v3)
├── cloudbuild.yaml               # Full pipeline (UPDATE — add signing, scanning)
├── cloudbuild-base.yaml          # Base image build (UPDATE)
├── cloud-run-gateway.yaml        # Cloud Run multi-container YAML (NEW)
├── cloud-run-keycloak.yaml       # Cloud Run Keycloak service YAML (NEW)
└── cloud-armor.yaml              # WAF rules for DCR rate limiting (NEW)

config/
├── defaults.env                  # UPDATE — v4 env vars
├── prod.env                      # UPDATE — v4 prod overrides
├── dev.env                       # NEW — dev mode overrides
└── .digests                      # NEW — all base image SHA256 digests

docker-compose.yml                # UPDATE — v4 topology (all 6 containers)
.env.example                      # UPDATE — v4 env var documentation

tests/
├── keycloak/                    # NEW — Keycloak config validation
│   └── test_realm_json.py
├── docker/                      # NEW — container image validation
│   └── test_images.sh
├── bootstrap/                   # NEW — bootstrap sidecar tests
│   └── test_bootstrap.py
├── acceptance/                  # NEW — 23 acceptance criteria as tests
│   ├── test_auth_bypass.sh       # AC #16
│   ├── test_jwt_forgery.sh       # AC #17
│   ├── test_pkce_required.sh     # AC #18
│   ├── test_pkce_method.sh       # AC #19 (distinct from #18)
│   ├── test_audience.sh          # AC #20
│   ├── test_feature_flags.sh     # AC #21
│   ├── test_dcr_restrictions.sh  # AC #22
│   ├── test_bootstrap_scope.sh   # AC #23
│   ├── test_rbac.sh              # AC #3
│   ├── test_fail_closed.sh       # AC #13
│   ├── test_e2e_flow.sh          # AC #1,2,4,5
│   ├── test_cold_start.sh        # AC #8
│   ├── test_container_security.sh # AC #11 (non-root + read-only rootfs)
│   ├── test_audit.sh             # AC #14
│   └── test_load.sh              # AC #15
├── integration/                 # NEW — cross-service tests
│   ├── test_keycloak_jwks.py
│   ├── test_contextforge_auth.py
│   └── test_sidecar_health.py

plugins/
└── resolve_user.py              # NEW — HTTP_AUTH_RESOLVE_USER plugin
```

### v3 files to retire (after v4 is verified)
```
scripts/entrypoint.sh             # Replaced by Cloud Run container management
scripts/bootstrap.sh              # Replaced by bootstrap/bootstrap.py
deploy/shopify-oauth/             # Replaced by Keycloak
services/shopify_oauth/           # Replaced by Keycloak
```

---

## Phase 1: Keycloak Auth Service

### MANDATORY SKILL INVOCATIONS (invoke BEFORE any code)
```
1. Use `context7` MCP tool to look up Keycloak 26.x docs:
   - Realm export/import format, Client Policy syntax, feature flags, SSO timeouts
2. Invoke `using-git-worktrees` — isolate Keycloak work from main
3. Invoke `configuring-oauth2-authorization-flow` (cybersecurity) — OAuth flow completeness checklist
4. Invoke `test-driven-development` skill
5. After completion: invoke `verification-before-completion`
6. After verification: invoke `finishing-a-development-branch`
```

### Task 1.1: Create Keycloak database and users

**Files:**
- Create: `scripts/setup-cloud-sql-v4.sh`

- [ ] **Step 1: Write the setup script**

```bash
#!/bin/bash
# Setup Cloud SQL databases and users for v4
# Run once against the existing Cloud SQL instance
set -euo pipefail

INSTANCE="${CLOUD_SQL_INSTANCE:?Set CLOUD_SQL_INSTANCE}"
PROJECT="${GCP_PROJECT:?Set GCP_PROJECT}"

# Create keycloak database
gcloud sql databases create keycloak --instance="$INSTANCE" --project="$PROJECT" 2>/dev/null || echo "keycloak DB exists"

# Create keycloak user (password from Secret Manager)
KC_PASS=$(gcloud secrets versions access latest --secret=keycloak-db-password --project="$PROJECT")
gcloud sql users create keycloak_user --instance="$INSTANCE" --password="$KC_PASS" --project="$PROJECT" 2>/dev/null || echo "keycloak_user exists"

# Restrict keycloak_user to keycloak DB only
# (Run via Cloud SQL proxy or direct psql)
echo "REVOKE ALL ON DATABASE contextforge FROM keycloak_user;" | psql "$CONTEXTFORGE_DB_URL"
echo "REVOKE ALL ON DATABASE postgres FROM keycloak_user;" | psql "$CONTEXTFORGE_DB_URL"
```

- [ ] **Step 2: Create secrets in Secret Manager**

```bash
# Keycloak DB password
echo -n "$(openssl rand -base64 32)" | gcloud secrets create keycloak-db-password --data-file=- --project=junlinleather-mcp

# Keycloak admin password
echo -n "$(openssl rand -base64 32)" | gcloud secrets create keycloak-admin-password --data-file=- --project=junlinleather-mcp
```

- [ ] **Step 3: Run setup script, verify databases exist**

Run: `bash scripts/setup-cloud-sql-v4.sh`
Verify: `gcloud sql databases list --instance=<instance>`
Expected: Both `keycloak` and `contextforge` databases listed

- [ ] **Step 4: Commit**

```bash
git add scripts/setup-cloud-sql-v4.sh
git commit -m "feat: Cloud SQL setup script for v4 (keycloak DB + user isolation)"
```

### Task 1.2: Create Keycloak realm JSON

**Files:**
- Create: `keycloak/realm-fluid.json`

- [ ] **Step 1: Use `context7` to look up Keycloak realm export format**

Invoke MCP tool: `mcp__plugin_context7_context7__resolve-library-id` with query "keycloak"
Then: `mcp__plugin_context7_context7__query-docs` for realm import JSON format, Client Policy syntax, audience mapper config

- [ ] **Step 2: Write failing test — verify realm JSON is valid**

Create: `tests/keycloak/test_realm_json.py`

```python
import json
import pytest

def test_realm_json_is_valid():
    with open("keycloak/realm-fluid.json") as f:
        realm = json.load(f)
    assert realm["realm"] == "fluid"
    assert realm["enabled"] is True

def test_realm_has_bootstrap_client():
    with open("keycloak/realm-fluid.json") as f:
        realm = json.load(f)
    clients = {c["clientId"]: c for c in realm.get("clients", [])}
    assert "fluid-bootstrap" in clients
    bootstrap = clients["fluid-bootstrap"]
    assert bootstrap["serviceAccountsEnabled"] is True
    assert bootstrap["publicClient"] is False

def test_realm_has_audience_mapper():
    with open("keycloak/realm-fluid.json") as f:
        realm = json.load(f)
    # Audience mapper should be in default client scopes
    scopes = {s["name"]: s for s in realm.get("clientScopes", [])}
    assert "fluid-audience" in scopes
    mappers = scopes["fluid-audience"].get("protocolMappers", [])
    aud_mapper = [m for m in mappers if m["name"] == "fluid-gateway-audience"]
    assert len(aud_mapper) == 1
    assert aud_mapper[0]["config"]["included.client.audience"] == "fluid-gateway"

def test_realm_sso_session_timeouts():
    with open("keycloak/realm-fluid.json") as f:
        realm = json.load(f)
    assert realm["ssoSessionIdleTimeout"] == 3600  # 1 hour
    assert realm["ssoSessionMaxLifespan"] == 86400  # 24 hours

def test_realm_token_lifetimes():
    with open("keycloak/realm-fluid.json") as f:
        realm = json.load(f)
    assert realm["accessTokenLifespan"] == 3600  # 1 hour
    assert realm["refreshTokenMaxReuse"] == 0  # one-time use

def test_realm_has_google_idp():
    with open("keycloak/realm-fluid.json") as f:
        realm = json.load(f)
    idps = {idp["alias"]: idp for idp in realm.get("identityProviders", [])}
    assert "google" in idps

def test_realm_no_credentials():
    """Realm JSON must not contain secrets (exported with --no-credentials)."""
    with open("keycloak/realm-fluid.json") as f:
        content = f.read()
    # Check for common secret patterns
    assert "clientSecret" not in content or '"clientSecret" : ""' in content or '"clientSecret" : "**********"' in content
    assert "password" not in content.lower() or '"credentials"' not in content

def test_realm_pkce_policy():
    with open("keycloak/realm-fluid.json") as f:
        realm = json.load(f)
    # Client profiles should enforce PKCE S256
    profiles = realm.get("clientProfiles", {}).get("profiles", [])
    pkce_found = False
    for profile in profiles:
        for executor in profile.get("executors", []):
            if executor.get("executor") == "pkce-enforcer":
                config = executor.get("configuration", {})
                if config.get("auto") == "true":
                    pkce_found = True
    assert pkce_found, "PKCE enforcement profile not found in realm JSON"
```

- [ ] **Step 3: Run test — confirm it fails**

Run: `pytest tests/keycloak/test_realm_json.py -v`
Expected: FAIL (file doesn't exist)

- [ ] **Step 4: Create the realm JSON**

Create `keycloak/realm-fluid.json` with:
- Realm: `fluid`, enabled
- SSO Session Idle: 3600, Max: 86400
- Access token: 3600, Refresh token: 86400
- Refresh token max reuse: 0 (one-time)
- Google IdP (with placeholder client ID/secret — real values from Secret Manager at runtime)
- IdP mapper: import only, email + name only
- Bootstrap service account client: `fluid-bootstrap`
- Audience mapper client scope: `fluid-audience` → adds `fluid-gateway` to `aud`
- Client Policy: PKCE S256 enforced for all clients
- DCR Client Registration Policy: public only, authorization_code only, code only, restricted scopes
- Brute force detection: enabled (5 failed attempts → 15-minute lockout)
- Feature flags note in comments (applied via CLI, not realm JSON)
- Event logging: enabled, 90-day retention
- `sid` in JWT claims (session ID for correlation)
- userProfile SPI: `tenant_id` and `roles` admin-only-writable
- `offline_access` removed from default optional client scopes

**CRITICAL:** Use `context7` to verify exact JSON field names. DO NOT guess.

- [ ] **Step 5: Run test — confirm it passes**

Run: `pytest tests/keycloak/test_realm_json.py -v`
Expected: ALL PASS

- [ ] **Step 6: Run gitleaks on realm JSON**

Run: `gitleaks detect --source keycloak/realm-fluid.json --no-git`
Expected: No leaks found

- [ ] **Step 7: Commit**

```bash
git add keycloak/realm-fluid.json tests/keycloak/
git commit -m "feat: Keycloak realm JSON — fluid realm with audience mapper, PKCE, DCR policy"
```

### Task 1.3: Create Keycloak Dockerfile

**Files:**
- Create: `keycloak/Dockerfile`
- Create: `keycloak/.dockerignore`

- [ ] **Step 1: Use `context7` to look up Keycloak Docker image structure**

Look up: quay.io/keycloak/keycloak image, `--import-realm` flag, `--optimized` flag, `--features` flag syntax

- [ ] **Step 2: Write the Dockerfile**

```dockerfile
FROM quay.io/keycloak/keycloak:26.1.4@sha256:PLACEHOLDER_DIGEST AS builder
# Build optimized Keycloak with disabled features
ENV KC_DB=postgres
ENV KC_FEATURES=token-exchange-standard:disabled,token-exchange:disabled,impersonation:disabled,device-flow:disabled,ciba:disabled
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.1.4@sha256:PLACEHOLDER_DIGEST
COPY --from=builder /opt/keycloak/ /opt/keycloak/
COPY realm-fluid.json /opt/keycloak/data/import/realm-fluid.json

# Strip SUID bits
USER root
RUN find / -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true
USER 1000

EXPOSE 8080
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized", "--import-realm", \
     "--hostname-strict=false", \
     "--http-enabled=true", \
     "--spi-events-listener-jboss-logging-success-level=info"]
```

- [ ] **Step 3: Write .dockerignore**

```
*.md
.git/
docs/
.env*
.claude/
```

- [ ] **Step 4: Record actual digest in .digests file**

```bash
# Get actual digest
docker pull quay.io/keycloak/keycloak:26.1.4
docker inspect --format='{{index .RepoDigests 0}}' quay.io/keycloak/keycloak:26.1.4
# Record in config/.digests
echo "keycloak=quay.io/keycloak/keycloak:26.1.4@sha256:<actual>" >> config/.digests
```

- [ ] **Step 5: Build and test locally**

Run: `docker build -t keycloak-v4 keycloak/`
Run: `docker run --rm -e KC_DB=postgres -e KC_DB_URL=jdbc:postgresql://host.docker.internal:5432/keycloak -e KC_DB_USERNAME=keycloak_user -e KC_DB_PASSWORD=test keycloak-v4`
Verify: Container starts, realm imports, `/health/ready` returns 200

- [ ] **Step 6: Commit**

```bash
git add keycloak/Dockerfile keycloak/.dockerignore config/.digests
git commit -m "feat: Keycloak Dockerfile — optimized build with feature hardening"
```

### Task 1.4: Create Keycloak Cloud Run service YAML

**Files:**
- Create: `deploy/cloud-run-keycloak.yaml`

- [ ] **Step 1: Use `context7` to look up Cloud Run service YAML format**

Look up: Cloud Run YAML spec, `--set-secrets` volume mount syntax, health probe config, `securityContext`

- [ ] **Step 2: Write the Cloud Run YAML**

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: keycloak
  annotations:
    run.googleapis.com/ingress: internal-and-cloud-load-balancing
spec:
  template:
    metadata:
      annotations:
        run.googleapis.com/cpu-throttling: "true"
        autoscaling.knative.dev/minScale: "0"
        autoscaling.knative.dev/maxScale: "1"
    spec:
      serviceAccountName: keycloak-sa@junlinleather-mcp.iam.gserviceaccount.com
      terminationGracePeriodSeconds: 30
      containers:
        - image: KEYCLOAK_IMAGE
          ports:
            - containerPort: 8080
          env:
            - name: KC_DB
              value: postgres
            - name: KC_DB_URL
              value: "jdbc:postgresql://CLOUD_SQL_IP:5432/keycloak"
            - name: KC_DB_POOL_INITIAL_SIZE
              value: "5"
            - name: KC_DB_POOL_MAX_SIZE
              value: "10"
            - name: KC_HOSTNAME_ADMIN
              value: "admin.internal"
          volumeMounts:
            - name: keycloak-db-password
              mountPath: /secrets/db-password
              readOnly: true
            - name: keycloak-admin-password
              mountPath: /secrets/admin-password
              readOnly: true
          resources:
            limits:
              cpu: "1"
              memory: 1Gi
          startupProbe:
            httpGet:
              path: /health/ready
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 30
          livenessProbe:
            httpGet:
              path: /health/live
              port: 8080
            periodSeconds: 30
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
      volumes:
        - name: keycloak-db-password
          secret:
            secretName: keycloak-db-password
        - name: keycloak-admin-password
          secret:
            secretName: keycloak-admin-password
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 128Mi
        - name: keycloak-data
          emptyDir:
            medium: Memory
            sizeLimit: 128Mi
```

- [ ] **Step 3: Commit**

```bash
git add deploy/cloud-run-keycloak.yaml
git commit -m "feat: Keycloak Cloud Run service YAML — health probes, secret mounts, security context"
```

### Task 1.5: Create GCP service accounts

**Files:**
- Create: `scripts/setup-iam-v4.sh`

- [ ] **Step 1: Write IAM setup script**

```bash
#!/bin/bash
set -euo pipefail
PROJECT="${GCP_PROJECT:-junlinleather-mcp}"

# Create service accounts
gcloud iam service-accounts create gateway-sa --display-name="Gateway SA" --project="$PROJECT" 2>/dev/null || true
gcloud iam service-accounts create keycloak-sa --display-name="Keycloak SA" --project="$PROJECT" 2>/dev/null || true

# Keycloak SA — Secret Manager (keycloak secrets only)
gcloud secrets add-iam-policy-binding keycloak-db-password \
  --member="serviceAccount:keycloak-sa@${PROJECT}.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" --project="$PROJECT"

gcloud secrets add-iam-policy-binding keycloak-admin-password \
  --member="serviceAccount:keycloak-sa@${PROJECT}.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" --project="$PROJECT"

# Keycloak SA — Cloud SQL
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:keycloak-sa@${PROJECT}.iam.gserviceaccount.com" \
  --role="roles/cloudsql.client"

# Gateway SA — Secret Manager (gateway secrets only)
for secret in shopify-client-id shopify-client-secret mcp-jwt-secret mcp-auth-passphrase; do
  gcloud secrets add-iam-policy-binding "$secret" \
    --member="serviceAccount:gateway-sa@${PROJECT}.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor" --project="$PROJECT"
done

# Gateway SA — Cloud SQL + Cloud Run invoker on Keycloak
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:gateway-sa@${PROJECT}.iam.gserviceaccount.com" \
  --role="roles/cloudsql.client"

# Cloud Build SA impersonation
gcloud iam service-accounts add-iam-policy-binding \
  "gateway-sa@${PROJECT}.iam.gserviceaccount.com" \
  --member="serviceAccount:cloudbuild-sa@${PROJECT}.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"

gcloud iam service-accounts add-iam-policy-binding \
  "keycloak-sa@${PROJECT}.iam.gserviceaccount.com" \
  --member="serviceAccount:cloudbuild-sa@${PROJECT}.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"

echo "IAM setup complete"
```

- [ ] **Step 2: Run and verify**

Run: `bash scripts/setup-iam-v4.sh`
Verify: `gcloud iam service-accounts list --project=junlinleather-mcp`

- [ ] **Step 3: Commit**

```bash
git add scripts/setup-iam-v4.sh
git commit -m "feat: GCP IAM setup — per-service SAs with least-privilege Secret Manager bindings"
```

### Task 1.6: Deploy Keycloak to Cloud Run and verify

- [ ] **Step 1: Build and push Keycloak image**

```bash
gcloud builds submit keycloak/ --tag asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/keycloak:v4.0.0 --project=junlinleather-mcp
```

- [ ] **Step 2: Deploy Keycloak service**

```bash
gcloud run services replace deploy/cloud-run-keycloak.yaml --region=asia-southeast1 --project=junlinleather-mcp
```

- [ ] **Step 3: Invoke `verification-before-completion` — verify all Keycloak acceptance criteria**

Verify:
- [ ] `/health/ready` returns 200
- [ ] `/realms/fluid/.well-known/openid-configuration` returns valid JSON with all required fields
- [ ] JWKS endpoint returns non-empty key set with RS256 key
- [ ] DCR endpoint accepts registration with `grant_types=["authorization_code"]`
- [ ] DCR endpoint rejects `grant_types=["client_credentials"]`
- [ ] PKCE enforcement: auth request without `code_challenge` is rejected
- [ ] Feature flags: token exchange endpoint returns error
- [ ] Admin console (`/admin`) is not reachable via public URL

- [ ] **Step 4: Commit verification results**

```bash
git commit -m "feat: Keycloak deployed and verified — OAuth 2.1, PKCE, DCR, feature hardening"
```

### Task 1.7: Resolve OAuth metadata path (BLOCKER)

The spec identifies this as a blocker: Keycloak serves `/.well-known/openid-configuration`, MCP spec expects `/.well-known/oauth-authorization-server`.

**Files:**
- Potentially modify: `deploy/cloud-run-keycloak.yaml` or create ALB URL rewrite rule

- [ ] **Step 1: Use `context7` to check Keycloak's metadata endpoint paths**

Verify: does Keycloak serve RFC 8414 metadata natively? Or only OIDC discovery?

- [ ] **Step 2: Test Keycloak response at both paths**

```bash
# OIDC discovery (should work)
curl https://<keycloak-url>/realms/fluid/.well-known/openid-configuration
# RFC 8414 (may 404)
curl https://<keycloak-url>/.well-known/oauth-authorization-server
```

- [ ] **Step 3: Implement resolution**

Options (in order of preference):
1. If Keycloak serves both natively → done
2. ALB URL rewrite: `/.well-known/oauth-authorization-server` → `/realms/fluid/.well-known/openid-configuration`
3. ContextForge proxy endpoint: serve metadata at `/.well-known/oauth-authorization-server` from gateway

- [ ] **Step 4: Verify MCP client can discover auth server via the standard path**
- [ ] **Step 5: Commit**

### Task 1.8: Configure ALB + Cloud Armor for Keycloak

**Files:**
- Create: `deploy/cloud-armor.yaml`
- Create: `scripts/setup-alb.sh`

- [ ] **Step 1: Create ALB with path-based routing (allowlist)**

```bash
# ALB path rules for Keycloak:
# ALLOW: /realms/*, /.well-known/*, /js/*, /resources/*
# DENY: everything else (including /admin/*, /health/*, /metrics)
```

- [ ] **Step 2: Create Cloud Armor WAF policy for DCR rate limiting**

```bash
# Rate limit: max 10 requests per IP per hour on /clients-registrations/ path
gcloud compute security-policies create keycloak-waf --project=junlinleather-mcp
gcloud compute security-policies rules create 1000 \
  --security-policy=keycloak-waf \
  --expression="request.path.matches('/realms/.*/clients-registrations/.*')" \
  --action=rate-based-ban \
  --rate-limit-threshold-count=10 \
  --rate-limit-threshold-interval-sec=3600 \
  --ban-duration-sec=3600
```

- [ ] **Step 3: Verify ALB routes + Cloud Armor rules**
- [ ] **Step 4: Commit**

```bash
git add deploy/cloud-armor.yaml scripts/setup-alb.sh
git commit -m "feat: ALB path allowlist + Cloud Armor DCR rate limiting for Keycloak"
```

---

## Phase 2: Sidecar Dockerfiles

### MANDATORY SKILL INVOCATIONS
```
1. Invoke `supply-chain-risk-auditor` (Trail of Bits) — audit all deps before building
2. Invoke `dispatching-parallel-agents` — build all 3 sidecars in parallel
3. Invoke `hardening-docker-containers-for-production` (cybersecurity) — CIS benchmark
4. Invoke `test-driven-development`
5. After completion: invoke `verification-before-completion`
```

### Task 2.1: Resolve mcpgateway.translate sidecar topology

**This is the open item from Batch 8 (line 953 of spec).** In v3, mcpgateway.translate runs inside the ContextForge monolith. In v4 sidecars, we need to determine if it runs as its own container or as subprocess.

- [ ] **Step 1: Use `context7` to look up mcpgateway.translate CLI interface**

Check: does `python -m mcpgateway.translate` work standalone (without ContextForge running)?
Check: what Python packages does it depend on?
Check: can it run from a minimal Python image (not full ContextForge base)?

- [ ] **Step 2: Test mcpgateway.translate standalone**

```bash
# In v3 environment, test if translate works without the full ContextForge gateway
cd /app && python -m mcpgateway.translate --help
```

- [ ] **Step 3: Document decision**

If standalone: Each stdio sidecar gets a lightweight Python container with just mcpgateway.translate
If requires ContextForge: Each sidecar uses the full ContextForge base image (heavier, ~512Mi+)

- [ ] **Step 4: Commit decision**

### Task 2.2: Create Apollo sidecar Dockerfile

**Files:**
- Create: `sidecars/apollo/Dockerfile`
- Create: `sidecars/apollo/.dockerignore`

- [ ] **Step 1: Write failing test — Apollo binary runs and serves health**

```bash
# tests/docker/test_apollo_image.sh
docker build -t apollo-test sidecars/apollo/
docker run --rm -d --name apollo-test -p 8000:8000 apollo-test
sleep 3
curl -sf http://localhost:8000/ && echo "PASS" || echo "FAIL"
docker stop apollo-test
```

- [ ] **Step 2: Write Apollo Dockerfile**

```dockerfile
FROM rust:1.78-slim AS builder
RUN apt-get update && apt-get install -y git pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN git clone https://github.com/apollographql/apollo-mcp-server.git . && \
    git checkout PINNED_COMMIT_HASH
RUN cargo build --release

FROM debian:bookworm-slim@sha256:PLACEHOLDER
RUN apt-get update && apt-get install -y ca-certificates tini && rm -rf /var/lib/apt/lists/*
RUN find / -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true
COPY --from=builder /build/target/release/apollo-mcp-server /usr/local/bin/
USER 1001
EXPOSE 8000
ENTRYPOINT ["tini", "--"]
CMD ["apollo-mcp-server", "--port", "8000"]
```

- [ ] **Step 3: Record digest, build, verify**
- [ ] **Step 4: Commit**

### Task 2.3: Create dev-mcp sidecar Dockerfile

**Files:**
- Create: `sidecars/devmcp/Dockerfile`
- Create: `sidecars/devmcp/package.json`
- Create: `sidecars/devmcp/package-lock.json`
- Create: `sidecars/devmcp/.dockerignore`

(Structure depends on Task 2.1 resolution — mcpgateway.translate standalone or ContextForge-based)

- [ ] **Step 1: Pin @shopify/dev-mcp version**

```bash
cd sidecars/devmcp && npm init -y && npm install @shopify/dev-mcp@latest --save-exact
# Record exact version in package.json
```

- [ ] **Step 2: Write Dockerfile** (based on Task 2.1 decision)
- [ ] **Step 3: Build and verify dev-mcp starts on port 8003**
- [ ] **Step 4: Commit**

### Task 2.4: Create Google Sheets sidecar Dockerfile

**Files:**
- Create: `sidecars/sheets/Dockerfile`
- Create: `sidecars/sheets/requirements.txt`
- Create: `sidecars/sheets/.dockerignore`

- [ ] **Step 1: Verify xing5/mcp-google-sheets license (must be MIT/Apache/BSD)**
- [ ] **Step 2: Pin version and generate requirements with hashes**

```bash
pip install mcp-google-sheets && pip freeze --require-hashes > sidecars/sheets/requirements.txt
```

- [ ] **Step 3: Write Dockerfile**
- [ ] **Step 4: Build and verify sheets sidecar starts on port 8004**
- [ ] **Step 5: Commit**

---

## Phase 3: Cloud Run + CI/CD

### MANDATORY SKILL INVOCATIONS
```
1. Use `context7` MCP tool to look up Cloud Run multi-container YAML format
2. Invoke `securing-serverless-functions` (cybersecurity) — Cloud Run attack surface checklist
3. Invoke `implementing-zero-trust-network-access` (cybersecurity) — VPC/network verification
4. Invoke `systematic-debugging` — deploy issues are inevitable
5. After first deploy: invoke `entry-point-analyzer` (Trail of Bits) — map attack surface
6. Invoke `performing-security-headers-audit` (cybersecurity) — verify HTTP headers
7. After completion: invoke `verification-before-completion`
```

### Task 3.1: Create Cloud Run Gateway multi-container YAML

**Files:**
- Create: `deploy/cloud-run-gateway.yaml`

- [ ] **Step 1: Use `context7` for Cloud Run multi-container YAML syntax**
- [ ] **Step 2: Write YAML with all 5 containers + bootstrap sidecar**

Must include per the spec:
- ContextForge (main, port 8080)
- Apollo (sidecar, port 8000)
- dev-mcp (sidecar, port 8003)
- Google Sheets (sidecar, port 8004)
- Bootstrap (run-once sidecar, depends on ContextForge healthy)
- Container dependencies: sidecars → ContextForge → bootstrap
- Per-container: securityContext, resource limits, tmpfs mounts, health probes
- `--no-cpu-throttling`, `--cpu-boost`
- Secret volume mounts (NOT env vars)
- SIGTERM delay in sidecars (5s sleep before shutdown)

- [ ] **Step 3: Commit**

### Task 3.2: Update Cloud Build pipeline

**Files:**
- Modify: `deploy/cloudbuild.yaml`

- [ ] **Step 1: Update pipeline with v4 steps**

Steps per spec Section 9:
1. Secret scan (trufflehog/gitleaks) — pin tool by digest
2. Lint + validate
3. Build ALL container images (Keycloak, ContextForge, Apollo, dev-mcp, sheets, bootstrap)
4. CVE scan (trivy — pin by digest)
5. SBOM generation (syft — pin by digest)
6. Image signing (cosign + Cloud KMS)
7. Push to Artifact Registry
8. Deploy to Cloud Run (Binary Authorization)
9. Post-deploy digest verification
10. Health check verification

- [ ] **Step 2: Create Cloud KMS key for cosign**

```bash
gcloud kms keyrings create cosign --location=asia-southeast1 --project=junlinleather-mcp
gcloud kms keys create image-signing --keyring=cosign --location=asia-southeast1 --purpose=asymmetric-signing --default-algorithm=ec-sign-p256-sha256 --project=junlinleather-mcp
```

- [ ] **Step 3: Configure branch protection on GitHub**

```bash
gh api repos/junlin3012/fluid-intelligence/branches/main/protection -X PUT -f required_pull_request_reviews='{"required_approving_review_count":1}' -f required_status_checks='{"strict":true,"contexts":[]}'
```

- [ ] **Step 4: Commit**

### Task 3.3: Update docker-compose.yml for dev mode

**Files:**
- Modify: `docker-compose.yml`

- [ ] **Step 1: Write docker-compose with all 6 containers**

All services: Keycloak, ContextForge, Apollo, dev-mcp, sheets, PostgreSQL
Same images as production, different orchestration

- [ ] **Step 2: Verify `docker compose up` works**

Run: `docker compose up -d`
Verify: All containers healthy
Run acceptance criterion: "docker-compose up works for dev mode"

- [ ] **Step 3: Commit**

### Task 3.4: Deploy gateway service to Cloud Run

- [ ] **Step 1: Build all images and push**
- [ ] **Step 2: Deploy with `--no-traffic` first**
- [ ] **Step 3: Invoke `systematic-debugging` if deploy fails**
- [ ] **Step 4: Verify health checks pass**
- [ ] **Step 5: Migrate traffic**
- [ ] **Step 6: Invoke `entry-point-analyzer` (Trail of Bits) — map external attack surface**
- [ ] **Step 7: Invoke `performing-security-headers-audit` (cybersecurity) — verify HTTP headers on responses**
- [ ] **Step 8: Commit**

### Task 3.5: Configure ContextForge readiness probe (JWKS-aware)

Per spec Section 8: readiness probe must verify JWKS is fetched before serving traffic.

- [ ] **Step 1: Use `context7` to check if ContextForge has a `/ready` endpoint or startup hook**
- [ ] **Step 2: Configure readiness probe in Cloud Run YAML**

Probe must return 200 only after JWKS cache is populated. `failureThreshold: 20`, `periodSeconds: 3` (60s window for lean tier Keycloak cold start).

- [ ] **Step 3: Test: stop Keycloak, restart gateway, verify gateway returns 503 (not 200)**
- [ ] **Step 4: Commit**

### Task 3.6: Configure Cloud Monitoring alerts + audit permissions

- [ ] **Step 1: Create alert policies**

```bash
# Error rate > 5% for 5 minutes
# Latency p99 > 5s for 5 minutes
# Instance restart count > 3 in 10 minutes
gcloud monitoring policies create ...
```

- [ ] **Step 2: Configure audit INSERT-only permissions**

```sql
-- contextforge_user can INSERT but not UPDATE/DELETE on audit tables
REVOKE UPDATE, DELETE ON audit_log FROM contextforge_user;
```

- [ ] **Step 3: Protect /metrics/prometheus endpoint**

Either disable external metrics (rely on Cloud Monitoring) or require JWT auth on `/metrics/*` via ContextForge config.

- [ ] **Step 4: Configure VPC egress firewall rules**

Restrict outbound to: Shopify API, Google APIs, Keycloak.

- [ ] **Step 5: Commit**

### Task 3.7: Configure Cloud SQL security

- [ ] **Step 1: Disable public IP on Cloud SQL**

```bash
gcloud sql instances patch INSTANCE --no-assign-ip --project=junlinleather-mcp
```

- [ ] **Step 2: Restrict Artifact Registry access**

```bash
# Remove allUsers/allAuthenticatedUsers if present
# Add only required SAs
gcloud artifacts repositories add-iam-policy-binding junlin-mcp \
  --location=asia-southeast1 --member="serviceAccount:gateway-sa@..." \
  --role="roles/artifactregistry.reader"
```

- [ ] **Step 3: Commit**

---

## Phase 4: ContextForge Configuration

### MANDATORY SKILL INVOCATIONS
```
1. Use `context7` MCP tool for ContextForge configuration docs
2. Invoke `insecure-defaults` (Trail of Bits) — verify all defaults are fail-safe
3. Invoke `sharp-edges` (Trail of Bits) — find dangerous API patterns
4. Invoke `test-driven-development` — write acceptance tests FIRST
5. Invoke `implementing-secrets-management-with-vault` (cybersecurity) — verify secret injection
6. After completion: invoke `requesting-code-review`
```

### Task 4.1: Update ContextForge env vars for v4

**Files:**
- Modify: `config/prod.env`
- Modify: `config/defaults.env`

- [ ] **Step 1: Use `context7` to verify every ContextForge env var name**

CRITICAL: Do not guess. Look up actual env var names in ContextForge source/docs.

- [ ] **Step 2: Write failing acceptance tests**

Create `tests/acceptance/test_auth_bypass.sh`, `test_jwt_forgery.sh`, etc. for ALL 23 acceptance criteria

- [ ] **Step 3: Update prod.env with v4 values**

Key changes from v3:
```env
AUTH_REQUIRED=true
MCP_CLIENT_AUTH_ENABLED=true
TRUST_PROXY_AUTH=false
TRUST_PROXY_AUTH_DANGEROUSLY=false
SSRF_ALLOW_LOCALHOST=false
SSRF_ALLOW_PRIVATE_NETWORKS=false
SSO_AUTO_CREATE_USERS=true
OTEL_ENABLE_OBSERVABILITY=true
OTEL_TRACES_EXPORTER=otlp
OTEL_EXPORTER_OTLP_ENDPOINT=https://telemetry.googleapis.com
ENABLE_METRICS=true
LOG_LEVEL=INFO
# JWKS endpoint — set at deploy time
# MCP_CLIENT_AUTH_JWKS_URL=https://<keycloak-url>/realms/fluid/protocol/openid-connect/certs
```

- [ ] **Step 4: Deploy, run acceptance tests**
- [ ] **Step 5: Invoke `insecure-defaults` on deployed config**
- [ ] **Step 6: Commit**

### Task 4.2: Implement HTTP_AUTH_RESOLVE_USER plugin hook

**Files:**
- Create: `plugins/resolve_user.py` (ContextForge custom plugin)

- [ ] **Step 1: Use `context7` to look up ContextForge plugin hook API**

Look up: `HTTP_AUTH_RESOLVE_USER` hook signature, how to register plugins, priority system

- [ ] **Step 2: Write plugin that derives roles from JWT claims per-request**

```python
# plugins/resolve_user.py
# ContextForge plugin: derive user role from Keycloak JWT roles claim
# Hook: HTTP_AUTH_RESOLVE_USER
# Priority: 100 (before RBAC enforcement)

ROLE_MAP = {
    "admin": "platform_admin",
    "developer": "developer",
    "viewer": "viewer",
}

def resolve_user(request, user):
    """Override DB-stored role with JWT-derived role on every request."""
    jwt_roles = request.state.jwt_claims.get("roles", [])

    # Default-deny: no roles claim = no access
    if not jwt_roles:
        user.role = None  # deny all
        return user

    # Map first matching Keycloak role to ContextForge role
    for kc_role in jwt_roles:
        if kc_role in ROLE_MAP:
            user.role = ROLE_MAP[kc_role]
            return user

    # Unknown role values = deny all
    user.role = None
    return user
```

- [ ] **Step 3: Test with TDD**
- [ ] **Step 4: Commit**

---

## Phase 5: Bootstrap Sidecar

### MANDATORY SKILL INVOCATIONS
```
1. Invoke `feature-dev` — guided feature development
2. Invoke `test-driven-development`
3. After coding: invoke `semgrep` (SAST) — static analysis on custom code
4. Invoke `requesting-code-review` — security-sensitive code
5. Invoke `verification-before-completion`
```

### Task 5.1: Create bootstrap sidecar

**Files:**
- Create: `bootstrap/bootstrap.py`
- Create: `bootstrap/Dockerfile`
- Create: `bootstrap/requirements.txt`

- [ ] **Step 1: Write failing tests for bootstrap behavior**

```python
# tests/bootstrap/test_bootstrap.py
def test_bootstrap_registers_three_gateways():
    """Bootstrap must register Apollo, dev-mcp, and sheets backends."""

def test_bootstrap_creates_virtual_servers():
    """Bootstrap must create fluid-admin and fluid-viewer virtual servers."""

def test_bootstrap_is_idempotent():
    """Running bootstrap twice must not fail or create duplicates."""

def test_bootstrap_handles_409_conflict():
    """Already-exists responses (409) must be handled gracefully."""
```

- [ ] **Step 2: Implement bootstrap.py**
- [ ] **Step 3: Run tests, verify pass**
- [ ] **Step 4: Run `semgrep` SAST scan on bootstrap.py**
- [ ] **Step 5: Invoke `requesting-code-review`**
- [ ] **Step 6: Commit**

---

## Phase 6: Tenant Context Injection

### MANDATORY SKILL INVOCATIONS
```
1. Invoke `brainstorming` FIRST — design does NOT exist yet
2. After design approved: invoke `writing-plans` — create sub-plan for this component
3. Invoke `test-driven-development`
4. After coding: invoke `semgrep` (SAST on custom code)
5. Invoke `requesting-code-review` (security-sensitive)
6. Invoke `verification-before-completion`
```

### Task 6.1: Design tenant context injection (brainstorming required)

**This is the ONE custom component. The design must be brainstormed before any code.**

- [ ] **Step 1: Invoke `brainstorming` skill**

Questions to resolve:
- Where does it run? (ContextForge plugin hook `tool_pre_invoke`? Separate middleware?)
- How does it resolve tenant_id → Secret Manager secret name?
- Naming convention: `shopify-token-{tenant_id}`?
- How does it inject credentials into backend requests?
- How does it handle credential failures (expired token, missing secret)?
- Caching: cache resolved credentials? TTL?

- [ ] **Step 2: Write design doc from brainstorming output**
- [ ] **Step 3: Implement with TDD**
- [ ] **Step 4: Run SAST + code review**
- [ ] **Step 5: Commit**

---

## Phase 7: Integration & Acceptance

### MANDATORY SKILL INVOCATIONS
```
1. Invoke `spec-to-code-compliance` (Trail of Bits) — verify impl matches spec
2. Invoke `testing-api-security-with-owasp-top-10` (cybersecurity)
3. Invoke `second-opinion` (Trail of Bits) — independent re-review
4. Invoke `postman:security` — API security scan on running gateway
5. Invoke `verification-before-completion` — ALL 23 acceptance criteria
6. Invoke `finishing-a-development-branch`
```

### Task 7.1: Run all 23 acceptance criteria

- [ ] **Step 1: Run each acceptance test from Section 16 of the spec**

| # | Criterion | Test | Result |
|---|-----------|------|--------|
| 1 | Keycloak issues JWTs via OAuth 2.1 + PKCE S256 | `test_e2e_flow.sh` | |
| 2 | ContextForge validates Keycloak JWTs via JWKS | `test_contextforge_auth.py` | |
| 3 | RBAC enforced | `test_rbac.sh` | |
| 4 | All 3 sidecars registered | `test_sidecar_health.py` | |
| 5 | Google OAuth end-to-end | Manual or `claude-in-chrome` | |
| 6 | Bootstrap idempotent | `test_bootstrap_idempotent.sh` | |
| 7 | docker-compose up works | `docker compose up -d` | |
| 8 | Cold start < 45s | Timer test | |
| 9 | CVE scan passes | Cloud Build pipeline | |
| 10 | Secret scan passes | Cloud Build pipeline | |
| 11 | Non-root + read-only rootfs | `docker inspect` | |
| 12 | Admin console not accessible | `curl` test | |
| 13 | Fail closed when Keycloak down | `test_fail_closed.sh` | |
| 14 | Audit trail records | `test_audit.sh` | |
| 15 | Load test 5 concurrent | `test_load.sh` | |
| 16-23 | Security tests | `test_auth_bypass.sh` through `test_bootstrap_scope.sh` | |

- [ ] **Step 2: Invoke `spec-to-code-compliance` — verify implementation matches all 965 lines of spec**
- [ ] **Step 3: Invoke `testing-api-security-with-owasp-top-10` — OWASP validation**
- [ ] **Step 4: Invoke `second-opinion` — independent re-review**
- [ ] **Step 5: Invoke `postman:security` — automated API security scan**
- [ ] **Step 6: Invoke `verification-before-completion` with evidence for ALL criteria**
- [ ] **Step 7: Invoke `finishing-a-development-branch` — merge/PR**

### Task 7.2: Decommission v3

- [ ] **Step 1: Verify v4 is handling all traffic**
- [ ] **Step 2: Delete v3 Cloud Run revision**
- [ ] **Step 3: Archive v3 scripts (already in docs/archive/)**
- [ ] **Step 4: Update CLAUDE.md**
- [ ] **Step 5: Final commit**

```bash
git commit -m "feat: Fluid Intelligence v4 — Keycloak auth, multi-container gateway, production-hardened"
```

---

## Post-Implementation

### MANDATORY SKILL INVOCATIONS
```
1. Invoke `mirror-polish-protocol` — code review (code-only mode)
2. Invoke `cognitive-reflection` — session post-mortem
3. Invoke `revise-claude-md` — update project instructions
```

### Task 8.1: Update agent behavior docs

- [ ] Update `docs/agent-behavior/system-understanding.md` with v4 architecture
- [ ] Update `docs/agent-behavior/insights.md` with implementation learnings
- [ ] Update `docs/agent-behavior/patterns.md` with v4 codebase patterns
- [ ] Update `docs/operations/architecture.md` for v4
- [ ] Update `docs/operations/runbook.md` for v4
