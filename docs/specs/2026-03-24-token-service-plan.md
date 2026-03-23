# Token Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an enterprise-grade credential lifecycle manager (token-service) and credential injection proxy that automatically refreshes Shopify OAuth tokens and injects them into Apollo's outbound requests — zero credentials in Apollo, zero restarts.

**Architecture:** Two new components: (1) `token-service` — a FastAPI Cloud Run service that manages OAuth token lifecycle with proactive + lazy refresh, PostgreSQL storage, AES-256-GCM encryption, and single-flight locking; (2) `credential-proxy` — a lightweight FastAPI sidecar that intercepts Apollo's outbound requests and injects fresh tokens from token-service. Apollo's config changes to point at the local proxy instead of Shopify directly.

**Tech Stack:** Python 3.12, FastAPI, uvicorn, httpx, SQLAlchemy (async), cryptography (AESGCM), google-auth, prometheus-client, pytest, Docker

**Spec:** `docs/specs/2026-03-24-token-service-design.md`

---

## File Structure

### New: `services/token-service/`

| File | Responsibility |
|---|---|
| `services/token-service/Dockerfile` | Container image for Cloud Run |
| `services/token-service/requirements.txt` | Python dependencies |
| `services/token-service/app/__init__.py` | Package init |
| `services/token-service/app/main.py` | FastAPI app, lifespan, route registration |
| `services/token-service/app/config.py` | Environment variables, settings |
| `services/token-service/app/db.py` | SQLAlchemy async engine, session factory, connection pool |
| `services/token-service/app/models.py` | `oauth_credentials` SQLAlchemy model |
| `services/token-service/app/encryption.py` | AES-256-GCM encrypt/decrypt using cryptography.hazmat AESGCM |
| `services/token-service/app/services/__init__.py` | Package init |
| `services/token-service/app/providers/__init__.py` | Package init |
| `services/token-service/app/routes/__init__.py` | Package init |
| `services/token-service/app/providers/base.py` | Abstract base class for OAuth providers |
| `services/token-service/app/providers/shopify.py` | Shopify-specific token refresh logic |
| `services/token-service/app/services/token_manager.py` | Core logic: proactive refresh loop, lazy refresh, single-flight lock |
| `services/token-service/app/services/state_nonce.py` | HMAC-SHA256 state nonce for CSRF protection |
| `services/token-service/app/routes/token.py` | `GET /token/{provider}` — token vending |
| `services/token-service/app/routes/oauth.py` | `GET /connect/{provider}`, `GET /callback/{provider}` — bootstrap |
| `services/token-service/app/routes/admin.py` | `POST /rotate/{provider}`, `GET /status` |
| `services/token-service/app/routes/health.py` | `GET /health`, `GET /metrics` |
| `services/token-service/tests/conftest.py` | Pytest fixtures (test DB, test client, mock Shopify) |
| `services/token-service/tests/test_encryption.py` | Encryption round-trip tests |
| `services/token-service/tests/test_token_manager.py` | Refresh loop, lazy refresh, single-flight tests |
| `services/token-service/tests/test_state_nonce.py` | Nonce generation, verification, expiry tests |
| `services/token-service/tests/test_routes.py` | API endpoint integration tests |
| `services/token-service/tests/test_providers_shopify.py` | Shopify provider tests (mocked HTTP) |

### New: `services/credential-proxy/`

| File | Responsibility |
|---|---|
| `services/credential-proxy/Dockerfile` | Container image for Cloud Run sidecar |
| `services/credential-proxy/requirements.txt` | Python dependencies |
| `services/credential-proxy/proxy.py` | Complete proxy application (~80 lines) |
| `services/credential-proxy/tests/test_proxy.py` | Proxy integration tests |

### Modified

| File | Change |
|---|---|
| `services/apollo/config.yaml` | Point endpoint at `localhost:8080`, remove token header |
| `docker-compose.yml` | Add token-service + credential-proxy services, modify apollo |
| `.env.example` | Add token-service env vars |
| `services/db-init.sh` | Add token-service DB init script reference |
| `services/token-service/db/init.sql` | New: `oauth_credentials` table DDL |

---

## Task 1: Database Schema and Init Script

**Files:**
- Create: `services/token-service/db/init.sql`
- Modify: `services/db-init.sh`
- Modify: `docker-compose.yml` (mount SQL file)

- [ ] **Step 1: Write the SQL init script**

Create `services/token-service/db/init.sql`:

```sql
-- Token Service database objects
-- Runs as postgres superuser during docker-entrypoint-initdb

-- Create token_service user (reuses contextforge database)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'token_service_user') THEN
        EXECUTE format('CREATE ROLE token_service_user LOGIN PASSWORD %L', :'TOKEN_SERVICE_DB_PASS');
    END IF;
END
$$;

-- Create table in contextforge database
\connect contextforge

CREATE TABLE IF NOT EXISTS oauth_credentials (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    provider                 TEXT NOT NULL,
    account_id               TEXT NOT NULL,
    encrypted_access_token   TEXT NOT NULL,
    encrypted_refresh_token  TEXT,
    token_expires_at         TIMESTAMPTZ NOT NULL,
    refresh_token_expires_at TIMESTAMPTZ,
    scopes                   TEXT,
    status                   TEXT NOT NULL DEFAULT 'active',
    failure_count            INT NOT NULL DEFAULT 0,
    last_refreshed_at        TIMESTAMPTZ,
    last_error               TEXT,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(provider, account_id)
);

CREATE INDEX IF NOT EXISTS idx_credentials_expiry
    ON oauth_credentials(token_expires_at)
    WHERE status = 'active';

-- Grant permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth_credentials TO token_service_user;
GRANT USAGE ON SCHEMA public TO token_service_user;
```

- [ ] **Step 2: Update db-init.sh to accept TOKEN_SERVICE_DB_PASS**

Replace the full content of `services/db-init.sh` with:

```bash
#!/bin/bash
# services/db-init.sh
# Runs all service DB init scripts in sequence.
# Mounted into postgres container via docker-compose.
set -euo pipefail

for sql in /docker-entrypoint-initdb.d/sql/*.sql; do
    echo "Running $sql..."
    psql -v ON_ERROR_STOP=1 \
         --username "$POSTGRES_USER" \
         --dbname postgres \
         --variable=CONTEXTFORGE_DB_PASS="${CONTEXTFORGE_DB_PASS}" \
         --variable=KEYCLOAK_DB_PASS="${KEYCLOAK_DB_PASS}" \
         --variable=TOKEN_SERVICE_DB_PASS="${TOKEN_SERVICE_DB_PASS}" \
         --file "$sql"
done
```

