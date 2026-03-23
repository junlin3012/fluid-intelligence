# Token Service — Enterprise Credential Lifecycle Manager

**Date**: 2026-03-24
**Status**: Draft (pending user review)
**Author**: Claude + Jun Lin
**Services affected**: New `token-service`, modified `apollo`
**Review**: Spec review round 1 — 4 critical, 6 major, 6 minor issues found and fixed

## 1. Problem Statement

Shopify's expiring offline access tokens live for **60 minutes** with a rotating refresh token (90-day TTL). Apollo MCP Server is a Rust binary that reads `SHOPIFY_ACCESS_TOKEN` as a static environment variable at startup — it has no mechanism to refresh tokens.

As of April 1, 2026, all new Shopify public apps are required to use expiring tokens. The current stack has **no credential lifecycle management**. When the token expires, Apollo fails silently with 401 errors from Shopify.

## 2. Design Principles

1. **Tokens live in PostgreSQL, not Secret Manager.** OAuth tokens rotate hourly — they belong in a database. Secret Manager holds static secrets (encryption keys, client secrets, DB passwords). Validated against: Nango, Stripe Secret Store, Shopify's own guidance.

2. **The proxy IS the consumer.** No secret propagation (no rolling restarts, no volume mounts, no pub/sub). The credential proxy reads from the DB via token-service on every request. Token refreshes are invisible to Apollo. Validated against: Nango proxy pattern, Netflix Edge Authentication.

3. **Services never hold third-party credentials.** Apollo has zero knowledge of Shopify tokens. The credential proxy injects them per-request. Validated against: Google Envoy/service mesh, Netflix Zuul Passport injection.

4. **Proactive + lazy refresh.** Background timer keeps tokens fresh; lazy refresh on `/token/{provider}` catches anything the timer missed. Validated against: Nango's dual-strategy pattern.

5. **Multi-provider from day one.** The schema and API are provider-agnostic. Shopify is the first row in the table, not a special case. Adding Google Sheets, Meta, Klaviyo is config, not code.

## 3. Architecture

