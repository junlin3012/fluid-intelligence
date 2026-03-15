import os
import pytest
import psycopg2

DB_URL = os.environ.get("TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(not DB_URL, reason="TEST_DATABASE_URL not set")

from services.shopify_oauth.db import (
    ensure_table,
    upsert_installation,
    get_installation,
    mark_uninstalled,
)

@pytest.fixture(autouse=True)
def setup_db():
    conn = psycopg2.connect(DB_URL)
    conn.autocommit = True
    ensure_table(conn)
    yield conn
    with conn.cursor() as cur:
        cur.execute("DELETE FROM shopify_installations")
    conn.close()

def test_upsert_new_installation(setup_db):
    upsert_installation(setup_db, "test.myshopify.com", "encrypted_token", "read_products", shop_id=12345)
    row = get_installation(setup_db, "test.myshopify.com")
    assert row is not None
    assert row["shop_domain"] == "test.myshopify.com"
    assert row["access_token_encrypted"] == "encrypted_token"
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
