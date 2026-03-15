# Shopify OAuth Service Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone Cloud Run service that handles Shopify OAuth authorization code grant, stores encrypted offline tokens in Cloud SQL, and replaces the gateway's 24h-expiry client_credentials flow.

**Architecture:** Separate Cloud Run service (`shopify-oauth`) with Python/FastAPI. Shares the existing `contextforge` Cloud SQL database. Tokens encrypted with AES-256-GCM at application layer. Gateway reads tokens from DB instead of fetching at startup.

**Tech Stack:** Python 3.12, FastAPI, uvicorn, psycopg2-binary, httpx, cryptography

**Spec:** `docs/specs/2026-03-16-shopify-oauth-service-design.md`

---

## File Structure

```
services/shopify-oauth/
  main.py           # FastAPI app, route handlers (/auth/install, /auth/callback, /health)
  security.py       # HMAC validation, nonce generation, shop hostname validation, timestamp check
  crypto.py         # AES-256-GCM encrypt/decrypt for access tokens
  db.py             # Database connection pool, UPSERT/query functions
  webhooks.py       # APP_UNINSTALLED + GDPR webhook handlers
  config.py         # Settings from environment variables

deploy/shopify-oauth/
  Dockerfile        # Lightweight Python image
  cloudbuild.yaml   # Cloud Build config for deploy
  requirements.txt  # Python dependencies

tests/shopify-oauth/
  conftest.py       # Shared fixtures (fake secrets, test DB)
  test_security.py  # HMAC, nonce, shop validation, timestamp tests
  test_crypto.py    # Encrypt/decrypt round-trip tests
  test_db.py        # UPSERT, query, status update tests
  test_main.py      # Integration tests for /auth/install, /auth/callback
  test_webhooks.py  # Webhook HMAC validation + handler tests
```

---

## Chunk 1: Core Security & Crypto (Tasks 1-3)

### Task 1: Security Module — HMAC, Nonce, Shop Validation

**Files:**
- Create: `services/shopify-oauth/security.py`
- Create: `tests/shopify-oauth/test_security.py`
- Create: `tests/shopify-oauth/conftest.py`

- [ ] **Step 1: Create conftest with shared fixtures**

```python
# tests/shopify-oauth/conftest.py
import pytest

@pytest.fixture
def client_secret():
    return "test_secret_key_for_hmac_validation"

@pytest.fixture
def valid_shop():
    return "test-store.myshopify.com"

@pytest.fixture
def invalid_shops():
    return [
        "evil.com",
        "test.notshopify.com",
        ".myshopify.com",
        "test store.myshopify.com",
        "test.myshopify.com.evil.com",
    ]
```

- [ ] **Step 2: Write failing tests for security module**

```python
# tests/shopify-oauth/test_security.py
import time
import pytest
from services.shopify_oauth.security import (
    validate_shop_hostname,
    compute_hmac,
    verify_hmac,
    generate_nonce,
    sign_nonce,
    verify_nonce_signature,
    validate_timestamp,
)

def test_valid_shop_hostname(valid_shop):
    assert validate_shop_hostname(valid_shop) is True

def test_invalid_shop_hostnames(invalid_shops):
    for shop in invalid_shops:
        assert validate_shop_hostname(shop) is False, f"{shop} should be invalid"

def test_compute_hmac_deterministic(client_secret):
    params = {"shop": "test.myshopify.com", "timestamp": "1234567890"}
    h1 = compute_hmac(params, client_secret)
    h2 = compute_hmac(params, client_secret)
    assert h1 == h2

def test_verify_hmac_valid(client_secret):
    params = {"shop": "test.myshopify.com", "timestamp": "1234567890"}
    mac = compute_hmac(params, client_secret)
    assert verify_hmac(params, mac, client_secret) is True

def test_verify_hmac_invalid(client_secret):
    params = {"shop": "test.myshopify.com", "timestamp": "1234567890"}
    assert verify_hmac(params, "badhmac", client_secret) is False

def test_generate_nonce_uniqueness():
    n1 = generate_nonce()
    n2 = generate_nonce()
    assert n1 != n2
    assert len(n1) == 64  # 32 bytes hex-encoded

def test_nonce_sign_and_verify(client_secret):
    nonce = generate_nonce()
    signed = sign_nonce(nonce, client_secret)
    assert verify_nonce_signature(nonce, signed, client_secret) is True

def test_nonce_verify_rejects_tampered(client_secret):
    nonce = generate_nonce()
    signed = sign_nonce(nonce, client_secret)
    assert verify_nonce_signature("tampered", signed, client_secret) is False

def test_validate_timestamp_fresh():
    ts = str(int(time.time()))
    assert validate_timestamp(ts) is True

def test_validate_timestamp_stale():
    ts = str(int(time.time()) - 600)  # 10 min ago
    assert validate_timestamp(ts) is False

def test_validate_timestamp_invalid():
    assert validate_timestamp("not_a_number") is False
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd /Users/junlin/Projects/Shopify/fluid-intelligence && python -m pytest tests/shopify-oauth/test_security.py -v`
Expected: FAIL (module not found)

- [ ] **Step 4: Implement security module**

