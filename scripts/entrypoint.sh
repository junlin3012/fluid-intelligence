#!/bin/bash
set -euo pipefail

# Require bash 4.3+ for wait -n support
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  echo "[fluid-intelligence] FATAL: bash 4.3+ required (have $BASH_VERSION)"
  exit 1
fi

START_TIME=$(date +%s)
elapsed() { echo $(( $(date +%s) - START_TIME )); }

echo "[fluid-intelligence] Starting services..."

# --- Graceful shutdown (set trap BEFORE starting processes) ---
PIDS=()
SHUTTING_DOWN=0
cleanup() {
  SHUTTING_DOWN=1
  echo "[fluid-intelligence] SIGTERM received, shutting down..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  # Clean up temp files (only entrypoint's own — bootstrap uses its own $$ for JWT/curl temp files)
  rm -f /tmp/shopify-curl-err-$$.log /tmp/jq-err-$$.log
  rm -f /tmp/apollo.pid /tmp/devmcp.pid /tmp/sheets.pid
  exit 143  # 128 + 15 (SIGTERM)
}
trap cleanup SIGTERM SIGINT

# Clean stale PID files from previous runs (safe on Cloud Run tmpfs, defensive for Docker Compose)
rm -f /tmp/apollo.pid /tmp/devmcp.pid /tmp/sheets.pid

# --- Validate required env vars (BEFORE any use, especially DB_PASSWORD in URL encoding) ---
: "${SHOPIFY_API_VERSION:?SHOPIFY_API_VERSION must be set (e.g., 2026-01)}"
: "${DB_PASSWORD:?DB_PASSWORD must be set}"
: "${SHOPIFY_CLIENT_ID:?SHOPIFY_CLIENT_ID must be set}"
: "${SHOPIFY_CLIENT_SECRET:?SHOPIFY_CLIENT_SECRET must be set}"
: "${JWT_SECRET_KEY:?JWT_SECRET_KEY must be set}"
: "${AUTH_PASSWORD:?AUTH_PASSWORD must be set}"
: "${SHOPIFY_STORE:?SHOPIFY_STORE must be set}"
: "${GOOGLE_OAUTH_CLIENT_ID:?GOOGLE_OAUTH_CLIENT_ID must be set}"
: "${GOOGLE_OAUTH_CLIENT_SECRET:?GOOGLE_OAUTH_CLIENT_SECRET must be set}"

# --- Validate env var formats (defense-in-depth against injection) ---
if ! [[ "$SHOPIFY_STORE" =~ ^[a-zA-Z0-9._-]+\.myshopify\.com$ ]]; then
  echo "[fluid-intelligence] FATAL: SHOPIFY_STORE must be a valid myshopify.com domain, got: $SHOPIFY_STORE"
  exit 1
fi
if ! [[ "${MCPGATEWAY_PORT:-4444}" =~ ^[0-9]+$ ]]; then
  echo "[fluid-intelligence] FATAL: MCPGATEWAY_PORT must be numeric, got: ${MCPGATEWAY_PORT:-4444}"
  exit 1
fi
if [[ -n "${EXTERNAL_URL:-}" ]] && ! [[ "$EXTERNAL_URL" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*(\.[a-zA-Z0-9][a-zA-Z0-9_-]*)+$ ]]; then
  echo "[fluid-intelligence] FATAL: EXTERNAL_URL contains invalid characters, got: $EXTERNAL_URL"
  exit 1
fi

# Validate DB_USER and DB_NAME (they're interpolated into DATABASE_URL — special chars corrupt the URI)
if [[ -n "${DB_USER:-}" ]] && ! [[ "${DB_USER}" =~ ^[a-zA-Z0-9_]+$ ]]; then
  echo "[fluid-intelligence] FATAL: DB_USER must be alphanumeric/underscore, got: $DB_USER"
  exit 1
fi
if [[ -n "${DB_NAME:-}" ]] && ! [[ "${DB_NAME}" =~ ^[a-zA-Z0-9_]+$ ]]; then
  echo "[fluid-intelligence] FATAL: DB_NAME must be alphanumeric/underscore, got: $DB_NAME"
  exit 1
fi

# --- Env var wiring ---
# URL-encode DB_PASSWORD to handle special chars (@, ?, /, %) that break connection strings
encoded_pw=$(DB_PASSWORD="$DB_PASSWORD" python3 -c "import urllib.parse, os; print(urllib.parse.quote(os.environ['DB_PASSWORD'], safe=''))")
if [ -z "$encoded_pw" ]; then
  echo "[fluid-intelligence] FATAL: URL-encoding DB_PASSWORD produced empty result"
  exit 1
