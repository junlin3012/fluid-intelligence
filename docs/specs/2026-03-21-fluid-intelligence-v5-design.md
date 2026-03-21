# Fluid Intelligence v5 — Architecture Design Spec

> Status: DRAFT
> Date: 2026-03-21
> Authors: junlin + Claude
> Supersedes: `docs/specs/2026-03-19-fluid-intelligence-v4-design.md`

---

## 1. Vision

Same as v4: A universal MCP gateway that gives AI clients a single endpoint to access any API — with per-user identity, role-based access, config-driven backends, and full audit trails. Shopify is the first vertical.

## 2. What Changed from v4

v4's architecture was sound. v4's execution was not. v5 uses the **same architecture** with a fundamentally different implementation approach.

| v4 Problem | v5 Fix |
|-----------|--------|
| 741 lines of custom code replaced by 9 env vars | **Configure first, code never** — Phase 0 capability audit before any work |
| 15 failed deploys | **Local first, cloud last** — docker-compose verified before Cloud Run |
| 0 security skills invoked | **25 skill invocations across 14 unique skills** — tracked as tasks, not comments |
| No browser testing until the end | **claude-in-chrome after every phase** — browser proof required |
| curl scripts for API management | **Postman collections** — organized, reusable, with test assertions |

## 3. Architecture (unchanged from v4)

### 3.1 Topology

```
Cloud Run Service 1: Keycloak (EXISTING — live, verified)
  └── Keycloak 26.1.4 → PostgreSQL (keycloak database)

Cloud Run Service 2: Fluid Intelligence Gateway (NEW — v5 deploy)
  ├── ContextForge 1.0.0-RC-2 (main container)
  ├── Apollo MCP Server (sidecar)
  ├── dev-mcp via mcpgateway.translate (sidecar)
  └── Google Sheets via mcpgateway.translate (sidecar)
  → PostgreSQL (contextforge database, same Cloud SQL instance)
```

### 3.2 Auth Flow

```
User (browser or AI client)
  → ContextForge (port 8080)
  → SSO redirect to Keycloak login page
  → User authenticates (Google / password)
  → Keycloak issues JWT with email, realm_access.roles, aud:fluid-gateway
  → Redirect back to ContextForge with JWT
  → ContextForge validates JWT via JWKS (built-in SSO, no custom plugin)
  → ContextForge maps realm roles to RBAC (SSO_KEYCLOAK_MAP_REALM_ROLES=true)
  → User sees admin UI / AI client gets MCP tools
```

**Key difference from v4:** No custom `resolve_user.py` plugin. ContextForge's native `SSO_KEYCLOAK_ENABLED` handles everything.

### 3.3 Port Map

| Container | Port | Protocol | Exposed? |
|-----------|------|----------|----------|
| ContextForge | 8080 | HTTP | Yes (Cloud Run) |
| Apollo | 8000 | SSE | No (localhost) |
| dev-mcp | 8003 | SSE (translate bridge) | No (localhost) |
| Google Sheets | 8004 | SSE (translate bridge) | No (localhost) |
| Keycloak | 8080 | HTTP | Yes (own service) |

### 3.4 Inter-Service Communication

```
ContextForge → Keycloak:  JWKS fetch (HTTPS, cached 5 min)
ContextForge → Apollo:    localhost:8000 (no auth, same container)
ContextForge → dev-mcp:   localhost:8003 (no auth, same container)
ContextForge → sheets:    localhost:8004 (no auth, same container)
Bootstrap → Keycloak:     client_credentials grant (service account JWT)
Bootstrap → ContextForge: POST /gateways, POST /servers (JWT auth)
```

**Keycloak is NOT in the hot path.** After initial JWKS fetch, all JWT validation is local (cached public keys). Keycloak is only called for login redirects and key rotation.

## 4. The v5 Rules

These rules are non-negotiable. They exist because v4 violated each one.

### Rule 1: Configure First, Code Never

Before writing ANY custom code:
1. Read both applications' integration docs via `context7`
2. Search for built-in integrations
3. If built-in exists, USE IT
4. Custom code requires written justification against the Phase 0 capability audit

### Rule 2: Local First, Cloud Last

1. `docker-compose up` → verify in browser → THEN deploy to Cloud Run
2. Every configuration must work locally before cloud deployment
3. Maximum 3 Cloud Run deploys per component

### Rule 3: Invoke Skills, Don't Skip Them

Skills are TASKS in the plan (checkboxed items), not comments. 14 skills across 6 phases. Each must be invoked and its output documented.

