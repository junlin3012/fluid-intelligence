"""Shopify OAuth service — handles app installation and token exchange."""

import logging
import urllib.parse

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse

from services.shopify_oauth.config import settings
from services.shopify_oauth.crypto import encrypt_token
from services.shopify_oauth.db import get_connection, ensure_table, upsert_installation
from services.shopify_oauth.security import (
    validate_shop_hostname,
    verify_hmac,
    generate_nonce,
    sign_nonce,
    verify_nonce_signature,
    validate_timestamp,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("shopify-oauth")

app = FastAPI(title="Shopify OAuth Service")


@app.on_event("startup")
def startup():
    try:
        conn = get_connection()
        ensure_table(conn)
        conn.close()
        log.info("Database table ensured")
    except Exception as e:
        log.warning(f"Could not ensure table on startup: {e}")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/auth/install")
def install(request: Request):
    params = dict(request.query_params)
    shop = params.get("shop", "")
    received_hmac = params.pop("hmac", "")
    timestamp = params.get("timestamp", "")

    if not validate_shop_hostname(shop):
        return Response("Invalid shop hostname", status_code=400)

    if not verify_hmac(params, received_hmac, settings.SHOPIFY_CLIENT_SECRET):
        return Response("Invalid HMAC", status_code=401)

    if not validate_timestamp(timestamp):
        return Response("Stale or invalid timestamp", status_code=401)

    nonce = generate_nonce()
    signature = sign_nonce(nonce, settings.SHOPIFY_CLIENT_SECRET)

    redirect_url = (
        f"https://{shop}/admin/oauth/authorize"
        f"?client_id={settings.SHOPIFY_CLIENT_ID}"
        f"&scope={urllib.parse.quote(settings.SHOPIFY_SCOPES)}"
        f"&redirect_uri={urllib.parse.quote(settings.CALLBACK_URL)}"
        f"&state={nonce}"
    )

    response = RedirectResponse(url=redirect_url, status_code=302)
    response.set_cookie(key="shopify_nonce", value=nonce, httponly=True, secure=True, samesite="lax", max_age=600)
    response.set_cookie(key="shopify_nonce_sig", value=signature, httponly=True, secure=True, samesite="lax", max_age=600)
    return response


@app.get("/auth/callback")
def callback(request: Request):
    params = dict(request.query_params)
    shop = params.get("shop", "")
    code = params.get("code", "")
    state = params.get("state", "")
    received_hmac = params.pop("hmac", "")

    if not validate_shop_hostname(shop):
        return Response("Invalid shop hostname", status_code=400)

    if not verify_hmac(params, received_hmac, settings.SHOPIFY_CLIENT_SECRET):
        return Response("Invalid HMAC", status_code=401)

    cookie_nonce = request.cookies.get("shopify_nonce", "")
    cookie_sig = request.cookies.get("shopify_nonce_sig", "")
    if not cookie_nonce or state != cookie_nonce:
        return Response("Invalid state/nonce", status_code=403)
    if not verify_nonce_signature(cookie_nonce, cookie_sig, settings.SHOPIFY_CLIENT_SECRET):
        return Response("Invalid nonce signature", status_code=403)

    access_token, scopes = exchange_code_for_token(shop, code)
    if not access_token:
        return Response("Token exchange failed", status_code=502)

    store_installation(shop, access_token, scopes)

    try:
        shop_id = fetch_shop_id(shop, access_token)
        if shop_id:
            conn = get_connection()
            with conn.cursor() as cur:
                cur.execute("UPDATE shopify_installations SET shop_id = %s WHERE shop_domain = %s", (shop_id, shop))
            conn.commit()
            conn.close()
    except Exception as e:
        log.warning(f"Could not fetch shop_id: {e}")

    try:
        register_webhooks(shop, access_token)
    except Exception as e:
        log.warning(f"Could not register webhooks: {e}")

    response = HTMLResponse(
        content=f"""
        <html><body style="font-family: sans-serif; text-align: center; margin-top: 50px;">
            <h1>Installation Complete</h1>
            <p>Your Shopify store <strong>{shop}</strong> has been connected.</p>
            <a href="https://{shop}/admin">Return to Shopify Admin</a>
        </body></html>
        """,
        status_code=200,
    )
    response.delete_cookie("shopify_nonce")
    response.delete_cookie("shopify_nonce_sig")
    return response


def exchange_code_for_token(shop: str, code: str) -> tuple[str, str]:
    try:
        r = httpx.post(
            f"https://{shop}/admin/oauth/access_token",
            data={"client_id": settings.SHOPIFY_CLIENT_ID, "client_secret": settings.SHOPIFY_CLIENT_SECRET, "code": code},
            timeout=30,
        )
        r.raise_for_status()
        data = r.json()
        return data.get("access_token", ""), data.get("scope", "")
    except Exception as e:
        log.error(f"Token exchange failed for {shop}: {e}")
        return "", ""


def store_installation(shop: str, access_token: str, scopes: str):
    encrypted = encrypt_token(access_token, settings.SHOPIFY_TOKEN_ENCRYPTION_KEY)
    conn = get_connection()
    upsert_installation(conn, shop, encrypted, scopes)
    conn.close()
    log.info(f"Stored installation for {shop}")


def fetch_shop_id(shop: str, access_token: str) -> int | None:
    try:
        r = httpx.get(
            f"https://{shop}/admin/api/{settings.SHOPIFY_API_VERSION}/shop.json",
            headers={"X-Shopify-Access-Token": access_token},
            timeout=10,
        )
        r.raise_for_status()
        return r.json().get("shop", {}).get("id")
    except Exception as e:
        log.warning(f"Could not fetch shop_id for {shop}: {e}")
        return None


def register_webhooks(shop: str, access_token: str):
    base = settings.CALLBACK_URL.rsplit("/auth/callback", 1)[0]
    webhooks = [{"topic": "app/uninstalled", "address": f"{base}/webhooks/app-uninstalled"}]
    for wh in webhooks:
        try:
            r = httpx.post(
                f"https://{shop}/admin/api/{settings.SHOPIFY_API_VERSION}/webhooks.json",
                headers={"X-Shopify-Access-Token": access_token, "Content-Type": "application/json"},
                json={"webhook": {"topic": wh["topic"], "address": wh["address"], "format": "json"}},
                timeout=10,
            )
            log.info(f"Registered webhook {wh['topic']} for {shop}: HTTP {r.status_code}")
        except Exception as e:
            log.warning(f"Failed to register webhook {wh['topic']} for {shop}: {e}")


# Include webhook routes
from services.shopify_oauth.webhooks import router as webhook_router  # noqa: E402
app.include_router(webhook_router)
