import asyncio
import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI

from app.config import settings
from app.providers.shopify import ShopifyProvider
from app.services.token_manager import TokenManager
from app.routes import health, token, oauth, admin

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

providers = {
    "shopify": ShopifyProvider(
        client_id=settings.SHOPIFY_CLIENT_ID,
        client_secret=settings.SHOPIFY_CLIENT_SECRET,
    ),
}

manager = TokenManager(providers=providers)


@asynccontextmanager
async def lifespan(app: FastAPI):
    refresh_task = asyncio.create_task(manager.start_refresh_loop())
    yield
    await manager.stop_refresh_loop()
    refresh_task.cancel()
    try:
        await refresh_task
    except asyncio.CancelledError:
        pass


app = FastAPI(title="Token Service", lifespan=lifespan)

token.token_manager = manager
admin.token_manager = manager
oauth.providers = providers

app.include_router(health.router)
app.include_router(token.router)
app.include_router(oauth.router)
app.include_router(admin.router)


@app.get("/")
async def root(shop: str = None):
    """Shopify sends users here after managed install. Redirect to OAuth connect."""
    if shop:
        import re
        from fastapi import HTTPException
        from fastapi.responses import RedirectResponse
        # Validate shop domain to prevent open redirect (M5)
        if not re.match(r'^[a-zA-Z0-9][a-zA-Z0-9\-]*\.myshopify\.com$', shop):
            raise HTTPException(status_code=400, detail="Invalid shop domain")
        return RedirectResponse(f"/connect/shopify?shop={shop}")
    return {"service": "token-service", "status": "ok"}