- [ ] **Step 3: Mount the new SQL file in docker-compose.yml**

Add under the `postgres` service `volumes`:
```yaml
- ./services/token-service/db/init.sql:/docker-entrypoint-initdb.d/sql/03-token-service.sql:ro
```

Add `TOKEN_SERVICE_DB_PASS: ${TOKEN_SERVICE_DB_PASS:?required}` to the postgres `environment`.

- [ ] **Step 4: Add TOKEN_SERVICE_DB_PASS to .env.example**

Add under `# === Required (generate each) ===`:
```
TOKEN_SERVICE_DB_PASS=
```

- [ ] **Step 5: Test locally**

Run: `docker compose down -v && docker compose up postgres -d && docker compose logs postgres`
Expected: See "Running /docker-entrypoint-initdb.d/sql/03-token-service.sql..." and no errors.

Verify table exists:
```bash
docker compose exec postgres psql -U postgres -d contextforge -c "\dt oauth_credentials"
```
Expected: Table listed.

- [ ] **Step 6: Commit**

```bash
git add services/token-service/db/init.sql services/db-init.sh docker-compose.yml .env.example
git commit -m "feat(token-service): add oauth_credentials table schema and DB init"
```

---

## Task 2: Encryption Module

**Files:**
- Create: `services/token-service/app/__init__.py`
- Create: `services/token-service/app/config.py`
- Create: `services/token-service/app/encryption.py`
- Create: `services/token-service/tests/__init__.py`
- Create: `services/token-service/tests/test_encryption.py`
- Create: `services/token-service/requirements.txt`

- [ ] **Step 1: Create requirements.txt**

```
fastapi==0.115.*
uvicorn[standard]==0.34.*
httpx==0.28.*
sqlalchemy[asyncio]==2.0.*
asyncpg==0.30.*
cryptography==44.*
prometheus-client==0.22.*
google-auth==2.38.*
pytest==8.*
pytest-asyncio==0.25.*
```

- [ ] **Step 2: Write config.py**

```python
import os

class Settings:
    DATABASE_URL: str = os.environ.get(
        "DATABASE_URL",
        "postgresql+asyncpg://token_service_user:password@localhost:5432/contextforge"
    )
    DB_POOL_SIZE: int = int(os.environ.get("DB_POOL_SIZE", "2"))
    DB_MAX_OVERFLOW: int = int(os.environ.get("DB_MAX_OVERFLOW", "2"))
    TOKEN_ENCRYPTION_KEY: str = os.environ.get("TOKEN_ENCRYPTION_KEY", "")
    SHOPIFY_CLIENT_ID: str = os.environ.get("SHOPIFY_CLIENT_ID", "")
    SHOPIFY_CLIENT_SECRET: str = os.environ.get("SHOPIFY_CLIENT_SECRET", "")
    BASE_URL: str = os.environ.get("BASE_URL", "http://localhost:8010")
    REFRESH_INTERVAL_SECONDS: int = int(os.environ.get("REFRESH_INTERVAL_SECONDS", "2700"))  # 45 min

settings = Settings()
```

- [ ] **Step 3: Write the failing test for encryption**

Create `services/token-service/tests/test_encryption.py`:

```python
from app.encryption import encrypt_token, decrypt_token

TEST_KEY = "dGVzdC1rZXktMzItYnl0ZXMtZm9yLWFlczI1Ng=="  # base64 of 32 bytes


def test_encrypt_decrypt_round_trip():
    plaintext = "shpat_test_token_12345"
    ciphertext = encrypt_token(plaintext, TEST_KEY)
    assert ciphertext != plaintext
    assert decrypt_token(ciphertext, TEST_KEY) == plaintext


def test_different_plaintexts_produce_different_ciphertexts():
    a = encrypt_token("token_a", TEST_KEY)
    b = encrypt_token("token_b", TEST_KEY)
    assert a != b


def test_decrypt_with_wrong_key_fails():
    import pytest
    ciphertext = encrypt_token("secret", TEST_KEY)
    wrong_key = "d3Jvbmcta2V5LTMyLWJ5dGVzLWZvci1hZXMyNTY="
    with pytest.raises(Exception):
        decrypt_token(ciphertext, wrong_key)
```

- [ ] **Step 4: Run test to verify it fails**

```bash
cd services/token-service && pip install -r requirements.txt && python -m pytest tests/test_encryption.py -v
```
Expected: FAIL — `ModuleNotFoundError: No module named 'app.encryption'`

- [ ] **Step 5: Write encryption.py (AES-256-GCM per spec)**

```python
import base64
import hashlib
import os

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def _derive_key(key_string: str) -> bytes:
    """Derive a 32-byte AES-256 key from an arbitrary string via SHA-256."""
    return hashlib.sha256(key_string.encode()).digest()


def encrypt_token(plaintext: str, key: str) -> str:
    """Encrypt with AES-256-GCM. Returns base64(nonce + ciphertext)."""
    aes_key = _derive_key(key)
    aesgcm = AESGCM(aes_key)
    nonce = os.urandom(12)  # 96-bit nonce for GCM
    ciphertext = aesgcm.encrypt(nonce, plaintext.encode(), None)
    return base64.urlsafe_b64encode(nonce + ciphertext).decode()


def decrypt_token(ciphertext: str, key: str) -> str:
    """Decrypt AES-256-GCM. Expects base64(nonce + ciphertext)."""
    aes_key = _derive_key(key)
    aesgcm = AESGCM(aes_key)
    raw = base64.urlsafe_b64decode(ciphertext.encode())
    nonce = raw[:12]
    ct = raw[12:]
    return aesgcm.decrypt(nonce, ct, None).decode()
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd services/token-service && python -m pytest tests/test_encryption.py -v
```
Expected: 3 tests PASS

- [ ] **Step 7: Commit**

```bash
git add services/token-service/
git commit -m "feat(token-service): AES-256-GCM encryption module using cryptography AESGCM"
```

---

## Task 3: Database Layer (SQLAlchemy Async)

**Files:**
- Create: `services/token-service/app/db.py`
- Create: `services/token-service/app/models.py`

- [ ] **Step 1: Write db.py**

```python
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession
from app.config import settings

engine = create_async_engine(
    settings.DATABASE_URL,
    pool_size=settings.DB_POOL_SIZE,
    max_overflow=settings.DB_MAX_OVERFLOW,
    echo=False,
)

async_session = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


async def get_session() -> AsyncSession:
    async with async_session() as session:
        yield session
```

- [ ] **Step 2: Write models.py**

