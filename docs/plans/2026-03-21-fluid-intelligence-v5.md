# Fluid Intelligence v5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **MANDATORY:** Read `docs/archive/v4/v4-challenges-for-v5.md` BEFORE starting. Skills listed below are TASKS — invoke them, don't skip them.

**Goal:** Deploy a production-hardened MCP gateway (Keycloak + ContextForge + 3 sidecars) on Cloud Run with seamless browser login, MCP tools working end-to-end, and all 23 acceptance criteria passing.

**Architecture:** Two Cloud Run services (existing Keycloak + new multi-container gateway), connected via OIDC SSO. Zero custom auth code — configuration only.

**Tech Stack:** Keycloak 26.1.4, IBM ContextForge 1.0.0-RC-2 (Python/FastAPI), Apollo MCP Server (Rust), @shopify/dev-mcp (Node.js), mcp-google-sheets (Python), Cloud Run, Cloud SQL PostgreSQL, Postman for API management.

**Spec:** `docs/specs/2026-03-21-fluid-intelligence-v5-design.md`

**v4 Lessons:** `docs/archive/v4/v4-challenges-for-v5.md` (10 challenges, 5 rules)

---

## File Structure (v5 — what's new vs cherry-picked)

### New files (written fresh in v5)
```
docker-compose.yml              # Rewritten — 6 services, SSO config
.env.example                    # Rewritten — v5 variables
config/dev.env                  # Rewritten — local dev overrides
config/prod.env                 # Rewritten — production values
docs/specs/v5-contextforge-capabilities.md   # Phase 0 research
docs/specs/v5-keycloak-capabilities.md       # Phase 0 research
docs/specs/v5-feature-to-config-map.md       # Phase 0 deliverable
```

### Cherry-picked from v4 (audit every line)
```
keycloak/Dockerfile             # Battle-tested (8 deploys)
keycloak/realm-fluid.json       # Stripped to importable fields
keycloak/.dockerignore
sidecars/apollo/Dockerfile      # Multi-stage Rust build
sidecars/apollo/.dockerignore
sidecars/devmcp/Dockerfile      # ContextForge base + Node.js
sidecars/devmcp/package.json
sidecars/devmcp/.dockerignore
sidecars/sheets/Dockerfile      # ContextForge base + pip
sidecars/sheets/requirements.txt
sidecars/sheets/.dockerignore
bootstrap/bootstrap.py          # Backend registration
bootstrap/Dockerfile
bootstrap/requirements.txt
bootstrap/.dockerignore
scripts/setup-cloud-sql-v4.sh   # Idempotent DB setup
scripts/setup-iam-v4.sh         # SA creation
scripts/setup-alb.sh            # ALB + Cloud Armor
scripts/setup-monitoring.sh     # Alert policies
scripts/setup-cloud-sql-security.sh  # Hardening
scripts/init-postgres.sql       # docker-compose DB init
scripts/init-postgres-wrapper.sh
deploy/cloud-run-gateway.yaml   # Multi-container template
deploy/cloud-run-keycloak-live.yaml  # Working Keycloak config
deploy/cloudbuild.yaml          # 10-step pipeline
deploy/cloud-armor.yaml         # WAF rules
config/.digests                 # Verified image digests
tests/keycloak/test_realm_json.py    # Realm validation (18 tests)
tests/bootstrap/test_bootstrap.py    # Bootstrap validation (16 tests)
```

### Deleted (NOT carried forward)
```
plugins/                        # Replaced by SSO_KEYCLOAK_ENABLED
scripts/gateway-entrypoint.sh   # Replaced by direct DATABASE_URL
deploy/Dockerfile.gateway-v4    # Replaced by base image + env vars
scripts/check-jwks-ready.sh     # Startup probe handles this
tests/plugins/                  # Tests for deleted plugin
```

---

## Phase 0: Deep Capability Audit

### Task 0.1: Invoke `context7` — ContextForge exhaustive audit