fi
export DATABASE_URL="postgresql://${DB_USER:-contextforge}:${encoded_pw}@/${DB_NAME:-contextforge}?host=/cloudsql/junlinleather-mcp:asia-southeast1:contextforge"
export AUTH_ENCRYPTION_SECRET="${JWT_SECRET_KEY}"
export PLATFORM_ADMIN_PASSWORD="${AUTH_PASSWORD}"
export PLATFORM_ADMIN_EMAIL="${PLATFORM_ADMIN_EMAIL:-admin@junlinleather.com}"

# Cloud Run injects PORT=8080 as a system env var that CANNOT be overridden.
# ContextForge reads MCG_PORT (not PORT) for its listen port.
export CONTEXTFORGE_PORT="${MCPGATEWAY_PORT:-4444}"
export MCG_PORT="$CONTEXTFORGE_PORT"
export MCG_HOST="0.0.0.0"

# --- Read Shopify access token from Cloud SQL (OAuth service writes it) ---
echo "[fluid-intelligence] Checking Cloud SQL for Shopify token..."
DB_TOKEN=$(/app/.venv/bin/python3 -c "
import os, sys
try:
    import psycopg2
    conn = psycopg2.connect(
        dbname=os.environ.get('DB_NAME', 'contextforge'),
        user=os.environ.get('DB_USER', 'contextforge'),
        password=os.environ.get('DB_PASSWORD', ''),
        host='/cloudsql/junlinleather-mcp:asia-southeast1:contextforge'
    )
    cur = conn.cursor()
    cur.execute('SELECT access_token_encrypted FROM shopify_installations WHERE shop_domain = %s AND status = %s',
                (os.environ.get('SHOPIFY_STORE', ''), 'active'))
    row = cur.fetchone()
    if row and row[0]:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        import base64
        key = base64.b64decode(os.environ.get('SHOPIFY_TOKEN_ENCRYPTION_KEY', ''))
        data = base64.b64decode(row[0])
        nonce, ct = data[:12], data[12:]
        print(AESGCM(key).decrypt(nonce, ct, None).decode())
    conn.close()
except Exception as e:
    print(f'DB_TOKEN_ERROR: {e}', file=sys.stderr)
" 2>/tmp/db-token-err-$$.log) || true

if [ -n "$DB_TOKEN" ] && [[ "$DB_TOKEN" == shp* ]]; then
  export SHOPIFY_ACCESS_TOKEN="$DB_TOKEN"
  echo "[fluid-intelligence] Shopify token loaded from Cloud SQL (permanent offline token)"
  rm -f /tmp/db-token-err-$$.log
else
  echo "[fluid-intelligence] No token in Cloud SQL, falling back to client_credentials..."
  [ -f /tmp/db-token-err-$$.log ] && [ -s /tmp/db-token-err-$$.log ] && echo "[fluid-intelligence]   DB error: $(cat /tmp/db-token-err-$$.log)"
  rm -f /tmp/db-token-err-$$.log

  # --- Fallback: Fetch Shopify access token via client credentials (24h expiry) ---
  TOKEN_ENDPOINT="https://${SHOPIFY_STORE}/admin/oauth/access_token"
  echo "[fluid-intelligence] Fetching Shopify access token via client_credentials..."
  body=""
  for attempt in 1 2 3 4 5; do
  # Pass credentials via stdin to avoid exposing SHOPIFY_CLIENT_SECRET in /proc/cmdline
  # Capture HTTP status separately for diagnostics on failure
  http_code=0
  response=$(curl -s -w "\n%{http_code}" --connect-timeout 5 --max-time 15 -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=$SHOPIFY_CLIENT_ID" \
    --data-urlencode "client_secret=$SHOPIFY_CLIENT_SECRET" \
    2>/tmp/shopify-curl-err-$$.log) || true
  if [ -n "$response" ]; then
    http_code=$(echo "$response" | tail -1)
    [[ "$http_code" =~ ^[0-9]+$ ]] || http_code=0
    body=$(echo "$response" | sed '$d')
    token=$(echo "$body" | jq -r '.access_token // empty' 2>/tmp/jq-err-$$.log) || true
    if [ -n "$token" ]; then
      export SHOPIFY_ACCESS_TOKEN="$token"
      echo "[fluid-intelligence] Shopify token acquired (attempt $attempt)"
      rm -f /tmp/shopify-curl-err-$$.log /tmp/jq-err-$$.log
      break
    fi
  fi
  if [ "$attempt" -eq 5 ]; then
    echo "[fluid-intelligence] FATAL: Could not fetch Shopify access token after 5 attempts"
    echo "[fluid-intelligence]   Last HTTP status: $http_code"
    echo "[fluid-intelligence]   Response body: $(echo "$body" | head -c 500)"
    [ -f /tmp/shopify-curl-err-$$.log ] && echo "[fluid-intelligence]   curl stderr: $(cat /tmp/shopify-curl-err-$$.log)"
    [ -f /tmp/jq-err-$$.log ] && [ -s /tmp/jq-err-$$.log ] && echo "[fluid-intelligence]   jq parse error: $(cat /tmp/jq-err-$$.log)"
    rm -f /tmp/shopify-curl-err-$$.log /tmp/jq-err-$$.log
    exit 1
  fi
  echo "[fluid-intelligence] Token attempt $attempt failed (HTTP $http_code)"
  sleep "$((attempt * 2))"
done
: "${SHOPIFY_ACCESS_TOKEN:?Token loop exited without setting SHOPIFY_ACCESS_TOKEN}"
fi  # end of client_credentials fallback

# Shopify schema (SDL) is baked into the image at /app/shopify-schema.graphql
# To update: re-run introspection against Shopify Admin API and rebuild Dockerfile.base

# --- Helper: start a process with early crash detection ---
start_and_verify() {
  local name="$1" pid="$2"
  sleep 2 &
  wait $!
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "[fluid-intelligence] FATAL: $name (PID $pid) crashed on startup"
    echo "[fluid-intelligence]   Check container logs above for $name stderr output"
    # Kill anything else we started
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    exit 1
  fi
  echo "[fluid-intelligence] $name started (PID $pid) [+$(elapsed)s]"
}

# --- Start services ---

# 1. Apollo MCP Server (Rust, Shopify GraphQL) — via stdio→SSE bridge
# Apollo only supports stdio or streamable_http transports.
# ContextForge's MCP client has a bug with streamable_http, so we use stdio
# and bridge it to SSE via mcpgateway.translate (same pattern as dev-mcp/sheets).
/app/.venv/bin/python -m mcpgateway.translate \
  --stdio "apollo /app/mcp-config.yaml" \
  --expose-sse \
  --port 8000 &
APOLLO_PID=$!
PIDS+=("$APOLLO_PID")
echo "$APOLLO_PID" > /tmp/apollo.pid
start_and_verify "Apollo bridge" "$APOLLO_PID"

# 2. IBM ContextForge (Python, gateway core)
# The `mcpgateway` entry point and `python -m mcpgateway` both fail at runtime.
# Direct invocation of main() works since the module IS importable.
MCG_PORT="$CONTEXTFORGE_PORT" /app/.venv/bin/python -c "
import os, sys
sys.argv = ['mcpgateway', '--port', os.environ['MCG_PORT'], '--host', '0.0.0.0']
from mcpgateway.cli import main
main()
" &
CONTEXTFORGE_PID=$!
PIDS+=("$CONTEXTFORGE_PID")
start_and_verify "ContextForge" "$CONTEXTFORGE_PID"

# 3. dev-mcp bridge (stdio→SSE)
/app/.venv/bin/python -m mcpgateway.translate \
  --stdio "npx -y @shopify/dev-mcp@1.7.1" \
  --expose-sse \
  --port 8003 &
TRANSLATE_DEVMCP_PID=$!
PIDS+=("$TRANSLATE_DEVMCP_PID")
echo "$TRANSLATE_DEVMCP_PID" > /tmp/devmcp.pid
start_and_verify "dev-mcp bridge" "$TRANSLATE_DEVMCP_PID"

# 4. google-sheets bridge (stdio→SSE)
/app/.venv/bin/python -m mcpgateway.translate \
  --stdio "uv tool run mcp-google-sheets@0.6.0 --transport stdio" \
  --expose-sse \
  --port 8004 &
TRANSLATE_SHEETS_PID=$!
PIDS+=("$TRANSLATE_SHEETS_PID")
echo "$TRANSLATE_SHEETS_PID" > /tmp/sheets.pid
start_and_verify "sheets bridge" "$TRANSLATE_SHEETS_PID"

# --- Wait for ContextForge health before starting auth proxy ---
echo "[fluid-intelligence] Waiting for ContextForge to be ready..."
# ContextForge health timeout must fit within Cloud Run startup probe (240s).
# Budget: ~115s already elapsed (token fetch + process starts), so ContextForge gets 120s max.
# Previous value of 180s exceeded the 240s probe, causing pod kills on slow starts.
CF_HEALTH_TIMEOUT=120
for i in $(seq 1 "$CF_HEALTH_TIMEOUT"); do
  if curl -sf --connect-timeout 2 --max-time 5 "http://127.0.0.1:${CONTEXTFORGE_PORT}/health" > /dev/null 2>&1; then
    echo "[fluid-intelligence] ContextForge ready after ${i}s [+$(elapsed)s]"
    break
  fi
  # Check if mcpgateway is still alive (fast-fail instead of waiting full timeout)
  if ! kill -0 "$CONTEXTFORGE_PID" 2>/dev/null; then
    wait "$CONTEXTFORGE_PID" 2>/dev/null; cf_exit=$?
    echo "[fluid-intelligence] FATAL: ContextForge process died during startup (exit code $cf_exit)"
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    exit 1
  fi
  if [ "$i" -eq "$CF_HEALTH_TIMEOUT" ]; then
    echo "[fluid-intelligence] FATAL: ContextForge not ready after ${CF_HEALTH_TIMEOUT}s [+$(elapsed)s]"
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    exit 1
  fi
  sleep 1
done

# 5. mcp-auth-proxy (Go, OAuth 2.1 front door) — starts after ContextForge is ready
# SECURITY NOTE: --password and --google-client-secret are passed via CLI args,
# which exposes them in /proc/cmdline. This is a known limitation of mcp-auth-proxy v2.5.4.
# TODO: Check if future versions support env var or config file for secrets.
# Risk is bounded: all processes run as UID 1001 in the same container.
mcp-auth-proxy \
  --listen :8080 \
  --external-url "https://${EXTERNAL_URL:-junlinleather.com}" \
  --google-client-id "$GOOGLE_OAUTH_CLIENT_ID" \
  --google-client-secret "$GOOGLE_OAUTH_CLIENT_SECRET" \
  --google-allowed-users "${GOOGLE_ALLOWED_USERS:-ourteam@junlinleather.com}" \
  --password "$AUTH_PASSWORD" \
  --no-auto-tls \
  --data-path /app/data \
  -- "http://127.0.0.1:${CONTEXTFORGE_PORT}" &
AUTHPROXY_PID=$!
PIDS+=("$AUTHPROXY_PID")
start_and_verify "auth-proxy" "$AUTHPROXY_PID"

# 6. Bootstrap: register backends (background so SIGTERM can kill it cleanly)
echo "[fluid-intelligence] Running bootstrap..."
/app/bootstrap.sh &
BOOTSTRAP_PID=$!
PIDS+=("$BOOTSTRAP_PID")
wait "$BOOTSTRAP_PID" || {
  # If SIGTERM arrived during bootstrap wait, let cleanup() handle it
  [ "$SHUTTING_DOWN" -eq 1 ] && exit 143
  echo "[fluid-intelligence] FATAL: bootstrap failed — backend registration incomplete"
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  exit 1
}
# Remove completed bootstrap PID from PIDS to avoid killing a reused PID
# Use exact match loop (not substring replacement which corrupts e.g. PID 12 inside 1234)
NEW_PIDS=()
for p in "${PIDS[@]}"; do [ "$p" != "$BOOTSTRAP_PID" ] && NEW_PIDS+=("$p"); done
PIDS=("${NEW_PIDS[@]}")

echo "[fluid-intelligence] All services running [+$(elapsed)s]"
echo "  Apollo bridge:  PID=$APOLLO_PID  :8000"
echo "  ContextForge:   PID=$CONTEXTFORGE_PID  :${CONTEXTFORGE_PORT}"
echo "  dev-mcp:        PID=$TRANSLATE_DEVMCP_PID  :8003"
echo "  sheets:         PID=$TRANSLATE_SHEETS_PID  :8004"
echo "  auth-proxy:     PID=$AUTHPROXY_PID  :8080"

# --- Monitor: exit if any process dies ---
# Disable set -e: wait -n returns error if a PID was already reaped (race condition)
set +e
wait -n "$APOLLO_PID" "$CONTEXTFORGE_PID" "$TRANSLATE_DEVMCP_PID" "$TRANSLATE_SHEETS_PID" "$AUTHPROXY_PID"
FIRST_EXIT=$?
set -e

echo "[fluid-intelligence] FATAL: A process exited unexpectedly (first exit code: $FIRST_EXIT)"

for name_pid in "Apollo-bridge:$APOLLO_PID" "ContextForge:$CONTEXTFORGE_PID" "dev-mcp:$TRANSLATE_DEVMCP_PID" "sheets:$TRANSLATE_SHEETS_PID" "auth-proxy:$AUTHPROXY_PID"; do
  name="${name_pid%%:*}"
  pid="${name_pid##*:}"
  if ! kill -0 "$pid" 2>/dev/null; then
    # Get per-process exit code (wait returns 127 if already reaped)
    wait "$pid" 2>/dev/null; pid_exit=$?
    # 127 = PID already reaped by shell before wait was called
    echo "[fluid-intelligence] FATAL: Process $name (PID $pid) exited (code $pid_exit$([ "$pid_exit" -eq 127 ] && echo ', already reaped'))"
  fi
done

for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
exit 1
