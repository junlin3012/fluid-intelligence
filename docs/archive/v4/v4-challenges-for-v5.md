# v4 Challenges & Setbacks — Required Reading for v5

> Every mistake documented here cost real time and money. v5 agents MUST read this before writing ANY code or deploying ANYTHING.

---

## Challenge 1: Configuration vs Code (MOST CRITICAL)

**What happened:** Built 741 lines of custom Python code (resolve_user plugin + tests + config) to bridge Keycloak auth into ContextForge. Spent ~8 hours debugging plugin loading, JWT verification, and role mapping.

**What should have happened:** Set `SSO_KEYCLOAK_ENABLED=true` and 8 other env vars. Total time: 5 minutes.

**Root cause:** The v4 spec said "build a resolve_user plugin" — written before discovering ContextForge has native Keycloak SSO. The implementing agent followed the spec literally instead of verifying the premise.

**v5 rule:** Before writing ANY custom code that connects two applications:
1. Read BOTH applications' integration docs
2. Use `context7` to search for built-in integrations
3. If a built-in integration exists, USE IT
4. Custom code is a last resort, not a first instinct

---

## Challenge 2: Deploy-and-Pray (15 Failed Deploys)

**What happened:** 8 Keycloak deploys + 7 Gateway deploys, each revealing a new configuration gap. Each deploy cycle cost ~5 minutes (build) + ~3 minutes (deploy) + ~2 minutes (verify) = ~150 minutes of waiting.

**Failures that should have been caught locally:**
- `KC_FEATURES` wrong syntax → `docker run` locally would have shown this
- `userProfile` not importable → `docker run --import-realm` locally would have shown this
- `clientProfiles` executor not found → same
- `asyncpg` module missing → `docker run` locally would have shown this
- `DATABASE_URL` not set → `docker run` locally would have shown this
- HTTP vs HTTPS issuer → `docker-compose up` would have shown this
- Admin console broken → `docker-compose up` and opening browser would have shown this

**v5 rule:**
1. ALWAYS run `docker-compose up` first and verify in browser
2. NEVER deploy to Cloud Run until docker-compose works perfectly
3. Each Cloud Run deploy should be the FINAL step, not the first debugging step

---

## Challenge 3: Keycloak Realm Import Limitations

**What happened:** The realm JSON included `userProfile`, `clientProfiles`, and `clientPolicies` sections. All three were rejected during import:
- `userProfile` → "Unrecognized field" (not in RealmRepresentation)
- `secure-response-type-executor` → "no executor provider found"
- `confidential-client-executor` → same
- `pkce-enforcer` → would have failed too (not tested)

**Root cause:** Keycloak's realm IMPORT accepts a SUBSET of what realm EXPORT produces. The JSON format documented online is the export format — not all fields are importable.

**v5 rule:**
1. Keep realm JSON MINIMAL — only fields that are universally importable: realm settings, clients, client scopes, identity providers, roles, event config, brute force config
2. Configure everything else POST-IMPORT via Admin API or bootstrap script
3. Test realm import with `docker run keycloak --import-realm` LOCALLY before deploying

---

## Challenge 4: Cloud SQL Connectivity from Cloud Run

**What happened:** Tried 5 different JDBC connection methods before finding one that works:
1. Direct public IP → Cloud Run can't reach without authorized networks
2. Cloud SQL connector + `socketFactory` → JAR not in Keycloak image
3. `?host=/cloudsql/` → PGJDBC doesn't support this format
4. `127.0.0.1:5432` → Cloud SQL connector only provides Unix sockets, not TCP
5. `?unixSocketPath=` → Keycloak's Quarkus/Agroal strips JDBC URL params

**Working solution:** Public IP with authorized networks (0.0.0.0/0 for dev). The JDBC URL is simply `jdbc:postgresql://IP:5432/keycloak`.

**For ContextForge (Python):** Cloud SQL connector works because Python/SQLAlchemy supports Unix sockets via `?host=/cloudsql/INSTANCE` in the DATABASE_URL.

