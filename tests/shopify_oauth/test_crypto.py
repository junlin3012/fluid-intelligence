import base64
import os
import pytest
from services.shopify_oauth.crypto import encrypt_token, decrypt_token


@pytest.fixture
def encryption_key():
    """32-byte AES-256 key, base64-encoded (matches Secret Manager format)."""
    return base64.b64encode(os.urandom(32)).decode()


def test_encrypt_decrypt_round_trip(encryption_key):
    token = "shpat_abc123def456"
    encrypted = encrypt_token(token, encryption_key)
    decrypted = decrypt_token(encrypted, encryption_key)
    assert decrypted == token


def test_encrypted_differs_from_plaintext(encryption_key):
    token = "shpat_abc123def456"
    encrypted = encrypt_token(token, encryption_key)
    assert encrypted != token


def test_different_encryptions_differ(encryption_key):
    token = "shpat_abc123def456"
    e1 = encrypt_token(token, encryption_key)
    e2 = encrypt_token(token, encryption_key)
    assert e1 != e2


def test_decrypt_with_wrong_key(encryption_key):
    token = "shpat_abc123def456"
    encrypted = encrypt_token(token, encryption_key)
    wrong_key = base64.b64encode(os.urandom(32)).decode()
    with pytest.raises(Exception):
        decrypt_token(encrypted, wrong_key)


def test_decrypt_tampered_ciphertext(encryption_key):
    token = "shpat_abc123def456"
    encrypted = encrypt_token(token, encryption_key)
    raw = base64.b64decode(encrypted)
    tampered = base64.b64encode(raw[:-1] + bytes([raw[-1] ^ 0xFF])).decode()
    with pytest.raises(Exception):
        decrypt_token(tampered, encryption_key)