### Rule 4: 3-Deploy Limit

If a cloud deploy fails 3 times:
1. STOP deploying
2. Invoke `systematic-debugging` skill
3. Reproduce locally, fix locally, then deploy once

### Rule 5: Postman for All API Interactions

All API calls (Keycloak Admin, ContextForge Admin, acceptance tests) organized as Postman collections — not ad-hoc curl commands.

## 5. Implementation Phases

### Phase 0: Deep Capability Audit

**Goal:** Complete inventory of what every component can do natively. No code, no config — research only.

**Skills:**
- [ ] `context7` — exhaustive doc search for ContextForge AND Keycloak
- [ ] `sharp-edges` (Trail of Bits) — dangerous patterns to avoid

**Deliverables:**
- `docs/specs/v5-contextforge-capabilities.md` — ALL env vars, SSO options, auth modes, UI features, plugin hooks, backend registration, RBAC, observability
- `docs/specs/v5-keycloak-capabilities.md` — Admin API endpoints, client policy executors (which ACTUALLY exist in 26.x), DCR, UserProfile API, token mappers
- `docs/specs/v5-feature-to-config-map.md` — every v5 feature mapped to config option. Any feature requiring custom code must have written justification.

**Gate:** Feature-to-config map exists. Every feature has a config solution or explicit justification for custom code.

---

### Phase 1: Keycloak Verification

**Goal:** Verify existing Keycloak passes all auth criteria. Fix gaps via Admin API.

**Skills:**
- [ ] `configuring-oauth2-authorization-flow` (cybersecurity) — OAuth completeness checklist
- [ ] `postman` — create Keycloak Admin API collection
- [ ] `claude-in-chrome` — verify login page renders in browser

**Deliverables:**
- Postman collection: `Fluid-Intelligence-Keycloak`
  ```
  📁 Fluid-Intelligence-Keycloak
  ├── 🌍 Environment: keycloak-prod
  ├── 📁 1. Auth Token (auto-refresh)
  ├── 📁 2. Verify Current State (7 requests with assertions)
  ├── 📁 3. Configure Gaps (PKCE, DCR, UserProfile, role mapper)
  ├── 📁 4. Acceptance Tests (6 requests with pass/fail assertions)
  └── 📁 5. Browser Flow (verified via claude-in-chrome)
  ```
- `scripts/configure-keycloak-policies.sh` — idempotent Admin API calls (exported from Postman)

**Acceptance criteria tested:** #1, #5 (IdP config only), #12, #18, #19, #21, #22 (Keycloak-only criteria. Auth bypass #16, JWT forgery #17, audience #20, bootstrap scope #23 require the gateway — tested in Phase 5)

**Gate:** All Postman assertions in folders 2 + 4 pass. Browser login verified via claude-in-chrome screenshot/GIF.

---

### Phase 2: Gateway Local (docker-compose)

**Goal:** ContextForge with Keycloak SSO working in browser — locally. Zero custom code.

**Skills:**
- [ ] `context7` — look up every ContextForge env var
- [ ] `claude-in-chrome` — verify browser login locally
- [ ] `verification-before-completion` — before declaring phase done

**What happens:**
1. Audit v4 `docker-compose.yml` line by line → cherry-pick PostgreSQL + Keycloak, rewrite ContextForge
2. Configure ContextForge via env vars ONLY (SSO_KEYCLOAK_ENABLED, AUTH_REQUIRED, MCPGATEWAY_UI_ENABLED, DATABASE_URL direct)
3. `docker-compose up` → verify all containers start
4. Browser test via claude-in-chrome: open → redirect to Keycloak → login → redirect back → admin UI renders

**ContextForge configuration (env vars only, no custom code):**
```env
SSO_ENABLED=true
SSO_KEYCLOAK_ENABLED=true
SSO_KEYCLOAK_BASE_URL=http://keycloak:8080
SSO_KEYCLOAK_REALM=fluid
SSO_KEYCLOAK_CLIENT_ID=fluid-gateway-sso
SSO_KEYCLOAK_CLIENT_SECRET=<from keycloak>
SSO_KEYCLOAK_MAP_REALM_ROLES=true
SSO_AUTO_CREATE_USERS=true
AUTH_REQUIRED=true
MCPGATEWAY_UI_ENABLED=true
MCPGATEWAY_ADMIN_API_ENABLED=true
DATABASE_URL=postgresql://contextforge:password@postgres:5432/contextforge
```

