from typing import Dict

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import RedirectResponse, HTMLResponse
from datetime import datetime, timezone, timedelta

from app.config import settings
from app.encryption import encrypt_token
from app.db import async_session
from app.models import OAuthCredential
from app.services.state_nonce import generate_nonce, verify_nonce

router = APIRouter()
providers: Dict = {}


@router.get("/connect/{provider}")
async def connect(provider: str, shop: str = Query(..., description="Shop domain")):
    prov = providers.get(provider)
    if not prov:
        raise HTTPException(status_code=404, detail=f"Unknown provider: {provider}")
    state = generate_nonce(provider, settings.TOKEN_ENCRYPTION_KEY)
    redirect_uri = f"{settings.BASE_URL}/callback/{provider}"
    url = prov.build_authorize_url(shop, redirect_uri, state)
    return RedirectResponse(url)


@router.get("/callback/{provider}")
async def callback(provider: str, code: str, state: str, shop: str):
    prov = providers.get(provider)
    if not prov:
        raise HTTPException(status_code=404, detail=f"Unknown provider: {provider}")
    if not verify_nonce(state, provider, settings.TOKEN_ENCRYPTION_KEY):
        raise HTTPException(status_code=400, detail="Invalid or expired state nonce")

    tokens = await prov.exchange_code(shop, code)
    key = settings.TOKEN_ENCRYPTION_KEY
    now = datetime.now(timezone.utc)

    cred = OAuthCredential(
        provider=provider,
        account_id=shop,
        encrypted_access_token=encrypt_token(tokens["access_token"], key),
        encrypted_refresh_token=encrypt_token(tokens["refresh_token"], key) if tokens.get("refresh_token") else None,
        token_expires_at=now + timedelta(seconds=tokens.get("expires_in", 3600)),
        refresh_token_expires_at=now + timedelta(seconds=tokens["refresh_token_expires_in"]) if tokens.get("refresh_token_expires_in") else None,
        scopes=tokens.get("scope"),
        last_refreshed_at=now,
    )

    async with async_session() as session:
        async with session.begin():
            session.add(cred)

    return HTMLResponse(
        "<h1>Connected!</h1>"
        f"<p>Provider: {provider}</p>"
        f"<p>Account: {shop}</p>"
        f"<p>Token expires in {tokens.get('expires_in', '?')} seconds. Auto-refresh is active.</p>"
    )
