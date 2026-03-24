from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, Response
from prometheus_client import generate_latest, CONTENT_TYPE_LATEST
from sqlalchemy import select

from app.auth import require_api_key
from app.config import settings
from app.db import async_session
from app.models import OAuthCredential

router = APIRouter()


@router.get("/health")
async def health():
    """Minimal health check. No auth required (Cloud Run needs this).
    Returns 503 if any provider is degraded. Does NOT leak provider details."""
    try:
        async with async_session() as session:
            stmt = select(OAuthCredential.status).where(
                OAuthCredential.status.in_(["error", "requires_reauth"])
            )
            result = await session.execute(stmt)
            degraded = result.scalars().all()
        if degraded:
            return JSONResponse({"status": "degraded"}, status_code=503)
    except Exception:
        # DB unreachable — report unhealthy so Cloud Run restarts us
        return JSONResponse({"status": "unhealthy"}, status_code=503)
    return {"status": "healthy"}


@router.get("/metrics")
async def metrics(request: Request):
    """Prometheus metrics. Protected by API key — contains operational intelligence."""
    require_api_key(request, settings.TOKEN_SERVICE_API_KEY)
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
