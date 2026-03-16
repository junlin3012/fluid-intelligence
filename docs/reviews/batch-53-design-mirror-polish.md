# Mirror Polish Batch 53 — Design Review of `docs/architecture.md`

**Rounds**: R531–R540
**Counter**: 2/5 consecutive clean batches needed (resets to 0/5 if any defect found)
**Complexity mix**: 4 Complex, 4 Medium, 2 Simple
**Defects found**: 0
**Fixes applied**: 0

---

## Methodology

Read `docs/architecture.md` in full (1123 lines), then verified 10 completely fresh angles against source files:

- `scripts/entrypoint.sh` (process orchestrator, 321 lines)
- `scripts/bootstrap.sh` (backend registration, 284 lines)
- `deploy/Dockerfile.base` (fat base image)
- `deploy/Dockerfile` (thin app image)
- `deploy/cloudbuild.yaml` (gateway deploy pipeline)
- `deploy/cloudbuild-base.yaml` (base image build pipeline)
- `deploy/shopify-oauth/cloudbuild.yaml` (OAuth service deploy)
- `services/shopify_oauth/main.py` (OAuth install/callback handlers)
- `services/shopify_oauth/webhooks.py` (webhook handlers)
- `services/shopify_oauth/db.py` (database operations)
- `services/shopify_oauth/security.py` (HMAC, nonce, timestamp validation)
- `services/shopify_oauth/config.py` (settings from environment)
- `services/shopify_oauth/crypto.py` (AES-256-GCM encryption)
- `config/mcp-config.yaml` (Apollo MCP Server configuration)

Note: This batch fills the gap between batches 52 and 54, which were already completed in prior sessions. Protocol was already completed twice (Batch 52: 5/5, Batch 55: 5/5). Fresh angles chosen from areas not covered in any prior batch.

---

## Review Rounds

### R531 (Complex) — `config.py` `DB_HOST` default: OAuth service hardcodes production Cloud SQL socket path

**Doc claim** (Database section, line 599):
```
- **Connection**: Unix socket via Cloud SQL Proxy (`/cloudsql/...`)
```

And (OAuth Service Environment Variables, line 693):
```
Secrets: `SHOPIFY_CLIENT_ID`, `SHOPIFY_CLIENT_SECRET`, `DB_PASSWORD`, `SHOPIFY_TOKEN_ENCRYPTION_KEY` (same GCP Secret Manager secrets as gateway).
```

**Source** (`services/shopify_oauth/config.py`, line 33):
```python
@property
def DB_HOST(self) -> str:
    return os.environ.get("DB_HOST", "/cloudsql/junlinleather-mcp:asia-southeast1:contextforge")
```

The OAuth service's `config.py` defaults `DB_HOST` to the same production Cloud SQL socket path as the gateway's `entrypoint.sh` inline Python (line 101: `host='/cloudsql/junlinleather-mcp:asia-southeast1:contextforge'`). The doc says both services connect via Unix socket to Cloud SQL. The default in `config.py` is not set via `cloudbuild.yaml` env vars (only `DB_USER`, `DB_NAME` are set), so the hardcoded default IS the connection mechanism in production. The doc's "Unix socket via Cloud SQL Proxy" claim is accurate for both services.

**Verdict**: CLEAN

---

### R532 (Complex) — `upsert_installation` SQL: `installed_at` not in INSERT columns — relies on DEFAULT NOW() to guarantee "First install time"

**Doc claim** (Database section, shopify_installations table, line 629):
```
| installed_at | TIMESTAMPTZ | First install time |
```

**Source** (`services/shopify_oauth/db.py`, lines 24–33):
```sql
INSERT INTO shopify_installations (shop_domain, shop_id, access_token_encrypted, scopes, status, updated_at)
VALUES (%s, %s, %s, %s, 'active', NOW())
ON CONFLICT (shop_domain) DO UPDATE SET
    shop_id = COALESCE(EXCLUDED.shop_id, shopify_installations.shop_id),
    access_token_encrypted = EXCLUDED.access_token_encrypted,
    scopes = EXCLUDED.scopes,
    status = 'active',
    updated_at = NOW();
```

And the `CREATE TABLE` definition (lines 15–16):
```sql
installed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
```

The `INSERT` column list explicitly omits `installed_at`, so it is set only by `DEFAULT NOW()` on initial row creation. The `ON CONFLICT ... DO UPDATE` clause does NOT include `installed_at`, leaving it unchanged on reinstall. Therefore `installed_at` retains the timestamp of the first installation even after a reinstall. The doc's "First install time" description is accurate.