```python
# services/shopify-oauth/security.py
"""Shopify OAuth security: HMAC validation, nonce generation, shop hostname checks."""

import hashlib
import hmac
import os
import re
import time

SHOP_HOSTNAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9\-]*\.myshopify\.com$")
TIMESTAMP_MAX_AGE = 300  # 5 minutes


def validate_shop_hostname(shop: str) -> bool:
    return bool(SHOP_HOSTNAME_RE.match(shop))


def compute_hmac(params: dict[str, str], secret: str) -> str:
    """Compute HMAC-SHA256 of sorted query params (Shopify convention)."""
    message = "&".join(f"{k}={v}" for k, v in sorted(params.items()))
    return hmac.new(
        secret.encode(), message.encode(), hashlib.sha256
    ).hexdigest()


def verify_hmac(params: dict[str, str], received_hmac: str, secret: str) -> bool:
    expected = compute_hmac(params, secret)
    return hmac.compare_digest(expected, received_hmac)


def generate_nonce() -> str:
    return os.urandom(32).hex()


def _derive_signing_key(secret: str) -> bytes:
    """HKDF-derive a signing key from the client secret (don't use raw secret for cookies)."""
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives import hashes

    return HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=b"shopify-oauth-nonce-signing",
        info=b"cookie-signing",
    ).derive(secret.encode())


def sign_nonce(nonce: str, secret: str) -> str:
    key = _derive_signing_key(secret)
    return hmac.new(key, nonce.encode(), hashlib.sha256).hexdigest()


def verify_nonce_signature(nonce: str, signature: str, secret: str) -> bool:
    expected = sign_nonce(nonce, secret)
    return hmac.compare_digest(expected, signature)


def validate_timestamp(timestamp: str) -> bool:
    try:
        ts = int(timestamp)
    except (ValueError, TypeError):
        return False
    return abs(time.time() - ts) <= TIMESTAMP_MAX_AGE
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/junlin/Projects/Shopify/fluid-intelligence && python -m pytest tests/shopify-oauth/test_security.py -v`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add services/shopify-oauth/security.py tests/shopify-oauth/
git commit -m "feat(shopify-oauth): add security module — HMAC, nonce, shop validation"
```

---

### Task 2: Crypto Module — AES-256-GCM Token Encryption

**Files:**
- Create: `services/shopify-oauth/crypto.py`
- Create: `tests/shopify-oauth/test_crypto.py`

- [ ] **Step 1: Write failing tests**

```python
# tests/shopify-oauth/test_crypto.py
import base64
import os
import pytest
from services.shopify_oauth.crypto import encrypt_token, decrypt_token

@pytest.fixture
def encryption_key():
    """32-byte AES-256 key, base64-encoded (matches Secret Manager format)."""
    return base64.b64encode(os.urandom(32)).decode()

def test_encrypt_decrypt_round_trip(encryption_key):
    token = "shpat_abc123def456"
    encrypted = encrypt_token(token, encryption_key)
    decrypted = decrypt_token(encrypted, encryption_key)
    assert decrypted == token

def test_encrypted_differs_from_plaintext(encryption_key):
    token = "shpat_abc123def456"
    encrypted = encrypt_token(token, encryption_key)
    assert encrypted != token

def test_different_encryptions_differ(encryption_key):
    """Each encryption uses a random nonce, so ciphertexts differ."""
    token = "shpat_abc123def456"
    e1 = encrypt_token(token, encryption_key)
    e2 = encrypt_token(token, encryption_key)
    assert e1 != e2

def test_decrypt_with_wrong_key(encryption_key):
    token = "shpat_abc123def456"
    encrypted = encrypt_token(token, encryption_key)
    wrong_key = base64.b64encode(os.urandom(32)).decode()
    with pytest.raises(Exception):
        decrypt_token(encrypted, wrong_key)

def test_decrypt_tampered_ciphertext(encryption_key):
    token = "shpat_abc123def456"
    encrypted = encrypt_token(token, encryption_key)
    # Tamper with the ciphertext
    raw = base64.b64decode(encrypted)
    tampered = base64.b64encode(raw[:-1] + bytes([raw[-1] ^ 0xFF])).decode()
    with pytest.raises(Exception):
        decrypt_token(tampered, encryption_key)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/shopify-oauth/test_crypto.py -v`
Expected: FAIL (module not found)

- [ ] **Step 3: Implement crypto module**

```python
# services/shopify-oauth/crypto.py
"""AES-256-GCM encryption for Shopify access tokens."""

import base64
import os

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

NONCE_SIZE = 12  # 96-bit nonce for AES-GCM


def encrypt_token(plaintext: str, key_b64: str) -> str:
    """Encrypt a token with AES-256-GCM. Returns base64-encoded nonce+ciphertext."""
    key = base64.b64decode(key_b64)
    nonce = os.urandom(NONCE_SIZE)
    ct = AESGCM(key).encrypt(nonce, plaintext.encode(), None)
    return base64.b64encode(nonce + ct).decode()


def decrypt_token(encrypted_b64: str, key_b64: str) -> str:
    """Decrypt an AES-256-GCM encrypted token. Input is base64-encoded nonce+ciphertext."""
    key = base64.b64decode(key_b64)
    data = base64.b64decode(encrypted_b64)
    nonce, ct = data[:NONCE_SIZE], data[NONCE_SIZE:]
    return AESGCM(key).decrypt(nonce, ct, None).decode()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/shopify-oauth/test_crypto.py -v`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add services/shopify-oauth/crypto.py tests/shopify-oauth/test_crypto.py
git commit -m "feat(shopify-oauth): add AES-256-GCM token encryption module"
```

