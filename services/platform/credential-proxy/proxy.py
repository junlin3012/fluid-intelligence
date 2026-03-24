import os
import time
import logging
import httpx
from contextlib import asynccontextmanager
from typing import Optional
from fastapi import FastAPI, Request, Response

logger = logging.getLogger(__name__)

TOKEN_SERVICE_URL = os.environ.get("TOKEN_SERVICE_URL", "")
SHOPIFY_HOST = os.environ.get("SHOPIFY_HOST", "")
TOKEN_SERVICE_API_KEY = os.environ.get("TOKEN_SERVICE_API_KEY", "")
IS_CLOUD_RUN = os.environ.get("K_SERVICE") is not None

if not TOKEN_SERVICE_URL or not SHOPIFY_HOST or not TOKEN_SERVICE_API_KEY:
    if IS_CLOUD_RUN:
        raise RuntimeError("FATAL: TOKEN_SERVICE_URL, SHOPIFY_HOST, and TOKEN_SERVICE_API_KEY are required")
    else:
        TOKEN_SERVICE_URL = TOKEN_SERVICE_URL or "http://token-service:8000"
        SHOPIFY_HOST = SHOPIFY_HOST or "https://junlinleather-dev.myshopify.com"
        TOKEN_SERVICE_API_KEY = TOKEN_SERVICE_API_KEY or "local-dev-key"

# Derive account_id from SHOPIFY_HOST (e.g. "junlinleather-5148.myshopify.com")
SHOPIFY_ACCOUNT_ID = SHOPIFY_HOST.replace("https://", "").replace("http://", "")

token_client: Optional[httpx.AsyncClient] = None
shopify_client: Optional[httpx.AsyncClient] = None


def _get_iam_headers() -> dict:
    """Get IAM ID token for service-to-service auth on Cloud Run.
    FAIL-CLOSED: raises on failure instead of returning empty headers."""
    if not IS_CLOUD_RUN:
        return {}
    metadata_url = (
        "http://metadata.google.internal/computeMetadata/v1/"
        f"instance/service-accounts/default/identity?audience={TOKEN_SERVICE_URL}"
    )
    resp = httpx.get(metadata_url, headers={"Metadata-Flavor": "Google"}, timeout=5)
    resp.raise_for_status()
    return {"Authorization": f"Bearer {resp.text}"}


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
    headers["X-Token-Service-Key"] = TOKEN_SERVICE_API_KEY

    resp = await token_client.get(f"/token/shopify?account_id={SHOPIFY_ACCOUNT_ID}", headers=headers)
    resp.raise_for_status()
    _cached_token = resp.json()["access_token"]
    _cached_at = time.time()
    logger.info(f"Fetched fresh token for {SHOPIFY_ACCOUNT_ID}")
    return _cached_token


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy(request: Request, path: str):
    try:
        token = await get_token()
    except Exception as e:
        # Return a proper JSON error, not HTML — Apollo needs to parse the response
        logger.error(f"Failed to get token: {e}")
        return Response(
            content=f'{{"errors": [{{"message": "credential-proxy: failed to get token: {e}"}}]}}',
            status_code=502,
            media_type="application/json",
        )

    # Forward to Shopify with token injected
    resp = await shopify_client.request(
        method=request.method,
        url=f"/{path}",
        headers={
            "X-Shopify-Access-Token": token,
            "Content-Type": request.headers.get("Content-Type", "application/json"),
        },
        content=await request.body(),
    )

    # Return Shopify's response with clean headers
    # Only pass through safe headers — avoid transfer-encoding, content-encoding
    # that could corrupt the response for Apollo
    return Response(
        content=resp.content,
        status_code=resp.status_code,
        media_type=resp.headers.get("content-type", "application/json"),
    )
