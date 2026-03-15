"""Webhook handlers for Shopify APP_UNINSTALLED and GDPR mandatory webhooks."""

import base64
import hashlib
import hmac
import json
import logging

from fastapi import APIRouter, Request, Response

from services.shopify_oauth.config import settings
from services.shopify_oauth.db import get_connection, mark_uninstalled

log = logging.getLogger("shopify-oauth")
router = APIRouter()


def verify_webhook_hmac(body: bytes, received_hmac: str) -> bool:
    expected = base64.b64encode(
        hmac.new(settings.SHOPIFY_CLIENT_SECRET.encode(), body, hashlib.sha256).digest()
    ).decode()
    return hmac.compare_digest(expected, received_hmac)


def mark_shop_uninstalled(shop_domain: str):
    try:
        conn = get_connection()
        mark_uninstalled(conn, shop_domain)
        conn.close()
        log.info(f"Marked {shop_domain} as uninstalled")
    except Exception as e:
        log.error(f"Failed to mark {shop_domain} uninstalled: {e}")


@router.post("/webhooks/app-uninstalled")
async def app_uninstalled(request: Request):
    body = await request.body()
    hmac_header = request.headers.get("X-Shopify-Hmac-SHA256", "")
    if not verify_webhook_hmac(body, hmac_header):
        return Response("Invalid HMAC", status_code=401)

    data = json.loads(body)
    shop_domain = data.get("myshopify_domain", "")
    if shop_domain:
        mark_shop_uninstalled(shop_domain)
    return {"status": "ok"}


@router.post("/webhooks/gdpr/{topic}")
async def gdpr_webhook(topic: str, request: Request):
    body = await request.body()
    hmac_header = request.headers.get("X-Shopify-Hmac-SHA256", "")
    if not verify_webhook_hmac(body, hmac_header):
        return Response("Invalid HMAC", status_code=401)

    data = json.loads(body)
    log.info(f"GDPR webhook received: {topic}")

    if topic == "shop-redact":
        shop_domain = data.get("shop_domain", "")
        if shop_domain:
            mark_shop_uninstalled(shop_domain)

    return {"status": "ok"}
