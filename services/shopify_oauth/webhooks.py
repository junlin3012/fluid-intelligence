"""Webhook handlers for Shopify APP_UNINSTALLED and GDPR mandatory webhooks."""

import base64
import hashlib
import hmac
import json
import logging

from fastapi import APIRouter, Request, Response

from services.shopify_oauth.config import settings
from services.shopify_oauth.db import get_connection, mark_uninstalled, get_customer_data, delete_customer_data, delete_shop_data

log = logging.getLogger("shopify-oauth")
router = APIRouter()

MAX_WEBHOOK_BODY = 1_048_576  # 1 MB — Shopify payloads are typically < 10 KB


def verify_webhook_hmac(body: bytes, received_hmac: str) -> bool:
    expected = base64.b64encode(
        hmac.new(settings.SHOPIFY_CLIENT_SECRET.encode(), body, hashlib.sha256).digest()
    ).decode()
    return hmac.compare_digest(expected, received_hmac)


def mark_shop_uninstalled(shop_domain: str):
    try:
        conn = get_connection()
        try:
            mark_uninstalled(conn, shop_domain)
        finally:
            conn.close()
        log.info(f"Marked {shop_domain} as uninstalled")
    except Exception as e:
        log.error(f"Failed to mark {shop_domain} uninstalled: {e}")


@router.post("/webhooks/app-uninstalled")
async def app_uninstalled(request: Request):
    body = await request.body()
    if len(body) > MAX_WEBHOOK_BODY:
        return Response("Payload too large", status_code=413)
    hmac_header = request.headers.get("X-Shopify-Hmac-SHA256", "")
    if not verify_webhook_hmac(body, hmac_header):
        return Response("Invalid HMAC", status_code=401)

    try:
        data = json.loads(body)
    except (json.JSONDecodeError, ValueError):
        return Response("Invalid JSON", status_code=400)
    shop_domain = data.get("myshopify_domain", "")
    if shop_domain:
        mark_shop_uninstalled(shop_domain)
    return {"status": "ok"}


@router.post("/webhooks/gdpr/{topic}")
async def gdpr_webhook(topic: str, request: Request):
    body = await request.body()
    if len(body) > MAX_WEBHOOK_BODY:
        return Response("Payload too large", status_code=413)
    hmac_header = request.headers.get("X-Shopify-Hmac-SHA256", "")
    if not verify_webhook_hmac(body, hmac_header):
        return Response("Invalid HMAC", status_code=401)

    try:
        data = json.loads(body)
    except (json.JSONDecodeError, ValueError):
        return Response("Invalid JSON", status_code=400)

    shop_domain = data.get("shop_domain", "")
    customer = data.get("customer", {})
    customer_email = customer.get("email", "") if isinstance(customer, dict) else ""

    log.info(f"GDPR webhook received: {topic} for shop={shop_domain}")

    try:
        conn = get_connection()
        try:
            if topic == "customers-data_request":
                result = get_customer_data(conn, shop_domain, customer_email)
                log.info(f"GDPR data request: shop={shop_domain}, customer={customer_email}, data_found={result is not None}")

            elif topic == "customers-redact":
                delete_customer_data(conn, shop_domain, customer_email)
                log.info(f"GDPR customer redact: shop={shop_domain}, customer={customer_email}")

            elif topic == "shop-redact":
                # Permanent deletion — unlike mark_uninstalled (soft delete),
                # this hard DELETEs the record for GDPR compliance
                delete_shop_data(conn, shop_domain)
                log.info(f"GDPR shop redact: permanently deleted shop={shop_domain}")

            else:
                log.warning(f"Unknown GDPR topic: {topic}")
        finally:
            conn.close()
    except Exception as e:
        log.error(f"GDPR webhook {topic} failed for shop={shop_domain}: {e}")
        # Return 200 anyway — Shopify retries on non-200, and we don't want
        # infinite retries on transient DB errors. Log for manual follow-up.

    return {"status": "ok"}
