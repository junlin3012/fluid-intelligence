import hmac
from fastapi import Request, HTTPException


def require_api_key(request: Request, expected_key: str):
    """Validate X-Token-Service-Key header. Defense-in-depth on top of Cloud Run IAM."""
    provided = request.headers.get("X-Token-Service-Key", "")
    if not provided or not hmac.compare_digest(provided, expected_key):
        raise HTTPException(status_code=403, detail="Forbidden: invalid or missing API key")
