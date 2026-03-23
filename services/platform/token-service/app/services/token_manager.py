import asyncio
import logging
import time
from datetime import datetime, timezone, timedelta
from typing import Optional
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import async_session
from app.encryption import encrypt_token, decrypt_token
from app.models import OAuthCredential
from app.providers.base import InvalidGrantError, RefreshError

logger = logging.getLogger(__name__)


class SingleFlight:
    """Ensures only one execution per key at a time. Others await the result."""

    def __init__(self):
        self._flights: dict[str, asyncio.Future] = {}

    async def do(self, key: str, fn):
        if key in self._flights:
            return await self._flights[key]

        loop = asyncio.get_event_loop()
        future = loop.create_future()
        self._flights[key] = future
        try:
            result = await fn()
            future.set_result(result)
            return result
        except Exception as e:
            future.set_exception(e)
            raise
        finally:
            self._flights.pop(key, None)


class TokenManager:
    def __init__(self, providers: dict):
        self.providers = providers
        self.single_flight = SingleFlight()
        self._cache: dict[str, tuple[str, float, float]] = {}
        self._running = False

    async def get_token(self, provider: str, account_id: Optional[str] = None) -> dict:
        cache_key = f"{provider}:{account_id or 'default'}"

        if cache_key in self._cache:
            token, expires_at, cached_at = self._cache[cache_key]
            if time.time() - cached_at < 30 and expires_at > time.time() + 300:
                return {"access_token": token, "expires_in": int(expires_at - time.time())}

        async with async_session() as session:
            stmt = select(OAuthCredential).where(
                OAuthCredential.provider == provider,
                OAuthCredential.status == "active",
            )
            if account_id:
                stmt = stmt.where(OAuthCredential.account_id == account_id)
            result = await session.execute(stmt)
            cred = result.scalar_one_or_none()

        if not cred:
            raise ValueError(f"No active credential for provider={provider}")

        key = settings.TOKEN_ENCRYPTION_KEY
        access_token = decrypt_token(cred.encrypted_access_token, key)
        expires_at = cred.token_expires_at.timestamp()

        if expires_at < time.time() + 300:
            access_token, expires_at = await self.single_flight.do(
                cache_key,
                lambda: self._do_refresh(cred.provider, cred.account_id),
            )

        self._cache[cache_key] = (access_token, expires_at, time.time())
        return {
            "access_token": access_token,
            "expires_in": int(expires_at - time.time()),
            "provider": provider,
            "account_id": cred.account_id,
        }

    async def _do_refresh(self, provider: str, account_id: str) -> tuple[str, float]:
        prov = self.providers.get(provider)
        if not prov:
            raise ValueError(f"Unknown provider: {provider}")

        key = settings.TOKEN_ENCRYPTION_KEY

        async with async_session() as session:
            async with session.begin():
                lock_key = f"{provider}:{account_id}"
                await session.execute(text("SELECT pg_advisory_xact_lock(hashtext(:key))"), {"key": lock_key})

                stmt = select(OAuthCredential).where(
                    OAuthCredential.provider == provider,
                    OAuthCredential.account_id == account_id,
                )
                result = await session.execute(stmt)
                cred = result.scalar_one_or_none()
                if not cred:
                    raise ValueError(f"Credential not found: {provider}:{account_id}")

                if cred.token_expires_at.timestamp() > time.time() + 300:
                    token = decrypt_token(cred.encrypted_access_token, key)
                    return token, cred.token_expires_at.timestamp()

                refresh_token = decrypt_token(cred.encrypted_refresh_token, key)
                try:
                    tokens = await prov.refresh(
                        shop_domain=account_id,
                        refresh_token=refresh_token,
                    )
                except InvalidGrantError as e:
                    cred.status = "requires_reauth"
                    cred.last_error = str(e)
                    cred.updated_at = datetime.now(timezone.utc)
                    logger.critical(f"INVALID_GRANT for {provider}:{account_id}: {e}")
                    raise
                except RefreshError as e:
                    cred.failure_count += 1
                    cred.last_error = str(e)
                    cred.updated_at = datetime.now(timezone.utc)
                    logger.error(f"Refresh failed for {provider}:{account_id}: {e}")
                    raise

                now = datetime.now(timezone.utc)
                cred.encrypted_access_token = encrypt_token(tokens["access_token"], key)
                if tokens.get("refresh_token"):
                    cred.encrypted_refresh_token = encrypt_token(tokens["refresh_token"], key)
                cred.token_expires_at = now + timedelta(seconds=tokens["expires_in"])
                if tokens.get("refresh_token_expires_in"):
                    cred.refresh_token_expires_at = now + timedelta(seconds=tokens["refresh_token_expires_in"])
                cred.last_refreshed_at = now
                cred.failure_count = 0
                cred.last_error = None
                cred.updated_at = now
                cred.scopes = tokens.get("scope", cred.scopes)

                new_token = tokens["access_token"]
                new_expires = cred.token_expires_at.timestamp()
                logger.info(f"Refreshed {provider}:{account_id}, expires in {tokens['expires_in']}s")

        return new_token, new_expires

    async def start_refresh_loop(self):
        self._running = True
        logger.info(f"Starting proactive refresh loop (interval={settings.REFRESH_INTERVAL_SECONDS}s)")
        while self._running:
            try:
                await self._refresh_expiring_credentials()
            except Exception:
                logger.exception("Error in proactive refresh loop")
            await asyncio.sleep(settings.REFRESH_INTERVAL_SECONDS)

    async def stop_refresh_loop(self):
        self._running = False

    async def _refresh_expiring_credentials(self):
        threshold = datetime.now(timezone.utc) + timedelta(minutes=15)
        async with async_session() as session:
            stmt = select(OAuthCredential).where(
                OAuthCredential.status == "active",
                OAuthCredential.token_expires_at < threshold,
            )
            result = await session.execute(stmt)
            expiring = result.scalars().all()

        for cred in expiring:
            try:
                await self._do_refresh(cred.provider, cred.account_id)
            except (InvalidGrantError, RefreshError):
                pass
            except Exception:
                logger.exception(f"Unexpected error refreshing {cred.provider}:{cred.account_id}")