```python
import uuid
from datetime import datetime
from sqlalchemy import Column, Text, Integer, DateTime, UniqueConstraint, Index
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    pass


class OAuthCredential(Base):
    __tablename__ = "oauth_credentials"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    provider = Column(Text, nullable=False)
    account_id = Column(Text, nullable=False)
    encrypted_access_token = Column(Text, nullable=False)
    encrypted_refresh_token = Column(Text, nullable=True)
    token_expires_at = Column(DateTime(timezone=True), nullable=False)
    refresh_token_expires_at = Column(DateTime(timezone=True), nullable=True)
    scopes = Column(Text, nullable=True)
    status = Column(Text, nullable=False, default="active")
    failure_count = Column(Integer, nullable=False, default=0)
    last_refreshed_at = Column(DateTime(timezone=True), nullable=True)
    last_error = Column(Text, nullable=True)
    created_at = Column(DateTime(timezone=True), nullable=False, default=datetime.utcnow)
    updated_at = Column(DateTime(timezone=True), nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)

    __table_args__ = (
        UniqueConstraint("provider", "account_id"),
        Index("idx_credentials_expiry", "token_expires_at", postgresql_where="status = 'active'"),
    )
```

- [ ] **Step 3: Commit**

```bash
git add services/token-service/app/db.py services/token-service/app/models.py
git commit -m "feat(token-service): SQLAlchemy async DB layer and OAuthCredential model"
```

---

## Task 4: Shopify Provider

**Files:**
- Create: `services/token-service/app/providers/base.py`
- Create: `services/token-service/app/providers/shopify.py`
- Create: `services/token-service/tests/test_providers_shopify.py`

- [ ] **Step 1: Write the failing test**

```python
import pytest
import httpx
from unittest.mock import AsyncMock, patch
from app.providers.shopify import ShopifyProvider


@pytest.fixture
def provider():
    return ShopifyProvider(
        client_id="test_client_id",
        client_secret="test_client_secret",
    )


@pytest.mark.asyncio
async def test_refresh_token_success(provider):
    mock_response = httpx.Response(
        200,
        json={
            "access_token": "shpat_new_token",
            "expires_in": 3600,
            "refresh_token": "shprt_new_refresh",
            "refresh_token_expires_in": 7776000,
            "scope": "read_products,write_products",
        },
    )
    with patch("app.providers.shopify.httpx.AsyncClient") as MockClient:
        mock_client = AsyncMock()
        mock_client.post.return_value = mock_response
        mock_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client.__aexit__ = AsyncMock(return_value=False)
        MockClient.return_value = mock_client

        result = await provider.refresh(
            shop_domain="test.myshopify.com",
            refresh_token="shprt_old_refresh",
        )

    assert result["access_token"] == "shpat_new_token"
    assert result["refresh_token"] == "shprt_new_refresh"
    assert result["expires_in"] == 3600


@pytest.mark.asyncio
async def test_refresh_token_invalid_grant(provider):
    mock_response = httpx.Response(
        400,
        json={"error": "invalid_grant", "error_description": "Token has been expired or revoked."},
    )
    with patch("app.providers.shopify.httpx.AsyncClient") as MockClient:
        mock_client = AsyncMock()
        mock_client.post.return_value = mock_response
        mock_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client.__aexit__ = AsyncMock(return_value=False)
        MockClient.return_value = mock_client

        from app.providers.base import InvalidGrantError
        with pytest.raises(InvalidGrantError):
            await provider.refresh(
                shop_domain="test.myshopify.com",
                refresh_token="shprt_dead",
            )
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/token-service && python -m pytest tests/test_providers_shopify.py -v
```
Expected: FAIL — `ModuleNotFoundError`

- [ ] **Step 3: Write base.py**

```python
from abc import ABC, abstractmethod


class InvalidGrantError(Exception):
    """Refresh token has been revoked or expired. Requires re-authorization."""
    pass


class RefreshError(Exception):
    """Transient refresh failure (network, 5xx, etc.)."""
    pass


class OAuthProvider(ABC):
    @abstractmethod
    async def refresh(self, shop_domain: str, refresh_token: str) -> dict:
        """Refresh tokens. Returns dict with access_token, refresh_token, expires_in, etc."""
        ...

    @abstractmethod
    def build_authorize_url(self, shop_domain: str, redirect_uri: str, state: str) -> str:
        """Build the OAuth authorization URL for initial bootstrap."""
        ...

    @abstractmethod
    async def exchange_code(self, shop_domain: str, code: str) -> dict:
        """Exchange authorization code for tokens."""
        ...
```

- [ ] **Step 4: Write shopify.py**

```python
import httpx
from app.providers.base import OAuthProvider, InvalidGrantError, RefreshError


class ShopifyProvider(OAuthProvider):
    def __init__(self, client_id: str, client_secret: str):
        self.client_id = client_id
        self.client_secret = client_secret

    def _token_url(self, shop_domain: str) -> str:
        return f"https://{shop_domain}/admin/oauth/access_token"

    async def refresh(self, shop_domain: str, refresh_token: str) -> dict:
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.post(
                self._token_url(shop_domain),
                data={
                    "client_id": self.client_id,
                    "client_secret": self.client_secret,
                    "grant_type": "refresh_token",
                    "refresh_token": refresh_token,
                },
                headers={"Accept": "application/json"},
            )

        if resp.status_code == 400:
            body = resp.json()
            if body.get("error") == "invalid_grant":
                raise InvalidGrantError(body.get("error_description", "Token revoked or expired"))
            raise RefreshError(f"Shopify 400: {body}")

        if resp.status_code != 200:
            raise RefreshError(f"Shopify {resp.status_code}: {resp.text}")

        return resp.json()

    def build_authorize_url(self, shop_domain: str, redirect_uri: str, state: str) -> str:
        scopes = (
            "read_products,write_products,read_customers,write_customers,"
            "read_orders,write_orders,read_draft_orders,write_draft_orders,"
            "read_inventory,write_inventory,read_fulfillments,write_fulfillments,"
            "read_discounts,write_discounts,read_locations"
        )
        return (
            f"https://{shop_domain}/admin/oauth/authorize?"
            f"client_id={self.client_id}&"
            f"scope={scopes}&"
            f"redirect_uri={redirect_uri}&"
            f"state={state}&"
            f"expiring=1"
        )

    async def exchange_code(self, shop_domain: str, code: str) -> dict:
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.post(
                self._token_url(shop_domain),
                data={
                    "client_id": self.client_id,
                    "client_secret": self.client_secret,
                    "code": code,
                    "expiring": "1",
                },
                headers={"Accept": "application/json"},
            )
        if resp.status_code != 200:
            raise RefreshError(f"Shopify code exchange failed: {resp.status_code} {resp.text}")
        return resp.json()
```

