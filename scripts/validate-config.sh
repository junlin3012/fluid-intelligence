#!/bin/bash
# Validate all required environment variables before starting services.
# Collects ALL errors and reports them at once — don't stop at the first failure.
# Exit 0 = all validated. Exit 1 = missing/invalid vars.

ERRORS=0

# --- Helpers ---
require() {
  local var_name="$1" description="$2" format="${3:-}"
  local value="${!var_name:-}"
  if [ -z "$value" ]; then
    echo "[config] ✗ $var_name — MISSING (required: $description)"
    ERRORS=$((ERRORS + 1))
    return
  fi
  if [ -n "$format" ]; then
    if ! [[ "$value" =~ $format ]]; then
      echo "[config] ✗ $var_name — INVALID format (got: $value, expected: $description)"
      ERRORS=$((ERRORS + 1))
      return
    fi
  fi
  # Don't print secrets, just confirm they're set
  if [[ "$var_name" =~ SECRET|PASSWORD|KEY|CREDENTIALS ]]; then
    echo "[config] ✓ $var_name (set, ${#value} chars)"
  else
    echo "[config] ✓ $var_name=$value"
  fi
}

require_unless() {
  local condition_var="$1" var_name="$2" description="$3" format="${4:-}"
  if [ -n "${!condition_var:-}" ]; then
    echo "[config] ○ $var_name — skipped ($condition_var is set)"
    return
  fi
  require "$var_name" "$description" "$format"
}

warn_if_equal() {
  local var1="$1" var2="$2" msg="$3"
  if [ -n "${!var1:-}" ] && [ "${!var1}" = "${!var2:-}" ]; then
    echo "[config] ⚠ WARNING: $var1 equals $var2 — $msg"
  fi
}

echo "[config] Validating environment..."

# --- Required business config ---
require "SHOPIFY_STORE" "your-store.myshopify.com" '^[a-zA-Z0-9._-]+\.myshopify\.com$'
require "SHOPIFY_API_VERSION" "YYYY-MM (e.g., 2026-01)" '^[0-9]{4}-[0-9]{2}$'
require "EXTERNAL_URL" "public hostname (no https://)" '^[a-zA-Z0-9][a-zA-Z0-9._-]+\.[a-zA-Z0-9._-]+$'
require "GOOGLE_ALLOWED_USERS" "comma-separated emails" '.*@.*'
require "PLATFORM_ADMIN_EMAIL" "admin email address" '.*@.*'

# CLOUDSQL_INSTANCE only required if DATABASE_URL is not set (Cloud Run mode)
require_unless "DATABASE_URL" "CLOUDSQL_INSTANCE" "project:region:instance" '^[a-zA-Z0-9_-]+:[a-zA-Z0-9_-]+:[a-zA-Z0-9_-]+$'

# --- Required secrets ---
require "SHOPIFY_CLIENT_ID" "Shopify app client ID"
require "SHOPIFY_CLIENT_SECRET" "Shopify app client secret"
require "JWT_SECRET_KEY" "JWT signing key (20+ chars)"
require "AUTH_PASSWORD" "CLI auth password"
require "GOOGLE_OAUTH_CLIENT_ID" "Google OAuth client ID"
require "GOOGLE_OAUTH_CLIENT_SECRET" "Google OAuth client secret"
require "SHOPIFY_TOKEN_ENCRYPTION_KEY" "Shopify token encryption key"
require "CREDENTIALS_CONFIG" "Google Sheets service account JSON"

# AUTH_ENCRYPTION_SECRET — required, warn if same as JWT_SECRET_KEY
require "AUTH_ENCRYPTION_SECRET" "DB encryption key (must differ from JWT_SECRET_KEY)"
warn_if_equal "AUTH_ENCRYPTION_SECRET" "JWT_SECRET_KEY" "rotating JWT will corrupt stored data"

# DB_PASSWORD only required if DATABASE_URL is not set
require_unless "DATABASE_URL" "DB_PASSWORD" "database password"

# --- Report ---
if [ "$ERRORS" -gt 0 ]; then
  echo "[config] FATAL: $ERRORS required variable(s) missing or invalid. Cannot start."
  exit 1
fi

echo "[config] All required variables validated."
