import time
from typing import Optional

from fastapi import APIRouter, HTTPException
from sqlalchemy import select

from app.db import async_session
from app.models import OAuthCredential

router = APIRouter()
token_manager = None


@router.post("/rotate/{provider}")
async def rotate(provider: str, account_id: Optional[str] = None):
    if not account_id:
        async with async_session() as session:
            stmt = select(OAuthCredential.account_id).where(
                OAuthCredential.provider == provider,
                OAuthCredential.status == "active",
            ).limit(1)
            result = await session.execute(stmt)
            row = result.scalar_one_or_none()
            if not row:
                raise HTTPException(status_code=404, detail=f"No active credential for {provider}")
            account_id = row

    try:
        result = await token_manager._do_refresh(provider, account_id)
        return {"status": "rotated", "provider": provider, "expires_in": int(result[1] - time.time())}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/status")
async def status():
    async with async_session() as session:
        result = await session.execute(select(OAuthCredential))
        creds = result.scalars().all()

    providers_status = {}
    now = time.time()
    for cred in creds:
        providers_status[cred.provider] = {
            "status": cred.status,
            "account_id": cred.account_id,
            "token_expires_in_seconds": max(0, int(cred.token_expires_at.timestamp() - now)),
            "refresh_token_expires_in_days": (
                max(0, int((cred.refresh_token_expires_at.timestamp() - now) / 86400))
                if cred.refresh_token_expires_at else None
            ),
            "last_refreshed_at": cred.last_refreshed_at.isoformat() if cred.last_refreshed_at else None,
            "failure_count": cred.failure_count,
            "last_error": cred.last_error,
        }
    return {"providers": providers_status}