- [ ] **Step 5: Create `__init__.py` files**

Create empty `services/token-service/app/providers/__init__.py` and `services/token-service/tests/__init__.py`.

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd services/token-service && python -m pytest tests/test_providers_shopify.py -v
```
Expected: 2 tests PASS

- [ ] **Step 7: Commit**

```bash
git add services/token-service/app/providers/ services/token-service/tests/
git commit -m "feat(token-service): Shopify OAuth provider with refresh and code exchange"
```

---

## Task 5: State Nonce (CSRF Protection)

**Files:**
- Create: `services/token-service/app/services/state_nonce.py`
- Create: `services/token-service/tests/test_state_nonce.py`

- [ ] **Step 1: Write the failing test**

```python
import time
import pytest
from app.services.state_nonce import generate_nonce, verify_nonce

TEST_KEY = "test-hmac-key-for-nonce-signing"


def test_generate_and_verify():
    nonce = generate_nonce("shopify", TEST_KEY)
    assert verify_nonce(nonce, "shopify", TEST_KEY) is True


def test_wrong_provider_fails():
    nonce = generate_nonce("shopify", TEST_KEY)
    assert verify_nonce(nonce, "google", TEST_KEY) is False


def test_wrong_key_fails():
    nonce = generate_nonce("shopify", TEST_KEY)
    assert verify_nonce(nonce, "shopify", "wrong-key") is False


def test_expired_nonce_fails(monkeypatch):
    nonce = generate_nonce("shopify", TEST_KEY)
    # Fast-forward time by 11 minutes (TTL is 10 min)
    monkeypatch.setattr("app.services.state_nonce.time.time", lambda: time.time() + 660)
    assert verify_nonce(nonce, "shopify", TEST_KEY) is False
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/token-service && python -m pytest tests/test_state_nonce.py -v
```
Expected: FAIL

- [ ] **Step 3: Write state_nonce.py**

```python
import base64
import hashlib
import hmac
import os
import time

NONCE_TTL_SECONDS = 600  # 10 minutes


def generate_nonce(provider: str, key: str) -> str:
    timestamp = str(int(time.time()))
    random_bytes = base64.urlsafe_b64encode(os.urandom(16)).decode()
    payload = f"{provider}:{timestamp}:{random_bytes}"
    signature = _sign(payload, key)
    return base64.urlsafe_b64encode(f"{payload}:{signature}".encode()).decode()


def verify_nonce(nonce: str, expected_provider: str, key: str) -> bool:
    try:
        decoded = base64.urlsafe_b64decode(nonce.encode()).decode()
        parts = decoded.rsplit(":", 1)
        if len(parts) != 2:
            return False
        payload, signature = parts

        # Verify HMAC
        if not hmac.compare_digest(signature, _sign(payload, key)):
            return False

        # Verify provider
        provider, timestamp, _ = payload.split(":", 2)
        if provider != expected_provider:
            return False

        # Verify TTL
        if time.time() - int(timestamp) > NONCE_TTL_SECONDS:
            return False

        return True
    except Exception:
        return False


def _sign(payload: str, key: str) -> str:
    return hmac.new(
        key.encode(), payload.encode(), hashlib.sha256
    ).hexdigest()
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/token-service && python -m pytest tests/test_state_nonce.py -v
```
Expected: 4 tests PASS

- [ ] **Step 5: Commit**

```bash
git add services/token-service/app/services/ services/token-service/tests/test_state_nonce.py
git commit -m "feat(token-service): HMAC-SHA256 state nonce for OAuth CSRF protection"
```

---

## Task 6: Token Manager (Core Logic)

**Files:**
- Create: `services/token-service/app/services/token_manager.py`
- Create: `services/token-service/tests/test_token_manager.py`

- [ ] **Step 1: Write the failing test**

```python
import pytest
import asyncio
from unittest.mock import AsyncMock, MagicMock, patch
from datetime import datetime, timezone, timedelta
from app.services.token_manager import TokenManager, SingleFlight


class TestSingleFlight:
    @pytest.mark.asyncio
    async def test_concurrent_calls_only_execute_once(self):
        sf = SingleFlight()
        call_count = 0

        async def slow_fn():
            nonlocal call_count
            call_count += 1
            await asyncio.sleep(0.1)
            return "result"

        # Launch 5 concurrent calls
        results = await asyncio.gather(
            sf.do("key", slow_fn),
            sf.do("key", slow_fn),
            sf.do("key", slow_fn),
            sf.do("key", slow_fn),
            sf.do("key", slow_fn),
        )

        assert call_count == 1  # Only one execution
        assert all(r == "result" for r in results)

    @pytest.mark.asyncio
    async def test_different_keys_execute_independently(self):
        sf = SingleFlight()
        calls = []

        async def fn(name):
            calls.append(name)
            return name

        await asyncio.gather(
            sf.do("a", lambda: fn("a")),
            sf.do("b", lambda: fn("b")),
        )
        assert sorted(calls) == ["a", "b"]

    @pytest.mark.asyncio
    async def test_exception_propagates_to_all_waiters(self):
        sf = SingleFlight()

        async def failing_fn():
            raise ValueError("boom")

        with pytest.raises(ValueError, match="boom"):
            await asyncio.gather(
                sf.do("key", failing_fn),
                sf.do("key", failing_fn),
            )
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/token-service && python -m pytest tests/test_token_manager.py::TestSingleFlight -v
```
Expected: FAIL

- [ ] **Step 3: Write token_manager.py**

```python
import asyncio
import logging
import time
from datetime import datetime, timezone, timedelta
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import async_session
from app.encryption import encrypt_token, decrypt_token
from app.models import OAuthCredential
from app.providers.base import InvalidGrantError, RefreshError

logger = logging.getLogger(__name__)


class SingleFlight:
    """Ensures only one execution per key at a time. Others await the result."""

    def __init__(self):
        self._flights: dict[str, asyncio.Future] = {}

    async def do(self, key: str, fn):
        if key in self._flights:
            return await self._flights[key]

        loop = asyncio.get_event_loop()
        future = loop.create_future()
        self._flights[key] = future
        try:
            result = await fn()
            future.set_result(result)
            return result
        except Exception as e:
            future.set_exception(e)
            raise
        finally:
            self._flights.pop(key, None)


