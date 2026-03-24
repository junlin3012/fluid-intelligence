from typing import Optional

from fastapi import APIRouter, HTTPException, Request
from app.auth import require_api_key
from app.config import settings
from app.services.token_manager import TokenManager

router = APIRouter()
token_manager: Optional[TokenManager] = None


@router.get("/token/{provider}")
async def get_token(request: Request, provider: str, account_id: Optional[str] = None):
    require_api_key(request, settings.TOKEN_SERVICE_API_KEY)
    try:
        return await token_manager.get_token(provider, account_id)
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=503, detail={"error": "refresh_failed", "message": str(e)})