**Verdict**: CLEAN

---

### R533 (Complex) — `install` handler no-HMAC branch: validates shop hostname first, then returns app home HTML — doc acknowledges this path

**Doc claim** (Service Endpoints table, lines 250–251):
```
| `/auth/install` | GET | Start OAuth install flow / app home page |
```

**Source** (`services/shopify_oauth/main.py`, lines 70–72):
```python
if not received_hmac:
    safe_shop = shop if validate_shop_hostname(shop) else ""
    return HTMLResponse(content=_app_home_html(safe_shop), status_code=200)
```

When the `/auth/install` request has no `hmac` parameter (e.g., Shopify loads it as an iframe), the handler performs a `validate_shop_hostname(shop)` call on the provided `shop` query parameter before constructing the HTML response. A valid shop hostname is passed to `_app_home_html`; an invalid one returns empty string for the shop display. The 200 HTML response for the no-HMAC case is the "app home page" path the doc acknowledges in the endpoint description. The doc's "Start OAuth install flow / app home page" correctly describes both paths (with HMAC = install flow, without HMAC = app home page).

**Verdict**: CLEAN

---

### R534 (Complex) — `register_gateway` retry sleep: `sleep "$attempt"` called AFTER increment, producing sleeps of 2s and 3s

**Doc claim**: The doc (Bootstrap Registration Pipeline, lines 552–558) does NOT state specific retry intervals for backend gateway registration — only for the Shopify token fallback (lines 179–180): "5 attempts with linear backoff (sleep 2s, 4s, 6s, 8s between attempts)". No claim about `register_gateway` retry timing.

**Source** (`scripts/bootstrap.sh`, lines 83–113):
```bash
local max_attempts=3 attempt=1
while [ "$attempt" -le "$max_attempts" ]; do
  ...
  attempt=$((attempt + 1))
  sleep "$attempt"
done
```

`sleep "$attempt"` is called AFTER `attempt=$((attempt + 1))`. On first failure: attempt becomes 2, sleep 2. On second failure: attempt becomes 3, sleep 3. On third failure: FATAL (no sleep, loop exits). Actual sleep intervals are 2s and 3s between the 3 attempts — not 1s, 2s, 3s. The doc makes no specific claim about `register_gateway` retry timing, so there is no false statement here. The `register_gateway` retry count (3 attempts) is also not stated in the doc — both are omissions, not errors.

**Verdict**: CLEAN (doc makes no claim about register_gateway retry specifics)

---

### R535 (Medium) — `get_connection()` in db.py uses `connect_timeout=5` — not documented in architecture doc

**Doc claim**: The Database section (lines 595–634) does not mention a connection timeout for the OAuth service's database connection.

**Source** (`services/shopify_oauth/db.py`, lines 36–45):
```python
def get_connection(dsn: str | None = None):
    if dsn:
        return psycopg2.connect(dsn)
    return psycopg2.connect(
        dbname=settings.DB_NAME,
        user=settings.DB_USER,
        password=settings.DB_PASSWORD,
        host=settings.DB_HOST,
        connect_timeout=5,
    )
```

`connect_timeout=5` (5 seconds) is configured for all OAuth service DB connections. The doc's Health Endpoints table says the `/health` endpoint "tests DB connectivity" — this test would fail within 5s rather than hanging indefinitely. The architecture doc does not claim any specific connection timeout for the OAuth service. Omission of this implementation detail is not a factual error.

**Verdict**: CLEAN (implementation detail not claimed in doc)

---

### R536 (Medium) — `exchange_code_for_token` uses `httpx.post` with `timeout=30` and `raise_for_status()` — not in doc

**Doc claim** (Install Flow, line 215):
```
|  Exchange code for permanent offline access token
```

**Source** (`services/shopify_oauth/main.py`, lines 158–170):
```python
def exchange_code_for_token(shop: str, code: str) -> tuple[str, str]:
    try:
        r = httpx.post(
            f"https://{shop}/admin/oauth/access_token",
            data={"client_id": ..., "client_secret": ..., "code": code},
            timeout=30,
        )
        r.raise_for_status()
        data = r.json()
        return data.get("access_token", ""), data.get("scope", "")
    except Exception as e:
        log.error(f"Token exchange failed for {shop}: {e}")
        return "", ""
```

