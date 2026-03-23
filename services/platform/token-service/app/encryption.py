import base64
import hashlib
import os

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def _derive_key(key_string: str) -> bytes:
    """Derive a 32-byte AES-256 key from an arbitrary string via SHA-256."""
    return hashlib.sha256(key_string.encode()).digest()


def _make_aesgcm(key: str) -> AESGCM:
    """Return an AESGCM instance keyed from the given string."""
    return AESGCM(_derive_key(key))


def encrypt_token(plaintext: str, key: str) -> str:
    """Encrypt with AES-256-GCM. Returns base64(nonce + ciphertext)."""
    nonce = os.urandom(12)
    ciphertext = _make_aesgcm(key).encrypt(nonce, plaintext.encode(), None)
    return base64.urlsafe_b64encode(nonce + ciphertext).decode()


def decrypt_token(ciphertext: str, key: str) -> str:
    """Decrypt AES-256-GCM. Expects base64(nonce + ciphertext)."""
    raw = base64.urlsafe_b64decode(ciphertext.encode())
    nonce, ct = raw[:12], raw[12:]
    return _make_aesgcm(key).decrypt(nonce, ct, None).decode()
