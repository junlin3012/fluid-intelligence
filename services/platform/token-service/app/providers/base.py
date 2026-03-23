from abc import ABC, abstractmethod


class InvalidGrantError(Exception):
    """Refresh token has been revoked or expired. Requires re-authorization."""
    pass


class RefreshError(Exception):
    """Transient refresh failure (network, 5xx, etc.)."""
    pass


class OAuthProvider(ABC):
    @abstractmethod
    async def refresh(self, shop_domain: str, refresh_token: str) -> dict:
        """Refresh tokens. Returns dict with access_token, refresh_token, expires_in, etc."""
        ...

    @abstractmethod
    def build_authorize_url(self, shop_domain: str, redirect_uri: str, state: str) -> str:
        """Build the OAuth authorization URL for initial bootstrap."""
        ...

    @abstractmethod
    async def exchange_code(self, shop_domain: str, code: str) -> dict:
        """Exchange authorization code for tokens."""
        ...