- [ ] **Step 1: Invoke `context7` for ContextForge**

Use `mcp__plugin_context7_context7__resolve-library-id` with query "ibm mcp-context-forge"
Then `mcp__plugin_context7_context7__query-docs` for each topic:
  - ALL environment variables (complete list)
  - SSO configuration (Keycloak, Google, GitHub, generic OIDC)
  - Auth modes (JWT, proxy auth, SSO, API key, basic auth)
  - UI features (admin UI, login page, dashboard)
  - Backend registration (API endpoints, auto-discovery, config file)
  - RBAC features (role mapping from SSO, team management)
  - Observability (OTEL, metrics, logging config)

- [ ] **Step 2: Write capabilities doc**

Create: `docs/specs/v5-contextforge-capabilities.md`
Document every env var, every SSO option, every auth mode.

- [ ] **Step 3: Commit**

```bash
git add docs/specs/v5-contextforge-capabilities.md
git commit -m "docs(phase-0): ContextForge capability audit via context7

Skills invoked: context7"
```

### Task 0.2: Invoke `context7` — Keycloak 26.x exhaustive audit

- [ ] **Step 1: Invoke `context7` for Keycloak 26.x**

Use `mcp__plugin_context7_context7__query-docs` for:
  - Admin API endpoints (full list)
  - Client policy executors that ACTUALLY EXIST in 26.x (not guessed)
  - Client profiles API (JSON format for PKCE enforcement)
  - DCR configuration (trusted hosts, registration policies)
  - UserProfile API (how to configure custom attributes post-import)
  - Token mapper types (realm role mapper, audience mapper, custom claims)
  - Realm import limitations (which fields are importable vs admin-API-only)

- [ ] **Step 2: Write capabilities doc**

Create: `docs/specs/v5-keycloak-capabilities.md`

- [ ] **Step 3: Commit**

```bash
git add docs/specs/v5-keycloak-capabilities.md
git commit -m "docs(phase-0): Keycloak 26.x capability audit via context7

Skills invoked: context7"
```

### Task 0.3: Build feature-to-config map

- [ ] **Step 1: Create the map**

Create: `docs/specs/v5-feature-to-config-map.md`

For EVERY v5 feature, document:

| Feature | Component | Config Solution | Custom Code Needed? |
|---------|-----------|----------------|-------------------|
| Browser login | ContextForge SSO | `SSO_KEYCLOAK_ENABLED=true` | No |
| JWT validation | ContextForge SSO | Built-in JWKS via SSO | No |
| Role mapping | ContextForge SSO | `SSO_KEYCLOAK_MAP_REALM_ROLES=true` | No |
| PKCE enforcement | Keycloak | Admin API client policy | No |
| DCR restrictions | Keycloak | Admin API registration policy | No |
| Backend registration | ContextForge API | POST /gateways, POST /servers | bootstrap.py (justified — no built-in auto-config) |
| Tool discovery | ContextForge | Built-in after gateway registration | No |
| Audit trail | ContextForge | Built-in, `AUDIT_TRAIL_RETENTION_DAYS` | No |
| ... | ... | ... | ... |

Any "Yes" in Custom Code requires a paragraph justifying why no built-in exists.

- [ ] **Step 2: Commit**

```bash
git add docs/specs/v5-feature-to-config-map.md
git commit -m "docs(phase-0): feature-to-config map — zero custom code except bootstrap

Skills invoked: context7"
```

### Task 0.4: Invoke `sharp-edges` (Trail of Bits)

- [ ] **Step 1: Invoke skill**

```
/sharp-edges
```

Run against ContextForge usage patterns. Document any dangerous defaults or misuse risks.

- [ ] **Step 2: Document findings and commit**

Add findings to `docs/specs/v5-feature-to-config-map.md` as a "Security Notes" section.

```bash
git commit -m "docs(phase-0): sharp-edges findings added to feature map

Skills invoked: sharp-edges (Trail of Bits)"
```

