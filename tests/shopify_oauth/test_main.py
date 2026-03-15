# tests/shopify_oauth/test_main.py
import time
import os
import base64
import urllib.parse
import pytest
from unittest.mock import patch, MagicMock
from fastapi.testclient import TestClient

os.environ.setdefault("SHOPIFY_CLIENT_ID", "test_client_id")
os.environ.setdefault("SHOPIFY_CLIENT_SECRET", "test_secret")
os.environ.setdefault("SHOPIFY_TOKEN_ENCRYPTION_KEY", base64.b64encode(os.urandom(32)).decode())
os.environ.setdefault("CALLBACK_URL", "http://localhost/auth/callback")
os.environ.setdefault("SHOPIFY_SCOPES", "read_products")

from services.shopify_oauth.main import app
from services.shopify_oauth.security import compute_hmac

# Use https://testserver so Secure cookies are included in test requests
client = TestClient(app, base_url="https://testserver")

def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"

def test_install_redirects_to_shopify():
    params = {"shop": "test-store.myshopify.com", "timestamp": str(int(time.time()))}
    params["hmac"] = compute_hmac(params, "test_secret")
    r = client.get("/auth/install", params=params, follow_redirects=False)
    assert r.status_code == 302
    assert "admin/oauth/authorize" in r.headers["location"]
    assert "client_id=test_client_id" in r.headers["location"]

def test_install_shows_app_home_without_hmac():
    """When Shopify loads application_url in iframe (no HMAC), show app home page."""
    r = client.get("/auth/install", params={"shop": "test-store.myshopify.com"})
    assert r.status_code == 200
    assert "Fluid Intelligence" in r.text
    assert "font-family" in r.text  # Has styling

def test_install_shows_app_home_no_params():
    """Bare /auth/install with no params at all returns app home."""
    r = client.get("/auth/install")
    assert r.status_code == 200
    assert "Fluid Intelligence" in r.text

def test_install_rejects_invalid_shop():
    params = {"shop": "evil.com", "timestamp": str(int(time.time()))}
    params["hmac"] = compute_hmac(params, "test_secret")
    r = client.get("/auth/install", params=params)
    assert r.status_code == 400

def test_install_rejects_bad_hmac():
    params = {"shop": "test.myshopify.com", "timestamp": str(int(time.time())), "hmac": "bad"}
    r = client.get("/auth/install", params=params)
    assert r.status_code == 401

def test_install_rejects_wrong_secret_hmac():
    """HMAC computed with wrong secret is rejected (valid hex format but wrong value)."""
    params = {"shop": "test.myshopify.com", "timestamp": str(int(time.time()))}
    params["hmac"] = compute_hmac(params, "wrong_secret")
    r = client.get("/auth/install", params=params)
    assert r.status_code == 401

def test_install_rejects_stale_timestamp():
    params = {"shop": "test.myshopify.com", "timestamp": str(int(time.time()) - 600)}
    params["hmac"] = compute_hmac(params, "test_secret")
    r = client.get("/auth/install", params=params)
    assert r.status_code == 401

@patch("services.shopify_oauth.main.exchange_code_for_token")
@patch("services.shopify_oauth.main.store_installation")
@patch("services.shopify_oauth.main.register_webhooks")
@patch("services.shopify_oauth.main.fetch_shop_id")
def test_callback_exchanges_token(mock_shop_id, mock_webhooks, mock_store, mock_exchange):
    mock_exchange.return_value = ("shpat_test_token", "read_products")
    mock_shop_id.return_value = 12345

    with TestClient(app, base_url="https://testserver") as session_client:
        # First do install to get nonce cookie (cookie jar persists on session_client)
        params = {"shop": "test-store.myshopify.com", "timestamp": str(int(time.time()))}
        params["hmac"] = compute_hmac(params, "test_secret")
        install_r = session_client.get("/auth/install", params=params, follow_redirects=False)
        assert install_r.status_code == 302

        # Extract state from redirect URL
        location = install_r.headers["location"]
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(location).query)
        state = qs["state"][0]

        # Now hit callback — cookies persist on session_client automatically
        cb_params = {"shop": "test-store.myshopify.com", "code": "auth_code_123", "state": state, "timestamp": str(int(time.time()))}
        cb_params["hmac"] = compute_hmac(cb_params, "test_secret")
        r = session_client.get("/auth/callback", params=cb_params)
        assert r.status_code == 200
        assert "Connected Successfully" in r.text
        assert "#78401F" in r.text  # Brand color present
        mock_exchange.assert_called_once()
        mock_store.assert_called_once()

@patch("services.shopify_oauth.main.exchange_code_for_token")
def test_callback_returns_502_on_token_exchange_failure(mock_exchange):
    """When Shopify token exchange fails, callback returns 502."""
    mock_exchange.return_value = ("", "")

    with TestClient(app, base_url="https://testserver") as session_client:
        params = {"shop": "test-store.myshopify.com", "timestamp": str(int(time.time()))}
        params["hmac"] = compute_hmac(params, "test_secret")
        install_r = session_client.get("/auth/install", params=params, follow_redirects=False)
        assert install_r.status_code == 302

        location = install_r.headers["location"]
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(location).query)
        state = qs["state"][0]

        cb_params = {"shop": "test-store.myshopify.com", "code": "bad_code", "state": state, "timestamp": str(int(time.time()))}
        cb_params["hmac"] = compute_hmac(cb_params, "test_secret")
        r = session_client.get("/auth/callback", params=cb_params)
        assert r.status_code == 502
        assert "Token exchange failed" in r.text
