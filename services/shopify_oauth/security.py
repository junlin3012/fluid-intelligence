"""Shopify OAuth security: HMAC validation, nonce generation, shop hostname checks."""

import hashlib
import hmac
import os
import re
import time

SHOP_HOSTNAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9\-]*\.myshopify\.com$")
TIMESTAMP_MAX_AGE = 300  # 5 minutes


def validate_shop_hostname(shop: str) -> bool:
    return bool(SHOP_HOSTNAME_RE.match(shop))


def compute_hmac(params: dict, secret: str) -> str:
    """Compute HMAC-SHA256 of sorted query params (Shopify convention)."""
    message = "&".join(f"{k}={v}" for k, v in sorted(params.items()))
    return hmac.new(
        secret.encode(), message.encode(), hashlib.sha256
    ).hexdigest()


def verify_hmac(params: dict, received_hmac: str, secret: str) -> bool:
    expected = compute_hmac(params, secret)
    return hmac.compare_digest(expected, received_hmac)


def generate_nonce() -> str:
    return os.urandom(32).hex()


def _derive_signing_key(secret: str) -> bytes:
    """HKDF-derive a signing key from the client secret."""
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives import hashes

    return HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=b"shopify-oauth-nonce-signing",
        info=b"cookie-signing",
    ).derive(secret.encode())


def sign_nonce(nonce: str, secret: str) -> str:
    key = _derive_signing_key(secret)
    return hmac.new(key, nonce.encode(), hashlib.sha256).hexdigest()


def verify_nonce_signature(nonce: str, signature: str, secret: str) -> bool:
    expected = sign_nonce(nonce, secret)
    return hmac.compare_digest(expected, signature)


def validate_timestamp(timestamp: str) -> bool:
    try:
        ts = int(timestamp)
    except (ValueError, TypeError):
        return False
    return abs(time.time() - ts) <= TIMESTAMP_MAX_AGE
