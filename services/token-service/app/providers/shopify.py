"""Shopify OAuth provider — handles token refresh and authorization code exchange."""
import httpx
from app.providers.base import OAuthProvider, InvalidGrantError, RefreshError


class ShopifyProvider(OAuthProvider):
    #: OAuth scopes requested during authorization
    _SCOPES = (
        "read_products,write_products,read_customers,write_customers,"
        "read_orders,write_orders,read_draft_orders,write_draft_orders,"
        "read_inventory,write_inventory,read_fulfillments,write_fulfillments,"
        "read_discounts,write_discounts,read_locations"
    )

    def __init__(self, client_id: str, client_secret: str):
        self.client_id = client_id
        self.client_secret = client_secret

    def _token_url(self, shop_domain: str) -> str:
        return f"https://{shop_domain}/admin/oauth/access_token"

    def _credentials(self) -> dict:
        return {"client_id": self.client_id, "client_secret": self.client_secret}
    async def _post_token(self, shop_domain: str, data: dict) -> httpx.Response:
        async with httpx.AsyncClient(timeout=30) as client:
            return await client.post(
                self._token_url(shop_domain),
                data=data,
                headers={"Accept": "application/json"},
            )

    async def refresh(self, shop_domain: str, refresh_token: str) -> dict:
        resp = await self._post_token(shop_domain, {
            **self._credentials(),
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
        })
        if resp.status_code == 400:
            body = resp.json()
            if body.get("error") == "invalid_grant":
                raise InvalidGrantError(body.get("error_description", "Token revoked or expired"))
            raise RefreshError(f"Shopify 400: {body}")
        if resp.status_code != 200:
            raise RefreshError(f"Shopify {resp.status_code}: {resp.text}")
        return resp.json()

    def build_authorize_url(self, shop_domain: str, redirect_uri: str, state: str) -> str:
        return (
            f"https://{shop_domain}/admin/oauth/authorize?"
            f"client_id={self.client_id}&"
            f"scope={self._SCOPES}&"
            f"redirect_uri={redirect_uri}&"
            f"state={state}&"
            f"expiring=1"
        )

    async def exchange_code(self, shop_domain: str, code: str) -> dict:
        resp = await self._post_token(shop_domain, {
            **self._credentials(),
            "code": code,
            "expiring": "1",
        })
        if resp.status_code != 200:
            raise RefreshError(f"Shopify code exchange failed: {resp.status_code} {resp.text}")
        return resp.json()
