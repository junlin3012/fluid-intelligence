from typing import Dict

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import RedirectResponse, HTMLResponse
from datetime import datetime, timezone, timedelta
from sqlalchemy import select

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

    async with async_session() as session:
        async with session.begin():
            # Upsert: update existing credential or insert new one
            stmt = select(OAuthCredential).where(
                OAuthCredential.provider == provider,
                OAuthCredential.account_id == shop,
            )
            result = await session.execute(stmt)
            cred = result.scalar_one_or_none()

            if cred:
                # Update existing
                cred.encrypted_access_token = encrypt_token(tokens["access_token"], key)
                cred.encrypted_refresh_token = encrypt_token(tokens["refresh_token"], key) if tokens.get("refresh_token") else None
                cred.token_expires_at = now + timedelta(seconds=tokens.get("expires_in", 3600))
                cred.refresh_token_expires_at = now + timedelta(seconds=tokens["refresh_token_expires_in"]) if tokens.get("refresh_token_expires_in") else None
                cred.scopes = tokens.get("scope")
                cred.last_refreshed_at = now
                cred.status = "active"
                cred.failure_count = 0
                cred.last_error = None
                cred.updated_at = now
            else:
                # Insert new
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
                session.add(cred)

    expires_min = tokens.get("expires_in", 3600) // 60
    refresh_days = tokens.get("refresh_token_expires_in", 0) // 86400
    return HTMLResponse(f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Connected - Token Service</title>
<style>
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #F5F0EB; color: #2D2926; display: flex; justify-content: center;
         align-items: center; min-height: 100vh; padding: 2rem; }}
  .card {{ background: #fff; border-radius: 16px; padding: 3rem; max-width: 480px;
           width: 100%; box-shadow: 0 4px 24px rgba(45,41,38,0.08); }}
  .icon {{ font-size: 3rem; margin-bottom: 1rem; }}
  h1 {{ font-size: 1.5rem; font-weight: 600; margin-bottom: 0.5rem; }}
  .subtitle {{ color: #6B5E54; margin-bottom: 2rem; }}
  .detail {{ display: flex; justify-content: space-between; padding: 0.75rem 0;
             border-bottom: 1px solid #EDE8E3; }}
  .detail:last-child {{ border-bottom: none; }}
  .label {{ color: #6B5E54; font-size: 0.875rem; }}
  .value {{ font-weight: 500; font-size: 0.875rem; }}
  .status {{ display: inline-flex; align-items: center; gap: 0.5rem;
             background: #E8F5E9; color: #2E7D32; padding: 0.25rem 0.75rem;
             border-radius: 999px; font-size: 0.8rem; font-weight: 500; }}
  .dot {{ width: 8px; height: 8px; background: #4CAF50; border-radius: 50%;
          animation: pulse 2s infinite; }}
  @keyframes pulse {{ 0%,100% {{ opacity: 1; }} 50% {{ opacity: 0.4; }} }}
</style></head><body>
<div class="card">
  <div class="icon">&#x2705;</div>
  <h1>Connected to {provider.title()}</h1>
  <p class="subtitle">{shop}</p>
  <div class="detail"><span class="label">Status</span>
    <span class="status"><span class="dot"></span> Auto-refreshing</span></div>
  <div class="detail"><span class="label">Access token</span>
    <span class="value">Expires in {expires_min} min</span></div>
  <div class="detail"><span class="label">Refresh token</span>
    <span class="value">{refresh_days}-day lifetime</span></div>
  <div class="detail"><span class="label">Scopes</span>
    <span class="value">{len(tokens.get('scope', '').split(','))} granted</span></div>
</div></body></html>""")