class TokenManager:
    def __init__(self, providers: dict):
        self.providers = providers  # {"shopify": ShopifyProvider, ...}
        self.single_flight = SingleFlight()
        self._cache: dict[str, tuple[str, float, float]] = {}  # key -> (token, expires_at, cached_at)
        self._running = False

    # ── Token Vending (with lazy refresh) ────────────────────────────

    async def get_token(self, provider: str, account_id: str | None = None) -> dict:
        """Get a valid access token. Triggers lazy refresh if near-expiry."""
        cache_key = f"{provider}:{account_id or 'default'}"

        # Check in-memory cache (30s TTL)
        if cache_key in self._cache:
            token, expires_at, cached_at = self._cache[cache_key]
            if time.time() - cached_at < 30 and expires_at > time.time() + 300:
                return {"access_token": token, "expires_in": int(expires_at - time.time())}

        # Read from DB
        async with async_session() as session:
            stmt = select(OAuthCredential).where(
                OAuthCredential.provider == provider,
                OAuthCredential.status == "active",
            )
            if account_id:
                stmt = stmt.where(OAuthCredential.account_id == account_id)
            result = await session.execute(stmt)
            cred = result.scalar_one_or_none()

        if not cred:
            raise ValueError(f"No active credential for provider={provider}")

        key = settings.TOKEN_ENCRYPTION_KEY
        access_token = decrypt_token(cred.encrypted_access_token, key)
        expires_at = cred.token_expires_at.timestamp()

        # If near-expiry (< 5 min), trigger lazy refresh
        if expires_at < time.time() + 300:
            access_token, expires_at = await self.single_flight.do(
                cache_key,
                lambda: self._do_refresh(cred.provider, cred.account_id),
            )

        # Update cache
        self._cache[cache_key] = (access_token, expires_at, time.time())
        return {
            "access_token": access_token,
            "expires_in": int(expires_at - time.time()),
            "provider": provider,
            "account_id": cred.account_id,
        }

    # ── Refresh Logic ────────────────────────────────────────────────

    async def _do_refresh(self, provider: str, account_id: str) -> tuple[str, float]:
        """Refresh a single credential. Returns (access_token, expires_at_timestamp)."""
        prov = self.providers.get(provider)
        if not prov:
            raise ValueError(f"Unknown provider: {provider}")

        key = settings.TOKEN_ENCRYPTION_KEY

        async with async_session() as session:
            async with session.begin():
                # Advisory lock prevents concurrent refresh across processes
                lock_key = f"{provider}:{account_id}"
                await session.execute(text(f"SELECT pg_advisory_xact_lock(hashtext(:key))"), {"key": lock_key})

                # Re-read inside transaction
                stmt = select(OAuthCredential).where(
                    OAuthCredential.provider == provider,
                    OAuthCredential.account_id == account_id,
                )
                result = await session.execute(stmt)
                cred = result.scalar_one_or_none()
                if not cred:
                    raise ValueError(f"Credential not found: {provider}:{account_id}")

                # Check if already refreshed by another process
                if cred.token_expires_at.timestamp() > time.time() + 300:
                    token = decrypt_token(cred.encrypted_access_token, key)
                    return token, cred.token_expires_at.timestamp()

                # Actually refresh
                refresh_token = decrypt_token(cred.encrypted_refresh_token, key)
                try:
                    tokens = await prov.refresh(
                        shop_domain=account_id,
                        refresh_token=refresh_token,
                    )
                except InvalidGrantError as e:
                    cred.status = "requires_reauth"
                    cred.last_error = str(e)
                    cred.updated_at = datetime.now(timezone.utc)
                    logger.critical(f"INVALID_GRANT for {provider}:{account_id}: {e}")
                    raise
                except RefreshError as e:
                    cred.failure_count += 1
                    cred.last_error = str(e)
                    cred.updated_at = datetime.now(timezone.utc)
                    logger.error(f"Refresh failed for {provider}:{account_id}: {e}")
                    raise

                # Atomic write
                now = datetime.now(timezone.utc)
                cred.encrypted_access_token = encrypt_token(tokens["access_token"], key)
                if tokens.get("refresh_token"):
                    cred.encrypted_refresh_token = encrypt_token(tokens["refresh_token"], key)
                cred.token_expires_at = now + timedelta(seconds=tokens["expires_in"])
                if tokens.get("refresh_token_expires_in"):
                    cred.refresh_token_expires_at = now + timedelta(seconds=tokens["refresh_token_expires_in"])
                cred.last_refreshed_at = now
                cred.failure_count = 0
                cred.last_error = None
                cred.updated_at = now
                cred.scopes = tokens.get("scope", cred.scopes)

                new_token = tokens["access_token"]
                new_expires = cred.token_expires_at.timestamp()
                logger.info(f"Refreshed {provider}:{account_id}, expires in {tokens['expires_in']}s")

        return new_token, new_expires

    # ── Proactive Refresh Loop ───────────────────────────────────────

    async def start_refresh_loop(self):
        """Background loop that proactively refreshes tokens before expiry."""
        self._running = True
        logger.info(f"Starting proactive refresh loop (interval={settings.REFRESH_INTERVAL_SECONDS}s)")
        while self._running:
            try:
                await self._refresh_expiring_credentials()
            except Exception:
                logger.exception("Error in proactive refresh loop")
            await asyncio.sleep(settings.REFRESH_INTERVAL_SECONDS)

    async def stop_refresh_loop(self):
        self._running = False

    async def _refresh_expiring_credentials(self):
        """Find and refresh credentials expiring in the next 15 minutes."""
        threshold = datetime.now(timezone.utc) + timedelta(minutes=15)
        async with async_session() as session:
            stmt = select(OAuthCredential).where(
                OAuthCredential.status == "active",
                OAuthCredential.token_expires_at < threshold,
            )
            result = await session.execute(stmt)
            expiring = result.scalars().all()

        for cred in expiring:
            try:
                await self._do_refresh(cred.provider, cred.account_id)
            except (InvalidGrantError, RefreshError):
                pass  # Already logged and updated in _do_refresh
            except Exception:
                logger.exception(f"Unexpected error refreshing {cred.provider}:{cred.account_id}")
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/token-service && python -m pytest tests/test_token_manager.py -v
```
Expected: 3 tests PASS

- [ ] **Step 5: Commit**

```bash
git add services/token-service/app/services/token_manager.py services/token-service/tests/test_token_manager.py
git commit -m "feat(token-service): token manager with single-flight lock and proactive refresh"
```

---

## Task 7: API Routes

**Files:**
- Create: `services/token-service/app/routes/token.py`
- Create: `services/token-service/app/routes/oauth.py`
- Create: `services/token-service/app/routes/admin.py`
- Create: `services/token-service/app/routes/health.py`
- Create: `services/token-service/app/routes/__init__.py`
- Create: `services/token-service/app/main.py`
- Create: `services/token-service/tests/test_routes.py`

- [ ] **Step 1: Write health.py**

```python
from fastapi import APIRouter
from fastapi.responses import JSONResponse, Response
from prometheus_client import generate_latest, CONTENT_TYPE_LATEST
from sqlalchemy import select

