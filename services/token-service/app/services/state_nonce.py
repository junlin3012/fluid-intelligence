import base64
import hashlib
import hmac
import os
import time

NONCE_TTL_SECONDS = 600  # 10 minutes


def generate_nonce(provider: str, key: str) -> str:
    timestamp = str(int(time.time()))
    random_bytes = base64.urlsafe_b64encode(os.urandom(16)).decode()
    payload = f"{provider}:{timestamp}:{random_bytes}"
    signature = _sign(payload, key)
    return base64.urlsafe_b64encode(f"{payload}:{signature}".encode()).decode()


def verify_nonce(nonce: str, expected_provider: str, key: str) -> bool:
    try:
        decoded = base64.urlsafe_b64decode(nonce.encode()).decode()
        parts = decoded.rsplit(":", 1)
        if len(parts) != 2:
            return False
        payload, signature = parts

        if not hmac.compare_digest(signature, _sign(payload, key)):
            return False

        provider, timestamp, _ = payload.split(":", 2)
        if provider != expected_provider:
            return False

        if time.time() - int(timestamp) > NONCE_TTL_SECONDS:
            return False

        return True
    except Exception:
        return False


def _sign(payload: str, key: str) -> str:
    return hmac.new(
        key.encode(), payload.encode(), hashlib.sha256
    ).hexdigest()
