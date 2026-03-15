# Shopify OAuth Service — Design Spec

**Date:** 2026-03-16
**Status:** Approved
**Author:** Claude + JunLin

## Problem

The gateway currently uses Shopify's `client_credentials` grant at startup to obtain an access token. This has two problems:

1. **Tokens expire in 24 hours** (`expires_in: 86399`). The gateway fetches once at startup — if the container runs >24h, the token dies silently.
2. **Single-tenant only.** One hardcoded store (`junlinleather-5148`). No path to multi-merchant support.

The "Install app" button in the Shopify Dev Dashboard triggers an OAuth authorization code grant flow, but the gateway has no callback endpoint to handle it.

## Solution

A standalone Cloud Run service (`shopify-oauth`) that handles Shopify's OAuth authorization code grant flow. It stores permanent offline access tokens in Cloud SQL. The gateway reads tokens from the database instead of fetching them via client_credentials at startup.

## Architecture

```
Merchant clicks "Install app" in Shopify Admin / Dev Dashboard
    │
    ▼
GET shopify-oauth/auth/install?shop=xxx&hmac=xxx&timestamp=xxx
    │  ← Validate HMAC, generate nonce, store in signed cookie
    ▼
302 → https://{shop}/admin/oauth/authorize
        ?client_id={client_id}
        &scope={scopes}
        &redirect_uri=https://shopify-oauth-XXXX.run.app/auth/callback
        &state={nonce}
    │
    ▼
Merchant approves scopes on Shopify consent screen
    │
    ▼
GET shopify-oauth/auth/callback?code=xxx&shop=xxx&hmac=xxx&state=xxx
    │  ← Validate HMAC + nonce + shop hostname
    │  ← POST https://{shop}/admin/oauth/access_token (exchange code for token)
    │  ← INSERT/UPDATE shopify_installations in Cloud SQL
    ▼
200 "Installation complete" page (or redirect to Shopify admin)
```

### Deployment Topology

```
Cloud Run: shopify-oauth (scale-to-zero)
    ├── Python/FastAPI (~100 lines)
    ├── Connects to Cloud SQL (junlinleather-mcp:asia-southeast1:contextforge)
    └── Reads secrets: shopify-client-id, shopify-client-secret

Cloud Run: fluid-intelligence (existing gateway)
    └── entrypoint.sh reads token from Cloud SQL instead of client_credentials
```

Two independent services. The OAuth service writes tokens; the gateway reads them. No coupling beyond the shared database table.

## Database Schema

New table in the existing `contextforge` PostgreSQL database:

```sql
CREATE TABLE IF NOT EXISTS shopify_installations (
    id SERIAL PRIMARY KEY,
    shop_domain TEXT NOT NULL UNIQUE,
    shop_id BIGINT,
    access_token_encrypted TEXT NOT NULL,
    scopes TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    installed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_shopify_installations_shop_domain
    ON shopify_installations(shop_domain);
CREATE INDEX IF NOT EXISTS idx_shopify_installations_status
    ON shopify_installations(status);
```

- `shop_domain`: e.g. `junlinleather-5148.myshopify.com` (unique constraint — one token per store)
- `shop_id`: Shopify's stable numeric store ID (fetched from `/admin/api/{version}/shop.json` after install). Domains can change; IDs don't.
- `access_token_encrypted`: AES-256-GCM encrypted offline token. Encrypted at application layer using a dedicated key from GCP Secret Manager (`shopify-token-encryption-key`). Cloud SQL disk encryption alone is insufficient — it doesn't protect against SQL injection, backup exposure, or DB admin access.
- `scopes`: granted scopes string for audit trail
- `status`: `active`, `uninstalled`, or `suspended`. Soft-delete preserves audit trail.
- `updated_at`: tracks re-installations (scope changes trigger new token)

On re-install (same shop), the existing row is updated (UPSERT) with the new token, scopes, and `status='active'`.

## OAuth Endpoints

### `GET /auth/install`

**Purpose:** Entry point for Shopify app installation.

**Query parameters from Shopify:**
- `shop` — store domain (e.g. `junlinleather-5148.myshopify.com`)
- `hmac` — HMAC-SHA256 signature of all other params
- `timestamp` — request timestamp

**Logic:**
1. Validate `shop` hostname: `^[a-zA-Z0-9][a-zA-Z0-9\-]*\.myshopify\.com$`
2. Validate HMAC using client secret (timing-safe comparison)
3. Validate timestamp staleness: reject if `abs(now - timestamp) > 300` seconds (prevents replay attacks)
4. Generate cryptographically random nonce (32 bytes, hex-encoded)
5. Store nonce in signed cookie (signed with HKDF-derived key from client secret, not the raw secret)
6. Redirect (302) to: `https://{shop}/admin/oauth/authorize?client_id={client_id}&scope={scopes}&redirect_uri={callback_url}&state={nonce}`

### `GET /auth/callback`

