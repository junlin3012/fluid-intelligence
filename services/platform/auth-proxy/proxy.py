"""Keycloak JWT auth proxy — validates Bearer tokens via JWKS before forwarding.

Sits in front of services that have no auth (Apollo, devmcp, etc.).
Same pattern as credential-proxy but for inbound auth instead of outbound tokens.

Also serves RFC 9728 Protected Resource Metadata so mcp-remote can discover
Keycloak and do the OAuth flow automatically.

Remove when services support auth natively or ContextForge handles all traffic.
"""

import os
import httpx
import jwt
from jwt import PyJWKClient
from fastapi import FastAPI, Request, Response
from starlette.responses import JSONResponse

app = FastAPI()

UPSTREAM_URL = os.environ["UPSTREAM_URL"]  # e.g. http://localhost:8001
KEYCLOAK_ISSUER = os.environ["KEYCLOAK_ISSUER"]  # e.g. https://keycloak-apanptkfaq-as.a.run.app/realms/fluid
PUBLIC_URL = os.environ.get("PUBLIC_URL", "")  # e.g. https://apollo-apanptkfaq-as.a.run.app
JWKS_URI = f"{KEYCLOAK_ISSUER}/protocol/openid-connect/certs"

jwks_client = PyJWKClient(JWKS_URI, cache_keys=True)
http_client = httpx.AsyncClient(timeout=30.0)


async def verify_token(token: str) -> dict | None:
    """Verify a Keycloak JWT against JWKS. Returns claims or None."""
    try:
        signing_key = jwks_client.get_signing_key_from_jwt(token)
        return jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256", "RS384", "RS512", "ES256"],
            options={"verify_exp": True, "verify_aud": False},
        )
    except jwt.PyJWTError:
        return None


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"])
async def proxy(request: Request, path: str):
    # Health check
    if path == "health":
        return JSONResponse({"status": "healthy"})

    # RFC 9728 Protected Resource Metadata — mcp-remote discovers Keycloak here
    if path.startswith(".well-known/oauth-protected-resource"):
        resource_path = path.replace(".well-known/oauth-protected-resource", "").strip("/")
        resource_url = f"{PUBLIC_URL}/{resource_path}" if resource_path else PUBLIC_URL
        return JSONResponse({
            "resource": resource_url,
            "authorization_servers": [KEYCLOAK_ISSUER],
            "bearer_methods_supported": ["header"],
            "scopes_supported": ["openid", "profile", "email"],
        })

    # RFC 8414 Authorization Server Metadata — mcp-remote checks this too
    if path == ".well-known/oauth-authorization-server":
        # Proxy to Keycloak's OIDC discovery
        resp = await http_client.get(f"{KEYCLOAK_ISSUER}/.well-known/openid-configuration")
        return Response(content=resp.content, status_code=resp.status_code,
                       headers={"content-type": "application/json"})

    # Keycloak paths (DCR, authorize, token) — forward directly
    if path.startswith("realms/"):
        resp = await http_client.request(
            method=request.method,
            url=f"{KEYCLOAK_ISSUER.rsplit('/realms/', 1)[0]}/{path}",
            content=await request.body(),
            headers={k: v for k, v in request.headers.items() if k.lower() != "host"},
        )
        return Response(content=resp.content, status_code=resp.status_code,
                       headers=dict(resp.headers))

    # Root-level OAuth shortcuts (Claude.ai bug #82)
    if path in ("authorize", "token", "register"):
        keycloak_paths = {
            "authorize": "protocol/openid-connect/auth",
            "token": "protocol/openid-connect/token",
            "register": "clients-registrations/openid-connect",
        }
        url = f"{KEYCLOAK_ISSUER}/{keycloak_paths[path]}"
        resp = await http_client.request(
            method=request.method, url=url,
            content=await request.body(),
            headers={k: v for k, v in request.headers.items() if k.lower() != "host"},
        )
        return Response(content=resp.content, status_code=resp.status_code,
                       headers=dict(resp.headers))

    # Everything else: require Keycloak token, forward to upstream
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        resource_metadata = f"{PUBLIC_URL}/.well-known/oauth-protected-resource/{path}" if PUBLIC_URL else ""
        www_auth = f'Bearer resource_metadata="{resource_metadata}"' if resource_metadata else "Bearer"
        return JSONResponse(
            {"detail": "Authentication required", "hint": "Provide a Keycloak Bearer token"},
            status_code=401,
            headers={"WWW-Authenticate": www_auth},
        )

    claims = await verify_token(auth[7:])
    if claims is None:
        return JSONResponse(
            {"detail": "Invalid or expired token"},
            status_code=401,
            headers={"WWW-Authenticate": "Bearer"},
        )

    # Forward to upstream
    body = await request.body()
    headers = {k: v for k, v in request.headers.items() if k.lower() != "host"}

    resp = await http_client.request(
        method=request.method,
        url=f"{UPSTREAM_URL}/{path}",
        content=body,
        headers=headers,
    )

    return Response(
        content=resp.content,
        status_code=resp.status_code,
        headers=dict(resp.headers),
    )
