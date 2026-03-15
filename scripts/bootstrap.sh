#!/bin/bash
set -euo pipefail

# Generate admin JWT for registration (10 min expiry to cover slow bridge starts:
# worst case Apollo 60s + dev-mcp 90s + sheets 60s = 3.5 min of waiting)
# Pass secrets via env vars to avoid shell injection (quotes in values would break inline Python)
PRIMARY_ERR=""
TOKEN=$(ADMIN_EMAIL="$PLATFORM_ADMIN_EMAIL" SECRET_KEY="$JWT_SECRET_KEY" /app/.venv/bin/python -c "
import os, sys
sys.argv = ['create_jwt_token', '--username', os.environ['ADMIN_EMAIL'], '--exp', '10', '--secret', os.environ['SECRET_KEY']]
from mcpgateway.utils.create_jwt_token import main
main()
" 2>/tmp/jwt-primary-err-$$.log) || {
  PRIMARY_ERR=$(cat /tmp/jwt-primary-err-$$.log 2>/dev/null)
  # Fallback: try the module directly
  TOKEN=$(python3 -m mcpgateway.utils.create_jwt_token \
    --username "$PLATFORM_ADMIN_EMAIL" \
    --exp 10 \
    --secret "$JWT_SECRET_KEY" 2>/tmp/jwt-fallback-err-$$.log)
}

if [ -z "$TOKEN" ]; then
  echo "[bootstrap] FATAL: Could not generate JWT token"
  [ -n "$PRIMARY_ERR" ] && echo "[bootstrap]   Primary: $PRIMARY_ERR"
  [ -f /tmp/jwt-fallback-err-$$.log ] && echo "[bootstrap]   Fallback: $(cat /tmp/jwt-fallback-err-$$.log)"
  rm -f /tmp/jwt-primary-err-$$.log /tmp/jwt-fallback-err-$$.log
  exit 1
fi
rm -f /tmp/jwt-primary-err-$$.log /tmp/jwt-fallback-err-$$.log
echo "[bootstrap] JWT token generated"

CF="http://127.0.0.1:${CONTEXTFORGE_PORT:-4444}"