**Purpose:** Receive authorization code from Shopify, exchange for access token.

**Query parameters from Shopify:**
- `code` — authorization code
- `shop` — store domain
- `hmac` — HMAC-SHA256 signature
- `state` — nonce (must match cookie)
- `timestamp` — request timestamp

**Logic:**
1. Validate `shop` hostname
2. Validate HMAC using client secret (timing-safe comparison)
3. Validate `state` matches nonce from signed cookie
4. Exchange code for token:
   ```
   POST https://{shop}/admin/oauth/access_token
   Content-Type: application/x-www-form-urlencoded

   client_id={client_id}&client_secret={client_secret}&code={code}
   ```
5. Parse response: `{ "access_token": "...", "scope": "..." }`
6. Encrypt access token with AES-256-GCM using key from Secret Manager (`shopify-token-encryption-key`)
7. UPSERT into `shopify_installations` (insert or update on shop_domain conflict, set `status='active'`)
8. Fetch `shop_id` from `GET https://{shop}/admin/api/2026-01/shop.json` and update the row
9. Register mandatory webhooks (`APP_UNINSTALLED`, GDPR webhooks) via Shopify API
10. Return success page with link back to Shopify admin

### `GET /health`

Returns `200 OK` with `{"status": "ok"}`. Used by Cloud Run startup/liveness probes.

### `POST /webhooks/app-uninstalled`

**Purpose:** Handle Shopify's `APP_UNINSTALLED` webhook when a merchant removes the app.

**Logic:**
1. Validate HMAC-SHA256 of the request body using client secret (Shopify signs webhook payloads)
2. Extract `shop_domain` from the webhook payload
3. Update `shopify_installations` row: set `status = 'uninstalled'`, clear `access_token_encrypted`
4. Return `200 OK`

Registered automatically during OAuth callback via `POST /admin/api/2026-01/webhooks.json`.

### `POST /webhooks/gdpr/{topic}`

**Purpose:** Handle Shopify's three mandatory GDPR webhooks. Required for all apps.

**Topics:** `customers/redact`, `shop/redact`, `customers/data_request`

**Logic:**
1. Validate HMAC-SHA256 of the request body
2. Log the request for audit
3. For `shop/redact`: set installation status to `uninstalled`, clear token
4. For `customers/redact` and `customers/data_request`: log and return 200 (this service stores no customer PII)

### `GET /auth/status`

**Purpose:** Debugging endpoint. Returns installation status for a given shop.

**Query parameters:** `shop` (required)
**Auth:** Requires `Authorization: Bearer {admin_token}` (internal use only)

**Response:** `{"shop": "...", "installed": true, "status": "active", "scopes": "...", "installed_at": "..."}`

## Security

| Concern | Mitigation |
|---------|------------|
| Request forgery | HMAC-SHA256 validation on every Shopify request |
| Replay attacks | Timestamp staleness check (reject if >5 min old) |
| CSRF | Cryptographic nonce in signed cookie, validated on callback |
| Timing attacks | `hmac.compare_digest()` for all comparisons |
| Invalid shops | Regex validation: `^[a-zA-Z0-9][a-zA-Z0-9\-]*\.myshopify\.com$` |
| Token at rest | AES-256-GCM application-layer encryption + GCP disk encryption |
| Token in transit | HTTPS enforced (Cloud Run default) |
| Secret exposure | Client ID/secret from Secret Manager, never in code or logs |
| Cookie signing | HKDF-derived key (not raw client secret) prevents credential leak via cookie vulnerabilities |
| Webhook forgery | HMAC-SHA256 validation on all webhook payloads |
| GDPR compliance | Mandatory `customers/redact`, `shop/redact`, `customers/data_request` endpoints |

## Gateway Changes

### entrypoint.sh Modification

Replace the `client_credentials` fetch (lines 91-128) with a database read:

```bash
# NEW: Read encrypted token from Cloud SQL, decrypt with KMS key
# Uses /app/.venv/bin/python (ContextForge's venv has psycopg2)
SHOPIFY_ACCESS_TOKEN=$(DB_PASSWORD="$DB_PASSWORD" ENCRYPTION_KEY="$SHOPIFY_TOKEN_ENCRYPTION_KEY" \
  /app/.venv/bin/python3 -c "
import os, psycopg2
from cryptography.fernet import Fernet  # or AES-GCM via cryptography lib
conn = psycopg2.connect(
    dbname=os.environ.get('DB_NAME', 'contextforge'),
    user=os.environ.get('DB_USER', 'contextforge'),
    password=os.environ['DB_PASSWORD'],
    host='/cloudsql/junlinleather-mcp:asia-southeast1:contextforge'
)
cur = conn.cursor()
cur.execute(
    'SELECT access_token_encrypted FROM shopify_installations WHERE shop_domain = %s AND status = %s',
    (os.environ.get('SHOPIFY_STORE', ''), 'active')
)
row = cur.fetchone()
if row:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    import base64
    key = base64.b64decode(os.environ['ENCRYPTION_KEY'])
    data = base64.b64decode(row[0])
    nonce, ct = data[:12], data[12:]
    print(AESGCM(key).decrypt(nonce, ct, None).decode())
conn.close()
")

if [ -z "$SHOPIFY_ACCESS_TOKEN" ]; then
    echo "[entrypoint] WARNING: No Shopify token in database for $SHOPIFY_STORE"
    echo "[entrypoint] Install the app first via the Shopify Dev Dashboard"
    # Fall back to client_credentials for backward compatibility
    # ... existing client_credentials code ...
fi
export SHOPIFY_ACCESS_TOKEN
```

