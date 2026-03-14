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
# We use --port flag for mcpgateway instead of relying on PORT env var.
export CONTEXTFORGE_PORT="${MCPGATEWAY_PORT:-4444}"

# --- Fetch Shopify access token via client credentials ---
TOKEN_ENDPOINT="https://${SHOPIFY_STORE}/admin/oauth/access_token"
echo "[fluid-intelligence] Fetching Shopify access token..."
for attempt in 1 2 3 4 5; do
  response=$(curl -sf --max-time 15 -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=${SHOPIFY_CLIENT_ID}&client_secret=${SHOPIFY_CLIENT_SECRET}" \
    2>/dev/null) || true
  if [ -n "$response" ]; then
    token=$(echo "$response" | jq -r '.access_token // empty')
    if [ -n "$token" ]; then
      export SHOPIFY_ACCESS_TOKEN="$token"
      echo "[fluid-intelligence] Shopify token acquired (attempt $attempt)"
      break
    fi
  fi
  if [ "$attempt" -eq 5 ]; then
    echo "[fluid-intelligence] FATAL: Could not fetch Shopify access token after 5 attempts"
    exit 1
  fi
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

# 1. Apollo MCP Server (Rust, Shopify GraphQL) — positional arg, NOT --config
apollo /app/mcp-config.yaml &
APOLLO_PID=$!
PIDS+=($APOLLO_PID)
start_and_verify "Apollo" $APOLLO_PID

# 2. IBM ContextForge (Python, gateway core)
# The `mcpgateway` entry point and `python -m mcpgateway` both fail at runtime.
# Direct invocation of main() works since the module IS importable.
/app/.venv/bin/python -c "
import sys
sys.argv = ['mcpgateway', '--port', '$CONTEXTFORGE_PORT', '--host', '0.0.0.0']
from mcpgateway.cli import main
main()
" &
CONTEXTFORGE_PID=$!
PIDS+=($CONTEXTFORGE_PID)
start_and_verify "ContextForge" $CONTEXTFORGE_PID

# 3. dev-mcp bridge (stdio→SSE)
python3 -m mcpgateway.translate \
  --stdio "npx -y @shopify/dev-mcp@latest" \
  --expose-sse \
  --port 8003 &
TRANSLATE_DEVMCP_PID=$!
PIDS+=($TRANSLATE_DEVMCP_PID)

# 4. google-sheets bridge (stdio→SSE)
python3 -m mcpgateway.translate \
  --stdio "uv tool run mcp-google-sheets@latest --transport stdio" \
  --expose-sse \
  --port 8004 &
TRANSLATE_SHEETS_PID=$!
PIDS+=($TRANSLATE_SHEETS_PID)

# --- Wait for ContextForge health before starting auth proxy ---
echo "[fluid-intelligence] Waiting for ContextForge to be ready..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:${CONTEXTFORGE_PORT}/healthz > /dev/null 2>&1; then
    echo "[fluid-intelligence] ContextForge ready after ${i}s"
    break
  fi
  # Check if mcpgateway is still alive (fast-fail instead of 60s timeout)
  if ! kill -0 "$CONTEXTFORGE_PID" 2>/dev/null; then
    echo "[fluid-intelligence] FATAL: ContextForge process died during startup"
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    exit 1
  fi
  if [ "$i" -eq 60 ]; then
    echo "[fluid-intelligence] FATAL: ContextForge not ready after 60s"
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    exit 1
  fi
  sleep 1
done

# 5. mcp-auth-proxy (Go, OAuth 2.1 front door) — starts after ContextForge is ready
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
PIDS+=($AUTHPROXY_PID)
start_and_verify "auth-proxy" $AUTHPROXY_PID

# 6. Bootstrap: register backends (foreground — fail fast if broken)
echo "[fluid-intelligence] Running bootstrap..."
/app/bootstrap.sh || {
  echo "[fluid-intelligence] FATAL: bootstrap failed — no backends registered"
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  exit 1
}

echo "[fluid-intelligence] All services running"
echo "  Apollo:         PID=$APOLLO_PID  :8000"
echo "  ContextForge:   PID=$CONTEXTFORGE_PID  :${CONTEXTFORGE_PORT}"
echo "  dev-mcp:        PID=$TRANSLATE_DEVMCP_PID  :8003"
echo "  sheets:         PID=$TRANSLATE_SHEETS_PID  :8004"
echo "  auth-proxy:     PID=$AUTHPROXY_PID  :8080"

# --- Monitor: exit if any process dies ---
wait -n $APOLLO_PID $CONTEXTFORGE_PID $TRANSLATE_DEVMCP_PID $TRANSLATE_SHEETS_PID $AUTHPROXY_PID
EXIT_CODE=$?

for name_pid in "Apollo:$APOLLO_PID" "ContextForge:$CONTEXTFORGE_PID" "dev-mcp:$TRANSLATE_DEVMCP_PID" "sheets:$TRANSLATE_SHEETS_PID" "auth-proxy:$AUTHPROXY_PID"; do
  name="${name_pid%%:*}"
  pid="${name_pid##*:}"
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "[fluid-intelligence] Process $name (PID $pid) died (exit $EXIT_CODE)"
  fi
done

for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
exit 1