# Register a backend MCP server with ContextForge via /gateways endpoint
# /gateways triggers tool auto-discovery; /servers is for virtual server composition only
# Always re-registers to pick up URL/transport changes across deployments
register_gateway() {
  local name="$1" url="$2" transport="$3"

  # Delete any existing registrations (stale URL/transport from previous deploy)
  # Use head -1 to handle multiple entries with the same name (delete each individually)
  local existing_ids
  existing_ids=$(curl -sf --max-time 10 -H "Authorization: Bearer $TOKEN" \
    "$CF/gateways" 2>/dev/null | \
    jq -r --arg n "$name" '.[] | select(.name==$n) | .id' 2>/dev/null) || true
  if [ -n "$existing_ids" ]; then
    echo "$existing_ids" | while read -r eid; do
      [ -z "$eid" ] || [ "$eid" = "null" ] && continue
      echo "[bootstrap] Deleting stale $name (id=$eid)"
      curl -sf --max-time 10 -X DELETE -H "Authorization: Bearer $TOKEN" \
        "$CF/gateways/$eid" > /dev/null 2>&1 || true
    done
  fi

  local max_attempts=3 attempt=1 http_code=0
  while [ $attempt -le $max_attempts ]; do
    payload=$(jq -n --arg n "$name" --arg u "$url" --arg t "$transport" \
      '{name: $n, url: $u, transport: $t}')
    response=$(curl -s -w "\n%{http_code}" --max-time 10 -X POST \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$CF/gateways" 2>/dev/null)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
      echo "[bootstrap] Registered $name via /gateways (tools auto-discovered)"
      return 0
    fi

    # 409 = already exists
    if [ "$http_code" -eq 409 ]; then
      echo "[bootstrap] $name already exists (409)"
      return 0
    fi

    echo "[bootstrap] $name registration failed (HTTP $http_code): $(echo "$body" | head -c 200)"
    attempt=$((attempt + 1))
    sleep $attempt
  done

  echo "[bootstrap] FATAL: Failed to register $name after $max_attempts attempts"
  return 1
}

# Wait for Apollo bridge before registering it
# SSE endpoint is streaming (never completes), so check TCP + HTTP response
# Check PID files written by entrypoint.sh to fast-fail if bridge crashes
echo "[bootstrap] Waiting for Apollo bridge..."
for i in $(seq 1 60); do
  # Fast-fail: check if bridge process is still alive (PID file from entrypoint)
  if [ -f /tmp/apollo.pid ]; then
    BRIDGE_PID=$(cat /tmp/apollo.pid 2>/dev/null)
    if [ -n "$BRIDGE_PID" ] && ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      echo "[bootstrap] FATAL: Apollo bridge process (PID $BRIDGE_PID) crashed"
      exit 1
    fi
  fi
  # curl exit 28 = timeout (connected but SSE stream) = success
  rc=0; curl -s --connect-timeout 2 --max-time 1 http://127.0.0.1:8000/sse -o /dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 28 ] && break
  [ "$i" -eq 60 ] && { echo "[bootstrap] FATAL: Apollo bridge not ready after 60s"; exit 1; }
  sleep 1
done

echo "[bootstrap] Registering Apollo MCP (Shopify GraphQL)..."
register_gateway "apollo-shopify" "http://127.0.0.1:8000/sse" "SSE"

# Wait for dev-mcp bridge (npx install can take 30-60s on cold start)
echo "[bootstrap] Waiting for dev-mcp bridge..."
for i in $(seq 1 90); do
  if [ -f /tmp/devmcp.pid ]; then
    BRIDGE_PID=$(cat /tmp/devmcp.pid 2>/dev/null)
    if [ -n "$BRIDGE_PID" ] && ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      echo "[bootstrap] FATAL: dev-mcp bridge process (PID $BRIDGE_PID) crashed"
      exit 1
    fi
  fi
  curl -sf --connect-timeout 2 --max-time 3 http://127.0.0.1:8003/healthz > /dev/null 2>&1 && break
  [ "$i" -eq 90 ] && { echo "[bootstrap] FATAL: dev-mcp bridge not ready after 90s"; exit 1; }
  sleep 1
done

echo "[bootstrap] Registering dev-mcp (Shopify docs)..."
register_gateway "shopify-dev-mcp" "http://127.0.0.1:8003/sse" "SSE"

# Wait for google-sheets bridge
echo "[bootstrap] Waiting for google-sheets bridge..."
for i in $(seq 1 60); do
  if [ -f /tmp/sheets.pid ]; then
    BRIDGE_PID=$(cat /tmp/sheets.pid 2>/dev/null)
    if [ -n "$BRIDGE_PID" ] && ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      echo "[bootstrap] FATAL: google-sheets bridge process (PID $BRIDGE_PID) crashed"
      exit 1
    fi
  fi
  curl -sf --connect-timeout 2 --max-time 3 http://127.0.0.1:8004/healthz > /dev/null 2>&1 && break
  [ "$i" -eq 60 ] && { echo "[bootstrap] FATAL: google-sheets bridge not ready after 60s"; exit 1; }
  sleep 1
done

echo "[bootstrap] Registering google-sheets..."
register_gateway "google-sheets" "http://127.0.0.1:8004/sse" "SSE"

# Verify tools discovered
echo "[bootstrap] All 3 backends registered"
TOOL_COUNT=$(curl -sf --max-time 10 -H "Authorization: Bearer $TOKEN" "$CF/tools" 2>/dev/null | jq 'length' 2>/dev/null) || TOOL_COUNT=0
[[ "$TOOL_COUNT" =~ ^[0-9]+$ ]] || TOOL_COUNT=0
echo "[bootstrap] $TOOL_COUNT tools in catalog"
if [ "$TOOL_COUNT" -eq 0 ]; then
  echo "[bootstrap] WARNING: Zero tools discovered — check backend registrations above"
fi

# --- Create virtual server bundling ALL discovered tools ---
# MCP clients connect to /servers/<UUID>/mcp (or /servers/<UUID>/sse)
# Without a virtual server, tools/list via MCP returns empty.
echo "[bootstrap] Creating virtual server..."

# Delete existing virtual server (stale from previous deploy)
existing_vs=$(curl -sf --max-time 10 -H "Authorization: Bearer $TOKEN" \
  "$CF/servers" 2>/dev/null | \
  jq -r '.[] | select(.name=="fluid-intelligence") | .id' 2>/dev/null) || true
if [ -n "$existing_vs" ] && [ "$existing_vs" != "null" ]; then
  echo "[bootstrap] Deleting stale virtual server (id=$existing_vs)"
  curl -sf --max-time 10 -X DELETE -H "Authorization: Bearer $TOKEN" \
    "$CF/servers/$existing_vs" > /dev/null 2>&1 || true
fi

# Get all tool IDs from the catalog
TOOL_IDS=$(curl -sf --max-time 10 -H "Authorization: Bearer $TOKEN" "$CF/tools" 2>/dev/null | \
  jq -r '[.[].id] | @json' 2>/dev/null) || TOOL_IDS="[]"
if [ "$TOOL_IDS" = "[]" ]; then
  echo "[bootstrap] WARNING: No tool IDs found — virtual server will expose zero tools"
  echo "[bootstrap] MCP clients will get empty tools/list"
fi

# Create virtual server with all tools
vs_payload=$(jq -n --argjson tools "$TOOL_IDS" \
  '{server: {name: "fluid-intelligence", description: "All Shopify + Google Sheets tools", associated_tools: $tools}}')
vs_response=$(curl -s -w "\n%{http_code}" --max-time 10 -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$vs_payload" \
  "$CF/servers" 2>/dev/null)
vs_code=$(echo "$vs_response" | tail -1)
vs_body=$(echo "$vs_response" | sed '$d')

if [ "$vs_code" -ge 200 ] && [ "$vs_code" -lt 300 ]; then
  VS_ID=$(echo "$vs_body" | jq -r '.id // .server.id // empty' 2>/dev/null)
  echo "[bootstrap] Virtual server created (id=$VS_ID)"
  echo "[bootstrap] MCP endpoint: /servers/$VS_ID/mcp"
  echo "[bootstrap] SSE endpoint: /servers/$VS_ID/sse"
else
  echo "[bootstrap] WARNING: Virtual server creation failed (HTTP $vs_code): $(echo "$vs_body" | head -c 200)"
  echo "[bootstrap] MCP tools/list will be empty — clients cannot discover tools"
fi

# --- Debug dump ---
echo "[bootstrap] --- Debug: /gateways ---"
curl -sf --max-time 5 -H "Authorization: Bearer $TOKEN" "$CF/gateways" 2>/dev/null | jq '[.[] | {name, id, url}]' 2>/dev/null || echo "  /gateways failed"
echo "[bootstrap] --- Debug: /servers ---"
curl -sf --max-time 5 -H "Authorization: Bearer $TOKEN" "$CF/servers" 2>/dev/null | jq '[.[] | {name, id}]' 2>/dev/null || echo "  /servers failed"
echo "[bootstrap] --- Debug: tool names ---"
curl -sf --max-time 5 -H "Authorization: Bearer $TOKEN" "$CF/tools" 2>/dev/null | jq '[.[].name]' 2>/dev/null | head -30 || echo "  /tools failed"
