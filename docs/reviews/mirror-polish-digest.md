# Mirror Polish Digest — Batches 1–47

## Summary

| Metric | Value |
|--------|-------|
| Batches covered | 1–47 (rounds R1–R480) |
| Total review angles | 470 |
| Total issues fixed | ~100 |
| Fix trend | 10/batch (B1-3) → steady decline → 0-2/batch (B15+) |
| First clean batch | Batch 18 (R181–R190) |
| Status at Batch 47 | Counter reset to 0/5 (1 defect found in R471) |

**Fix trend by phase:**
- Batches 1–5: Fundamental architectural gaps (10 fixes each). mcp-auth-proxy stays, identity propagation, GDPR bugs, phase inversion.
- Batches 6–9: Operational issues (4→3→1, then spike back to 10 when Batch 8 was all-Simple and Batch 9 restored proper complexity mix).
- Batches 10–17: Cross-document consistency (4–6 each). .env.example, runbook, CLAUDE.md.
- Batches 15–17: 1 defect each (stale timeout, SSRF description inverted, operation name).
- Batch 18: First clean batch (R181–R190).
- Batches 19–20: Clean (2/5, 3/5).
- Batch 21: Reset (README version discrepancy).
- Batches 22–25: Clean (1/5 → 4/5).
- Batch 26: Reset (4 issues — stale counts, MCPGATEWAY_PORT direction inverted).
- Batches 27–29: Clean (1/5 → 3/5... wait counter resets at B28/B30).
- Late batches (30–47): Typically 0–2 defects. Recurring: V4 batch count drifts; behavioral misdescriptions surface occasionally.

---

## Defect Categories

| Category | Count | Last Batch | Example |
|----------|-------|------------|---------|
| Architectural gap / wrong design claim | ~14 | B9 | R2: ContextForge cannot be OAuth 2.1 AS; R13: sidecars lose startup gating; R90: phase dependency inversion |
| v3 production bugs found during review | 3 | B5 | R15: Apollo mutation_mode not set; R29: webhook swallows DB errors; R48: GDPR handlers are no-ops |
| Security / compliance gap | 6 | B16 | R32: AUTH_ENCRYPTION_SECRET aliased from JWT_SECRET_KEY; R33: no error sanitization policy; R161: SSRF description inverted |
| Identity / auth design gap | 3 | B9 | R23: AUTH_REQUIRED=false makes audit anonymous; R83: identity not forwarded to ContextForge; R90: phase inversion on identity propagation |
| Stale count or version (config/doc) | ~12 | B47 | R40: v3 spec superseded; R264/R301/R376/R401/R433: V4 batch count drift; R131: scope count stale |
| Incorrect operational order/behavior | ~8 | B47 | R342: OAuth install validation order wrong; R422: callback validation order wrong; R351: timestamp < vs <=; R471: dev-mcp tool count internal inconsistency |
| Missing critical documentation | ~9 | B45 | R27: audit gaps; R121: runbook missing secret; R126: runbook blind to shopify-oauth service; R452: AUTH_ENCRYPTION_SECRET/PLATFORM_ADMIN_PASSWORD absent from env vars table |
| Cross-document inconsistency | ~8 | B14 | R101: .env.example missing SHOPIFY_TOKEN_ENCRYPTION_KEY; R110: crypto.py dual-deployment undocumented; R140: CLAUDE.md graphql count wrong |
| Behavioral misdescription | ~7 | B47 | R337: "Apollo SHA-256 verified" (it is built from source, no checksum); R338: "5 secrets shared" (actually 4); R431: Apollo probe "TCP check" (actually HTTP GET /sse); R392: "no error log" on key failure (it IS logged) |
| Stale numeric value (timeout/line count) | ~10 | B47 | R144: runbook 180s vs 120s; R171: singular vs plural operation name; R282: localhost vs 127.0.0.1; R387/R393: convergence "2 consecutive" description oscillated through 2 corrections |

---

## Key Decisions

**Architecture (permanent rulings):**
- **mcp-auth-proxy stays** (R2/B1): ContextForge cannot serve MCP OAuth 2.1 AS (/.well-known, DCR, PKCE). This is a hard architectural boundary.
- **Shopify OAuth stays as separate service** (R3/B1): ContextForge plugins cannot add HTTP routes.
- **Sidecars do NOT solve crash cascade** (R1/B1): Any sidecar crash recycles the entire Cloud Run instance. Single-container process-supervisor model is superior.
- **`execute` tool is query-only** (R15/B2 + R21/B3 + R24/B3): No mutation_mode configured. Critical design fact — 20 on-disk mutations are NOT accessible.
- **Identity propagation is Phase 1, not optional** (R23/B3): AUTH_REQUIRED=false makes all audit trail anonymous. This single fix enables per-user audit, rate limiting, and RBAC.
- **Phase structure must respect plugin stability boundary** (R90/B9): Phase 1 = no plugins required. Phase 2 = built-in plugins only. Phase 3 = custom plugins. "Plugins are Phase 3" was propagated to Phase 1 items, creating a circular dependency.
- **VS UUID stability requires thin routing layer** (R17/B2): ServerUpdate cannot modify associated_tools. VS recreation changes UUID, breaking all clients. Named-alias proxy is the Phase 1 fix.
- **Architecture Issue #12 added** (R83/B9): Identity lost at proxy boundary — directly contradicts "identity-first" product value proposition.

