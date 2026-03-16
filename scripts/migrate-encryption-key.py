#!/usr/bin/env python3
"""One-time migration: re-encrypt all Shopify tokens from old key to new key.

Usage:
  OLD_KEY=<old-base64-key> NEW_KEY=<new-base64-key> DATABASE_URL=<url> python3 scripts/migrate-encryption-key.py

Safety:
  - Dry-run by default (prints what would change, no writes)
  - Pass --commit to actually write
  - Idempotent: tokens already encrypted with NEW_KEY are skipped (decrypt fails gracefully)
"""
import os
import sys

import psycopg2
import psycopg2.extras

# Allow importing from project root
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from services.shopify_oauth.crypto import decrypt_token, encrypt_token


def main():
    old_key = os.environ["OLD_KEY"]
    new_key = os.environ["NEW_KEY"]
    dsn = os.environ["DATABASE_URL"]
    commit = "--commit" in sys.argv

    conn = psycopg2.connect(dsn)
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute("SELECT id, shop_domain, access_token_encrypted FROM shopify_installations WHERE status = 'active' AND access_token_encrypted != ''")
    rows = cur.fetchall()

    migrated = 0
    skipped = 0
    for row in rows:
        try:
            plaintext = decrypt_token(row["access_token_encrypted"], old_key)
        except Exception:
            # Already on new key or corrupted — skip
            skipped += 1
            continue

        new_ct = encrypt_token(plaintext, new_key)
        if commit:
            cur.execute(
                "UPDATE shopify_installations SET access_token_encrypted = %s, updated_at = NOW() WHERE id = %s",
                (new_ct, row["id"]),
            )
        print(f"{'MIGRATED' if commit else 'WOULD MIGRATE'}: {row['shop_domain']} (id={row['id']})")
        migrated += 1

    if commit:
        conn.commit()
    conn.close()
    print(f"\nDone: {migrated} migrated, {skipped} skipped")
    if not commit and migrated > 0:
        print("Run with --commit to apply changes")


if __name__ == "__main__":
    main()