**Files:**
- `docker-compose.yml` — fresh, audited
- `.env.example` — v5 variables documented

**Gate:** Browser login end-to-end locally. Screenshot/GIF proof.

---

### Phase 3: Sidecars Local

**Goal:** All 3 backend sidecars running, tools registered and callable locally.

**Skills:**
- [ ] `context7` — verify Apollo, dev-mcp, sheets current versions
- [ ] `supply-chain-risk-auditor` (Trail of Bits) — audit deps before building images
- [ ] `hardening-docker-containers-for-production` (cybersecurity) — CIS benchmark on Dockerfiles
- [ ] `verification-before-completion` — before declaring phase done

**What happens:**
1. Audit v4 sidecar Dockerfiles line by line → cherry-pick proven, fix issues
2. Resolve Apollo commit hash (verify v1.9.0 or newer)
3. Run `npm install` for dev-mcp lockfile, verify sheets pip version
4. Add sidecars + bootstrap to docker-compose
   → Bootstrap runs as a `restart: "no"` service (one-shot init container pattern)
   → Depends on ContextForge being healthy
5. `docker-compose up` → all containers healthy, bootstrap exits 0
6. Bootstrap registers 3 backends → tools appear in ContextForge
7. Call a tool via Postman → verify result

**Postman collection: `Fluid-Intelligence-Gateway`**
```
📁 Fluid-Intelligence-Gateway
├── 🌍 Environment: gateway-local / gateway-prod
├── 📁 1. Auth (SSO token or admin basic auth)
├── 📁 2. Backend Registration (POST /gateways, POST /servers)
├── 📁 3. Tool Discovery (GET /tools, verify all tools listed)
├── 📁 4. Tool Execution (call Shopify query, verify result)
└── 📁 5. Health Checks (all sidecars healthy)
```

**Files:**
- `sidecars/apollo/Dockerfile` — audited from v4
- `sidecars/devmcp/Dockerfile` + `package.json` + `package-lock.json` — audited
- `sidecars/sheets/Dockerfile` + `requirements.txt` — audited
- `bootstrap/bootstrap.py` + `Dockerfile` — audited from v4
- `docker-compose.yml` — updated with sidecars

**Gate:** All 3 sidecars healthy, tools visible in admin UI, at least one Shopify query returns data. Verified via Postman + claude-in-chrome.

---

### Phase 4: Cloud Deploy

**Goal:** Working local stack deployed to Cloud Run. Maximum 3 deploys.

**Skills:**
- [ ] `securing-serverless-functions` (cybersecurity) — Cloud Run checklist BEFORE deploying
- [ ] `implementing-zero-trust-network-access` (cybersecurity) — VPC/network verification
- [ ] `entry-point-analyzer` (Trail of Bits) — map attack surface AFTER deploy
- [ ] `performing-security-headers-audit` (cybersecurity) — HTTP headers AFTER deploy
- [ ] `claude-in-chrome` — browser test AFTER deploy
- [ ] `systematic-debugging` — invoke if ANY deploy fails (3-deploy limit)

**What happens:**
1. Invoke securing-serverless-functions BEFORE any deploy
2. Audit v4 Cloud Run YAML line by line → cherry-pick multi-container template
   → Known gotchas from v4: no `terminationGracePeriodSeconds` in single-container YAML, TCP liveness probes NOT supported (use HTTP), `allUsers` invoker binding lost on service delete/recreate, `gcloud run services replace` does NOT do env var substitution
3. Build sidecar images via Cloud Build
4. Deploy gateway multi-container service
5. Verify via claude-in-chrome: SSO login → admin UI → tool execution
6. Invoke entry-point-analyzer + security-headers-audit

**Postman:** Switch `Fluid-Intelligence-Gateway` environment from `gateway-local` to `gateway-prod`. Run same collection against Cloud Run URL.

**Files:**
- `deploy/cloud-run-gateway.yaml` — audited from v4, updated with v5 env vars
- `deploy/cloudbuild.yaml` — audited from v4

**Gate:** Postman gateway collection passes against Cloud Run URL. Browser login works. claude-in-chrome proof.

---

### Phase 5: Harden + Accept

**Goal:** All 23 acceptance criteria pass. Production hardened.

**Skills:**
- [ ] `insecure-defaults` (Trail of Bits) — verify all defaults fail-safe
- [ ] `testing-api-security-with-owasp-top-10` (cybersecurity) — OWASP validation
- [ ] `supply-chain-risk-auditor` (Trail of Bits) — final dep audit
- [ ] `spec-to-code-compliance` (Trail of Bits) — verify implementation matches this spec
- [ ] `second-opinion` (Trail of Bits) — independent re-review
- [ ] `postman:security` — API security scan on running gateway
- [ ] `verification-before-completion` — final gate

