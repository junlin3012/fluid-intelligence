"""Settings loaded from environment variables."""

import os


class Settings:
    @property
    def SHOPIFY_CLIENT_ID(self) -> str:
        return os.environ.get("SHOPIFY_CLIENT_ID", "")

    @property
    def SHOPIFY_CLIENT_SECRET(self) -> str:
        return os.environ.get("SHOPIFY_CLIENT_SECRET", "")

    @property
    def SHOPIFY_TOKEN_ENCRYPTION_KEY(self) -> str:
        return os.environ.get("SHOPIFY_TOKEN_ENCRYPTION_KEY", "")

    @property
    def DB_USER(self) -> str:
        return os.environ.get("DB_USER", "contextforge")

    @property
    def DB_NAME(self) -> str:
        return os.environ.get("DB_NAME", "contextforge")

    @property
    def DB_PASSWORD(self) -> str:
        return os.environ.get("DB_PASSWORD", "")

    @property
    def DB_HOST(self) -> str:
        return os.environ.get("DB_HOST", "/cloudsql/junlinleather-mcp:asia-southeast1:contextforge")

    @property
    def SHOPIFY_API_VERSION(self) -> str:
        return os.environ.get("SHOPIFY_API_VERSION", "2026-01")

    @property
    def SHOPIFY_SCOPES(self) -> str:
        return os.environ.get("SHOPIFY_SCOPES", "")

    @property
    def CALLBACK_URL(self) -> str:
        return os.environ.get("CALLBACK_URL", "")


settings = Settings()