**v5 rule:**
1. Keycloak (Java/JDBC) → use public IP with authorized networks, or VPC connector with private IP
2. ContextForge (Python/SQLAlchemy) → use Cloud SQL connector annotation with Unix socket URL
3. Test DB connectivity in docker-compose FIRST (PostgreSQL container, same URL format)

---

## Challenge 5: Keycloak 26.x Breaking Changes

**What happened:** Multiple breaking changes from older Keycloak docs:
- Feature flags: `KC_FEATURES=feature:disabled` → `--features-disabled=feature` CLI flag
- Health endpoints: need `--health-enabled=true` at BUILD time (not runtime)
- Admin bootstrap: need `KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD` env vars
- Hostname: need `KC_HOSTNAME=https://...` + `KC_PROXY_HEADERS=xforwarded` for Cloud Run
- `KC_HOSTNAME_STRICT_HTTPS` → deprecated, use `KC_HOSTNAME` instead

**v5 rule:**
1. Use `context7` for EVERY Keycloak configuration option
2. Use version-specific docs (26.x, not generic)
3. Test with `docker run` locally before deploying

---

## Challenge 6: ContextForge Auth Architecture Misunderstanding

**What happened:** Misunderstood how ContextForge auth works:
- `AUTH_REQUIRED` controls admin UI auth AND MCP endpoint auth (not separately)
- `MCP_CLIENT_AUTH_ENABLED` only controls MCP-specific JWT validation
- ContextForge has its OWN JWT system (HMAC) separate from Keycloak's (RS256)
- `/docs` is FastAPI Swagger — returns JSON 401, not a browser redirect
- SSO login is an API endpoint (`/auth/sso/login/{provider}`) that returns JSON, not a redirect
- `PLUGINS_ENABLED=true` + `PLUGIN_CONFIG_FILE` required to load any plugin
- `MCPGATEWAY_UI_ENABLED=true` needed for UI features
- `BASIC_AUTH_PASSWORD` is different from `PLATFORM_ADMIN_PASSWORD`
- `DATABASE_URL` must be constructed — ContextForge doesn't read `CLOUDSQL_INSTANCE`

**v5 rule:**
1. Read ContextForge's FULL env var list via `context7` before setting ANY config
2. Use `SSO_KEYCLOAK_ENABLED=true` for Keycloak integration (not custom plugins)
3. Test EVERY UI flow in browser, not just API calls with curl

---

## Challenge 7: Cloud Run YAML Gotchas

**What happened:**
- `terminationGracePeriodSeconds` not supported in single-container Knative YAML
- TCP liveness probes not supported (only HTTP or gRPC)
- `allUsers` invoker binding lost when service is deleted/recreated
- `--startup-cpu-boost` flag doesn't exist (it's `--cpu-boost`)
- `--startup-probe-type` flag doesn't exist (use YAML instead)
- `gcloud run services replace` doesn't do env var substitution in YAML

**v5 rule:**
1. Use `gcloud run deploy` with `--set-env-vars` for simple deploys
2. Use `gcloud run services replace` with YAML only for multi-container
3. Always re-add `allUsers` invoker after service delete/recreate
4. Use `context7` for Cloud Run YAML format verification

---

## Challenge 8: Skipped Skills and Verification

**What happened:** The v4 plan mandated 15+ security and verification skills. None were invoked during implementation:
- `configuring-oauth2-authorization-flow` → would have caught SSO config path
- `claude-in-chrome` → would have caught browser UI issues immediately
- `verification-before-completion` → would have caught the 401/login issues
- `insecure-defaults` → would have caught 0.0.0.0/0 authorized networks
- `systematic-debugging` → would have structured the 15-deploy debugging

**v5 rule:**
1. Skills are MANDATORY, not optional
2. Invoke `configuring-oauth2-authorization-flow` BEFORE any auth config
3. Invoke `claude-in-chrome` AFTER every deploy to test browser flows
4. Invoke `verification-before-completion` BEFORE claiming any task is done
5. Invoke `systematic-debugging` after the FIRST failed deploy, not the eighth

---

## Challenge 9: Cost