**Postman collection: `Fluid-Intelligence-Acceptance`**
```
📁 Fluid-Intelligence-Acceptance
├── 📁 Auth (AC #1, #2, #3, #5)
├── 📁 Security (AC #9, #10, #11, #12, #13, #16-23)
├── 📁 Operations (AC #4, #6, #7, #14)
└── 📁 Performance (AC #8, #15)
```

Each request has test assertions that produce a pass/fail result.

**Production hardening:**
- Restrict Cloud SQL authorized networks (remove 0.0.0.0/0)
- Deploy ALB + Cloud Armor (`scripts/setup-alb.sh` from v4)
- Configure VPC connector for private Cloud SQL
- Enable cosign image signing in Cloud Build
- Activate monitoring alerts (`scripts/setup-monitoring.sh` from v4)

**Gate:** All 23 acceptance criteria pass in Postman. All 7 security skills invoked. Production hardening complete.

## 6. Acceptance Criteria (same 23 as v4)

| # | Criterion | Phase Tested | How Tested |
|---|-----------|-------------|------------|
| 1 | Keycloak issues JWTs via OAuth 2.1 + PKCE S256 | Phase 1 | Postman |
| 2 | ContextForge validates Keycloak JWTs via JWKS | Phase 2 | Postman |
| 3 | RBAC enforced (admin/user/readonly) | Phase 3 | Postman (different roles → different tool access) |
| 4 | All 3 sidecars registered and healthy | Phase 3 | Postman |
| 5 | Google OAuth end-to-end login | Phase 1 (IdP config) + Phase 2 (e2e flow) | Postman (Phase 1) + claude-in-chrome (Phase 2) |
| 6 | Bootstrap idempotent | Phase 3 | Postman (run twice) |
| 7 | docker-compose up works | Phase 2 | docker-compose up |
| 8 | Cold start < 45s | Phase 5 | Timer |
| 9 | CVE scan passes | Phase 5 | Cloud Build pipeline |
| 10 | Secret scan passes | Phase 5 | Cloud Build pipeline |
| 11 | Non-root + read-only rootfs | Phase 5 | docker inspect |
| 12 | Admin console not publicly accessible | Phase 1 | Postman |
| 13 | Fail closed when Keycloak down | Phase 5 | Postman (stop Keycloak, test gateway) |
| 14 | Audit trail records all actions | Phase 5 | Postman (check audit log) |
| 15 | Load test 5 concurrent users | Phase 5 | Postman runner / hey |
| 16 | Auth bypass test | Phase 5 | Postman |
| 17 | JWT forgery test | Phase 5 | Postman |
| 18 | PKCE required | Phase 1 | Postman |
| 19 | PKCE method S256 only | Phase 1 | Postman |
| 20 | Audience validation | Phase 5 | Postman |
| 21 | Feature flags enforced | Phase 1 | Postman |
| 22 | DCR restrictions | Phase 1 | Postman |
| 23 | Bootstrap scope limited | Phase 5 | Postman |

## 7. Skill Invocation Map

Every skill is a checkboxed TASK — not a comment.

| Phase | Skills | Count |
|-------|--------|-------|
| 0 | `context7`, `sharp-edges` | 2 |
| 1 | `configuring-oauth2-authorization-flow`, `postman`, `claude-in-chrome` | 3 |
| 2 | `context7`, `claude-in-chrome`, `verification-before-completion` | 3 |
| 3 | `context7`, `supply-chain-risk-auditor`, `hardening-docker-containers`, `verification-before-completion` | 4 |
| 4 | `securing-serverless-functions`, `zero-trust-network`, `entry-point-analyzer`, `security-headers-audit`, `claude-in-chrome`, `systematic-debugging` | 6 |
| 5 | `insecure-defaults`, `owasp-top-10`, `supply-chain-risk-auditor`, `spec-to-code-compliance`, `second-opinion`, `postman:security`, `verification-before-completion` | 7 |
| **Total** | | **25 skill invocations** |

## 8. Files from v4 to Cherry-Pick (audit every line)