### 3.1 System Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          GCP (junlinleather-mcp)                        │
│                                                                         │
│  ┌─── Cloud Run: token-service (min=1, max=1) ──────────────────────┐  │
│  │  FastAPI :8000                                                    │  │
│  │  ├── GET /token/{provider}     (IAM-protected, for proxy)         │  │
│  │  ├── GET /connect/{provider}   (OAuth bootstrap)                  │  │
│  │  ├── GET /callback/{provider}  (OAuth callback)                   │  │
│  │  ├── POST /rotate/{provider}   (manual refresh)                   │  │
│  │  ├── GET /health               (all providers' status)            │  │
│  │  ├── GET /metrics              (Prometheus)                       │  │
│  │  └── Background: proactive refresh loop (every 45 min)            │  │
│  └───────────────────────────┬───────────────────────────────────────┘  │
│                              │ reads/writes                             │
│                              ▼                                          │
│  ┌─── Cloud SQL PostgreSQL (existing instance) ──────────────────────┐  │
│  │  oauth_credentials table (encrypted tokens, per-provider)         │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                              ↑                                          │
│  ┌─── Cloud Run: apollo (multi-container) ───────────────────────┐     │
│  │                                                                │     │
│  │  Container 1: Apollo MCP Server :8000                          │     │
│  │    → sends GraphQL to localhost:8080 (no credentials)          │     │
│  │                                                                │     │
│  │  Container 2: credential-proxy :8080                           │     │
│  │    → GET token-service/token/shopify (30s cache)               │     │
│  │    → injects X-Shopify-Access-Token header                     │     │
│  │    → forwards to Shopify API                                   │     │
│  │    → returns response to Apollo                                │     │
│  └────────────────────────────────────────────────────────────────┘     │
│                                                                         │
│  ┌─── Secret Manager (static secrets only) ──────────────────────────┐ │
│  │  shopify-client-secret, token-encryption-key, db-password          │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│  ┌─── Cloud Monitoring ──────────────────────────────────────────────┐ │
│  │  Scrapes /metrics, fires alerts on Tier 1/2 conditions             │ │
│  └────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 New Service: token-service

- **Runtime**: Python 3.12, FastAPI, uvicorn
- **Cloud Run config**: min-instances=1, max-instances=1, 256MB RAM, 1 vCPU, `--cpu-always-allocated` (required for background refresh loop — without this, Cloud Run freezes CPU between requests, silently killing the timer)
- **Port**: 8000
- **Database**: Existing Cloud SQL PostgreSQL instance (`contextforge`)
- **DB pool**: `DB_POOL_SIZE=2`, `DB_MAX_OVERFLOW=2` (token-service needs at most 2 concurrent connections)
- **Static secrets** (from Secret Manager): `shopify-client-secret`, `token-encryption-key`
- **Env vars**: `FORWARDED_ALLOW_IPS=*` (required for uvicorn behind Cloud Run's HTTPS proxy)

### 3.2.1 Database Connection Budget

The existing Cloud SQL instance (`db-f1-micro`) has `max_connections=50`. Budget after token-service:

| Service | Pool size | Max overflow | Worst case |
|---|---|---|---|
| ContextForge (2 workers) | 5 x 2 = 10 | 5 x 2 = 10 | 20 |
| Keycloak | 2 | 3 | 5 |
| **token-service** | **2** | **2** | **4** |
| **Total** | | | **29 of 50** |

Headroom: 21 connections for future services or connection spikes.

### 3.3 Modified Service: apollo

Apollo's Cloud Run service becomes multi-container:

- **Container 1**: Apollo MCP Server (unchanged Rust binary, port 8000)
- **Container 2**: credential-proxy (new, Python, port 8080)

Apollo's `config.yaml` changes:

```yaml
# BEFORE
endpoint: https://junlinleather-5148.myshopify.com/admin/api/2026-01/graphql.json
headers:
  X-Shopify-Access-Token: ${env.SHOPIFY_ACCESS_TOKEN}

# AFTER
endpoint: http://localhost:8080/admin/api/2026-01/graphql.json
headers: {}
```

Apollo no longer holds any credentials.

## 4. Database Schema

Uses the existing Cloud SQL PostgreSQL instance. New table:

```sql
CREATE TABLE oauth_credentials (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    provider                 TEXT NOT NULL,              -- 'shopify', 'google_sheets', etc.
    account_id               TEXT NOT NULL,              -- 'junlinleather-5148.myshopify.com'

    -- Encrypted tokens (AES-256-GCM, application-level)
    encrypted_access_token   TEXT NOT NULL,
    encrypted_refresh_token  TEXT,                       -- NULL for client_credentials providers

    -- Lifecycle
    token_expires_at         TIMESTAMPTZ NOT NULL,
    refresh_token_expires_at TIMESTAMPTZ,                -- 90-day countdown for Shopify
    scopes                   TEXT,                        -- 'read_products,write_products,...'

    -- Operational
    status                   TEXT NOT NULL DEFAULT 'active',  -- active, error, requires_reauth
    failure_count            INT NOT NULL DEFAULT 0,
    last_refreshed_at        TIMESTAMPTZ,
    last_error               TEXT,

    -- Metadata
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE(provider, account_id)
);

CREATE INDEX idx_credentials_expiry
    ON oauth_credentials(token_expires_at)
    WHERE status = 'active';
```

### Encryption

- **Database-level**: Cloud SQL encrypts all data at rest (GCP-managed AES-256, always on).
- **Application-level**: Tokens encrypted with AES-256-GCM before DB write, decrypted on read. Key stored in Secret Manager (`token-encryption-key`). Defense in depth.

## 5. API Specification

### 5.1 Token Vending

```
GET /token/{provider}
```

**Access**: IAM-protected. Only `credential-proxy` service account.

**Response** (200):
```json
{
  "access_token": "shpat_...",
  "expires_in": 1847,
  "provider": "shopify",
  "account_id": "junlinleather-5148.myshopify.com"
}
```

**Behavior**:
1. Read credential from DB (or in-memory cache, 30s TTL).
2. If `expires_at > now() + 5 min` → return token (happy path, ~1ms).
3. If `expires_at < now() + 5 min` → trigger lazy refresh inline.
4. Single-flight lock: only one refresh per provider at a time; concurrent requests await the result.
5. On refresh failure → return 503.

**Response** (503 — token expired and refresh failed):
```json
{
  "error": "refresh_failed",
  "provider": "shopify",
  "last_error": "invalid_grant",
  "requires_reauth": true
}
```

### 5.2 OAuth Bootstrap

```
GET /connect/{provider}
```

**Access**: Temporarily public during initial setup, then IAM-locked.

**Behavior**: Builds the provider's OAuth authorization URL and redirects the browser. For Shopify:

```
→ 302 Redirect to:
https://{shop_domain}/admin/oauth/authorize?
  client_id=f597c0aaa02fac7278a54c617d7b344d&
  scope=read_products,write_products,read_customers,write_customers,
        read_orders,write_orders,read_draft_orders,write_draft_orders,
        read_inventory,write_inventory,read_fulfillments,write_fulfillments,
        read_discounts,write_discounts,read_locations&
  redirect_uri=https://token-service-apanptkfaq-as.a.run.app/callback/shopify&
  state={signed_nonce}&
  expiring=1
```

**Note**: `shop_domain` is `junlinleather-5148.myshopify.com` for v1. The `/connect` endpoint should accept `?shop=domain` as a query parameter for future multi-shop support. The `expiring=1` parameter opts into expiring offline tokens — after April 1, 2026 this becomes the default for all new public apps.

### 5.2.1 State Nonce Specification (CSRF Protection)

The `state` parameter prevents CSRF attacks on the OAuth callback:

- **Algorithm**: HMAC-SHA256
- **Key**: Derived from `token-encryption-key` (from Secret Manager) — no separate key needed
- **Payload**: `{provider}:{timestamp}:{random_16_bytes}`
- **Format**: `base64url(payload):base64url(hmac_signature)`
- **TTL**: 10 minutes (reject if `timestamp` is older)
- **Verification**: On `/callback`, decode state, verify HMAC, check timestamp < 10 min ago, check provider matches URL

```
GET /callback/{provider}
```

**Access**: Temporarily public during initial setup, then IAM-locked.

**Behavior**:
1. Verify `state` nonce (CSRF protection).
2. Exchange authorization code for tokens: `POST https://{shop}/admin/oauth/access_token`.
3. Encrypt tokens (AES-256-GCM).
4. `INSERT INTO oauth_credentials`.
5. Render success page.

### 5.3 Admin

```
POST /rotate/{provider}
```

**Access**: IAM-protected, admin only.

**Behavior**: Forces an immediate token refresh regardless of expiry time. Useful for incident response.

```
GET /status
```

**Access**: IAM-protected, admin only.

**Response** (200):
```json
{
  "providers": {
    "shopify": {
      "status": "active",
      "account_id": "junlinleather-5148.myshopify.com",
      "token_expires_in_seconds": 1847,
      "refresh_token_expires_in_days": 87,
      "last_refreshed_at": "2026-03-24T10:15:00Z",
      "failure_count": 0,
      "last_error": null
    }
  }
}
```

### 5.4 Health & Metrics

```
GET /health
```

**Access**: Public. Used by Cloud Run health checks. Minimal — no provider details exposed.

**Response** (200):
```json
{
  "status": "healthy"
}
```

**Response** (503 — any provider in error/requires_reauth state):
```json
{
  "status": "degraded"
}
```

```
GET /metrics
```

**Access**: **IAM-protected** (admin service account only). Exposes operational intelligence (provider names, error types, token TTL) that should not be public.

```
# HELP token_refresh_total Successful token refreshes
# TYPE token_refresh_total counter
token_refresh_total{provider="shopify"} 142

# HELP token_refresh_errors_total Failed token refreshes
# TYPE token_refresh_errors_total counter
token_refresh_errors_total{provider="shopify",error_type="network"} 2
token_refresh_errors_total{provider="shopify",error_type="invalid_grant"} 0

# HELP token_ttl_seconds Seconds until access token expires
# TYPE token_ttl_seconds gauge
token_ttl_seconds{provider="shopify"} 1847

# HELP refresh_token_ttl_days Days until refresh token expires
# TYPE refresh_token_ttl_days gauge
refresh_token_ttl_days{provider="shopify"} 87

# HELP token_vend_latency_seconds Token vend response time
# TYPE token_vend_latency_seconds histogram
token_vend_latency_seconds_bucket{provider="shopify",le="0.01"} 980
token_vend_latency_seconds_bucket{provider="shopify",le="0.1"} 995
token_vend_latency_seconds_bucket{provider="shopify",le="1"} 1000
```

## 6. Refresh Loop Algorithm

### 6.1 Proactive Refresh (Background Timer)

Runs every 45 minutes inside the token-service process:

```
1. SELECT * FROM oauth_credentials
   WHERE status = 'active'
   AND token_expires_at < now() + interval '15 minutes'

2. For each expiring credential:
   a. BEGIN TRANSACTION
   b. SELECT pg_advisory_xact_lock(hashtext(provider || ':' || account_id))
   c. Re-read row (another process may have refreshed since step 1)
   d. If still expiring:
      i.   POST https://{account_id}/admin/oauth/access_token
           Content-Type: application/x-www-form-urlencoded
           body: client_id={client_id}&client_secret={client_secret}&grant_type=refresh_token&refresh_token={refresh_token}

           Verified against: https://shopify.dev/docs/apps/build/authentication-authorization/access-tokens/offline-access-tokens

           Expected 200 response:
           {
             "access_token": "shpat_new...",
             "expires_in": 3600,
             "refresh_token": "shprt_new...",
             "refresh_token_expires_in": 7776000,
             "scope": "read_products,write_products,..."
           }

           CRITICAL: Both tokens rotate on every refresh. The old refresh_token is
           invalidated immediately after single use. This is why the single-flight
           lock (section 6.4) is essential.

      ii.  On 200: encrypt new tokens, UPDATE row (access_token, refresh_token,
           token_expires_at = now() + expires_in,
           refresh_token_expires_at = now() + refresh_token_expires_in,
           last_refreshed_at = now(), failure_count = 0)
      iii. On 400 {"error": "invalid_grant"}: UPDATE status='requires_reauth', fire CRITICAL alert
      iv.  On other error: INCREMENT failure_count, log error, schedule retry
   e. COMMIT (releases advisory lock)
```

### 6.2 Lazy Refresh (On-Demand via /token/{provider})

```
1. Check in-memory cache (30s TTL)
   → If fresh: return cached token (~0ms)

2. Read from DB
   → If token_expires_at > now() + 5 min: cache it, return it (~2ms)

3. Token near-expiry: trigger inline refresh
   a. Acquire in-memory single-flight lock for this provider
      → If another request is already refreshing: await its result
   b. Refresh (same Shopify POST as proactive)
   c. Atomic write to DB
   d. Update in-memory cache
   e. Return new token
```

### 6.3 Retry & Backoff

```
On transient failure (network error, 5xx from Shopify):
  Attempt 1: immediate
  Attempt 2: after 30 seconds
  Attempt 3: after 2 minutes
  Attempt 4: after 10 minutes
  After 4 failures: set status='error', fire WARNING alert, stop retrying

On invalid_grant (terminal — refresh token revoked/expired):
  Do NOT retry
  Set status='requires_reauth'
  Fire CRITICAL alert: "Provider {provider} requires re-authorization via /connect/{provider}"
```

### 6.4 Single-Flight Lock

Prevents concurrent refresh attempts from consuming a single-use refresh token:

```python
import asyncio

class SingleFlight:
    def __init__(self):
        self._locks: dict[str, asyncio.Future] = {}

    async def do(self, key: str, fn):
        if key in self._locks:
            return await self._locks[key]  # piggyback on in-flight refresh

        future = asyncio.get_event_loop().create_future()
        self._locks[key] = future
        try:
            result = await fn()
            future.set_result(result)
            return result
        except Exception as e:
            future.set_exception(e)
            raise
        finally:
            del self._locks[key]
```

## 7. Credential Proxy Specification

### 7.1 Purpose

A lightweight HTTP proxy that runs as a sidecar container in Apollo's Cloud Run service. It intercepts Apollo's outbound requests to Shopify, injects the `X-Shopify-Access-Token` header with a fresh token from token-service, and forwards to Shopify's API.

### 7.2 Implementation (~60 lines)

```python
import os
import time
import httpx
import google.auth.transport.requests
import google.oauth2.id_token
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request, Response

# Cloud Run: use actual service URL + IAM auth
# Local dev (docker-compose): use container name, no IAM
TOKEN_SERVICE_URL = os.environ.get(
    "TOKEN_SERVICE_URL",
    "https://token-service-apanptkfaq-as.a.run.app"
)
SHOPIFY_HOST = os.environ.get(
    "SHOPIFY_HOST",
    "https://junlinleather-5148.myshopify.com"
)
IS_CLOUD_RUN = os.environ.get("K_SERVICE") is not None  # Cloud Run sets K_SERVICE

# Connection-pooled HTTP clients (created once, reused for all requests)
token_client: httpx.AsyncClient = None
shopify_client: httpx.AsyncClient = None

@asynccontextmanager
async def lifespan(app):
    global token_client, shopify_client
    token_client = httpx.AsyncClient(base_url=TOKEN_SERVICE_URL, timeout=10)
    shopify_client = httpx.AsyncClient(base_url=SHOPIFY_HOST, timeout=30)
    yield
    await token_client.aclose()
    await shopify_client.aclose()

app = FastAPI(lifespan=lifespan)

@app.get("/health")
async def health():
    """Health endpoint for Cloud Run startup probe."""
    return {"status": "healthy"}

# In-memory token cache (30s TTL)
_cached_token: str | None = None
_cached_at: float = 0

def _get_iam_token() -> str:
    """Get an ID token for service-to-service auth on Cloud Run."""
    auth_req = google.auth.transport.requests.Request()
    return google.oauth2.id_token.fetch_id_token(auth_req, TOKEN_SERVICE_URL)

async def get_token() -> str:
    global _cached_token, _cached_at
    if _cached_token and time.time() - _cached_at < 30:
        return _cached_token

    headers = {}
    if IS_CLOUD_RUN:
        headers["Authorization"] = f"Bearer {_get_iam_token()}"

    resp = await token_client.get("/token/shopify", headers=headers)
    resp.raise_for_status()
    _cached_token = resp.json()["access_token"]
    _cached_at = time.time()
    return _cached_token

@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy(request: Request, path: str):
    token = await get_token()
    headers = {
        "X-Shopify-Access-Token": token,
        "Content-Type": request.headers.get("Content-Type", "application/json"),
    }

    resp = await shopify_client.request(
        method=request.method,
        url=f"/{path}",
        headers=headers,
        content=await request.body(),
    )
    return Response(
        content=resp.content,
        status_code=resp.status_code,
        headers=dict(resp.headers),
    )
```

**Key implementation details:**
- **Connection pooling**: `httpx.AsyncClient` instances are created once via FastAPI lifespan, reused across all requests. No per-request TCP connection overhead.
- **IAM authentication**: On Cloud Run, the proxy fetches an ID token from the metadata server and sends it as a Bearer token to token-service. Locally (docker-compose), IAM is skipped.
- **Environment detection**: `K_SERVICE` env var is set automatically by Cloud Run. Used to toggle IAM auth on/off.

### 7.3 Container Config

```dockerfile
FROM python:3.12-slim
WORKDIR /app
RUN pip install fastapi uvicorn httpx google-auth
COPY proxy.py .
CMD ["uvicorn", "proxy:app", "--host", "0.0.0.0", "--port", "8080"]
```

### 7.3.1 Cloud Run Multi-Container Deployment

Deploy via `gcloud` CLI (preferred over raw YAML for clarity):

```bash
gcloud run services replace apollo-service.yaml --region=asia-southeast1
```

Full `apollo-service.yaml`:

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: apollo
  annotations:
    run.googleapis.com/launch-stage: BETA
spec:
  template:
    metadata:
      annotations:
        # credential-proxy must start before apollo sends its first request
        run.googleapis.com/container-dependencies: '{"apollo": ["credential-proxy"]}'
    spec:
      containers:
        # Ingress container — receives external MCP traffic
        - name: apollo
          image: asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/apollo:latest
          ports:
            - containerPort: 8000
          resources:
            limits:
              memory: 512Mi
              cpu: "1"

        # Sidecar — injects Shopify credentials into outbound requests
        - name: credential-proxy
          image: asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/credential-proxy:latest
          ports:
            - containerPort: 8080
          env:
            - name: FORWARDED_ALLOW_IPS
              value: "*"
            - name: TOKEN_SERVICE_URL
              value: "https://token-service-apanptkfaq-as.a.run.app"
            - name: SHOPIFY_HOST
              value: "https://junlinleather-5148.myshopify.com"
          resources:
            limits:
              memory: 128Mi
              cpu: "0.5"
          startupProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 2
```

**Key annotations:**
- `container-dependencies`: ensures credential-proxy is ready before Apollo starts sending requests
- Apollo is the ingress container (has `ports` with `containerPort: 8000`)
- credential-proxy gets minimal resources (128MB, 0.5 vCPU) — it's a lightweight proxy

### 7.3.2 Local Development (docker-compose additions)

Since docker-compose does not support multi-container pods, the credential-proxy runs as a separate service. Apollo talks to it via Docker networking.

```yaml
# Add to docker-compose.yml:

  token-service:
    build: ./services/token-service
    ports:
      - "8010:8000"
    environment:
      - DATABASE_URL=postgresql://contextforge:${DB_PASSWORD}@postgres:5432/contextforge
      - DB_POOL_SIZE=2
      - DB_MAX_OVERFLOW=2
      - TOKEN_ENCRYPTION_KEY=${TOKEN_ENCRYPTION_KEY}
      - SHOPIFY_CLIENT_ID=${SHOPIFY_CLIENT_ID}
      - SHOPIFY_CLIENT_SECRET=${SHOPIFY_CLIENT_SECRET}
      - FORWARDED_ALLOW_IPS=*
    depends_on:
      - postgres

  credential-proxy:
    build: ./services/credential-proxy
    ports:
      - "8011:8080"
    environment:
      - TOKEN_SERVICE_URL=http://token-service:8000
      - SHOPIFY_HOST=https://junlinleather-5148.myshopify.com
      - FORWARDED_ALLOW_IPS=*
    depends_on:
      - token-service

  # Modify existing apollo service:
  apollo:
    # ... existing config ...
    environment:
      # REMOVE: SHOPIFY_ACCESS_TOKEN
      # Apollo now talks to credential-proxy instead of Shopify directly
      - APOLLO_ENDPOINT=http://credential-proxy:8080/admin/api/2026-01/graphql.json
    depends_on:
      - credential-proxy
```

**Local dev workflow:**
1. `docker compose up` — all services start
2. Open `http://localhost:8010/connect/shopify` — authorize once
3. Apollo sends GraphQL to credential-proxy, which injects the token and forwards to Shopify
4. Token refreshes automatically in the background

## 8. Monitoring & Alerts

### 8.1 Tier 1: Critical (pages immediately)

| Alert | Condition | Action |
|---|---|---|
| `invalid_grant` | Shopify returned `invalid_grant` on refresh | Manual re-auth required via `/connect/shopify` |
| Refresh failure x4 | 4 consecutive failures for any provider | Investigate Shopify status, network, credentials |
| Token expired | `token_expires_at < now()` for any active credential | Consumers getting 401s — immediate action needed |

### 8.2 Tier 2: Warning (investigate within hours)

| Alert | Condition | Action |
|---|---|---|
| Refresh token aging | Last used > 60 days ago | 30 days until permanent lockout |
| Single refresh failure | One attempt failed, retries may succeed | Monitor — likely transient |
| Proxy latency > 500ms | `/token/{provider}` slow | DB performance or frequent lazy refreshes |

### 8.3 Tier 3: Info (dashboard only)

| Metric | Purpose |
|---|---|
| `token_refresh_total` | Track refresh frequency per provider |
| `token_refresh_errors_total` | Track error types and rates |
| `token_ttl_seconds` | Current token remaining lifetime |
| `refresh_token_ttl_days` | 90-day countdown (Shopify) |
| `token_vend_latency_seconds` | Performance of token vending endpoint |

## 9. Security

### 9.1 Encryption Layers

| Layer | Scope | Method |
|---|---|---|
| Transport | All service-to-service | Cloud Run HTTPS + internal TLS |
| Database at rest | All Cloud SQL data | GCP-managed AES-256 (always on) |
| Application at rest | Token fields in `oauth_credentials` | AES-256-GCM, key from Secret Manager |
| In-memory | Proxy's 30s token cache | Cloud Run container isolation |

### 9.2 IAM Access Control

| Endpoint | Allowed callers |
|---|---|
| `GET /token/{provider}` | `credential-proxy` service account only |
| `GET /connect/*`, `GET /callback/*` | Temporarily public for bootstrap, then IAM-locked |
| `POST /rotate/*`, `GET /status` | Admin service account only |
| `GET /health` | Public (minimal response, no provider details) |
| `GET /metrics` | Admin service account only (exposes operational intelligence) |

### 9.3 Logging Policy

- Access tokens: **masked** in all logs (`shpat_****...{last4}`)
- Refresh tokens: **never logged** (not even masked)
- Client secret: lives only in Secret Manager, injected as env var
- Encryption key: lives only in Secret Manager, injected as env var
- Error messages: never contain token values

## 10. Service Inventory (After Implementation)

| # | Service | Role | Changed? |
|---|---|---|---|
| 1 | ContextForge | MCP gateway, RBAC, SSO | No |
| 2 | Keycloak | User identity, SSO | No |
| 3 | Apollo | Shopify GraphQL execution | **Yes** — multi-container, proxy sidecar, config change |
| 4 | devmcp | Shopify docs/learning | No |
| 5 | sheets | Google Sheets bridge | No (future: add credential-proxy) |
| 6 | PostgreSQL | Shared database | **Yes** — new `oauth_credentials` table |
| 7 | **token-service** | **Credential lifecycle manager** | **New** |

## 11. Cost

| Component | Monthly cost |
|---|---|
| token-service (Cloud Run, min-instances=1) | ~$5 |
| credential-proxy (sidecar, shares Apollo's instances) | $0 incremental |
| Cloud SQL (existing instance, new table) | $0 incremental |
| Secret Manager (3 static secrets) | $0 (free tier) |
| Cloud Monitoring (metrics + alerts) | $0 (free tier for this volume) |
| **Total** | **~$5/mo** |

## 12. Future Extensibility

Adding a new OAuth provider requires:

1. Add a provider config (token endpoint URL, client_id secret name, refresh interval).
2. Open `/connect/{provider}` → authorize → tokens stored.
3. Deploy a credential-proxy sidecar in the consuming service's Cloud Run container.

No code changes to token-service core. No schema changes. One row in `oauth_credentials`, one sidecar per consumer.

## 13. Rollback Plan

If something goes wrong mid-deployment:

| Failure | Rollback |
|---|---|
| token-service deploys but Apollo multi-container fails | Revert Apollo to single-container with `SHOPIFY_ACCESS_TOKEN` env var. Token-service can be deleted independently. |
| credential-proxy can't reach token-service | Apollo returns 502s. Revert Apollo to single-container with static token. |
| `oauth_credentials` table migration fails | Table is additive — does not affect existing services. Drop table and retry. |
| Token refresh loop breaks after deployment | Manually set `SHOPIFY_ACCESS_TOKEN` env var on Apollo as a static fallback. Investigate token-service logs. |

**The `oauth_credentials` table is purely additive.** No existing tables are modified. No existing services read from it. Rollback = revert Apollo's config and delete token-service.

## 14. Documentation Updates Required

This spec introduces the first application code in the Fluid Intelligence system. The following docs must be updated post-implementation:

- **`docs/architecture.md`**: Remove "zero application code" claim. Add token-service and credential-proxy to the service inventory. Explain why application code is justified here (third-party credential lifecycle cannot be solved with config alone).
- **`CLAUDE.md`**: Update "Configure, don't code" guidance to note the exception: token-service is application code because no existing component in the stack handles OAuth token lifecycle.
- **`docs/config-reference.md`**: Add token-service env vars and credential-proxy env vars.
- **`docs/known-gotchas.md`**: Add entry about Cloud SQL `max_connections` budget (now 29 of 50).

## 15. Enterprise Pattern References

| Pattern | Source | How we use it |
|---|---|---|
| OAuth tokens in DB, not secrets manager | Nango, Stripe, Shopify guidance | `oauth_credentials` table in Cloud SQL |
| Proactive + lazy refresh | Nango dual-strategy | Background timer + inline refresh on `/token` |
| Single-flight lock | Nango concurrency blog | In-memory lock per provider, prevents double-refresh |
| PostgreSQL advisory locks | Kleppmann, Konrad Reiche | `pg_advisory_xact_lock` in proactive loop |
| Credential injection proxy | Netflix Zuul, Google Envoy, Nango proxy | credential-proxy sidecar in Apollo |
| Application-level encryption | Nango (AES-256), Cloudflare (2-level keys) | AES-256-GCM on token fields |
| Multi-tenant logical isolation | Azure guidance, FusionAuth, Nango | Single table with `(provider, account_id)` |
| Alert on failures + expiry countdown | Microsoft Entra, Nango | Tier 1/2/3 alerting with 60/30/7-day warnings |
