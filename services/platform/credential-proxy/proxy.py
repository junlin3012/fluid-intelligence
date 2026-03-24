import os
import time
import logging
import httpx
from contextlib import asynccontextmanager
from typing import Optional
from fastapi import FastAPI, Request, Response

logger = logging.getLogger(__name__)

TOKEN_SERVICE_URL = os.environ.get(
    "TOKEN_SERVICE_URL",
    "https://token-service-apanptkfaq-as.a.run.app"
)
SHOPIFY_HOST = os.environ.get(
    "SHOPIFY_HOST",
    "https://junlinleather-5148.myshopify.com"
)
IS_CLOUD_RUN = os.environ.get("K_SERVICE") is not None

token_client: Optional[httpx.AsyncClient] = None
shopify_client: Optional[httpx.AsyncClient] = None


def _get_iam_headers() -> dict:
    """Get IAM ID token for service-to-service auth on Cloud Run."""
    if not IS_CLOUD_RUN:
        return {}
    try:
        # Fetch ID token from metadata server (no external library needed)
        metadata_url = (
            "http://metadata.google.internal/computeMetadata/v1/"
            f"instance/service-accounts/default/identity?audience={TOKEN_SERVICE_URL}"
        )
        resp = httpx.get(metadata_url, headers={"Metadata-Flavor": "Google"}, timeout=5)
        resp.raise_for_status()
        return {"Authorization": f"Bearer {resp.text}"}
    except Exception as e:
        logger.warning(f"Failed to get IAM token, proceeding without: {e}")
        return {}


@asynccontextmanager
async def lifespan(app):
    global token_client, shopify_client
    token_client = httpx.AsyncClient(base_url=TOKEN_SERVICE_URL, timeout=10)
    shopify_client = httpx.AsyncClient(base_url=SHOPIFY_HOST, timeout=30)
    yield
    await token_client.aclose()
    await shopify_client.aclose()


app = FastAPI(lifespan=lifespan)

_cached_token: Optional[str] = None
_cached_at: float = 0


@app.get("/health")
async def health():
    return {"status": "healthy"}


async def get_token() -> str:
    global _cached_token, _cached_at
    if _cached_token and time.time() - _cached_at < 30:
        return _cached_token

    headers = _get_iam_headers()
    resp = await token_client.get("/token/shopify", headers=headers)
    resp.raise_for_status()
    _cached_token = resp.json()["access_token"]
    _cached_at = time.time()
    return _cached_token


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy(request: Request, path: str):
    token = await get_token()
    headers = {
        "X-Shopify-Access-Token": token,
        "Content-Type": request.headers.get("Content-Type", "application/json"),
    }

    resp = await shopify_client.request(
        method=request.method,
        url=f"/{path}",
        headers=headers,
        content=await request.body(),
    )
    return Response(
        content=resp.content,
        status_code=resp.status_code,
        headers=dict(resp.headers),
    )
