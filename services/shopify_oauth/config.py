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