The token exchange uses `timeout=30` (30 seconds) and `raise_for_status()`. On any HTTP error or timeout, the exception is caught and `("", "")` is returned, which causes the callback to return HTTP 502 (`if not access_token: return Response("Token exchange failed", status_code=502)`). The doc's install flow diagram correctly shows the callback as "Exchange code for permanent offline access token" and "200 Connected Successfully" for success. The 30s timeout and error handling are implementation details; the doc makes no false claim by omitting them.

**Verdict**: CLEAN (implementation detail not claimed in doc)

---

### R537 (Medium) — `cloudbuild-base.yaml` timeout `3600s` consistent with doc's "~20 min" build time claim

**Doc claim** (Deployment Architecture, line 507):
```
- Build time: 5s for app changes vs ~20 min for base rebuild
```

**Source** (`deploy/cloudbuild-base.yaml`, lines 16–18):
```yaml
timeout: '3600s'
options:
  machineType: 'E2_HIGHCPU_8'
```

The `cloudbuild-base.yaml` sets a 3600s (1 hour) pipeline timeout. The doc says the base build takes "~20 min" — this is the expected duration, not the timeout. Cloud Build timeouts are maximum bounds; actual duration is typically much shorter. A 1-hour timeout for a ~20-minute build provides substantial headroom (3× margin) for network variance and slow Rust compilation under high load. The doc's "~20 min" claim and the `timeout: '3600s'` in source are consistent — they describe different things (expected duration vs maximum allowed time). No false claim.

**Verdict**: CLEAN

---

### R538 (Medium) — `mcp-config.yaml` `introspection.execute.enabled: true` and `validate.enabled: true` match doc's "2 dynamic tools"

**Doc claim** (Apollo MCP Server section, lines 435–441):
```
#### Dynamic Tools (2)

| Tool | Description |
|------|-------------|
| **execute** | Execute arbitrary GraphQL queries at runtime (validated against schema) |
| **validate** | Validate GraphQL syntax without executing |
```

And (Tool Catalog Overview, line 351):
```
Apollo loads predefined `.graphql` operations from configured paths and provides 2 dynamic tools.
```

**Source** (`config/mcp-config.yaml`, lines 32–36):
```yaml
introspection:
  execute:
    enabled: true
  validate:
    enabled: true
```

Both `execute` and `validate` are explicitly enabled in `mcp-config.yaml`. The doc claims exactly 2 dynamic tools — one for execution, one for validation. The config has exactly 2 introspection tool entries, both enabled. The tool names `execute` and `validate` as used in the doc match the Apollo MCP Server's standard tool naming for these introspection capabilities.

**Verdict**: CLEAN

---

### R539 (Simple) — `--add-cloudsql-instances` in both gateway and OAuth service `cloudbuild.yaml` configs

**Doc claim** (Database section, line 597):
```
- **Instance**: Cloud SQL PostgreSQL, `junlinleather-mcp:asia-southeast1:contextforge`
```

And (Database section, line 599):
```
- **Connection**: Unix socket via Cloud SQL Proxy (`/cloudsql/...`)
```

**Source** (`deploy/cloudbuild.yaml`, line 24):
```
'--add-cloudsql-instances=junlinleather-mcp:asia-southeast1:contextforge'
```

**Source** (`deploy/shopify-oauth/cloudbuild.yaml`, line 20):
```
'--add-cloudsql-instances=junlinleather-mcp:asia-southeast1:contextforge'
```

Both services mount the same Cloud SQL instance: `junlinleather-mcp:asia-southeast1:contextforge`. This matches the doc's instance name claim and confirms the Unix socket path `DATABASE_URL` in the gateway (`?host=/cloudsql/junlinleather-mcp:asia-southeast1:contextforge`) and the `config.py` default in the OAuth service (`/cloudsql/junlinleather-mcp:asia-southeast1:contextforge`) both refer to the same instance. The instance name is consistent across all references.

**Verdict**: CLEAN

---

### R540 (Simple) — `shopify-schema.graphql` in app image diagram and Cloud Run memory rationale

**Doc claim** (Deployment Architecture, app image diagram, line 496):
```
|  +-- shopify-schema.graphql (98K lines)      |
```

And (Cloud Run Configuration, Gateway table, line 573):
```
| Memory | **4Gi** | 5 processes + 98K-line schema. 2Gi caused OOM. |
```

**Source** (`deploy/Dockerfile`, line 12):
```dockerfile
COPY shopify-schema.graphql /app/shopify-schema.graphql
```

**Source** (file count):
```
$ wc -l shopify-schema.graphql
98082 shopify-schema.graphql
```

