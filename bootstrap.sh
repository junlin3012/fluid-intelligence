#!/bin/bash
set -euo pipefail

echo "[bootstrap] Waiting for ContextForge to be healthy..."
MAX_WAIT=60; WAITED=0
until curl -sf http://localhost:4444/healthz > /dev/null 2>&1; do
  WAITED=$((WAITED + 1))
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "[bootstrap] FATAL: ContextForge not healthy after ${MAX_WAIT}s"
    exit 1
  fi
  sleep 1
done
echo "[bootstrap] ContextForge is healthy"

# Generate admin JWT token for backend registration
TOKEN=$(python3 -m mcpgateway.utils.create_jwt_token \
  --username "$PLATFORM_ADMIN_EMAIL" \
  --exp 10080 \
  --secret "$JWT_SECRET_KEY")

echo "[bootstrap] Registering Apollo MCP (Shopify GraphQL)..."
curl -sf -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"apollo-shopify","url":"http://localhost:8000/mcp","transport":"STREAMABLEHTTP"}' \
  http://localhost:4444/gateways

echo "[bootstrap] Waiting for dev-mcp bridge..."
MAX_WAIT=90; WAITED=0
until curl -sf --connect-timeout 2 --max-time 3 http://localhost:8003/healthz > /dev/null 2>&1; do
  WAITED=$((WAITED + 1))
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "[bootstrap] FATAL: dev-mcp bridge not ready after ${MAX_WAIT}s"
    exit 1
  fi
  sleep 1
done

echo "[bootstrap] Registering dev-mcp (Shopify docs)..."
curl -sf -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"shopify-dev-mcp","url":"http://localhost:8003/sse","transport":"SSE"}' \
  http://localhost:4444/gateways

echo "[bootstrap] Waiting for google-sheets bridge..."
MAX_WAIT=60; WAITED=0
until curl -sf --connect-timeout 2 --max-time 3 http://localhost:8004/healthz > /dev/null 2>&1; do
  WAITED=$((WAITED + 1))
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "[bootstrap] FATAL: google-sheets bridge not ready after ${MAX_WAIT}s"
    exit 1
  fi
  sleep 1
done

echo "[bootstrap] Registering google-sheets..."
curl -sf -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"google-sheets","url":"http://localhost:8004/sse","transport":"SSE"}' \
  http://localhost:4444/gateways

echo "[bootstrap] All 3 backends registered"
