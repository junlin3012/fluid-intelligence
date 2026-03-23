import pytest
import httpx
from unittest.mock import AsyncMock, patch
from app.providers.shopify import ShopifyProvider
from app.providers.base import InvalidGrantError

TEST_CLIENT_ID = "test_client_id"
TEST_APP_CREDENTIAL = "test_app_credential"
TEST_SHOP = "test.myshopify.com"
TEST_OLD_TOKEN = "shprt_old_refresh"

@pytest.fixture
def provider():
    return ShopifyProvider(client_id=TEST_CLIENT_ID, client_secret=TEST_APP_CREDENTIAL)

def _make_mock_client(response):
    mock_client = AsyncMock()
    mock_client.post.return_value = response
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)
    return patch("app.providers.shopify.httpx.AsyncClient", return_value=mock_client)

@pytest.mark.asyncio
async def test_refresh_token_success(provider):
    mock_response = httpx.Response(
        200,
        json={
            "access_token": "shpat_new_token",
            "expires_in": 3600,
            "refresh_token": "shprt_new_refresh",
            "refresh_token_expires_in": 7776000,
            "scope": "read_products,write_products",
        },
    )
    with _make_mock_client(mock_response):
        result = await provider.refresh(shop_domain=TEST_SHOP, refresh_token=TEST_OLD_TOKEN)
    assert result["access_token"] == "shpat_new_token"
    assert result["refresh_token"] == "shprt_new_refresh"
    assert result["expires_in"] == 3600

@pytest.mark.asyncio
async def test_refresh_token_invalid_grant(provider):
    mock_response = httpx.Response(
        400,
        json={"error": "invalid_grant", "error_description": "Token has been expired or revoked."},
    )
    with _make_mock_client(mock_response):
        with pytest.raises(InvalidGrantError):
            await provider.refresh(shop_domain=TEST_SHOP, refresh_token="shprt_dead")
