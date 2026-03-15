import time
import pytest
from services.shopify_oauth.security import (
    validate_shop_hostname,
    compute_hmac,
    verify_hmac,
    generate_nonce,
    sign_nonce,
    verify_nonce_signature,
    validate_timestamp,
)


def test_valid_shop_hostname(valid_shop):
    assert validate_shop_hostname(valid_shop) is True


def test_invalid_shop_hostnames(invalid_shops):
    for shop in invalid_shops:
        assert validate_shop_hostname(shop) is False, f"{shop} should be invalid"


def test_compute_hmac_deterministic(client_secret):
    params = {"shop": "test.myshopify.com", "timestamp": "1234567890"}
    h1 = compute_hmac(params, client_secret)
    h2 = compute_hmac(params, client_secret)
    assert h1 == h2


def test_verify_hmac_valid(client_secret):
    params = {"shop": "test.myshopify.com", "timestamp": "1234567890"}
    mac = compute_hmac(params, client_secret)
    assert verify_hmac(params, mac, client_secret) is True


def test_verify_hmac_invalid(client_secret):
    params = {"shop": "test.myshopify.com", "timestamp": "1234567890"}
    assert verify_hmac(params, "badhmac", client_secret) is False


def test_generate_nonce_uniqueness():
    n1 = generate_nonce()
    n2 = generate_nonce()
    assert n1 != n2
    assert len(n1) == 64  # 32 bytes hex-encoded


def test_nonce_sign_and_verify(client_secret):
    nonce = generate_nonce()
    signed = sign_nonce(nonce, client_secret)
    assert verify_nonce_signature(nonce, signed, client_secret) is True


def test_nonce_verify_rejects_tampered(client_secret):
    nonce = generate_nonce()
    signed = sign_nonce(nonce, client_secret)
    assert verify_nonce_signature("tampered", signed, client_secret) is False


def test_validate_timestamp_fresh():
    ts = str(int(time.time()))
    assert validate_timestamp(ts) is True


def test_validate_timestamp_stale():
    ts = str(int(time.time()) - 600)  # 10 min ago
    assert validate_timestamp(ts) is False


def test_validate_timestamp_invalid():
    assert validate_timestamp("not_a_number") is False