from app.db import async_session
from app.models import OAuthCredential

router = APIRouter()


@router.get("/health")
async def health():
    """Minimal health check. Returns 503 if any provider is degraded."""
    try:
        async with async_session() as session:
            stmt = select(OAuthCredential.status).where(
                OAuthCredential.status.in_(["error", "requires_reauth"])
            )
            result = await session.execute(stmt)
            degraded = result.scalars().all()
        if degraded:
            return JSONResponse({"status": "degraded"}, status_code=503)
    except Exception:
        pass  # DB not available — still report healthy for Cloud Run startup
    return {"status": "healthy"}


@router.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
```

- [ ] **Step 2: Write token.py**

```python
from fastapi import APIRouter, HTTPException
from app.services.token_manager import TokenManager

router = APIRouter()
token_manager: TokenManager | None = None  # Set during app startup


@router.get("/token/{provider}")
async def get_token(provider: str, account_id: str | None = None):
    try:
        return await token_manager.get_token(provider, account_id)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=503, detail={"error": "refresh_failed", "message": str(e)})
```

- [ ] **Step 3: Write oauth.py**

```python
from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import RedirectResponse, HTMLResponse
from datetime import datetime, timezone, timedelta

from app.config import settings
from app.encryption import encrypt_token
from app.db import async_session
from app.models import OAuthCredential
from app.services.state_nonce import generate_nonce, verify_nonce

router = APIRouter()
providers: dict = {}  # Set during app startup


@router.get("/connect/{provider}")
async def connect(provider: str, shop: str = Query(..., description="Shop domain")):
    prov = providers.get(provider)
    if not prov:
        raise HTTPException(status_code=404, detail=f"Unknown provider: {provider}")

    state = generate_nonce(provider, settings.TOKEN_ENCRYPTION_KEY)
    redirect_uri = f"{settings.BASE_URL}/callback/{provider}"
    url = prov.build_authorize_url(shop, redirect_uri, state)
    return RedirectResponse(url)


@router.get("/callback/{provider}")
async def callback(provider: str, code: str, state: str, shop: str):
    prov = providers.get(provider)
    if not prov:
        raise HTTPException(status_code=404, detail=f"Unknown provider: {provider}")

    if not verify_nonce(state, provider, settings.TOKEN_ENCRYPTION_KEY):
        raise HTTPException(status_code=400, detail="Invalid or expired state nonce")

    tokens = await prov.exchange_code(shop, code)
    key = settings.TOKEN_ENCRYPTION_KEY
    now = datetime.now(timezone.utc)

    cred = OAuthCredential(
        provider=provider,
        account_id=shop,
        encrypted_access_token=encrypt_token(tokens["access_token"], key),
        encrypted_refresh_token=encrypt_token(tokens["refresh_token"], key) if tokens.get("refresh_token") else None,
        token_expires_at=now + timedelta(seconds=tokens.get("expires_in", 3600)),
        refresh_token_expires_at=now + timedelta(seconds=tokens["refresh_token_expires_in"]) if tokens.get("refresh_token_expires_in") else None,
        scopes=tokens.get("scope"),
        last_refreshed_at=now,
    )

    async with async_session() as session:
        async with session.begin():
            session.add(cred)

    return HTMLResponse(
        "<h1>Connected!</h1>"
        f"<p>Provider: {provider}</p>"
        f"<p>Account: {shop}</p>"
        f"<p>Token expires in {tokens.get('expires_in', '?')} seconds. Auto-refresh is active.</p>"
    )
```

- [ ] **Step 4: Write admin.py**

```python
from fastapi import APIRouter, HTTPException
from sqlalchemy import select
from app.db import async_session
from app.models import OAuthCredential
from app.encryption import decrypt_token
from app.config import settings
import time

router = APIRouter()
token_manager = None  # Set during app startup


@router.post("/rotate/{provider}")
async def rotate(provider: str, account_id: str | None = None):
    # If no account_id given, find the first active credential for this provider
    if not account_id:
        async with async_session() as session:
            from sqlalchemy import select
            stmt = select(OAuthCredential.account_id).where(
                OAuthCredential.provider == provider,
                OAuthCredential.status == "active",
            ).limit(1)
            result = await session.execute(stmt)
            row = result.scalar_one_or_none()
            if not row:
                raise HTTPException(status_code=404, detail=f"No active credential for {provider}")
            account_id = row

    try:
        result = await token_manager._do_refresh(provider, account_id)
        return {"status": "rotated", "provider": provider, "expires_in": int(result[1] - time.time())}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/status")
async def status():
    async with async_session() as session:
        result = await session.execute(select(OAuthCredential))
        creds = result.scalars().all()

    providers = {}
    now = time.time()
    for cred in creds:
        providers[cred.provider] = {
            "status": cred.status,
            "account_id": cred.account_id,
            "token_expires_in_seconds": max(0, int(cred.token_expires_at.timestamp() - now)),
            "refresh_token_expires_in_days": (
                max(0, int((cred.refresh_token_expires_at.timestamp() - now) / 86400))
                if cred.refresh_token_expires_at else None
            ),
            "last_refreshed_at": cred.last_refreshed_at.isoformat() if cred.last_refreshed_at else None,
            "failure_count": cred.failure_count,
            "last_error": cred.last_error,
        }

    return {"providers": providers}
```

- [ ] **Step 5: Write main.py**

```python
import asyncio
import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI

from app.config import settings
from app.providers.shopify import ShopifyProvider
from app.services.token_manager import TokenManager
from app.routes import health, token, oauth, admin

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

# Initialize providers
providers = {
    "shopify": ShopifyProvider(
        client_id=settings.SHOPIFY_CLIENT_ID,
        client_secret=settings.SHOPIFY_CLIENT_SECRET,
    ),
}

# Initialize token manager
manager = TokenManager(providers=providers)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Start background refresh loop
    refresh_task = asyncio.create_task(manager.start_refresh_loop())
    yield
    # Shutdown
    await manager.stop_refresh_loop()
    refresh_task.cancel()
    try:
        await refresh_task
    except asyncio.CancelledError:
        pass


app = FastAPI(title="Token Service", lifespan=lifespan)

# Wire up shared state
token.token_manager = manager
admin.token_manager = manager
oauth.providers = providers