The schema file is 98,082 lines, which the doc rounds to "98K lines" — accurate. The Dockerfile COPYs it to `/app/shopify-schema.graphql`. The memory rationale cites both the 5 processes and the schema file loading as contributing to the 4Gi requirement (previously 2Gi caused OOM). All three doc claims are consistent with source.

**Verdict**: CLEAN

---

## Summary

| Round | Complexity | Angle | Verdict |
|-------|------------|-------|---------|
| R531 | Complex | `config.py` `DB_HOST` defaults to production Cloud SQL socket path `/cloudsql/junlinleather-mcp:asia-southeast1:contextforge` — same as gateway; doc's Unix socket claim accurate | CLEAN |
| R532 | Complex | `upsert_installation` UPSERT: `installed_at` omitted from INSERT columns, set by `DEFAULT NOW()` only; `ON CONFLICT` does not update it — "First install time" confirmed | CLEAN |
| R533 | Complex | `install` handler no-HMAC branch: validates `shop` hostname before returning app home HTML; doc's "app home page" acknowledgment accurate | CLEAN |
| R534 | Complex | `register_gateway` retry: `sleep "$attempt"` called after increment → sleeps 2s, 3s between 3 attempts; doc makes no claim about registration retry timing | CLEAN |
| R535 | Medium | `get_connection()` in `db.py` uses `connect_timeout=5`; doc doesn't claim this — omission, not a false claim | CLEAN |
| R536 | Medium | `exchange_code_for_token` uses `httpx.post(timeout=30)` and `raise_for_status()`; doc doesn't claim these details — omission, not a false claim | CLEAN |
| R537 | Medium | `cloudbuild-base.yaml` `timeout: '3600s'` (1 hour max) is consistent with doc's "~20 min" expected build duration — different concepts | CLEAN |
| R538 | Medium | `mcp-config.yaml` has `execute.enabled: true` and `validate.enabled: true` — exactly 2 dynamic tools as doc claims | CLEAN |
| R539 | Simple | `--add-cloudsql-instances=junlinleather-mcp:asia-southeast1:contextforge` in both `cloudbuild.yaml` files confirms doc's instance name and Unix socket path | CLEAN |
| R540 | Simple | `shopify-schema.graphql` is 98,082 lines (doc says "98K lines"); Dockerfile COPYs it; memory rationale ("98K-line schema") all consistent | CLEAN |

**Defects found**: 0
**Fixed inline**: 0
**Counter**: 3/5 — (Batch 51 = 1/5, Batch 52 = 5/5 COMPLETE, gap here [Batch 53], Batch 54 = 1/5 after gap reset, Batch 55 = 5/5 COMPLETE)

Note: Since this batch fills the retroactive gap between batches 52 and 54, the counter state is informational. Protocol was already completed twice before this batch was written.

---

## Notes on Angles Explored but Not Flagged

The following angles were considered and confirmed either clean or out of scope before selecting the 10 above:

- **`register_gateway` 409 handling**: `bootstrap.sh` line 103 treats HTTP 409 (already exists) as success. Doc says "delete stale ... then register" — delete first should prevent 409, but 409 is treated as graceful. Not a doc claim.
- **`_app_home_html` function**: Returns 200 with HTML for the iframe home page. Doc says "app home page" path exists. Consistent.
- **`upsert_installation` COALESCE for shop_id**: `COALESCE(EXCLUDED.shop_id, shopify_installations.shop_id)` preserves existing shop_id on reinstall if new value is NULL. Doc doesn't describe this merge logic — implementation detail.
- **`fetch_shop_id` called after `store_installation`**: The shop_id is stored in a separate `UPDATE` query after `store_installation` sets the initial row (without shop_id). The doc shows this as a single "Fetch shop numeric ID" step — accurate at the level of abstraction.
- **`cloudbuild-base.yaml` `images` field**: Lists the base image for Cloud Build artifact tracking. `cloudbuild.yaml` (app) has no `images` field. Not a doc claim.
- **`mcp-config.yaml` `transport.type: stdio`**: Apollo runs in stdio mode and is bridged to SSE by `mcpgateway.translate`. Doc says "Apollo bridge (Rust->stdio->SSE)". Consistent.
- **`headers` block in `mcp-config.yaml`**: `X-Shopify-Access-Token: ${env.SHOPIFY_ACCESS_TOKEN}` injects the token. Doc says "Apollo reads this env var once." The `${env.VAR_NAME}` syntax is noted in the mcp-config.yaml comment. Not a new finding.