**Session cost:** ~$43 for v4 implementation
**Useful work:** ~$15 (infrastructure scripts, Dockerfiles, realm JSON, CI/CD pipeline)
**Wasted work:** ~$28 (redundant plugin, 15 failed deploys, debugging config issues)

**v5 budget rule:**
1. Local docker-compose verification before ANY Cloud Build ($0.50-1.00 per build)
2. Maximum 3 Cloud Run deploys per component (plan → deploy → fix → done)
3. If a deploy fails 3 times, STOP and use `systematic-debugging` skill

---

## Challenge 10: Mandatory Skills Not Invoked (MOST CONCERNING)

**What happened:** The v4 plan listed 15+ mandatory skills across 7 phases. ZERO security skills were invoked during implementation. The `mandatory-skills.md` rule says "Before ANY task, check if a skill applies. This is mandatory, not optional." This rule was directly violated.

**Skills that were available but never invoked:**
- `configuring-oauth2-authorization-flow` — would have caught SSO config path
- `testing-oauth2-implementation-flaws` — would have caught HTTP vs HTTPS issuer
- `hardening-docker-containers-for-production` — CIS benchmark
- `implementing-secrets-management-with-vault` — secret injection review
- `securing-serverless-functions` — Cloud Run attack surface
- `testing-api-security-with-owasp-top-10` — OWASP validation
- `performing-security-headers-audit` — HTTP headers
- `implementing-zero-trust-network-access` — VPC/network
- `insecure-defaults` (Trail of Bits) — would have caught 0.0.0.0/0
- `supply-chain-risk-auditor` (Trail of Bits) — dep audit
- `entry-point-analyzer` (Trail of Bits) — attack surface mapping
- `sharp-edges` (Trail of Bits) — dangerous patterns
- `verification-before-completion` — would have caught every UI issue
- `claude-in-chrome` — would have caught browser login failures immediately
- `systematic-debugging` — would have structured the 15 failed deploys

**Root cause analysis — 4 structural failures:**

1. **`subagent-driven-development` displaced skill discipline.** The subagent workflow became the dominant process. It dispatches implementer → spec review → code review per task. But it has NO step for invoking security/verification skills. The controller was busy managing 4-6 concurrent subagents and never paused to invoke skills.

2. **Speed pressure displaced skill discipline.** Parallel execution and fast iteration meant the controller optimized for throughput (dispatch next task) rather than quality (invoke security skill first). Each skill invocation takes 30-60 seconds — multiplied by 26 tasks, that's 13-26 minutes of "overhead" that was silently skipped.

3. **The plan listed skills as comments, not as executable tasks.** Each phase had "MANDATORY SKILL INVOCATIONS" at the top, but these were formatted as documentation, not as checkboxed tasks. The `subagent-driven-development` executor read the plan for TASKS (checkbox items) and ignored the skill invocation headers.

4. **No enforcement mechanism exists.** The `mandatory-skills.md` rule is advisory — it relies on agent discipline. There is no hook, no gate, no automated check that blocks implementation when a mandatory skill hasn't been invoked. Under pressure, advisory rules are the first to be dropped.

**What must change for v5:**

1. **Skills must be TASKS in the plan** — actual checkboxed steps like `- [ ] Invoke configuring-oauth2-authorization-flow`, not comments above a phase
2. **Skill invocation before subagent dispatch** — the controller MUST invoke the relevant skill BEFORE dispatching any implementer for that phase
3. **`verification-before-completion` as a hard gate** — must run before marking ANY task complete
4. **`claude-in-chrome` after EVERY deploy** — automated browser test, not manual curl
5. **Skill invocation logged in commit messages** — so there's an audit trail of which skills were actually invoked

---

## Summary: The 5 Rules for v5

1. **Configure first, code never** — exhaust env vars and admin APIs. Custom code is a code smell.
2. **Local first, cloud last** — docker-compose up → browser test → Cloud Run deploy.
3. **Read docs before touching config** — use `context7` for every external component.
4. **Invoke skills, don't skip them** — especially OAuth, browser testing, verification.
5. **3-deploy limit** — if it doesn't work after 3 deploys, stop and debug systematically.