# Register routes
app.include_router(health.router)
app.include_router(token.router)
app.include_router(oauth.router)
app.include_router(admin.router)
```

- [ ] **Step 6: Write Dockerfile**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ app/
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

- [ ] **Step 7: Write basic route tests**

Note: Full route integration tests require a running PostgreSQL instance. For CI, use `testcontainers` or a docker-compose test profile. For now, unit test the route handlers with mocked DB.

Create `services/token-service/tests/test_routes.py`:

```python
import pytest
from unittest.mock import patch, AsyncMock
from fastapi.testclient import TestClient


@pytest.fixture
def client():
    """Create test client with mocked DB."""
    import os
    os.environ.setdefault("TOKEN_ENCRYPTION_KEY", "test-key")
    os.environ.setdefault("SHOPIFY_CLIENT_ID", "test")
    os.environ.setdefault("SHOPIFY_CLIENT_SECRET", "test")
    os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://x:x@localhost/test")

    # Mock the DB session to avoid real PostgreSQL connection
    with patch("app.routes.health.async_session") as mock_session:
        mock_ctx = AsyncMock()
        mock_ctx.__aenter__ = AsyncMock(return_value=mock_ctx)
        mock_ctx.__aexit__ = AsyncMock(return_value=False)
        mock_result = AsyncMock()
        mock_result.scalars.return_value.all.return_value = []  # No degraded providers
        mock_ctx.execute = AsyncMock(return_value=mock_result)
        mock_session.return_value = mock_ctx

        from app.main import app
        yield TestClient(app, raise_server_exceptions=False)


def test_health_endpoint(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "healthy"}
```

- [ ] **Step 8: Run tests**

```bash
cd services/token-service && python -m pytest tests/test_routes.py -v
```
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add services/token-service/
git commit -m "feat(token-service): all API routes, FastAPI app, and Dockerfile"
```

---

## Task 8: Credential Proxy

**Files:**
- Create: `services/credential-proxy/proxy.py`
- Create: `services/credential-proxy/requirements.txt`
- Create: `services/credential-proxy/Dockerfile`
- Create: `services/credential-proxy/tests/test_proxy.py`

- [ ] **Step 1: Write requirements.txt**

```
fastapi==0.115.*
uvicorn[standard]==0.34.*
httpx==0.28.*
google-auth==2.38.*
pytest==8.*
```

- [ ] **Step 2: Write proxy.py**

Copy the complete proxy code from the spec (section 7.2, post-review version). Includes:
- Connection-pooled httpx clients via FastAPI lifespan
- IAM authentication for Cloud Run (K_SERVICE detection)
- `/health` endpoint for startup probe
- 30s in-memory token cache
- Catch-all route for proxying

- [ ] **Step 3: Write Dockerfile**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY proxy.py .
EXPOSE 8080
CMD ["uvicorn", "proxy:app", "--host", "0.0.0.0", "--port", "8080"]
```

- [ ] **Step 4: Write basic proxy test**

```python
import pytest
from unittest.mock import AsyncMock, patch
from fastapi.testclient import TestClient


def test_proxy_health():
    from proxy import app
    client = TestClient(app)
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "healthy"}
```

- [ ] **Step 5: Run tests**

```bash
cd services/credential-proxy && pip install -r requirements.txt && python -m pytest tests/test_proxy.py -v
```
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add services/credential-proxy/
git commit -m "feat(credential-proxy): HTTP proxy sidecar with token injection and IAM auth"
```

---

## Task 9: Apollo Config Change

**Files:**
- Modify: `services/apollo/config.yaml`

- [ ] **Step 1: Update Apollo production config (Cloud Run)**

Replace `services/apollo/config.yaml` with:

```yaml
# Apollo MCP Server config — Shopify GraphQL (Cloud Run production)
# Apollo talks to credential-proxy sidecar at localhost:8080.
# The proxy injects X-Shopify-Access-Token and forwards to Shopify.
endpoint: http://localhost:8080/admin/api/${env.SHOPIFY_API_VERSION:-2026-01}/graphql.json

transport:
  type: streamable_http
  address: 0.0.0.0
  port: 8000
  host_validation:
    enabled: true
    allowed_hosts:
      - apollo-apanptkfaq-as.a.run.app
      - apollo-1056128102929.asia-southeast1.run.app

schema:
  source: local
  path: /app/shopify-schema.graphql

introspection:
  execute:
    enabled: true
  validate:
    enabled: true

# No headers — credential-proxy handles authentication
headers: {}
```

- [ ] **Step 2: Create local dev config override**

Create `services/apollo/config-local.yaml`:

```yaml
# Apollo MCP Server config — local development (docker-compose)
# Points at credential-proxy Docker service instead of localhost.
endpoint: http://credential-proxy:8080/admin/api/2026-01/graphql.json

transport:
  type: streamable_http
  address: 0.0.0.0
  port: 8000
  host_validation:
    enabled: false

schema:
  source: local
  path: /app/shopify-schema.graphql

introspection:
  execute:
    enabled: true
  validate:
    enabled: true

headers: {}
```

- [ ] **Step 3: Commit**

```bash
git add services/apollo/config.yaml services/apollo/config-local.yaml
git commit -m "feat(apollo): point endpoint at credential-proxy, remove static token

Production config (config.yaml): localhost:8080 sidecar, host_validation preserved.
Local config (config-local.yaml): credential-proxy Docker service, host_validation disabled."
```

---

## Task 10: Docker Compose Integration

**Files:**
- Modify: `docker-compose.yml`
- Modify: `.env.example`

- [ ] **Step 1: Add token-service and credential-proxy to docker-compose.yml**

Add after the `sheets` service:

```yaml
  # ── 7. Token Service ─────────────────────────────────────────────
  token-service:
    build:
      context: ./services/token-service
      dockerfile: Dockerfile
    environment:
      DATABASE_URL: "postgresql+asyncpg://token_service_user:${TOKEN_SERVICE_DB_PASS:?required}@postgres:5432/contextforge"
      DB_POOL_SIZE: "2"
      DB_MAX_OVERFLOW: "2"
      TOKEN_ENCRYPTION_KEY: "${TOKEN_ENCRYPTION_KEY:?required}"
      SHOPIFY_CLIENT_ID: "${SHOPIFY_CLIENT_ID}"
      SHOPIFY_CLIENT_SECRET: "${SHOPIFY_CLIENT_SECRET}"
      BASE_URL: "http://localhost:8010"
      FORWARDED_ALLOW_IPS: "*"
    ports:
      - "8010:8000"
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8000/health > /dev/null || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 10s
    networks:
      - fluid-net
    logging: *default-logging
    restart: unless-stopped

  # ── 8. Credential Proxy ──────────────────────────────────────────
  credential-proxy:
    build:
      context: ./services/credential-proxy
      dockerfile: Dockerfile
    environment:
      TOKEN_SERVICE_URL: "http://token-service:8000"
      SHOPIFY_HOST: "https://${SHOPIFY_STORE:-junlinleather-5148.myshopify.com}"
      FORWARDED_ALLOW_IPS: "*"
    depends_on:
      token-service:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080/health > /dev/null || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 5s
    networks:
      - fluid-net
    logging: *default-logging
    restart: unless-stopped
```

