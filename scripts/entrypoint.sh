#!/bin/bash
set -euo pipefail

echo "[fluid-intelligence] Starting services..."

# --- Graceful shutdown (set trap BEFORE starting processes) ---
PIDS=()
cleanup() {
  echo "[fluid-intelligence] SIGTERM received, shutting down..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait
  exit 0
}
trap cleanup SIGTERM SIGINT

# --- Env var wiring ---
export DATABASE_URL="postgresql://${DB_USER:-contextforge}:${DB_PASSWORD}@/${DB_NAME:-contextforge}?host=/cloudsql/junlinleather-mcp:asia-southeast1:contextforge"
export AUTH_ENCRYPTION_SECRET="${JWT_SECRET_KEY}"
export PLATFORM_ADMIN_PASSWORD="${AUTH_PASSWORD}"
export PLATFORM_ADMIN_EMAIL="${PLATFORM_ADMIN_EMAIL:-admin@junlinleather.com}"

# Cloud Run injects PORT=8080 as a system env var that CANNOT be overridden.
# ContextForge reads MCG_PORT (not PORT) for its listen port.
export CONTEXTFORGE_PORT="${MCPGATEWAY_PORT:-4444}"
export MCG_PORT="$CONTEXTFORGE_PORT"
export MCG_HOST="0.0.0.0"

# --- Validate required env vars ---
: "${SHOPIFY_API_VERSION:?SHOPIFY_API_VERSION must be set (e.g., 2026-01)}"
: "${DB_PASSWORD:?DB_PASSWORD must be set}"
: "${SHOPIFY_CLIENT_ID:?SHOPIFY_CLIENT_ID must be set}"
: "${SHOPIFY_CLIENT_SECRET:?SHOPIFY_CLIENT_SECRET must be set}"
: "${JWT_SECRET_KEY:?JWT_SECRET_KEY must be set}"
: "${AUTH_PASSWORD:?AUTH_PASSWORD must be set}"

# --- Fetch Shopify access token via client credentials ---
TOKEN_ENDPOINT="https://${SHOPIFY_STORE}/admin/oauth/access_token"
echo "[fluid-intelligence] Fetching Shopify access token..."
for attempt in 1 2 3 4 5; do
  # Pass credentials via stdin to avoid exposing SHOPIFY_CLIENT_SECRET in /proc/cmdline
  # Capture HTTP status separately for diagnostics on failure
  http_code=0
  response=$(printf 'grant_type=client_credentials&client_id=%s&client_secret=%s' \
    "$SHOPIFY_CLIENT_ID" "$SHOPIFY_CLIENT_SECRET" | \
    curl -s -w "\n%{http_code}" --max-time 15 -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d @- 2>/tmp/shopify-curl-err.log) || true
  if [ -n "$response" ]; then
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    token=$(echo "$body" | jq -r '.access_token // empty' 2>/dev/null)
    if [ -n "$token" ]; then
      export SHOPIFY_ACCESS_TOKEN="$token"
      echo "[fluid-intelligence] Shopify token acquired (attempt $attempt)"
      rm -f /tmp/shopify-curl-err.log
      break
    fi
  fi
  if [ "$attempt" -eq 5 ]; then
    echo "[fluid-intelligence] FATAL: Could not fetch Shopify access token after 5 attempts"
    echo "[fluid-intelligence]   Last HTTP status: $http_code"
    [ -f /tmp/shopify-curl-err.log ] && echo "[fluid-intelligence]   curl stderr: $(cat /tmp/shopify-curl-err.log)"
    rm -f /tmp/shopify-curl-err.log
    exit 1
  fi
  echo "[fluid-intelligence] Token attempt $attempt failed (HTTP $http_code)"
  sleep $((attempt * 2))
done

# Shopify schema (SDL) is baked into the image at /app/shopify-schema.graphql
# To update: re-run introspection and convert to SDL (see CLAUDE.md)

# --- Helper: start a process with early crash detection ---
start_and_verify() {
  local name="$1" pid="$2"
  sleep 2
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "[fluid-intelligence] FATAL: $name (PID $pid) crashed on startup"
    # Kill anything else we started
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    exit 1
  fi
  echo "[fluid-intelligence] $name started (PID $pid)"
}

# --- Start services ---

# 1. Apollo MCP Server (Rust, Shopify GraphQL) — via stdio→SSE bridge
# Apollo only supports stdio or streamable_http transports.
# ContextForge's MCP client has a bug with streamable_http, so we use stdio
# and bridge it to SSE via mcpgateway.translate (same pattern as dev-mcp/sheets).
python3 -m mcpgateway.translate \
  --stdio "apollo /app/mcp-config.yaml" \
  --expose-sse \
  --port 8000 &
APOLLO_PID=$!
PIDS+=("$APOLLO_PID")
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
python3 -m mcpgateway.translate \
  --stdio "npx -y @shopify/dev-mcp@latest" \
  --expose-sse \
  --port 8003 &
TRANSLATE_DEVMCP_PID=$!
PIDS+=("$TRANSLATE_DEVMCP_PID")
start_and_verify "dev-mcp bridge" "$TRANSLATE_DEVMCP_PID"

# 4. google-sheets bridge (stdio→SSE)
python3 -m mcpgateway.translate \
  --stdio "uv tool run mcp-google-sheets@latest --transport stdio" \
  --expose-sse \
  --port 8004 &
TRANSLATE_SHEETS_PID=$!
PIDS+=("$TRANSLATE_SHEETS_PID")
start_and_verify "sheets bridge" "$TRANSLATE_SHEETS_PID"

# --- Wait for ContextForge health before starting auth proxy ---
echo "[fluid-intelligence] Waiting for ContextForge to be ready..."
for i in $(seq 1 180); do
  if curl -sf http://localhost:${CONTEXTFORGE_PORT}/health > /dev/null 2>&1; then
    echo "[fluid-intelligence] ContextForge ready after ${i}s"
    break
  fi
  # Check if mcpgateway is still alive (fast-fail instead of waiting full timeout)
  if ! kill -0 "$CONTEXTFORGE_PID" 2>/dev/null; then
    echo "[fluid-intelligence] FATAL: ContextForge process died during startup"
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    exit 1
  fi
  if [ "$i" -eq 180 ]; then
    echo "[fluid-intelligence] FATAL: ContextForge not ready after 180s"
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
  -- http://localhost:${CONTEXTFORGE_PORT} &
AUTHPROXY_PID=$!
PIDS+=("$AUTHPROXY_PID")
start_and_verify "auth-proxy" "$AUTHPROXY_PID"

# 6. Bootstrap: register backends (foreground — fail fast if broken)
echo "[fluid-intelligence] Running bootstrap..."
/app/bootstrap.sh || {
  echo "[fluid-intelligence] FATAL: bootstrap failed — backend registration incomplete"
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  exit 1
}

echo "[fluid-intelligence] All services running"
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

for name_pid in "Apollo-bridge:$APOLLO_PID" "ContextForge:$CONTEXTFORGE_PID" "dev-mcp:$TRANSLATE_DEVMCP_PID" "sheets:$TRANSLATE_SHEETS_PID" "auth-proxy:$AUTHPROXY_PID"; do
  name="${name_pid%%:*}"
  pid="${name_pid##*:}"
  if ! kill -0 "$pid" 2>/dev/null; then
    # Get per-process exit code (wait returns 127 if already reaped)
    wait "$pid" 2>/dev/null; pid_exit=$?
    echo "[fluid-intelligence] Process $name (PID $pid) exited (code $pid_exit)"
  fi
done

for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
exit 1
