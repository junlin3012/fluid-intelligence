#!/bin/bash
# Test: AUTH_ENCRYPTION_SECRET should NOT be unconditionally derived from JWT_SECRET_KEY.
# It must only fall back to JWT_SECRET_KEY inside a guarded else branch.

# The old coupling was a bare line starting with 'export AUTH_ENCRYPTION_SECRET="${'
# followed by JWT_SECRET_KEY — no leading whitespace.
# After the fix the only remaining reference is indented (inside an else block).
if grep -E '^export AUTH_ENCRYPTION_SECRET=.*JWT_SECRET_KEY' scripts/entrypoint.sh; then
  echo "FAIL: entrypoint.sh still unconditionally derives AUTH_ENCRYPTION_SECRET from JWT_SECRET_KEY"
  exit 1
fi
echo "PASS: AUTH_ENCRYPTION_SECRET is independent (fallback is guarded)"
