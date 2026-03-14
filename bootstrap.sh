#!/bin/bash
set -euo pipefail

# Generate short-lived admin JWT for registration
TOKEN=$(python3 -m mcpgateway.utils.create_jwt_token \
  --username "$PLATFORM_ADMIN_EMAIL" \
  --exp 5 \
  --secret "$JWT_SECRET_KEY")

# Idempotent registration: check if server exists, create if not
register_server() {
  local name="$1" url="$2" transport="$3"

  # Check if already registered (container restart case)
  if curl -sf -H "Authorization: Bearer $TOKEN" \
    "http://localhost:4444/servers" 2>/dev/null | \
    jq -e ".[] | select(.name==\"$name\")" > /dev/null 2>&1; then
    echo "[bootstrap] $name already registered, skipping"
    return 0
  fi

  local max_attempts=3 attempt=1
  while [ $attempt -le $max_attempts ]; do
    response=$(curl -s -w "\n%{http_code}" -X POST \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"$name\",\"url\":\"$url\",\"transport\":\"$transport\"}" \
      http://localhost:4444/servers 2>&1)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | head -n -1)

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
      echo "[bootstrap] Registered $name"
      return 0
    fi

    # 409 = already exists (idempotent success)
    if [ "$http_code" -eq 409 ]; then
      echo "[bootstrap] $name already exists (409), skipping"
      return 0
    fi

    echo "[bootstrap] $name registration failed (HTTP $http_code): $body"
    attempt=$((attempt + 1))
    sleep $attempt
  done

  echo "[bootstrap] FATAL: Failed to register $name after $max_attempts attempts"
  return 1
}

# Wait for Apollo before registering it
echo "[bootstrap] Waiting for Apollo..."
for i in $(seq 1 30); do
  curl -sf http://localhost:8000/healthz > /dev/null 2>&1 && break
  [ "$i" -eq 30 ] && { echo "[bootstrap] FATAL: Apollo not ready after 30s"; exit 1; }
  sleep 1
done

echo "[bootstrap] Registering Apollo MCP (Shopify GraphQL)..."
register_server "apollo-shopify" "http://localhost:8000/mcp" "streamablehttp"

# Wait for dev-mcp bridge (npx install can take 30-60s on cold start)
echo "[bootstrap] Waiting for dev-mcp bridge..."
for i in $(seq 1 90); do
  curl -sf --connect-timeout 2 --max-time 3 http://localhost:8003/healthz > /dev/null 2>&1 && break
  [ "$i" -eq 90 ] && { echo "[bootstrap] FATAL: dev-mcp bridge not ready after 90s"; exit 1; }
  sleep 1
done

echo "[bootstrap] Registering dev-mcp (Shopify docs)..."
register_server "shopify-dev-mcp" "http://localhost:8003/sse" "sse"

# Wait for google-sheets bridge
echo "[bootstrap] Waiting for google-sheets bridge..."
for i in $(seq 1 60); do
  curl -sf --connect-timeout 2 --max-time 3 http://localhost:8004/healthz > /dev/null 2>&1 && break
  [ "$i" -eq 60 ] && { echo "[bootstrap] FATAL: google-sheets bridge not ready after 60s"; exit 1; }
  sleep 1
done

echo "[bootstrap] Registering google-sheets..."
register_server "google-sheets" "http://localhost:8004/sse" "sse"

echo "[bootstrap] All 3 backends registered"
