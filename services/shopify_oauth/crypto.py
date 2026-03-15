"""AES-256-GCM encryption for Shopify access tokens."""

import base64
import os

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

NONCE_SIZE = 12  # 96-bit nonce for AES-GCM


def encrypt_token(plaintext: str, key_b64: str) -> str:
    """Encrypt a token with AES-256-GCM. Returns base64-encoded nonce+ciphertext."""
    key = base64.b64decode(key_b64)
    nonce = os.urandom(NONCE_SIZE)
    ct = AESGCM(key).encrypt(nonce, plaintext.encode(), None)
    return base64.b64encode(nonce + ct).decode()


def decrypt_token(encrypted_b64: str, key_b64: str) -> str:
    """Decrypt an AES-256-GCM encrypted token. Input is base64-encoded nonce+ciphertext."""
    key = base64.b64decode(key_b64)
    data = base64.b64decode(encrypted_b64)
    nonce, ct = data[:NONCE_SIZE], data[NONCE_SIZE:]
    return AESGCM(key).decrypt(nonce, ct, None).decode()
