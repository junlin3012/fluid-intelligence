"""Tests for GDPR webhook handlers."""
import json
import hashlib
import hmac
import base64
from unittest.mock import patch, MagicMock

import pytest
from fastapi.testclient import TestClient
from fastapi import FastAPI

from services.shopify_oauth.webhooks import router


def make_hmac(body: bytes, secret: str = "test-secret") -> str:
    return base64.b64encode(
        hmac.new(secret.encode(), body, hashlib.sha256).digest()
    ).decode()


@patch("services.shopify_oauth.webhooks.settings")
@patch("services.shopify_oauth.webhooks.get_connection")
def test_customers_data_request(mock_conn_fn, mock_settings):
    """customers/data_request should connect to DB and return 200."""
    mock_settings.SHOPIFY_CLIENT_SECRET = "test-secret"
    mock_conn = MagicMock()
    mock_conn_fn.return_value = mock_conn

    app = FastAPI()
    app.include_router(router)
    client = TestClient(app)

    body = json.dumps({
        "shop_domain": "test.myshopify.com",
        "customer": {"email": "customer@example.com"},
    }).encode()

    response = client.post(
        "/webhooks/gdpr/customers-data_request",
        content=body,
        headers={"X-Shopify-Hmac-SHA256": make_hmac(body)},
    )
    assert response.status_code == 200
    mock_conn.close.assert_called()


@patch("services.shopify_oauth.webhooks.settings")
@patch("services.shopify_oauth.webhooks.get_connection")
def test_customers_redact(mock_conn_fn, mock_settings):
    """customers/redact should connect to DB and return 200."""
    mock_settings.SHOPIFY_CLIENT_SECRET = "test-secret"
    mock_conn = MagicMock()
    mock_conn_fn.return_value = mock_conn

    app = FastAPI()
    app.include_router(router)
    client = TestClient(app)

    body = json.dumps({
        "shop_domain": "test.myshopify.com",
        "customer": {"email": "customer@example.com"},
    }).encode()

    response = client.post(
        "/webhooks/gdpr/customers-redact",
        content=body,
        headers={"X-Shopify-Hmac-SHA256": make_hmac(body)},
    )
    assert response.status_code == 200
    mock_conn.close.assert_called()


@patch("services.shopify_oauth.webhooks.settings")
@patch("services.shopify_oauth.webhooks.get_connection")
def test_shop_redact_deletes_data(mock_conn_fn, mock_settings):
    """shop/redact should connect to DB and return 200."""
    mock_settings.SHOPIFY_CLIENT_SECRET = "test-secret"
    mock_conn = MagicMock()
    mock_conn_fn.return_value = mock_conn

    app = FastAPI()
    app.include_router(router)
    client = TestClient(app)

    body = json.dumps({
        "shop_domain": "test.myshopify.com",
    }).encode()

    response = client.post(
        "/webhooks/gdpr/shop-redact",
        content=body,
        headers={"X-Shopify-Hmac-SHA256": make_hmac(body)},
    )
    assert response.status_code == 200
    mock_conn.close.assert_called()


@patch("services.shopify_oauth.webhooks.settings")
def test_gdpr_invalid_hmac(mock_settings):
    """GDPR webhook with invalid HMAC should return 401."""
    mock_settings.SHOPIFY_CLIENT_SECRET = "test-secret"

    app = FastAPI()
    app.include_router(router)
    client = TestClient(app)

    body = json.dumps({"shop_domain": "test.myshopify.com"}).encode()
    response = client.post(
        "/webhooks/gdpr/shop-redact",
        content=body,
        headers={"X-Shopify-Hmac-SHA256": "invalid-hmac"},
    )
    assert response.status_code == 401
