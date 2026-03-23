import time
import pytest
from app.services.state_nonce import generate_nonce, verify_nonce

TEST_KEY = "test-hmac-key-for-nonce-signing"


def test_generate_and_verify():
    nonce = generate_nonce("shopify", TEST_KEY)
    assert verify_nonce(nonce, "shopify", TEST_KEY) is True


def test_wrong_provider_fails():
    nonce = generate_nonce("shopify", TEST_KEY)
    assert verify_nonce(nonce, "google", TEST_KEY) is False


def test_wrong_key_fails():
    nonce = generate_nonce("shopify", TEST_KEY)
    assert verify_nonce(nonce, "shopify", "wrong-key") is False


def test_expired_nonce_fails(monkeypatch):
    nonce = generate_nonce("shopify", TEST_KEY)
    monkeypatch.setattr("app.services.state_nonce.time.time", lambda: time.time() + 660)
    assert verify_nonce(nonce, "shopify", TEST_KEY) is False