**Operational (permanent rulings):**
- **AUTH_ENCRYPTION_SECRET must be decoupled from JWT_SECRET_KEY** (R32/B4): Rotating JWT also rotates database encryption key, silently destroying stored credentials.
- **SSE sessions limited by Cloud Run --timeout** (R64/B7): Default 300s disconnects mid-session. Must set --timeout=3600.
- **Bootstrap convergence needs minimum floor ~70** (R86/B9 + R471/B47): Convergence check accepts any stable non-zero count. Expected: Apollo ~7 + dev-mcp ~50+ + sheets ~17 = ~74+.
- **Latency budget must be configured** (R81/B9): No inner-layer timeouts. Shopify 30s hangs are invisible and cause duplicate mutations on retry.

**Documentation rulings:**
- **Defect criteria tightened at Batch 15**: Only factual errors, missing critical info, security vulnerabilities, or behavioral inconsistencies. Cosmetic/style issues do NOT reset counter.
- **v3 spec marked SUPERSEDED** (R40/B4): 5 material contradictions with deployed system. docs/architecture.md is authoritative.
- **Cross-reference, don't merge** (B14): KL, Architecture Issues, and Risk Register serve different purposes. Add "Related: Issue #N" pointers.

---

## Verified-Clean Angles (Exclusion List)

All the following were verified clean and should NOT be re-checked in future batches unless there is specific reason to believe the underlying code changed.

**Repeatedly verified (5+ times, extremely stable):**
- Startup probe: failureThreshold=48 × periodSeconds=5 = 240s TCP :8080
- Token fallback backoff: 5 attempts, sleep $((attempt*2)) → 2s/4s/6s/8s between attempts 1-4
- GraphQL file count: 30 total (5 products + 25 other); 25 non-product breakdown: customers=5, orders=8+1discount, fulfillments=1, inventory=2, metafields=2, transfers=6
- script line counts: entrypoint.sh=321, bootstrap.sh=284
- 9 secrets in GCP Secret Manager (confirmed in both cloudbuild files and secrets table)
- OAuth service: CPU=1, memory=256Mi, min=0, max=2
- Component versions: Apollo v1.9.0, mcp-auth-proxy v2.5.4, tini v0.19.0, uv v0.10.10, dev-mcp v1.7.1, google-sheets v0.6.0

**Cloud Run & infrastructure (verified clean):**
- R39: Logging verbosity (INFO, within free tier)
- R42: Cold start time budget (~15-20s, 240s probe window)
- R51: min-instances=0 trade-off (deliberate)
- R52: DB_POOL_SIZE=5 (correctly sized)
- R61: Cloud SQL db-f1-micro no-HA (documented, appropriate for workload)
- R63: Container disk (tmpfs usage minimal)
- R66: Ingress (accept all, auth at application layer)
- R71: --cpu-boost + --no-cpu-throttling combination
- R75: Cloud SQL maintenance window (~60s monthly)
- R79: Cloud SQL proxy Unix socket (no VPC connector needed)

**Security implementation (verified clean):**
- R43: Git secrets (no secrets in history, .gitignore correct)
- R46: License compatibility (all MIT/Apache/LGPL)
- R69: SSRF configuration (localhost/private exemptions required for same-container backends)
- R176: AES-256-GCM nonce = 96-bit os.urandom (NIST SP 800-38D compliant)
- R206: Webhook HMAC uses hmac.compare_digest (constant-time)
- R235: OAuth nonce generated with os.urandom, stored in signed HttpOnly cookie
- R243: OAuth flow (HMAC, nonces, cookies, token exchange all technically accurate)
- R402: HMAC SHA-256, timestamp TIMESTAMP_MAX_AGE=300 with <= operator, shop hostname regex correct

