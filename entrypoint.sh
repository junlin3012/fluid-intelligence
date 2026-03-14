#!/bin/bash
set -euo pipefail

echo "[fluid-intelligence] Starting services..."

# Construct DATABASE_URL for ContextForge (Cloud SQL PostgreSQL via Unix socket)
export DATABASE_URL="postgresql://${DB_USER:-contextforge}:${DB_PASSWORD}@/${DB_NAME:-contextforge}?host=/cloudsql/junlinleather-mcp:asia-southeast1:contextforge"
export AUTH_ENCRYPTION_SECRET="${JWT_SECRET_KEY}"
export PLATFORM_ADMIN_PASSWORD="${AUTH_PASSWORD}"

# 1. Apollo MCP Server (Rust, Shopify GraphQL, Streamable HTTP)
apollo --config /app/mcp-config.yaml &
APOLLO_PID=$!

# 2. IBM ContextForge (Python, gateway)
# Start via `mcpgateway` CLI (console_scripts entry point)
mcpgateway &
CONTEXTFORGE_PID=$!

# 3. mcpgateway.translate #1 (stdio→HTTP bridge for dev-mcp)
python3 -m mcpgateway.translate \
  --stdio "npx -y @shopify/dev-mcp@latest" \
  --expose-sse \
  --port 8003 &
TRANSLATE_DEVMCP_PID=$!

# 4. mcpgateway.translate #2 (stdio→HTTP bridge for google-sheets)
python3 -m mcpgateway.translate \
  --stdio "uvx mcp-google-sheets@latest --transport stdio" \
  --expose-sse \
  --port 8004 &
TRANSLATE_SHEETS_PID=$!

# 5. mcp-auth-proxy (Go, OAuth 2.1 front door)
# Google OAuth as primary auth, password as CLI fallback
mcp-auth-proxy \
  --listen :8080 \
  --external-url "https://${EXTERNAL_URL:-junlinleather.com}" \
  --google-client-id "$GOOGLE_OAUTH_CLIENT_ID" \
  --google-client-secret "$GOOGLE_OAUTH_CLIENT_SECRET" \
  --google-allowed-users "${GOOGLE_ALLOWED_USERS:-ourteam@junlinleather.com}" \
  --password "$AUTH_PASSWORD" \
  --no-auto-tls \
  --data-path /app/data \
  -- http://localhost:4444 &
AUTHPROXY_PID=$!

# 6. Bootstrap: register backends with ContextForge (runs once)
/app/bootstrap.sh &

echo "[fluid-intelligence] All services started"
echo "  Apollo MCP:       PID=$APOLLO_PID  port=8000  (Streamable HTTP at /mcp)"
echo "  ContextForge:     PID=$CONTEXTFORGE_PID  port=4444"
echo "  dev-mcp bridge:   PID=$TRANSLATE_DEVMCP_PID  port=8003  (SSE at /sse)"
echo "  sheets bridge:    PID=$TRANSLATE_SHEETS_PID  port=8004  (SSE at /sse)"
echo "  mcp-auth-proxy:   PID=$AUTHPROXY_PID  port=8080"

# Exit if any long-running process dies → Cloud Run restarts container
wait -n $APOLLO_PID $CONTEXTFORGE_PID $TRANSLATE_DEVMCP_PID $TRANSLATE_SHEETS_PID $AUTHPROXY_PID
echo "[fluid-intelligence] A process exited, shutting down"
kill $APOLLO_PID $CONTEXTFORGE_PID $TRANSLATE_DEVMCP_PID $TRANSLATE_SHEETS_PID $AUTHPROXY_PID 2>/dev/null || true
exit 1
