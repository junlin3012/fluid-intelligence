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
    if not key_b64:
        raise ValueError("Encryption key is empty — check SHOPIFY_TOKEN_ENCRYPTION_KEY")
    if not encrypted_b64:
        raise ValueError("Encrypted token is empty — check shopify_installations table")
    key = base64.b64decode(key_b64)
    if len(key) not in (16, 24, 32):
        raise ValueError(f"Invalid key size ({len(key)} bytes) — AES requires 16, 24, or 32 bytes")
    data = base64.b64decode(encrypted_b64)
    if len(data) <= NONCE_SIZE:
        raise ValueError(f"Encrypted data too short ({len(data)} bytes) — corrupted token")
    nonce, ct = data[:NONCE_SIZE], data[NONCE_SIZE:]
    return AESGCM(key).decrypt(nonce, ct, None).decode()