### Keep (after line-by-line audit)
- `keycloak/Dockerfile` — battle-tested, 8 deploy iterations
- `keycloak/realm-fluid.json` — stripped to importable fields
- `keycloak/.dockerignore`
- `sidecars/apollo/Dockerfile` — multi-stage Rust build
- `sidecars/devmcp/Dockerfile` + `package.json`
- `sidecars/sheets/Dockerfile` + `requirements.txt`
- `bootstrap/bootstrap.py` + `Dockerfile` + `requirements.txt`
- `scripts/setup-cloud-sql-v4.sh` — idempotent DB setup
- `scripts/setup-iam-v4.sh` — SA creation
- `scripts/setup-alb.sh` — ALB + Cloud Armor
- `scripts/setup-monitoring.sh` — alert policies
- `scripts/setup-cloud-sql-security.sh` — hardening
- `scripts/test-v4-regression.sh` — regression suite
- `deploy/cloud-run-gateway.yaml` — multi-container template
- `deploy/cloud-run-keycloak-live.yaml` — working Keycloak config
- `deploy/cloudbuild.yaml` — 10-step pipeline
- `deploy/cloud-armor.yaml` — WAF rules
- `config/.digests` — verified image digests
- `tests/keycloak/test_realm_json.py` — realm validation
- `tests/bootstrap/test_bootstrap.py` — bootstrap validation

### Delete (redundant — replaced by configuration)
- `plugins/resolve_user.py` — replaced by SSO_KEYCLOAK_ENABLED
- `plugins/config.yaml` — not needed
- `plugins/__init__.py` — not needed
- `tests/plugins/test_resolve_user.py` — not needed
- `tests/plugins/__init__.py` — not needed
- `scripts/gateway-entrypoint.sh` — replaced by direct DATABASE_URL
- `deploy/Dockerfile.gateway-v4` — replaced by base image + env vars
- `scripts/check-jwks-ready.sh` — marginal, startup probe handles this

## 9. GCP Resources to Reuse

| Resource | Status | Action |
|----------|--------|--------|
| Cloud SQL `contextforge` instance | Running | Reuse |
| Database `keycloak` | Created | Reuse |
| Database `contextforge` | Exists | Reuse |
| Secret `keycloak-db-password` | Created | Reuse |
| Secret `keycloak-admin-password` | Created | Reuse |
| SA `gateway-sa` | Created | Reuse |
| SA `keycloak-sa` | Created | Reuse |
| Cloud Run `keycloak` service | v4.0.4 live | Keep, verify in Phase 1 |
| Keycloak client `fluid-gateway-sso` | Created | Reuse |
| Cloud SQL authorized networks 0.0.0.0/0 | TEMP | Restrict in Phase 5 |

## 10. Cost Budget

| Phase | Expected Cost | Rationale |
|-------|-------------|-----------|
| 0 | ~$3 | Research only, no builds |
| 1 | ~$2 | Postman + curl, no deploys |
| 2 | ~$2 | Local docker-compose, no cloud |
| 3 | ~$5 | Build 4 sidecar images |
| 4 | ~$5 | Max 3 Cloud Run deploys |
| 5 | ~$5 | Security scans + hardening |
| **Total** | **~$22** | **vs $43 in v4 (49% reduction)** |

## 11. Rollback Strategy

v5 deploys as a **NEW Cloud Run service** (`fluid-intelligence-v5`), parallel to v3 (`fluid-intelligence`). v3 continues running until v5 passes all 23 acceptance criteria. Only then is v3 decommissioned.

If v5 fails:
- Delete `fluid-intelligence-v5` Cloud Run service
- v3 continues serving (unaffected)
- Keycloak continues running (shared, not tied to gateway version)

This zero-downtime approach means v5 deployment is risk-free to the existing system.

## 12. Cloud SQL Final-State Connectivity

**Keycloak (Java/JDBC):** Public IP with restricted authorized networks (Cloud Run egress IP ranges only, not 0.0.0.0/0). JDBC URL: `jdbc:postgresql://PUBLIC_IP:5432/keycloak`. VPC connector not used because JDBC doesn't support Unix sockets without a socket factory JAR.

**ContextForge (Python/SQLAlchemy):** Cloud SQL connector annotation (`--add-cloudsql-instances`) with Unix socket. DATABASE_URL: `postgresql://user:pass@/contextforge?host=/cloudsql/INSTANCE`.

This is documented because v4 tried 5 different connection methods before finding these.

## 13. What This Spec Does NOT Cover

- Tenant context injection (Phase 6 — separate spec after v5 is working)
- Google OAuth client credentials (requires Google Cloud Console setup by user)
- Custom domain (junlinleather.com → Cloud Run mapping)
- v3 decommission (after v5 is verified)