- [ ] **Step 2: Update apollo service in docker-compose.yml**

In docker-compose, credential-proxy is a separate service (not a sidecar like in Cloud Run). Apollo needs `config-local.yaml` (created in Task 9) mounted over `config.yaml` so it points at `credential-proxy:8080` instead of `localhost:8080`.

Replace the entire `apollo` service block with:

```yaml
  # ── 4. Apollo MCP Server ───────────────────────────────────────────
  apollo:
    build:
      context: ./services/apollo
      dockerfile: Dockerfile
    environment:
      SHOPIFY_API_VERSION: "${SHOPIFY_API_VERSION:-2026-01}"
      APOLLO_GRAPH_REF: "${APOLLO_GRAPH_REF:-shopify-fluid-intelligence@current}"
      APOLLO_KEY: "${APOLLO_KEY}"
    volumes:
      - ./services/apollo/config-local.yaml:/app/config.yaml:ro
    depends_on:
      credential-proxy:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "exec 3<>/dev/tcp/localhost/8000 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    networks:
      - fluid-net
    logging: *default-logging
    restart: unless-stopped
```

Key changes: removed `SHOPIFY_STORE` and `SHOPIFY_ACCESS_TOKEN` env vars, mounted `config-local.yaml`, added `credential-proxy` dependency.

- [ ] **Step 3: Update .env.example**

Add:
```
# === Token Service ===
TOKEN_SERVICE_DB_PASS=
TOKEN_ENCRYPTION_KEY=
SHOPIFY_CLIENT_ID=
SHOPIFY_CLIENT_SECRET=
```

- [ ] **Step 4: Test locally**

```bash
docker compose down -v
docker compose build token-service credential-proxy
docker compose up -d
docker compose logs token-service --tail 20
docker compose logs credential-proxy --tail 20
curl http://localhost:8010/health
```
Expected: `{"status": "healthy"}`

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml .env.example services/apollo/config.yaml services/apollo/config-local.yaml
git commit -m "feat: integrate token-service and credential-proxy into docker-compose"
```

---

## Task 11: End-to-End Local Test

- [ ] **Step 1: Start full stack**

```bash
docker compose up -d
docker compose ps  # All 8 services healthy
```

- [ ] **Step 2: Verify token-service health**

```bash
curl http://localhost:8010/health
# {"status": "healthy"}

curl http://localhost:8010/status
# {"providers": {}}  (no credentials yet — bootstrap needed)
```

- [ ] **Step 3: Verify credential-proxy health**

```bash
curl http://localhost:8011/health
# {"status": "healthy"}
```

- [ ] **Step 4: Verify Apollo points at proxy**

```bash
docker compose logs apollo --tail 5
# Should show Apollo starting, no token errors
```

- [ ] **Step 5: Commit final integration test notes**

```bash
git commit --allow-empty -m "test: local e2e verification — all 8 services healthy, ready for OAuth bootstrap"
```

---

## Task 12: Cloud Run Deployment Config

**Files:**
- Create: `services/token-service/cloudbuild.yaml`
- Create: `services/credential-proxy/cloudbuild.yaml`
- Create: `services/apollo/apollo-service.yaml` (multi-container)

- [ ] **Step 1: Write token-service cloudbuild.yaml**

```yaml
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/token-service:$COMMIT_SHA', '.']
    dir: 'services/token-service'
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/token-service:$COMMIT_SHA']
  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    entrypoint: 'gcloud'
    args:
      - 'run'
      - 'deploy'
      - 'token-service'
      - '--image=asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/token-service:$COMMIT_SHA'
      - '--region=asia-southeast1'
      - '--min-instances=1'
      - '--max-instances=1'
      - '--cpu-always-allocated'
      - '--memory=256Mi'
      - '--set-secrets=TOKEN_ENCRYPTION_KEY=token-encryption-key:latest,SHOPIFY_CLIENT_SECRET=shopify-client-secret:latest'
      - '--set-env-vars=SHOPIFY_CLIENT_ID=f597c0aaa02fac7278a54c617d7b344d,DB_POOL_SIZE=2,DB_MAX_OVERFLOW=2,FORWARDED_ALLOW_IPS=*,DATABASE_URL=postgresql+asyncpg://token_service_user:PASSWORD@/contextforge?host=/cloudsql/junlinleather-mcp:asia-southeast1:contextforge'
      - '--add-cloudsql-instances=junlinleather-mcp:asia-southeast1:contextforge'
      - '--no-allow-unauthenticated'
```

- [ ] **Step 2: Write credential-proxy cloudbuild.yaml**

```yaml
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/credential-proxy:$COMMIT_SHA', '.']
    dir: 'services/credential-proxy'
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', 'asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/credential-proxy:$COMMIT_SHA']
```

- [ ] **Step 3: Write Apollo multi-container service YAML**

Create `services/apollo/apollo-service.yaml` from the spec (section 7.3.1).

- [ ] **Step 4: Commit**

```bash
git add services/token-service/cloudbuild.yaml services/credential-proxy/cloudbuild.yaml services/apollo/apollo-service.yaml
git commit -m "feat: Cloud Run deployment configs for token-service, credential-proxy, and multi-container Apollo"
```

---

## Summary

| Task | What | Files | Commits |
|---|---|---|---|
| 1 | Database schema | SQL + db-init + compose | 1 |
| 2 | Encryption module | encrypt/decrypt + tests | 1 |
| 3 | DB layer (SQLAlchemy) | engine, model | 1 |
| 4 | Shopify provider | refresh, exchange, authorize | 1 |
| 5 | State nonce | HMAC-SHA256 CSRF | 1 |
| 6 | Token manager | single-flight, proactive refresh | 1 |
| 7 | API routes + FastAPI app | all endpoints + Dockerfile | 1 |
| 8 | Credential proxy | sidecar proxy + Dockerfile | 1 |
| 9 | Apollo config change | point at proxy | 1 |
| 10 | Docker compose integration | full local stack | 1 |
| 11 | E2E local test | verify all 8 services | 1 |
| 12 | Cloud Run deployment | cloudbuild + service YAML | 1 |

**Total: 12 tasks, ~12 commits, ~600 lines of application code**