### Task 0.5: Phase 0 gate check

- [ ] **Step 1: Verify the gate**

Confirm:
- `v5-contextforge-capabilities.md` exists and covers ALL env vars
- `v5-keycloak-capabilities.md` exists and covers Admin API
- `v5-feature-to-config-map.md` exists and every feature has a config solution or written justification
- No feature marked "custom code needed" without justification

**DO NOT proceed to Phase 1 until this gate passes.**

---

## Phase 1: Keycloak Verification

### Task 1.1: Invoke `configuring-oauth2-authorization-flow`

- [ ] **Step 1: Invoke skill**

```
/configuring-oauth2-authorization-flow
```

Produces an OAuth completeness checklist. Document which items are already satisfied by the existing Keycloak deployment and which need Admin API configuration.

- [ ] **Step 2: Save checklist to docs and commit**

```bash
git commit -m "docs(phase-1): OAuth flow checklist from cybersecurity skill

Skills invoked: configuring-oauth2-authorization-flow"
```

### Task 1.2: Create Postman collection — Keycloak Admin

- [ ] **Step 1: Invoke `postman` skill**

Use the Postman MCP tools to create collection `Fluid-Intelligence-Keycloak` with environment `keycloak-prod`:

**Environment variables:**
- `KC_URL` = `https://keycloak-apanptkfaq-as.a.run.app`
- `REALM` = `fluid`
- `ADMIN_USER` = `admin`
- `ADMIN_PASSWORD` = (from `gcloud secrets versions access latest --secret=keycloak-admin-password --project=junlinleather-mcp`)

**Folder 1 — Auth Token:**
- POST `{{KC_URL}}/realms/master/protocol/openid-connect/token` with client_credentials grant
- Store `access_token` in environment variable (auto-refresh via pre-request script)

**Folder 2 — Verify Current State (7 requests):**
- GET OIDC Discovery → assert `issuer` starts with `https://`
- GET JWKS → assert at least 1 key with `alg: RS256`
- GET List Clients → assert `fluid-bootstrap`, `fluid-gateway`, `fluid-gateway-sso` exist
- GET List IdPs → assert `google` exists
- GET Realm Settings → assert `bruteForceProtected: true`
- POST Token Exchange → assert HTTP 400 (disabled)
- GET Event Config → assert `eventsEnabled: true`, retention 7776000

**Folder 3 — Configure Gaps:**
- PUT Client Policy for PKCE (use executor names from Phase 0 Keycloak audit — NOT guessed)
- PUT DCR trusted hosts (add gateway Cloud Run URL)
- PUT UserProfile attributes (tenant_id, roles — admin-only writable)
- POST Realm Role Mapper on fluid-bootstrap (if not already present)

**Folder 4 — Acceptance Tests (6 requests):**
- POST DCR with `authorization_code` → assert 201
- POST DCR with `client_credentials` → assert rejected
- GET Auth endpoint without PKCE code_challenge → assert rejected
- POST Get Bootstrap Token → assert `realm_access.roles` in JWT
- POST Get Bootstrap Token → assert `aud` contains `fluid-gateway`
- GET Admin Console path → assert blocked (403 or redirect only)

- [ ] **Step 2: Run Folders 2 + 4 — verify all assertions pass**
- [ ] **Step 3: If assertions fail, run Folder 3 to fix gaps, then re-run Folder 4**
- [ ] **Step 4: Commit Postman collection export**

```bash
git commit -m "feat(phase-1): Keycloak Postman collection — verify + configure + test

Skills invoked: postman"
```

### Task 1.3: Browser verification via `claude-in-chrome`

- [ ] **Step 1: Invoke `claude-in-chrome`**

Open `https://keycloak-apanptkfaq-as.a.run.app/realms/fluid/account/` in browser.
Verify: login page renders, username/password fields visible.
If Google IdP configured: verify "Login with Google" button appears.