**Backward compatibility:** If no token exists in the database (app not yet installed via OAuth), fall back to the existing `client_credentials` flow. This ensures the gateway works during the migration period.

### mcp-config.yaml — No Changes

Apollo still reads `SHOPIFY_ACCESS_TOKEN` from the environment. The source changes (database vs client_credentials), but the interface stays the same.

## Shopify App TOML Update

```toml
client_id = "f597c0aaa02fac7278a54c617d7b344d"
name = "JunLin MCP Server"
application_url = "https://shopify-oauth-XXXX.asia-southeast1.run.app/auth/install"
embedded = false

[access_scopes]
scopes = "read_analytics,read_app_proxy,..."  # existing full scope string
use_legacy_install_flow = false

[auth]
redirect_urls = ["https://shopify-oauth-XXXX.asia-southeast1.run.app/auth/callback"]
```

The exact Cloud Run URL will be known after first deployment. Update TOML and `shopify app deploy --force` to push.

## File Structure

```
deploy/
  shopify-oauth/
    Dockerfile           # Lightweight Python image
    cloudbuild.yaml      # Build + deploy to Cloud Run
    requirements.txt     # fastapi, uvicorn, psycopg2-binary, httpx
services/
  shopify-oauth/
    main.py              # FastAPI app + route handlers
    db.py                # Database connection, UPSERT, encryption
    security.py          # HMAC validation, nonce generation, timestamp check
    webhooks.py          # APP_UNINSTALLED + GDPR webhook handlers
```

## Deployment

### Cloud Run Configuration

```yaml
--region=asia-southeast1
--platform=managed
--allow-unauthenticated          # Shopify must reach callback
--add-cloudsql-instances=junlinleather-mcp:asia-southeast1:contextforge
--set-secrets=SHOPIFY_CLIENT_ID=shopify-client-id:latest,SHOPIFY_CLIENT_SECRET=shopify-client-secret:latest,DB_PASSWORD=db-password:latest,SHOPIFY_TOKEN_ENCRYPTION_KEY=shopify-token-encryption-key:latest
--set-env-vars=DB_USER=contextforge,DB_NAME=contextforge
--min-instances=0                 # Scale to zero
--max-instances=2                 # Installs are rare
--cpu=1 --memory=256Mi            # Minimal resources
```

### CI/CD

Separate Cloud Build trigger on `deploy/shopify-oauth/` path. Pushes to main trigger build + deploy.

## Testing

1. **Unit tests:** HMAC validation, nonce generation, shop hostname validation
2. **Integration test:** Mock Shopify token endpoint, verify full flow writes to DB
3. **Manual E2E:** Click "Install app" in Dev Dashboard, verify token appears in Cloud SQL, verify gateway reads it

## Migration Path

1. Deploy `shopify-oauth` service
2. Update Shopify TOML with real URLs, deploy via CLI
3. Click "Install app" — token stored in Cloud SQL
4. Update gateway `entrypoint.sh` to read from DB (with client_credentials fallback)
5. Redeploy gateway
6. Verify gateway uses DB token
7. Once stable, remove client_credentials fallback code

## New Secret Required

Create a 256-bit AES encryption key in Secret Manager:

```bash
python3 -c "import os, base64; print(base64.b64encode(os.urandom(32)).decode())" | \
  gcloud secrets create shopify-token-encryption-key --data-file=- --project=junlinleather-mcp
```

Both the OAuth service and the gateway need access to this secret.

## Cost Impact

- Cloud Run scale-to-zero: ~$0/month (installs happen once per merchant)
- No new Cloud SQL instance (shared existing `contextforge` database)
- One new secret (`shopify-token-encryption-key`): ~$0.06/month
- Total additional cost: effectively $0

## Future Considerations

- **Scope changes:** When new scopes are added to the TOML, existing merchants must re-authorize. Shopify supports incremental authorization (shows only the scope delta). This can be triggered by redirecting merchants to `/admin/oauth/authorize` with the new scope set.
- **Token rotation:** Shopify offline tokens are permanent, but a `/auth/rotate` endpoint could force re-authorization for security incidents.
- **Multi-vertical:** When adding Stripe, QuickBooks, etc., this service can evolve into a shared `backend-oauth` service with per-provider handlers, or each vertical gets its own service.