**Process & startup (verified clean):**
- R53: Private app, no App Store review required
- R54: entrypoint.sh set -euo pipefail with correct suppressions
- R59: SHOPIFY_STORE used consistently across all references
- R60: Architecture doc ToC completeness (all sections present)
- R68: PID file races (shell variables used; files for debugging only)
- R74: Only tools capability advertised (correct MCP behavior)
- R77: Dynamic bootstrap superior to catalog file for wait-and-verify
- R91: OAuth service DB connections protected by try/finally
- R95: Bootstrap JWT 10-minute expiry (well within timing budget)
- R108: Sync DB calls in async webhook handlers (max-instances=2, rare traffic)
- R141-R150: OAuth error handling, SIGTERM propagation, bootstrap errors, Cloud Run config, .env.example completeness, Dockerfile COPY paths, crypto.py error handling, CPU/memory values
- R163: Tool convergence partial-tools (documented in Risk R8)
- R175: entrypoint.sh env var validation block complete
- R182-R190: cloudbuild env vars, OAuth redirect URIs, API version consistency, DB column names, webhook HMAC, Cloud Run service names, auth-proxy flags, file count, startup probe
- R203-R210: Cloud SQL socket path, EXTERNAL_URL regex, VS creation payload, op file counts, OAuth Dockerfile, shopify-schema 98K lines, mcp-config env vars
- R241-R250: 15 OAuth scope names valid, ASCII diagram correct, OAuth flow accuracy, DATABASE_URL format, tini -g behavior, startup timing consistency, bash variable expansions, auth-proxy launch args, graphql count, "5 processes" across 5 references
- R283: SIGTERM+SIGINT trap (SIGINT is implementation detail for local dev)
- R309: tini -g in Dockerfile ENTRYPOINT
- R344: start_and_verify = sleep 2s then kill -0 PID check
- R345: SIGTERM trap description (doc describes Cloud Run scenario only, SIGINT is additional)
- R362: Nonce "signed HttpOnly cookie" (two cookies nonce+sig, summary is accurate)
- R364: SIGTERM cleanup sends to 5 steady-state PIDs
- R365: exit 143 = 128+15=SIGTERM
- R369: execute tool has no mutation_mode or overrides in mcp-config.yaml
- R421: Apollo binary compiled from source, installed as /usr/local/bin/apollo
- R423: tini -g flag in ENTRYPOINT
- R424: Token loading uses direct psycopg2, not DATABASE_URL (correctly shows 1 token fetch + 5 pool = ~6 total)
- R425-R430: AUTH_REQUIRED=false, TRANSPORT_TYPE=all, SSRF flags (3 confirmed), 4 shared secrets, MCPGATEWAY_ADMIN_API_ENABLED=true, MCPGATEWAY_UI_ENABLED=false
- R435: VS named "fluid-intelligence" in bootstrap.sh
- R453: bootstrap.sh comment "dev-mcp 90s" is stale (actual 120s) but architecture.md correctly says 120s
- R455: ContextForge health endpoint is /health NOT /healthz
- R456: PLATFORM_ADMIN_EMAIL=admin@junlinleather.com in both entrypoint.sh and cloudbuild.yaml
- R472: Callback nonce omits verify_nonce_signature (incompleteness, not false — doc says "signed")
- R474: JWT generated via ContextForge Python venv (primary path; fallback to system python3 not mentioned, acceptable)
- R475: Container exits with exit 1 (doc says "exits" without claiming value — correct)
- R477: Nonce cookies have samesite="lax" but doc doesn't claim this attribute
- R479: "1 entrypoint token fetch" is transient psycopg2 connection that closes after read

---

## Rulings (Precedent for Future Batches)

**What counts as a defect:**
- A claim in docs/architecture.md that directly contradicts source code (wrong value, wrong order, wrong algorithm, wrong count that cannot be explained by rounding or summarization)
- Missing critical operational info required to debug production failures (precedent: R452 — AUTH_ENCRYPTION_SECRET/PLATFORM_ADMIN_PASSWORD)
- Security misdescriptions that could mislead operators (precedent: R161 — SSRF inversion)
- Internal consistency violations between sections of the same document (precedent: R471 — dev-mcp tool count "~20" vs "~50+" in same doc)

**What does NOT count as a defect:**
- Summaries that omit implementation details without making false claims (R472: omits nonce signature verification; R383: shows decoded URL form)
- Cosmetic differences that are functionally identical (localhost vs 127.0.0.1 in illustrative text when code block is correct; escaped vs unescaped hyphen in character class)
- Constraints/attributes not mentioned (R448: NOT NULL not in schema table; R449: base64 encoding not specified for webhook HMAC)
- Implementation details appropriately omitted from architecture level (Rust version, psycopg2-binary version)
- Stale bootstrap.sh inline comments — the defect lives in the script's comment, not in architecture.md

**Recurring trap — V4 batch count:**
The line "Accumulated corrections from N batches of Mirror Polish design review (~M review angles)" in V4 Design Directions drifts and has been found stale in batches 26, 37, 40, and 43. Future batches should update this line proactively as part of every session rather than treating it as a defect each time. The recurring fix wastes counter resets.

**Complexity mix is mandatory:**
Batch 8 (all Simple angles) found 1 defect. Batch 9 (proper 4 Complex / 4 Medium / 2 Simple mix) found 10. All-Simple batches are artificially easy and produce dishonest results. Every batch must maintain a non-trivial complexity distribution.

**Meta-counts reset the counter:**
The V4 batch count is self-referential (the batch report documents its own staleness) but still counts as a genuine defect per the protocol. It resets the counter. Pre-emptive updates at every session avoid this.

**Convergence description oscillated:**
R387 (B38) changed "2 consecutive equal counts" to "3 consecutive equal readings." R393 (B39) corrected this back to "2 consecutive equal readings" with a more precise explanation. The final settled description: "2 consecutive equal readings — stable increments on each iteration where TOOL_COUNT equals prev_count and is >0; loop breaks when stable reaches 2, meaning 2 back-to-back iterations must return the same non-zero count." Do not re-examine convergence semantics unless bootstrap.sh changes.

---

*Digest compiled 2026-03-16. Covers batches 1–47 (R1–R480). Individual batch files deleted after digest creation.*