- [ ] **Step 2: Record GIF or screenshot as proof**

```bash
git commit -m "docs(phase-1): Keycloak browser verification via claude-in-chrome

Skills invoked: claude-in-chrome"
```

### Task 1.4: Phase 1 gate check

- [ ] **Step 1: Verify all Postman assertions in Folders 2 + 4 pass**
- [ ] **Step 2: Verify browser login page renders**
- [ ] **Step 3: Verify acceptance criteria #1, #5(IdP), #12, #18, #19, #21, #22 pass**

**DO NOT proceed to Phase 2 until this gate passes.**

---

## Phase 2: Gateway Local (docker-compose)

### Task 2.1: Invoke `context7` — ContextForge env vars

- [ ] **Step 1: Look up EVERY ContextForge env var we plan to set**

Use `context7` to verify each variable name, default value, and valid options:
- `SSO_ENABLED`, `SSO_KEYCLOAK_ENABLED`, `SSO_KEYCLOAK_BASE_URL`, `SSO_KEYCLOAK_REALM`
- `SSO_KEYCLOAK_CLIENT_ID`, `SSO_KEYCLOAK_CLIENT_SECRET`
- `SSO_KEYCLOAK_MAP_REALM_ROLES`, `SSO_AUTO_CREATE_USERS`
- `AUTH_REQUIRED`, `MCPGATEWAY_UI_ENABLED`, `MCPGATEWAY_ADMIN_API_ENABLED`
- `DATABASE_URL`, `MCG_HOST`, `MCG_PORT`

**DO NOT guess any env var name.** Every one must be verified against docs.

- [ ] **Step 2: Document verified env vars and commit**

```bash
git commit -m "docs(phase-2): verified ContextForge env vars via context7

Skills invoked: context7"
```

### Task 2.2: Create docker-compose.yml (fresh)

- [ ] **Step 1: Audit v4 docker-compose.yml**

Read: `.worktrees/v4-implementation/docker-compose.yml`
Cherry-pick: PostgreSQL service definition, Keycloak service definition.
Note: ContextForge service must be rewritten from scratch (no plugins, no entrypoint wrapper).

- [ ] **Step 2: Write docker-compose.yml**

Create `docker-compose.yml` with 3 services (sidecars added in Phase 3):

```yaml
services:
  postgres:
    image: postgres:16-alpine
    # ... (cherry-pick from v4, audit every line)

  keycloak:
    build: ./keycloak
    # ... (cherry-pick from v4, audit every line)

  contextforge:
    image: ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2
    # NO custom Dockerfile — base image + env vars only
    environment:
      - SSO_ENABLED=true
      - SSO_KEYCLOAK_ENABLED=true
      - SSO_KEYCLOAK_BASE_URL=http://keycloak:8080
      - SSO_KEYCLOAK_REALM=fluid
      - SSO_KEYCLOAK_CLIENT_ID=fluid-gateway-sso
      - SSO_KEYCLOAK_CLIENT_SECRET=${SSO_CLIENT_SECRET}
      - SSO_KEYCLOAK_MAP_REALM_ROLES=true
      - SSO_AUTO_CREATE_USERS=true
      - AUTH_REQUIRED=true
      - MCPGATEWAY_UI_ENABLED=true
      - MCPGATEWAY_ADMIN_API_ENABLED=true
      - DATABASE_URL=postgresql://contextforge:${CF_DB_PASSWORD}@postgres:5432/contextforge
      - MCG_HOST=0.0.0.0
      - MCG_PORT=8080
    ports:
      - "8080:8080"
    depends_on:
      postgres:
        condition: service_healthy
      keycloak:
        condition: service_healthy
```

