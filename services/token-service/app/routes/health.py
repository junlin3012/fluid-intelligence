from fastapi import APIRouter
from fastapi.responses import JSONResponse, Response
from prometheus_client import generate_latest, CONTENT_TYPE_LATEST
from sqlalchemy import select

from app.db import async_session
from app.models import OAuthCredential

router = APIRouter()


@router.get("/health")
async def health():
    """Minimal health check. Returns 503 if any provider is degraded."""
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
        pass
    return {"status": "healthy"}


@router.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
