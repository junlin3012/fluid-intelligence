# tests/shopify_oauth/test_webhooks.py
import hashlib
import hmac
import json
import os
import base64
import pytest
from unittest.mock import patch, MagicMock
from fastapi.testclient import TestClient

os.environ.setdefault("SHOPIFY_CLIENT_ID", "test_client_id")
os.environ.setdefault("SHOPIFY_CLIENT_SECRET", "test_secret")
os.environ.setdefault("SHOPIFY_TOKEN_ENCRYPTION_KEY", base64.b64encode(os.urandom(32)).decode())
os.environ.setdefault("CALLBACK_URL", "http://localhost/auth/callback")
os.environ.setdefault("SHOPIFY_SCOPES", "read_products")

from services.shopify_oauth.main import app

client = TestClient(app)

def shopify_webhook_hmac(body: bytes, secret: str = "test_secret") -> str:
    return base64.b64encode(hmac.new(secret.encode(), body, hashlib.sha256).digest()).decode()

def test_app_uninstalled_webhook():
    body = json.dumps({"myshopify_domain": "test-store.myshopify.com"}).encode()
    mac = shopify_webhook_hmac(body)
    with patch("services.shopify_oauth.webhooks.mark_shop_uninstalled") as mock:
        r = client.post("/webhooks/app-uninstalled", content=body, headers={"X-Shopify-Hmac-SHA256": mac, "Content-Type": "application/json"})
    assert r.status_code == 200
    mock.assert_called_once_with("test-store.myshopify.com")

def test_webhook_rejects_bad_hmac():
    body = json.dumps({"myshopify_domain": "test.myshopify.com"}).encode()
    r = client.post("/webhooks/app-uninstalled", content=body, headers={"X-Shopify-Hmac-SHA256": "bad", "Content-Type": "application/json"})
    assert r.status_code == 401

def test_gdpr_customers_redact():
    body = json.dumps({"shop_domain": "test.myshopify.com"}).encode()
    mac = shopify_webhook_hmac(body)
    r = client.post("/webhooks/gdpr/customers-redact", content=body, headers={"X-Shopify-Hmac-SHA256": mac, "Content-Type": "application/json"})
    assert r.status_code == 200

def test_gdpr_shop_redact():
    """shop/redact now calls delete_shop_data (hard DELETE) for GDPR compliance."""
    body = json.dumps({"shop_domain": "test.myshopify.com"}).encode()
    mac = shopify_webhook_hmac(body)
    mock_conn = MagicMock()
    with patch("services.shopify_oauth.webhooks.get_connection", return_value=mock_conn), \
         patch("services.shopify_oauth.webhooks.delete_shop_data") as mock_delete:
        r = client.post("/webhooks/gdpr/shop-redact", content=body, headers={"X-Shopify-Hmac-SHA256": mac, "Content-Type": "application/json"})
    assert r.status_code == 200
    mock_delete.assert_called_once()
    mock_conn.close.assert_called()

def test_gdpr_data_request():
    """customers/data_request now queries DB for shop data."""
    body = json.dumps({"shop_domain": "test.myshopify.com", "customer": {"email": "c@test.com"}}).encode()
    mac = shopify_webhook_hmac(body)
    mock_conn = MagicMock()
    with patch("services.shopify_oauth.webhooks.get_connection", return_value=mock_conn), \
         patch("services.shopify_oauth.webhooks.get_customer_data"):
        r = client.post("/webhooks/gdpr/customers-data_request", content=body, headers={"X-Shopify-Hmac-SHA256": mac, "Content-Type": "application/json"})
    assert r.status_code == 200
    mock_conn.close.assert_called()