---

### Task 3: Database Module — Connection, UPSERT, Query

**Files:**
- Create: `services/shopify-oauth/db.py`
- Create: `services/shopify-oauth/config.py`
- Create: `tests/shopify-oauth/test_db.py`

- [ ] **Step 1: Create config module**

```python
# services/shopify-oauth/config.py
"""Settings loaded from environment variables."""

import os


class Settings:
    SHOPIFY_CLIENT_ID: str = os.environ.get("SHOPIFY_CLIENT_ID", "")
    SHOPIFY_CLIENT_SECRET: str = os.environ.get("SHOPIFY_CLIENT_SECRET", "")
    SHOPIFY_TOKEN_ENCRYPTION_KEY: str = os.environ.get("SHOPIFY_TOKEN_ENCRYPTION_KEY", "")
    DB_USER: str = os.environ.get("DB_USER", "contextforge")
    DB_NAME: str = os.environ.get("DB_NAME", "contextforge")
    DB_PASSWORD: str = os.environ.get("DB_PASSWORD", "")
    DB_HOST: str = os.environ.get("DB_HOST", "/cloudsql/junlinleather-mcp:asia-southeast1:contextforge")
    SHOPIFY_API_VERSION: str = os.environ.get("SHOPIFY_API_VERSION", "2026-01")
    SHOPIFY_SCOPES: str = os.environ.get("SHOPIFY_SCOPES", "")
    CALLBACK_URL: str = os.environ.get("CALLBACK_URL", "")


settings = Settings()
```

- [ ] **Step 2: Write failing tests for db module**

```python
# tests/shopify-oauth/test_db.py
import os
import pytest
import psycopg2

# Skip if no test database configured
DB_URL = os.environ.get("TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(not DB_URL, reason="TEST_DATABASE_URL not set")

from services.shopify_oauth.db import (
    get_connection,
    ensure_table,
    upsert_installation,
    get_installation,
    mark_uninstalled,
)

@pytest.fixture(autouse=True)
def setup_db():
    """Create table and clean up after each test."""
    conn = psycopg2.connect(DB_URL)
    conn.autocommit = True
    cur = conn.cursor()
    ensure_table(conn)
    yield conn
    cur.execute("DELETE FROM shopify_installations")
    conn.close()

def test_upsert_new_installation(setup_db):
    upsert_installation(
        setup_db, "test.myshopify.com", "encrypted_token_abc", "read_products", shop_id=12345
    )
    row = get_installation(setup_db, "test.myshopify.com")
    assert row is not None
    assert row["shop_domain"] == "test.myshopify.com"
    assert row["access_token_encrypted"] == "encrypted_token_abc"
    assert row["scopes"] == "read_products"
    assert row["status"] == "active"
    assert row["shop_id"] == 12345

def test_upsert_updates_existing(setup_db):
    upsert_installation(setup_db, "test.myshopify.com", "token_v1", "read_products")
    upsert_installation(setup_db, "test.myshopify.com", "token_v2", "read_products,write_products")
    row = get_installation(setup_db, "test.myshopify.com")
    assert row["access_token_encrypted"] == "token_v2"
    assert row["scopes"] == "read_products,write_products"
    assert row["status"] == "active"

def test_mark_uninstalled(setup_db):
    upsert_installation(setup_db, "test.myshopify.com", "token", "scopes")
    mark_uninstalled(setup_db, "test.myshopify.com")
    row = get_installation(setup_db, "test.myshopify.com")
    assert row["status"] == "uninstalled"
    assert row["access_token_encrypted"] == ""

def test_get_nonexistent_installation(setup_db):
    row = get_installation(setup_db, "nonexistent.myshopify.com")
    assert row is None
```

- [ ] **Step 3: Implement db module**

```python
# services/shopify-oauth/db.py
"""Database operations for shopify_installations table."""

import psycopg2
import psycopg2.extras
from services.shopify_oauth.config import settings

CREATE_TABLE_SQL = """
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
"""

UPSERT_SQL = """
INSERT INTO shopify_installations (shop_domain, shop_id, access_token_encrypted, scopes, status, updated_at)
VALUES (%s, %s, %s, %s, 'active', NOW())
ON CONFLICT (shop_domain) DO UPDATE SET
    shop_id = COALESCE(EXCLUDED.shop_id, shopify_installations.shop_id),
    access_token_encrypted = EXCLUDED.access_token_encrypted,
    scopes = EXCLUDED.scopes,
    status = 'active',
    updated_at = NOW();
"""


def get_connection(dsn: str | None = None):
    if dsn:
        return psycopg2.connect(dsn)
    return psycopg2.connect(
        dbname=settings.DB_NAME,
        user=settings.DB_USER,
        password=settings.DB_PASSWORD,
        host=settings.DB_HOST,
    )


def ensure_table(conn):
    with conn.cursor() as cur:
        cur.execute(CREATE_TABLE_SQL)
    conn.commit()


def upsert_installation(
    conn, shop_domain: str, encrypted_token: str, scopes: str, shop_id: int | None = None
):
    with conn.cursor() as cur:
        cur.execute(UPSERT_SQL, (shop_domain, shop_id, encrypted_token, scopes))
    conn.commit()


def get_installation(conn, shop_domain: str) -> dict | None:
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            "SELECT * FROM shopify_installations WHERE shop_domain = %s", (shop_domain,)
        )
        return cur.fetchone()


def mark_uninstalled(conn, shop_domain: str):
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE shopify_installations SET status = 'uninstalled', access_token_encrypted = '', updated_at = NOW() WHERE shop_domain = %s",
            (shop_domain,),
        )
    conn.commit()
```