- [ ] **Step 3: Write `.env.example`**
- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml .env.example
git commit -m "feat(phase-2): docker-compose with ContextForge SSO — zero custom code"
```

### Task 2.3: Cherry-pick Keycloak files (audit every line)

- [ ] **Step 1: Audit `keycloak/Dockerfile` from v4**

Read: `.worktrees/v4-implementation/keycloak/Dockerfile`
Verify: `--features-disabled`, `--health-enabled=true`, SUID stripping, non-root user, pinned digest.
Copy to: `keycloak/Dockerfile`

- [ ] **Step 2: Audit `keycloak/realm-fluid.json` from v4**

Read: `.worktrees/v4-implementation/keycloak/realm-fluid.json`
Verify: no `userProfile`, no `clientProfiles`, no `clientPolicies` (these were removed after v4 import failures).
Copy to: `keycloak/realm-fluid.json`

- [ ] **Step 3: Copy `.dockerignore`**
- [ ] **Step 4: Run realm JSON tests**

Cherry-pick: `.worktrees/v4-implementation/tests/keycloak/test_realm_json.py`
Run: `python3 -m pytest tests/keycloak/test_realm_json.py -v`
Expected: 18 passed, 5 skipped

- [ ] **Step 5: Commit**

```bash
git add keycloak/ tests/keycloak/
git commit -m "feat(phase-2): cherry-pick Keycloak files — audited every line"
```

### Task 2.4: Run docker-compose and verify

- [ ] **Step 1: Create `.env` from `.env.example` with real values**
- [ ] **Step 2: Run `docker-compose up -d`**
- [ ] **Step 3: Check all containers healthy**

```bash
docker-compose ps
```
Expected: postgres (healthy), keycloak (healthy), contextforge (healthy)

- [ ] **Step 4: Check ContextForge logs for SSO**

```bash
docker-compose logs contextforge | grep -i "SSO\|sso\|Keycloak"
```
Expected: "SSO router included", "Created SSO provider: Keycloak"

- [ ] **Step 5: Check database connection**

```bash
docker-compose logs contextforge | grep -i "postgresql\|database\|SQLite"
```
Expected: PostgreSQL connected (NOT SQLite fallback)

### Task 2.5: Browser login test via `claude-in-chrome`

- [ ] **Step 1: Invoke `claude-in-chrome`**

Open `http://localhost:8080/docs` in browser.
Expected flow:
1. Page shows login option or redirects to Keycloak
2. Keycloak login page renders
3. Enter admin credentials
4. Redirected back to ContextForge
5. Admin UI renders with user identity

- [ ] **Step 2: Record GIF as proof**
- [ ] **Step 3: If login doesn't redirect, check SSO login endpoint**

Try: `http://localhost:8080/auth/sso/login/keycloak?redirect_uri=/docs`

- [ ] **Step 4: Commit**

```bash
git commit -m "docs(phase-2): browser login verified via claude-in-chrome

Skills invoked: claude-in-chrome"
```

### Task 2.6: Invoke `verification-before-completion`

- [ ] **Step 1: Invoke skill**

```
/verification-before-completion
```

