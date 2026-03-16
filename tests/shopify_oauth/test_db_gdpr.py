"""Tests for GDPR database operations."""
from unittest.mock import MagicMock

from services.shopify_oauth.db import (
    get_customer_data,
    delete_customer_data,
    delete_shop_data,
)


def test_get_customer_data_returns_dict():
    """get_customer_data should return a dict with shop_domain and customer info."""
    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.cursor.return_value.__enter__ = lambda s: mock_cursor
    mock_conn.cursor.return_value.__exit__ = MagicMock(return_value=False)
    mock_cursor.fetchone.return_value = {
        "shop_domain": "test.myshopify.com",
        "status": "active",
        "installed_at": "2026-01-01",
    }

    result = get_customer_data(mock_conn, "test.myshopify.com", "customer@example.com")
    assert result is not None
    assert "shop_domain" in result


def test_get_customer_data_returns_none_for_unknown():
    """get_customer_data should return None for unknown shops."""
    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.cursor.return_value.__enter__ = lambda s: mock_cursor
    mock_conn.cursor.return_value.__exit__ = MagicMock(return_value=False)
    mock_cursor.fetchone.return_value = None

    result = get_customer_data(mock_conn, "unknown.myshopify.com", "customer@example.com")
    assert result is None


def test_delete_customer_data():
    """delete_customer_data should execute without error (no per-customer PII stored)."""
    mock_conn = MagicMock()
    delete_customer_data(mock_conn, "test.myshopify.com", "customer@example.com")
    mock_conn.commit.assert_called_once()


def test_delete_shop_data():
    """delete_shop_data should permanently DELETE the shop's installation record."""
    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.cursor.return_value.__enter__ = lambda s: mock_cursor
    mock_conn.cursor.return_value.__exit__ = MagicMock(return_value=False)

    delete_shop_data(mock_conn, "test.myshopify.com")
    # Verify it executed a DELETE
    mock_cursor.execute.assert_called_once()
    sql_arg = mock_cursor.execute.call_args[0][0]
    assert "DELETE" in sql_arg.upper()
    mock_conn.commit.assert_called_once()