- [ ] **Step 4: Run tests (requires TEST_DATABASE_URL or skip)**

Run: `python -m pytest tests/shopify-oauth/test_db.py -v`
Expected: SKIP if no TEST_DATABASE_URL, or PASS if configured

- [ ] **Step 5: Commit**

```bash
git add services/shopify-oauth/config.py services/shopify-oauth/db.py tests/shopify-oauth/test_db.py
git commit -m "feat(shopify-oauth): add database module — connection, UPSERT, query"
```

---

## Chunk 2: FastAPI App & Webhook Handlers (Tasks 4-5)

### Task 4: Main FastAPI App — OAuth Endpoints

**Files:**
- Create: `services/shopify-oauth/main.py`
- Create: `tests/shopify-oauth/test_main.py`

- [ ] **Step 1: Write failing integration tests**

```python
# tests/shopify-oauth/test_main.py
import hashlib
import hmac
import time
import os
import base64
import pytest
from unittest.mock import patch, MagicMock
from fastapi.testclient import TestClient

# Set env vars before importing app
os.environ.setdefault("SHOPIFY_CLIENT_ID", "test_client_id")
os.environ.setdefault("SHOPIFY_CLIENT_SECRET", "test_secret")
os.environ.setdefault("SHOPIFY_TOKEN_ENCRYPTION_KEY", base64.b64encode(os.urandom(32)).decode())
os.environ.setdefault("CALLBACK_URL", "http://localhost/auth/callback")
os.environ.setdefault("SHOPIFY_SCOPES", "read_products")

from services.shopify_oauth.main import app

client = TestClient(app)

def make_hmac(params: dict, secret: str = "test_secret") -> str:
    message = "&".join(f"{k}={v}" for k, v in sorted(params.items()))
    return hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()

def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"

def test_install_redirects_to_shopify():
    params = {"shop": "test-store.myshopify.com", "timestamp": str(int(time.time()))}
    params["hmac"] = make_hmac(params)
    r = client.get("/auth/install", params=params, follow_redirects=False)
    assert r.status_code == 302
    assert "admin/oauth/authorize" in r.headers["location"]
    assert "client_id=test_client_id" in r.headers["location"]

def test_install_rejects_invalid_shop():
    params = {"shop": "evil.com", "timestamp": str(int(time.time()))}
    params["hmac"] = make_hmac(params)
    r = client.get("/auth/install", params=params)
    assert r.status_code == 400

def test_install_rejects_bad_hmac():
    params = {"shop": "test.myshopify.com", "timestamp": str(int(time.time())), "hmac": "bad"}
    r = client.get("/auth/install", params=params)
    assert r.status_code == 401

def test_install_rejects_stale_timestamp():
    params = {"shop": "test.myshopify.com", "timestamp": str(int(time.time()) - 600)}
    params["hmac"] = make_hmac(params)
    r = client.get("/auth/install", params=params)
    assert r.status_code == 401

@patch("services.shopify_oauth.main.exchange_code_for_token")
@patch("services.shopify_oauth.main.store_installation")
@patch("services.shopify_oauth.main.register_webhooks")
@patch("services.shopify_oauth.main.fetch_shop_id")
def test_callback_exchanges_token(mock_shop_id, mock_webhooks, mock_store, mock_exchange):
    mock_exchange.return_value = ("shpat_test_token", "read_products")
    mock_shop_id.return_value = 12345

    # First do install to get nonce cookie
    params = {"shop": "test-store.myshopify.com", "timestamp": str(int(time.time()))}
    params["hmac"] = make_hmac(params)
    install_r = client.get("/auth/install", params=params, follow_redirects=False)
    cookies = install_r.cookies

    # Extract state from redirect URL
    import urllib.parse
    location = install_r.headers["location"]
    qs = urllib.parse.parse_qs(urllib.parse.urlparse(location).query)
    state = qs["state"][0]

    # Now hit callback
    cb_params = {
        "shop": "test-store.myshopify.com",
        "code": "auth_code_123",
        "state": state,
        "timestamp": str(int(time.time())),
    }
    cb_params["hmac"] = make_hmac(cb_params)
    r = client.get("/auth/callback", params=cb_params, cookies=cookies)
    assert r.status_code == 200
    mock_exchange.assert_called_once()
    mock_store.assert_called_once()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/shopify-oauth/test_main.py -v`
Expected: FAIL (module not found)

- [ ] **Step 3: Implement main.py**

