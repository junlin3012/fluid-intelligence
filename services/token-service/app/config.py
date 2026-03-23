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
    REFRESH_INTERVAL_SECONDS: int = int(os.environ.get("REFRESH_INTERVAL_SECONDS", "2700"))

settings = Settings()
