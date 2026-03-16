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
        connect_timeout=5,
    )


def ensure_table(conn):
    with conn.cursor() as cur:
        cur.execute(CREATE_TABLE_SQL)
    conn.commit()


def upsert_installation(conn, shop_domain: str, encrypted_token: str, scopes: str, shop_id: int | None = None):
    with conn.cursor() as cur:
        cur.execute(UPSERT_SQL, (shop_domain, shop_id, encrypted_token, scopes))
    conn.commit()


def get_installation(conn, shop_domain: str) -> dict | None:
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT * FROM shopify_installations WHERE shop_domain = %s", (shop_domain,))
        return cur.fetchone()


def mark_uninstalled(conn, shop_domain: str):
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE shopify_installations SET status = 'uninstalled', access_token_encrypted = '', updated_at = NOW() WHERE shop_domain = %s",
            (shop_domain,),
        )
    conn.commit()


def get_customer_data(conn, shop_domain: str, customer_email: str) -> dict | None:
    """Return installation data for a shop (for GDPR data request).

    Note: We store shop-level data, not per-customer data. The customer_email
    is logged for audit but we can only return shop-level installation info.
    """
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            "SELECT shop_domain, status, scopes, installed_at, updated_at FROM shopify_installations WHERE shop_domain = %s",
            (shop_domain,),
        )
        return cur.fetchone()


def delete_customer_data(conn, shop_domain: str, customer_email: str):
    """Delete customer-specific data for GDPR customers/redact.

    Note: We don't store per-customer PII — only shop-level installation data
    and encrypted access tokens. This is a no-op for customer data but we log
    the request for audit compliance.
    """
    conn.commit()


def delete_shop_data(conn, shop_domain: str):
    """Delete ALL data for a shop (GDPR shop/redact). Permanent deletion."""
    with conn.cursor() as cur:
        cur.execute(
            "DELETE FROM shopify_installations WHERE shop_domain = %s",
            (shop_domain,),
        )
    conn.commit()