```python
# services/shopify-oauth/main.py
"""Shopify OAuth service — handles app installation and token exchange."""

import logging
import urllib.parse

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse

from services.shopify_oauth.config import settings
from services.shopify_oauth.crypto import encrypt_token
from services.shopify_oauth.db import get_connection, ensure_table, upsert_installation
from services.shopify_oauth.security import (
    validate_shop_hostname,
    verify_hmac,
    generate_nonce,
    sign_nonce,
    verify_nonce_signature,
    validate_timestamp,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("shopify-oauth")

app = FastAPI(title="Shopify OAuth Service")


@app.on_event("startup")
def startup():
    try:
        conn = get_connection()
        ensure_table(conn)
        conn.close()
        log.info("Database table ensured")
    except Exception as e:
        log.warning(f"Could not ensure table on startup: {e}")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/auth/install")
def install(request: Request):
    params = dict(request.query_params)
    shop = params.get("shop", "")
    received_hmac = params.pop("hmac", "")
    timestamp = params.get("timestamp", "")

    if not validate_shop_hostname(shop):
        return Response("Invalid shop hostname", status_code=400)

    if not verify_hmac(params, received_hmac, settings.SHOPIFY_CLIENT_SECRET):
        return Response("Invalid HMAC", status_code=401)

    if not validate_timestamp(timestamp):
        return Response("Stale or invalid timestamp", status_code=401)

    nonce = generate_nonce()
    signature = sign_nonce(nonce, settings.SHOPIFY_CLIENT_SECRET)

    redirect_url = (
        f"https://{shop}/admin/oauth/authorize"
        f"?client_id={settings.SHOPIFY_CLIENT_ID}"
        f"&scope={urllib.parse.quote(settings.SHOPIFY_SCOPES)}"
        f"&redirect_uri={urllib.parse.quote(settings.CALLBACK_URL)}"
        f"&state={nonce}"
    )

    response = RedirectResponse(url=redirect_url, status_code=302)
    response.set_cookie(
        key="shopify_nonce",
        value=nonce,
        httponly=True,
        secure=True,
        samesite="lax",
        max_age=600,
    )
    response.set_cookie(
        key="shopify_nonce_sig",
        value=signature,
        httponly=True,
        secure=True,
        samesite="lax",
        max_age=600,
    )
    return response


@app.get("/auth/callback")
def callback(request: Request):
    params = dict(request.query_params)
    shop = params.get("shop", "")
    code = params.get("code", "")
    state = params.get("state", "")
    received_hmac = params.pop("hmac", "")

    if not validate_shop_hostname(shop):
        return Response("Invalid shop hostname", status_code=400)

    if not verify_hmac(params, received_hmac, settings.SHOPIFY_CLIENT_SECRET):
        return Response("Invalid HMAC", status_code=401)

    # Verify nonce
    cookie_nonce = request.cookies.get("shopify_nonce", "")
    cookie_sig = request.cookies.get("shopify_nonce_sig", "")
    if not cookie_nonce or state != cookie_nonce:
        return Response("Invalid state/nonce", status_code=403)
    if not verify_nonce_signature(cookie_nonce, cookie_sig, settings.SHOPIFY_CLIENT_SECRET):
        return Response("Invalid nonce signature", status_code=403)

    # Exchange code for token
    access_token, scopes = exchange_code_for_token(shop, code)
    if not access_token:
        return Response("Token exchange failed", status_code=502)

    # Store installation
    store_installation(shop, access_token, scopes)

    # Fetch shop_id and register webhooks (best-effort)
    try:
        shop_id = fetch_shop_id(shop, access_token)
        if shop_id:
            conn = get_connection()
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE shopify_installations SET shop_id = %s WHERE shop_domain = %s",
                    (shop_id, shop),
                )
            conn.commit()
            conn.close()
    except Exception as e:
        log.warning(f"Could not fetch shop_id: {e}")

    try:
        register_webhooks(shop, access_token)
    except Exception as e:
        log.warning(f"Could not register webhooks: {e}")

    # Clear nonce cookies
    response = HTMLResponse(
        content=f"""
        <html><body style="font-family: sans-serif; text-align: center; margin-top: 50px;">
            <h1>Installation Complete</h1>
            <p>Your Shopify store <strong>{shop}</strong> has been connected.</p>
            <a href="https://{shop}/admin">Return to Shopify Admin</a>
        </body></html>
        """,
        status_code=200,
    )
    response.delete_cookie("shopify_nonce")
    response.delete_cookie("shopify_nonce_sig")
    return response


def exchange_code_for_token(shop: str, code: str) -> tuple[str, str]:
    """Exchange authorization code for offline access token."""
    try:
        r = httpx.post(
            f"https://{shop}/admin/oauth/access_token",
            data={
                "client_id": settings.SHOPIFY_CLIENT_ID,
                "client_secret": settings.SHOPIFY_CLIENT_SECRET,
                "code": code,
            },
            timeout=30,
        )
        r.raise_for_status()
        data = r.json()
        return data.get("access_token", ""), data.get("scope", "")
    except Exception as e:
        log.error(f"Token exchange failed for {shop}: {e}")
        return "", ""


def store_installation(shop: str, access_token: str, scopes: str):
    """Encrypt token and store in database."""
    encrypted = encrypt_token(access_token, settings.SHOPIFY_TOKEN_ENCRYPTION_KEY)
    conn = get_connection()
    upsert_installation(conn, shop, encrypted, scopes)
    conn.close()
    log.info(f"Stored installation for {shop}")


def fetch_shop_id(shop: str, access_token: str) -> int | None:
    """Fetch the stable numeric shop ID from Shopify API."""
    try:
        r = httpx.get(
            f"https://{shop}/admin/api/{settings.SHOPIFY_API_VERSION}/shop.json",
            headers={"X-Shopify-Access-Token": access_token},
            timeout=10,
        )
        r.raise_for_status()
        return r.json().get("shop", {}).get("id")
    except Exception as e:
        log.warning(f"Could not fetch shop_id for {shop}: {e}")
        return None


def register_webhooks(shop: str, access_token: str):
    """Register APP_UNINSTALLED and GDPR webhooks."""
    base = settings.CALLBACK_URL.rsplit("/auth/callback", 1)[0]
    webhooks = [
        {"topic": "app/uninstalled", "address": f"{base}/webhooks/app-uninstalled"},
    ]
    for wh in webhooks:
        try:
            r = httpx.post(
                f"https://{shop}/admin/api/{settings.SHOPIFY_API_VERSION}/webhooks.json",
                headers={
                    "X-Shopify-Access-Token": access_token,
                    "Content-Type": "application/json",
                },
                json={"webhook": {"topic": wh["topic"], "address": wh["address"], "format": "json"}},
                timeout=10,
            )
            log.info(f"Registered webhook {wh['topic']} for {shop}: HTTP {r.status_code}")
        except Exception as e:
            log.warning(f"Failed to register webhook {wh['topic']} for {shop}: {e}")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/shopify-oauth/test_main.py -v`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add services/shopify-oauth/main.py tests/shopify-oauth/test_main.py