Verify:
- docker-compose up works (AC #7)
- Browser login works end-to-end
- ContextForge connects to PostgreSQL (not SQLite)
- SSO router enabled in logs
- No custom code written (zero plugins, zero entrypoint scripts)

- [ ] **Step 2: Document verification result and commit**

```bash
git commit -m "docs(phase-2): verification-before-completion passed

Skills invoked: verification-before-completion"
```

### Task 2.7: Phase 2 gate check

- [ ] **Step 1: Browser login screenshot/GIF exists**
- [ ] **Step 2: docker-compose ps shows all 3 services healthy**
- [ ] **Step 3: Zero custom Python/shell code written**
- [ ] **Step 4: AC #2 (JWT validation), #5 (e2e login), #7 (docker-compose) pass**

**DO NOT proceed to Phase 3 until this gate passes.**

---

## Phase 3: Sidecars Local

### Task 3.1: Invoke `context7` — verify sidecar versions

- [ ] **Step 1: Check Apollo MCP Server latest version/commit**

```bash
git ls-remote https://github.com/apollographql/apollo-mcp-server.git HEAD
```

- [ ] **Step 2: Check @shopify/dev-mcp latest version**

```bash
npm view @shopify/dev-mcp version
```

- [ ] **Step 3: Check mcp-google-sheets latest version + license**

```bash
pip index versions mcp-google-sheets
```

- [ ] **Step 4: Document versions and commit**

### Task 3.2: Invoke `supply-chain-risk-auditor` (Trail of Bits)

- [ ] **Step 1: Invoke skill**

```
/supply-chain-risk-auditor
```

Audit: Apollo (Rust crate deps), dev-mcp (npm deps), sheets (pip deps).
Document findings.

- [ ] **Step 2: Commit**

```bash
git commit -m "docs(phase-3): supply chain audit

Skills invoked: supply-chain-risk-auditor (Trail of Bits)"
```

### Task 3.3: Invoke `hardening-docker-containers-for-production`

- [ ] **Step 1: Invoke skill**

```
/hardening-docker-containers-for-production
```

Check all sidecar Dockerfiles against CIS Docker benchmark.

- [ ] **Step 2: Apply any fixes and commit**

```bash
git commit -m "fix(phase-3): CIS benchmark fixes for sidecar Dockerfiles

Skills invoked: hardening-docker-containers-for-production"
```

### Task 3.4: Cherry-pick and audit sidecar Dockerfiles

- [ ] **Step 1: Audit `sidecars/apollo/Dockerfile` from v4**

Read: `.worktrees/v4-implementation/sidecars/apollo/Dockerfile`
Verify: multi-stage build, pinned commit, tini, non-root, SUID stripped.
Update: replace PINNED_COMMIT_HASH with real value from Task 3.1.
Copy to: `sidecars/apollo/Dockerfile`

- [ ] **Step 2: Audit `sidecars/devmcp/Dockerfile` + `package.json` from v4**

Read line by line. Update @shopify/dev-mcp version.
Run: `cd sidecars/devmcp && npm install` to generate `package-lock.json`

- [ ] **Step 3: Audit `sidecars/sheets/Dockerfile` + `requirements.txt` from v4**

Read line by line. Update mcp-google-sheets version.

- [ ] **Step 4: Commit**

```bash
git add sidecars/
git commit -m "feat(phase-3): cherry-pick sidecar Dockerfiles — audited, versions updated"
```

### Task 3.5: Cherry-pick and audit bootstrap

- [ ] **Step 1: Audit `bootstrap/bootstrap.py` from v4**

Read: `.worktrees/v4-implementation/bootstrap/bootstrap.py`
Verify: registers 3 backends, creates virtual servers, handles 409, reads secret from file, exits 0/1.

- [ ] **Step 2: Copy bootstrap files**
- [ ] **Step 3: Run bootstrap tests**

Cherry-pick: `.worktrees/v4-implementation/tests/bootstrap/test_bootstrap.py`
Run: `python3 -m pytest tests/bootstrap/test_bootstrap.py -v`
Expected: 16 passed

- [ ] **Step 4: Commit**

```bash
git add bootstrap/ tests/bootstrap/
git commit -m "feat(phase-3): cherry-pick bootstrap — audited, 16 tests pass"
```

### Task 3.6: Add sidecars to docker-compose

- [ ] **Step 1: Add Apollo, dev-mcp, sheets, bootstrap services**

```yaml
  apollo:
    build: ./sidecars/apollo
    ports:
      - "8000:8000"

  devmcp:
    build: ./sidecars/devmcp
    ports:
      - "8003:8003"

  sheets:
    build: ./sidecars/sheets
    ports:
      - "8004:8004"

  bootstrap:
    build: ./bootstrap
    restart: "no"
    depends_on:
      contextforge:
        condition: service_healthy
    environment:
      - CONTEXTFORGE_URL=http://contextforge:8080
      - KEYCLOAK_TOKEN_URL=http://keycloak:8080/realms/fluid/protocol/openid-connect/token
      - BOOTSTRAP_CLIENT_ID=fluid-bootstrap
      # ... (from v4 audit)
```

- [ ] **Step 2: `docker-compose up -d --build`**
- [ ] **Step 3: Verify all containers healthy, bootstrap exits 0**

```bash
docker-compose ps
docker-compose logs bootstrap
```

- [ ] **Step 4: Commit**

### Task 3.7: Create Postman collection — Gateway

- [ ] **Step 1: Create `Fluid-Intelligence-Gateway` collection**

Environment `gateway-local`:
- `GW_URL` = `http://localhost:8080`

Requests:
- GET /health → assert `{"status":"healthy"}`
- GET /tools (or equivalent) → assert tools from all 3 backends listed
- POST tool execution (Shopify query) → assert result returned

- [ ] **Step 2: Run collection — all assertions pass**
- [ ] **Step 3: Commit**

### Task 3.8: Invoke `verification-before-completion`

- [ ] **Step 1: Invoke skill**
- [ ] **Step 2: Verify AC #3 (RBAC), #4 (sidecars), #6 (bootstrap idempotent)**
- [ ] **Step 3: Commit verification result**

### Task 3.9: Phase 3 gate check

- [ ] All 3 sidecars healthy in docker-compose
- [ ] Tools visible in ContextForge admin UI (via claude-in-chrome)
- [ ] At least one Shopify query returns data (via Postman)
- [ ] Bootstrap exits 0, runs idempotently
- [ ] Unit tests pass (realm: 18, bootstrap: 16)

**DO NOT proceed to Phase 4 until this gate passes.**

---

## Phase 4: Cloud Deploy

### Task 4.1: Invoke `securing-serverless-functions` (BEFORE deploying)

- [ ] **Step 1: Invoke skill**

```
/securing-serverless-functions
```

Get Cloud Run security checklist. Document any issues to address.

- [ ] **Step 2: Commit**

```bash
git commit -m "docs(phase-4): Cloud Run security checklist

Skills invoked: securing-serverless-functions"
```

### Task 4.2: Invoke `implementing-zero-trust-network-access`

- [ ] **Step 1: Invoke skill**
- [ ] **Step 2: Document VPC/network decisions and commit**

### Task 4.3: Audit v4 Cloud Run YAML

- [ ] **Step 1: Read `.worktrees/v4-implementation/deploy/cloud-run-gateway.yaml` line by line**

Known v4 gotchas to check for:
- No `terminationGracePeriodSeconds` in single-container YAML
- TCP liveness probes NOT supported (use HTTP)
- `allUsers` invoker binding lost on service delete/recreate
- `gcloud run services replace` does NOT do env var substitution

- [ ] **Step 2: Update for v5**

Key changes from v4:
- Service name: `fluid-intelligence-v5` (parallel to v3)
- SSO env vars instead of plugin env vars
- No `PLUGINS_ENABLED`, no `PLUGIN_CONFIG_FILE`
- `DATABASE_URL` set directly (no entrypoint wrapper)
- `SSO_KEYCLOAK_BASE_URL` = `https://keycloak-apanptkfaq-as.a.run.app`

- [ ] **Step 3: Audit v4 cloudbuild.yaml line by line**
- [ ] **Step 4: Commit**

### Task 4.4: Build and deploy (max 3 deploys)

- [ ] **Step 1: Build all images**

```bash
gcloud builds submit --config=deploy/cloudbuild.yaml --project=junlinleather-mcp --region=asia-southeast1
```

- [ ] **Step 2: Deploy**

```bash
gcloud run services replace deploy/cloud-run-gateway-v5.yaml --region=asia-southeast1 --project=junlinleather-mcp
```

- [ ] **Step 3: Add allUsers invoker**

```bash
gcloud run services add-iam-policy-binding fluid-intelligence-v5 --member="allUsers" --role="roles/run.invoker" --region=asia-southeast1 --project=junlinleather-mcp
```

- [ ] **Step 4: If deploy fails → invoke `systematic-debugging`**

```
/systematic-debugging
```
Reproduce locally first. Fix locally. Then retry (max 3 total deploys).

### Task 4.5: Verify via Postman + browser

- [ ] **Step 1: Switch Postman environment from `gateway-local` to `gateway-prod`**

Update `GW_URL` = `https://fluid-intelligence-v5-apanptkfaq-as.a.run.app`

- [ ] **Step 2: Run `Fluid-Intelligence-Gateway` collection — all pass**
- [ ] **Step 3: Browser test via `claude-in-chrome`**

Open gateway URL → SSO login → admin UI → tools visible.
Record GIF.

### Task 4.6: Post-deploy security skills

- [ ] **Step 1: Invoke `entry-point-analyzer` (Trail of Bits)**

```
/entry-point-analyzer
```

- [ ] **Step 2: Invoke `performing-security-headers-audit`**

```
/performing-security-headers-audit
```

- [ ] **Step 3: Commit findings**

### Task 4.7: Phase 4 gate check

- [ ] Postman gateway collection passes against Cloud Run URL
- [ ] Browser login works end-to-end on Cloud Run
- [ ] claude-in-chrome GIF proof exists
- [ ] entry-point-analyzer + security-headers-audit invoked

**DO NOT proceed to Phase 5 until this gate passes.**

---

## Phase 5: Harden + Accept

### Task 5.1: Create Postman collection — Acceptance Tests

- [ ] **Step 1: Create `Fluid-Intelligence-Acceptance` collection**

23 requests, one per acceptance criterion, each with pass/fail assertions.

### Task 5.2: Run all 23 acceptance criteria

- [ ] **Step 1: Run acceptance collection**
- [ ] **Step 2: Fix any failures**
- [ ] **Step 3: Re-run until all 23 pass**

### Task 5.3: Invoke security skills (7 total)

- [ ] **Step 1: `insecure-defaults`** (Trail of Bits)
- [ ] **Step 2: `testing-api-security-with-owasp-top-10`** (cybersecurity)
- [ ] **Step 3: `supply-chain-risk-auditor`** (Trail of Bits) — final audit
- [ ] **Step 4: `spec-to-code-compliance`** (Trail of Bits) — verify vs spec
- [ ] **Step 5: `second-opinion`** (Trail of Bits) — independent review
- [ ] **Step 6: `postman:security`** — API security scan
- [ ] **Step 7: `verification-before-completion`** — final gate

### Task 5.4: Production hardening

- [ ] **Step 1: Restrict Cloud SQL authorized networks**

Remove 0.0.0.0/0. Add Cloud Run egress IP ranges only.

- [ ] **Step 2: Deploy ALB + Cloud Armor**

Run: `bash scripts/setup-alb.sh`

- [ ] **Step 3: Activate monitoring alerts**

Run: `bash scripts/setup-monitoring.sh`

- [ ] **Step 4: Enable cosign image signing in Cloud Build**
- [ ] **Step 5: Commit**

### Task 5.5: Final regression

- [ ] **Step 1: Run all unit tests**

```bash
python3 -m pytest tests/ -v --ignore=tests/shopify_oauth
```

- [ ] **Step 2: Run Postman acceptance collection — all 23 pass**
- [ ] **Step 3: Browser login via claude-in-chrome — works**
- [ ] **Step 4: All 25 skill invocations documented in commit messages**

### Task 5.6: Phase 5 gate check (FINAL)

- [ ] All 23 acceptance criteria pass in Postman
- [ ] All 7 Phase 5 security skills invoked
- [ ] Production hardening complete (Cloud SQL restricted, ALB deployed, monitoring active)
- [ ] Unit tests pass (34+ tests)
- [ ] Browser login verified
- [ ] Zero custom auth code in the codebase

**v5 is DONE when this gate passes.**
