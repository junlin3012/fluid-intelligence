#!/bin/bash
set -euo pipefail

# Generate short-lived admin JWT for registration
TOKEN=$(/app/.venv/bin/python -c "
import sys
sys.argv = ['create_jwt_token', '--username', '$PLATFORM_ADMIN_EMAIL', '--exp', '5', '--secret', '$JWT_SECRET_KEY']
from mcpgateway.utils.create_jwt_token import main
main()
" 2>/dev/null) || {
  # Fallback: try the module directly
  TOKEN=$(python3 -m mcpgateway.utils.create_jwt_token \
    --username "$PLATFORM_ADMIN_EMAIL" \
    --exp 5 \
    --secret "$JWT_SECRET_KEY" 2>/dev/null)
}

if [ -z "$TOKEN" ]; then
  echo "[bootstrap] FATAL: Could not generate JWT token"
  exit 1
fi
echo "[bootstrap] JWT token generated"

CF="http://localhost:${CONTEXTFORGE_PORT:-4444}"

# Register a backend MCP server with ContextForge via /gateways endpoint
# /gateways triggers tool auto-discovery; /servers is for virtual server composition only
# Always re-registers to pick up URL/transport changes across deployments
register_gateway() {
  local name="$1" url="$2" transport="$3"

  # Delete any existing registration (stale URL/transport from previous deploy)
  local existing_id
  existing_id=$(curl -sf -H "Authorization: Bearer $TOKEN" \
    "$CF/gateways" 2>/dev/null | \
    jq -r ".[] | select(.name==\"$name\") | .id" 2>/dev/null) || true
  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    echo "[bootstrap] Deleting stale $name (id=$existing_id)"
    curl -sf -X DELETE -H "Authorization: Bearer $TOKEN" \
      "$CF/gateways/$existing_id" > /dev/null 2>&1 || true
  fi

  local max_attempts=3 attempt=1
  while [ $attempt -le $max_attempts ]; do
    response=$(curl -s -w "\n%{http_code}" -X POST \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"$name\",\"url\":\"$url\",\"transport\":\"$transport\"}" \
      "$CF/gateways" 2>&1)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | head -n -1)

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
      echo "[bootstrap] Registered $name via /gateways (tools auto-discovered)"
      return 0
    fi

    # 409 = already exists
    if [ "$http_code" -eq 409 ]; then
      echo "[bootstrap] $name already exists (409)"
      return 0
    fi

    echo "[bootstrap] $name registration failed (HTTP $http_code): $body"
    attempt=$((attempt + 1))
    sleep $attempt
  done

  echo "[bootstrap] FATAL: Failed to register $name after $max_attempts attempts"
  return 1
}

# Wait for Apollo bridge before registering it
# SSE endpoint is streaming (never completes), so check TCP + HTTP response
echo "[bootstrap] Waiting for Apollo bridge..."
for i in $(seq 1 60); do
  # curl exit 28 = timeout (connected but SSE stream) = success
  rc=0; curl -s --connect-timeout 2 --max-time 1 http://localhost:8000/sse -o /dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 28 ] && break
  [ "$i" -eq 60 ] && { echo "[bootstrap] FATAL: Apollo bridge not ready after 60s"; exit 1; }
  sleep 1
done

echo "[bootstrap] Registering Apollo MCP (Shopify GraphQL)..."
register_gateway "apollo-shopify" "http://localhost:8000/sse" "SSE"

# Wait for dev-mcp bridge (npx install can take 30-60s on cold start)
echo "[bootstrap] Waiting for dev-mcp bridge..."
for i in $(seq 1 90); do
  curl -sf --connect-timeout 2 --max-time 3 http://localhost:8003/healthz > /dev/null 2>&1 && break
  [ "$i" -eq 90 ] && { echo "[bootstrap] FATAL: dev-mcp bridge not ready after 90s"; exit 1; }
  sleep 1
done

echo "[bootstrap] Registering dev-mcp (Shopify docs)..."
register_gateway "shopify-dev-mcp" "http://localhost:8003/sse" "SSE"

# Wait for google-sheets bridge
echo "[bootstrap] Waiting for google-sheets bridge..."
for i in $(seq 1 60); do
  curl -sf --connect-timeout 2 --max-time 3 http://localhost:8004/healthz > /dev/null 2>&1 && break
  [ "$i" -eq 60 ] && { echo "[bootstrap] FATAL: google-sheets bridge not ready after 60s"; exit 1; }
  sleep 1
done

echo "[bootstrap] Registering google-sheets..."
register_gateway "google-sheets" "http://localhost:8004/sse" "SSE"

# Verify tools were discovered and dump debug info
tool_count=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "$CF/tools" 2>/dev/null | jq 'length' 2>/dev/null) || tool_count=0
echo "[bootstrap] All 3 backends registered, $tool_count tools discovered"

# Debug: list gateways and servers
echo "[bootstrap] Gateways:"
curl -sf -H "Authorization: Bearer $TOKEN" "$CF/gateways" 2>/dev/null | jq -c '.[] | {name, id, url, transport}' 2>/dev/null || echo "  (none)"
echo "[bootstrap] Servers:"
curl -sf -H "Authorization: Bearer $TOKEN" "$CF/servers" 2>/dev/null | jq -c '.[] | {name, id}' 2>/dev/null || echo "  (none)"
echo "[bootstrap] Tools (first 5):"
curl -sf -H "Authorization: Bearer $TOKEN" "$CF/tools" 2>/dev/null | jq -c '.[0:5][] | {name, id, gateway_id}' 2>/dev/null || echo "  (none)"