git commit -m "feat(shopify-oauth): add FastAPI app with OAuth install/callback endpoints"
```

---

### Task 5: Webhook Handlers

**Files:**
- Create: `services/shopify-oauth/webhooks.py`
- Create: `tests/shopify-oauth/test_webhooks.py`
- Modify: `services/shopify-oauth/main.py` (add webhook routes)

- [ ] **Step 1: Write failing tests**

```python
# tests/shopify-oauth/test_webhooks.py
import hashlib
import hmac
import json
import os
import base64
import pytest
from unittest.mock import patch
from fastapi.testclient import TestClient

os.environ.setdefault("SHOPIFY_CLIENT_ID", "test_client_id")
os.environ.setdefault("SHOPIFY_CLIENT_SECRET", "test_secret")
os.environ.setdefault("SHOPIFY_TOKEN_ENCRYPTION_KEY", base64.b64encode(os.urandom(32)).decode())
os.environ.setdefault("CALLBACK_URL", "http://localhost/auth/callback")
os.environ.setdefault("SHOPIFY_SCOPES", "read_products")

from services.shopify_oauth.main import app

client = TestClient(app)

def shopify_webhook_hmac(body: bytes, secret: str = "test_secret") -> str:
    return base64.b64encode(
        hmac.new(secret.encode(), body, hashlib.sha256).digest()
    ).decode()

def test_app_uninstalled_webhook():
    body = json.dumps({"myshopify_domain": "test-store.myshopify.com"}).encode()
    mac = shopify_webhook_hmac(body)
    with patch("services.shopify_oauth.webhooks.mark_shop_uninstalled") as mock:
        r = client.post(
            "/webhooks/app-uninstalled",
            content=body,
            headers={"X-Shopify-Hmac-SHA256": mac, "Content-Type": "application/json"},
        )
    assert r.status_code == 200
    mock.assert_called_once_with("test-store.myshopify.com")

def test_webhook_rejects_bad_hmac():
    body = json.dumps({"myshopify_domain": "test.myshopify.com"}).encode()
    r = client.post(
        "/webhooks/app-uninstalled",
        content=body,
        headers={"X-Shopify-Hmac-SHA256": "bad", "Content-Type": "application/json"},
    )
    assert r.status_code == 401

def test_gdpr_customers_redact():
    body = json.dumps({"shop_domain": "test.myshopify.com"}).encode()
    mac = shopify_webhook_hmac(body)
    r = client.post(
        "/webhooks/gdpr/customers-redact",
        content=body,
        headers={"X-Shopify-Hmac-SHA256": mac, "Content-Type": "application/json"},
    )
    assert r.status_code == 200

def test_gdpr_shop_redact():
    body = json.dumps({"shop_domain": "test.myshopify.com"}).encode()
    mac = shopify_webhook_hmac(body)
    with patch("services.shopify_oauth.webhooks.mark_shop_uninstalled") as mock:
        r = client.post(
            "/webhooks/gdpr/shop-redact",
            content=body,
            headers={"X-Shopify-Hmac-SHA256": mac, "Content-Type": "application/json"},
        )
    assert r.status_code == 200
    mock.assert_called_once()

def test_gdpr_data_request():
    body = json.dumps({"shop_domain": "test.myshopify.com"}).encode()
    mac = shopify_webhook_hmac(body)
    r = client.post(
        "/webhooks/gdpr/customers-data-request",
        content=body,
        headers={"X-Shopify-Hmac-SHA256": mac, "Content-Type": "application/json"},
    )
    assert r.status_code == 200
```

- [ ] **Step 2: Implement webhooks module and add routes to main.py**

```python
# services/shopify-oauth/webhooks.py
"""Webhook handlers for Shopify APP_UNINSTALLED and GDPR mandatory webhooks."""

