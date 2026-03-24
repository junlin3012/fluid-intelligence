import os
import sys


def _require(name: str) -> str:
    """Require an env var or crash at startup. Fail-secure, never fail-open."""
    value = os.environ.get(name, "")
    if not value:
        print(f"FATAL: Required environment variable {name} is not set. Refusing to start.", file=sys.stderr)
        sys.exit(1)
    return value


class Settings:
    # Fail-secure: crash if critical config is missing
    DATABASE_URL: str = _require("DATABASE_URL")
    TOKEN_ENCRYPTION_KEY: str = _require("TOKEN_ENCRYPTION_KEY")
    SHOPIFY_CLIENT_ID: str = _require("SHOPIFY_CLIENT_ID")
    SHOPIFY_CLIENT_SECRET: str = _require("SHOPIFY_CLIENT_SECRET")

    # App-level API key for defense-in-depth (on top of Cloud Run IAM)
    # Credential-proxy must send this as X-Token-Service-Key header
    TOKEN_SERVICE_API_KEY: str = _require("TOKEN_SERVICE_API_KEY")

    # Non-critical (safe defaults)
    DB_POOL_SIZE: int = int(os.environ.get("DB_POOL_SIZE", "2"))
    DB_MAX_OVERFLOW: int = int(os.environ.get("DB_MAX_OVERFLOW", "2"))
    BASE_URL: str = os.environ.get("BASE_URL", "http://localhost:8010")
    REFRESH_INTERVAL_SECONDS: int = int(os.environ.get("REFRESH_INTERVAL_SECONDS", "2700"))


settings = Settings()