import base64
import hashlib
import hmac
import json
import logging

from fastapi import APIRouter, Request, Response

from services.shopify_oauth.config import settings
from services.shopify_oauth.db import get_connection, mark_uninstalled

log = logging.getLogger("shopify-oauth")
router = APIRouter()


def verify_webhook_hmac(body: bytes, received_hmac: str) -> bool:
    expected = base64.b64encode(
        hmac.new(settings.SHOPIFY_CLIENT_SECRET.encode(), body, hashlib.sha256).digest()
    ).decode()
    return hmac.compare_digest(expected, received_hmac)


def mark_shop_uninstalled(shop_domain: str):
    try:
        conn = get_connection()
        mark_uninstalled(conn, shop_domain)
        conn.close()
        log.info(f"Marked {shop_domain} as uninstalled")
    except Exception as e:
        log.error(f"Failed to mark {shop_domain} uninstalled: {e}")


@router.post("/webhooks/app-uninstalled")
async def app_uninstalled(request: Request):
    body = await request.body()
    hmac_header = request.headers.get("X-Shopify-Hmac-SHA256", "")
    if not verify_webhook_hmac(body, hmac_header):
        return Response("Invalid HMAC", status_code=401)

    data = json.loads(body)
    shop_domain = data.get("myshopify_domain", "")
    if shop_domain:
        mark_shop_uninstalled(shop_domain)
    return {"status": "ok"}


@router.post("/webhooks/gdpr/{topic}")
async def gdpr_webhook(topic: str, request: Request):
    body = await request.body()
    hmac_header = request.headers.get("X-Shopify-Hmac-SHA256", "")
    if not verify_webhook_hmac(body, hmac_header):
        return Response("Invalid HMAC", status_code=401)

    data = json.loads(body)
    log.info(f"GDPR webhook received: {topic}")

    if topic == "shop-redact":
        shop_domain = data.get("shop_domain", "")
        if shop_domain:
            mark_shop_uninstalled(shop_domain)

    # customers-redact and customers-data-request: no customer PII stored
    return {"status": "ok"}
```

Add to `main.py` after app creation:
```python
from services.shopify_oauth.webhooks import router as webhook_router
app.include_router(webhook_router)
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `python -m pytest tests/shopify-oauth/test_webhooks.py -v`
Expected: All PASS

- [ ] **Step 4: Commit**

```bash
git add services/shopify-oauth/webhooks.py tests/shopify-oauth/test_webhooks.py services/shopify-oauth/main.py
git commit -m "feat(shopify-oauth): add webhook handlers (APP_UNINSTALLED + GDPR)"
```

---

## Chunk 3: Deployment & Gateway Integration (Tasks 6-8)

### Task 6: Dockerfile & Cloud Build Config

**Files:**
- Create: `deploy/shopify-oauth/Dockerfile`
- Create: `deploy/shopify-oauth/cloudbuild.yaml`
- Create: `deploy/shopify-oauth/requirements.txt`

- [ ] **Step 1: Create requirements.txt**

```
# deploy/shopify-oauth/requirements.txt
fastapi==0.115.*
uvicorn[standard]==0.34.*
psycopg2-binary==2.9.*
httpx==0.28.*
cryptography==44.*
```

- [ ] **Step 2: Create Dockerfile**

```dockerfile
# deploy/shopify-oauth/Dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY deploy/shopify-oauth/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY services/shopify-oauth/ services/shopify_oauth/
# Create __init__.py for package imports
RUN touch services/__init__.py services/shopify_oauth/__init__.py

ENV PORT=8080
EXPOSE 8080

CMD ["uvicorn", "services.shopify_oauth.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

- [ ] **Step 3: Create cloudbuild.yaml**

```yaml
# deploy/shopify-oauth/cloudbuild.yaml
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/shopify-oauth:$COMMIT_SHA', '-t', 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/shopify-oauth:latest', '-f', 'deploy/shopify-oauth/Dockerfile', '.']
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/shopify-oauth:$COMMIT_SHA']
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/shopify-oauth:latest']
  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    entrypoint: gcloud
    args:
      - 'run'
      - 'deploy'
      - 'shopify-oauth'
      - '--image=asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/shopify-oauth:$COMMIT_SHA'
      - '--region=asia-southeast1'
      - '--platform=managed'
      - '--allow-unauthenticated'
      - '--add-cloudsql-instances=junlinleather-mcp:asia-southeast1:contextforge'
      - '--set-secrets=SHOPIFY_CLIENT_ID=shopify-client-id:latest,SHOPIFY_CLIENT_SECRET=shopify-client-secret:latest,DB_PASSWORD=db-password:latest,SHOPIFY_TOKEN_ENCRYPTION_KEY=shopify-token-encryption-key:latest'
      - '--set-env-vars=DB_USER=contextforge,DB_NAME=contextforge,SHOPIFY_API_VERSION=2026-01,SHOPIFY_SCOPES=read_analytics$(comma)read_app_proxy$(comma)read_apps$(comma)read_orders$(comma)write_orders$(comma)read_products$(comma)write_products$(comma)read_customers$(comma)write_customers$(comma)read_discounts$(comma)write_discounts$(comma)read_inventory$(comma)write_inventory$(comma)read_fulfillments$(comma)write_fulfillments$(comma)read_draft_orders$(comma)write_draft_orders'
      - '--min-instances=0'
      - '--max-instances=2'
      - '--cpu=1'
      - '--memory=256Mi'
options:
  logging: CLOUD_LOGGING_ONLY
```

Note: `CALLBACK_URL` and full `SHOPIFY_SCOPES` will be set after first deploy (once Cloud Run URL is known). Use `gcloud run services update` to add them.

- [ ] **Step 4: Commit**

```bash
git add deploy/shopify-oauth/
git commit -m "feat(shopify-oauth): add Dockerfile, cloudbuild.yaml, requirements.txt"
```

---

### Task 7: Create Encryption Key in Secret Manager

- [ ] **Step 1: Generate and store AES-256 key**

```bash
python3 -c "import os, base64; print(base64.b64encode(os.urandom(32)).decode())" | \
  gcloud secrets create shopify-token-encryption-key --data-file=- --project=junlinleather-mcp
```

- [ ] **Step 2: Grant access to compute service account**

```bash
gcloud secrets add-iam-policy-binding shopify-token-encryption-key \
  --member="serviceAccount:1056128102929-compute@developer.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" \
  --project=junlinleather-mcp
```

- [ ] **Step 3: Commit (nothing to commit — infrastructure only)**

---

### Task 8: First Deploy & TOML Update

- [ ] **Step 1: Build and deploy manually (first time)**

```bash
cd /Users/junlin/Projects/Shopify/fluid-intelligence
gcloud builds submit --config=deploy/shopify-oauth/cloudbuild.yaml --project=junlinleather-mcp .
```

- [ ] **Step 2: Get the Cloud Run URL**

```bash
gcloud run services describe shopify-oauth --region=asia-southeast1 --project=junlinleather-mcp --format='value(status.url)'
```

- [ ] **Step 3: Update CALLBACK_URL env var with real URL**

```bash
gcloud run services update shopify-oauth \
  --region=asia-southeast1 \
  --set-env-vars="CALLBACK_URL=https://ACTUAL-URL/auth/callback" \
  --project=junlinleather-mcp
```

- [ ] **Step 4: Update Shopify TOML and deploy**

Update `/tmp/shopify-token/shopify.app.toml`:
```toml
application_url = "https://ACTUAL-URL/auth/install"
use_legacy_install_flow = false
[auth]
redirect_urls = ["https://ACTUAL-URL/auth/callback"]
```

Then:
```bash
cd /tmp/shopify-token && shopify app deploy --force
```

- [ ] **Step 5: Verify health endpoint**

```bash
curl https://ACTUAL-URL/health
# Expected: {"status":"ok"}
```

- [ ] **Step 6: Commit any TOML changes**

---

## Chunk 4: Gateway Integration & E2E Test (Tasks 9-10)

### Task 9: Update Gateway entrypoint.sh

**Files:**
- Modify: `scripts/entrypoint.sh` (replace client_credentials with DB read, keep fallback)

- [ ] **Step 1: Read current entrypoint.sh Shopify token section**

Read: `scripts/entrypoint.sh` lines 91-128

- [ ] **Step 2: Add DB read before client_credentials fallback**

Insert new code before the existing client_credentials block. The new code tries to read from Cloud SQL first. If no row found, falls back to existing flow.

- [ ] **Step 3: Add SHOPIFY_TOKEN_ENCRYPTION_KEY to gateway's cloudbuild.yaml secrets**

Modify: `deploy/cloudbuild.yaml` — add `SHOPIFY_TOKEN_ENCRYPTION_KEY=shopify-token-encryption-key:latest` to `--set-secrets`

- [ ] **Step 4: Commit**

```bash
git add scripts/entrypoint.sh deploy/cloudbuild.yaml
git commit -m "feat: gateway reads Shopify token from Cloud SQL with client_credentials fallback"
```

---

### Task 10: End-to-End Test

- [ ] **Step 1: Click "Install app" in Shopify Dev Dashboard**

Go to: https://dev.shopify.com → JunLin MCP Server → Install app
Expected: Redirect to Shopify consent screen → approve → "Installation Complete" page

- [ ] **Step 2: Verify token in Cloud SQL**

```bash
gcloud sql connect contextforge --user=contextforge --project=junlinleather-mcp
# Then:
SELECT shop_domain, status, scopes, installed_at FROM shopify_installations;
```

- [ ] **Step 3: Redeploy gateway and verify it uses DB token**

```bash
gcloud builds submit --config=deploy/cloudbuild.yaml --project=junlinleather-mcp .
```

Check logs for `[entrypoint] Using Shopify token from database` instead of client_credentials.

- [ ] **Step 4: Test a Shopify API call through the gateway**

Use the MCP endpoint to call a Shopify tool and verify it works with the new token.

- [ ] **Step 5: Run mirror polish protocol for exhaustive review**

---

## Post-Implementation

After all tasks complete and E2E passes:
1. Run mirror polish protocol (`/junlin-custom-skills:mirror-polish-protocol`) for exhaustive code review
2. Update `docs/agent-behavior/system-understanding.md` with new OAuth flow
3. Update `docs/architecture.md` with shopify-oauth service
4. Commit documentation updates
