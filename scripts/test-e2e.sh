#!/bin/bash
# End-to-end test suite for Fluid Intelligence MCP gateway
# Usage: ./scripts/test-e2e.sh
# Requires: AUTH_PASSWORD env var (or reads from GCP Secret Manager)
#           BASE_URL env var (default: Cloud Run URL)
set -uo pipefail

# --- Config (all from env, no hardcoded secrets) ---
BASE="${BASE_URL:-https://fluid-intelligence-1056128102929.asia-southeast1.run.app}"

if [ -z "${AUTH_PASSWORD:-}" ]; then
  echo "[setup] AUTH_PASSWORD not set, fetching from Secret Manager..."
  AUTH_PASSWORD=$(gcloud secrets versions access latest \
    --secret=mcp-auth-passphrase \
    --project=junlinleather-mcp 2>/dev/null) || {
    echo "FATAL: Set AUTH_PASSWORD or configure gcloud for secret access"
    exit 1
  }
fi

COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR"' EXIT

PASSED=0
FAILED=0
TOTAL=0
FAILURES=""

result() {
  TOTAL=$((TOTAL + 1))
  if [ "$1" = "PASS" ]; then
    PASSED=$((PASSED + 1))
    echo "  ✅ $2"
  else
    FAILED=$((FAILED + 1))
    echo "  ❌ $2: $3"
    FAILURES="${FAILURES}\n  - $2: $3"
  fi
}

echo "========================================="
echo "  Fluid Intelligence — E2E Test Suite"
echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "  Target: $BASE"
echo "========================================="
echo ""

# =============================================
# 1. REACHABILITY
# =============================================
echo "--- 1. Reachability ---"
http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE/" 2>&1)
if [ "$http_code" = "401" ]; then
  result "PASS" "Root returns 401 (auth-proxy alive)"
else
  result "FAIL" "Root reachability" "Expected 401, got $http_code"
fi

# =============================================
# 2. OAUTH DISCOVERY
# =============================================
echo "--- 2. OAuth Discovery ---"

oauth_as=$(curl -sf --max-time 10 "$BASE/.well-known/oauth-authorization-server" 2>&1)
if echo "$oauth_as" | jq -e '.token_endpoint' > /dev/null 2>&1; then
  result "PASS" "OAuth authorization server metadata"
else
  result "FAIL" "OAuth AS metadata" "Missing token_endpoint"
fi

oauth_pr=$(curl -sf --max-time 10 "$BASE/.well-known/oauth-protected-resource" 2>&1)
if echo "$oauth_pr" | jq -e '.resource' > /dev/null 2>&1; then
  result "PASS" "OAuth protected resource metadata"
else
  result "FAIL" "OAuth PR metadata" "Missing resource"
fi

# =============================================
# 3. OAUTH FLOW (DCR → AUTH CODE → TOKEN)
# =============================================
echo "--- 3. OAuth Flow ---"

# 3a. Dynamic Client Registration
REDIRECT_URI="http://localhost:29999/callback"
CLIENT_REG=$(curl -sf --max-time 10 -X POST \
  -H "Content-Type: application/json" \
  -d "{\"redirect_uris\":[\"$REDIRECT_URI\"],\"client_name\":\"e2e-test-$(date +%s)\"}" \
  "$BASE/.idp/register" 2>&1)
CLIENT_ID=$(echo "$CLIENT_REG" | jq -r '.client_id // empty' 2>/dev/null)
CLIENT_SECRET=$(echo "$CLIENT_REG" | jq -r '.client_secret // empty' 2>/dev/null)

if [ -n "$CLIENT_ID" ]; then
  result "PASS" "Dynamic Client Registration"
else
  result "FAIL" "DCR" "No client_id returned: $CLIENT_REG"
fi

# 3b. PKCE code challenge
CODE_VERIFIER=$(python3 -c "import secrets; print(secrets.token_urlsafe(43))")
CODE_CHALLENGE=$(CODE_VERIFIER="$CODE_VERIFIER" python3 -c "
import hashlib, base64, os
v=os.environ['CODE_VERIFIER']
print(base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b'=').decode())
")
STATE=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")

# 3c. Start auth flow → login page → submit password → get auth code
curl -sL --max-time 10 -c "$COOKIE_JAR" \
  "$BASE/.idp/auth?response_type=code&client_id=$CLIENT_ID&redirect_uri=$REDIRECT_URI&state=$STATE&code_challenge=$CODE_CHALLENGE&code_challenge_method=S256" \
  -o /dev/null 2>&1

LOGIN_HEADERS=$(curl -sv --max-time 10 \
  -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
  -X POST -d "password=$(AUTH_PASSWORD="$AUTH_PASSWORD" python3 -c "import os, urllib.parse; print(urllib.parse.quote(os.environ['AUTH_PASSWORD']))")" \
  "$BASE/.auth/login" 2>&1)
AUTH_SESSION=$(echo "$LOGIN_HEADERS" | grep -oi "location: /.idp/auth/[a-f0-9-]*" | head -1 | sed 's/[Ll]ocation: //')

AUTH_CODE=""
if [ -n "$AUTH_SESSION" ]; then
  CODE_REDIRECT=$(curl -sv --max-time 10 \
    -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    "$BASE$AUTH_SESSION" 2>&1)
  AUTH_CODE=$(echo "$CODE_REDIRECT" | grep -o "code=[^&]*" | head -1 | sed 's/code=//')
  RETURNED_STATE=$(echo "$CODE_REDIRECT" | grep -o "state=[^&\"]*" | head -1 | sed 's/state=//')
fi

if [ -n "$AUTH_CODE" ]; then
  result "PASS" "Authorization code obtained"
else
  result "FAIL" "Auth code" "No code in redirect (session=$AUTH_SESSION)"
fi

# Validate state parameter (CSRF protection)
if [ -n "$RETURNED_STATE" ] && [ "$RETURNED_STATE" = "$STATE" ]; then
  result "PASS" "State CSRF validation"
elif [ -n "$RETURNED_STATE" ]; then
  result "FAIL" "State CSRF validation" "Expected $STATE, got $RETURNED_STATE"
else
  result "FAIL" "State CSRF validation" "No state parameter in redirect"
fi

# 3d. Exchange auth code for access token
ACCESS_TOKEN=""
if [ -n "$AUTH_CODE" ]; then
  TOKEN_RESP=$(curl -sf --max-time 10 -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=authorization_code&code=$AUTH_CODE&redirect_uri=$REDIRECT_URI&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&code_verifier=$CODE_VERIFIER" \
    "$BASE/.idp/token" 2>&1)
  ACCESS_TOKEN=$(echo "$TOKEN_RESP" | jq -r '.access_token // empty' 2>/dev/null)
  EXPIRES_IN=$(echo "$TOKEN_RESP" | jq -r '.expires_in // "?"' 2>/dev/null)
  TOKEN_TYPE=$(echo "$TOKEN_RESP" | jq -r '.token_type // empty' 2>/dev/null)

  if [ -n "$ACCESS_TOKEN" ]; then
    result "PASS" "Token exchange (expires_in=${EXPIRES_IN}s)"
  else
    result "FAIL" "Token exchange" "$TOKEN_RESP"
  fi

  # OAuth 2.1 requires token_type=Bearer
  if [ -n "$TOKEN_TYPE" ]; then
    if [[ "${TOKEN_TYPE,,}" == "bearer" ]]; then
      result "PASS" "Token type is Bearer"
    else
      result "FAIL" "Token type" "Expected Bearer, got $TOKEN_TYPE"
    fi
  fi
else
  result "FAIL" "Token exchange" "Skipped (no auth code)"
fi

if [ -z "$ACCESS_TOKEN" ]; then
  echo ""
  echo "========================================="
  echo "  ABORT: No access token — cannot test MCP"
  echo "  Results: $PASSED/$TOTAL passed, $FAILED failed"
  echo "========================================="
  exit 1
fi

# =============================================
# 3b. AUTH NEGATIVE TESTS
# =============================================
echo "--- 3b. Auth Negative Tests ---"

# Verify invalid token is rejected
INVALID_RESP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  -H "Authorization: Bearer invalid-token-12345" \
  -H "Accept: application/json" \
  -X POST -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  "$BASE/mcp" 2>&1)
if [ "$INVALID_RESP" = "401" ]; then
  result "PASS" "Invalid token rejected (401)"
else
  result "FAIL" "Invalid token rejection" "Expected 401, got $INVALID_RESP"
fi

# Verify no-token request is rejected
NO_TOKEN_RESP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  -H "Accept: application/json" \
  -X POST -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  "$BASE/mcp" 2>&1)
if [ "$NO_TOKEN_RESP" = "401" ]; then
  result "PASS" "No-token request rejected (401)"
else
  result "FAIL" "No-token rejection" "Expected 401, got $NO_TOKEN_RESP"
fi

# =============================================
# 4. MCP PROTOCOL — ROOT /mcp
# =============================================
echo "--- 4. MCP Protocol (root /mcp) ---"

mcp_post() {
  local path="$1" body="$2"
  curl -sf --max-time 15 -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "$body" \
    "$BASE$path" 2>&1
}

# Initialize
INIT=$(mcp_post "/mcp" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e-test","version":"1.0"}}}')
if echo "$INIT" | jq -e '.result.serverInfo' > /dev/null 2>&1; then
  SERVER=$(echo "$INIT" | jq -r '.result.serverInfo.name')
  result "PASS" "MCP initialize (server=$SERVER)"
else
  result "FAIL" "MCP initialize" "$(echo "$INIT" | head -c 200)"
fi

# Send initialized notification
mcp_post "/mcp" '{"jsonrpc":"2.0","method":"notifications/initialized"}' > /dev/null 2>&1

# tools/list
TOOLS=$(mcp_post "/mcp" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
TOOL_COUNT=$(echo "$TOOLS" | jq '.result.tools | length' 2>/dev/null)
if [ -n "$TOOL_COUNT" ] && [ "$TOOL_COUNT" -gt 0 ]; then
  result "PASS" "tools/list at /mcp: $TOOL_COUNT tools"
  echo "  Tools:"
  echo "$TOOLS" | jq -r '.result.tools[].name' 2>/dev/null | sort | sed 's/^/    /'
else
  result "FAIL" "tools/list at /mcp" "Got ${TOOL_COUNT:-null} tools (expected >0). Response: $(echo "$TOOLS" | head -c 300)"
fi

# =============================================
# 5. VIRTUAL SERVER CHECK
# =============================================
echo "--- 5. Virtual Servers ---"

# Try /servers REST endpoint (may be blocked by auth mismatch)
SERVERS_RESP=$(curl -s --max-time 10 -w "\nHTTPCODE:%{http_code}" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$BASE/servers" 2>&1)
SERVERS_CODE=$(echo "$SERVERS_RESP" | grep -o 'HTTPCODE:[0-9]*' | cut -d: -f2)
SERVERS_BODY=$(echo "$SERVERS_RESP" | sed '/HTTPCODE:/d')

VS_ID=""
if [ "$SERVERS_CODE" = "200" ]; then
  VS_COUNT=$(echo "$SERVERS_BODY" | jq 'if type == "array" then length else 0 end' 2>/dev/null)
  VS_ID=$(echo "$SERVERS_BODY" | jq -r 'if type == "array" then .[0].id // empty else empty end' 2>/dev/null)
  VS_NAME=$(echo "$SERVERS_BODY" | jq -r 'if type == "array" then .[0].name // empty else empty end' 2>/dev/null)
  result "PASS" "/servers: $VS_COUNT server(s) (name=$VS_NAME)"
else
  # auth-proxy blocks admin REST endpoints — this is expected, not a failure
  echo "  ⚠️  /servers REST blocked (HTTP $SERVERS_CODE) — expected, auth-proxy blocks admin endpoints"
fi

# If we have a virtual server, test its MCP endpoint
if [ -n "$VS_ID" ]; then
  echo "--- 6. MCP via Virtual Server (/servers/$VS_ID/mcp) ---"

  VS_INIT=$(mcp_post "/servers/$VS_ID/mcp" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e-test","version":"1.0"}}}')
  if echo "$VS_INIT" | jq -e '.result.serverInfo' > /dev/null 2>&1; then
    result "PASS" "MCP initialize at virtual server"
  else
    result "FAIL" "MCP initialize at VS" "$(echo "$VS_INIT" | head -c 200)"
  fi

  mcp_post "/servers/$VS_ID/mcp" '{"jsonrpc":"2.0","method":"notifications/initialized"}' > /dev/null 2>&1

  VS_TOOLS=$(mcp_post "/servers/$VS_ID/mcp" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
  VS_TOOL_COUNT=$(echo "$VS_TOOLS" | jq '.result.tools | length' 2>/dev/null)
  if [ -n "$VS_TOOL_COUNT" ] && [ "$VS_TOOL_COUNT" -gt 0 ]; then
    result "PASS" "tools/list at VS: $VS_TOOL_COUNT tools"
  else
    result "FAIL" "tools/list at VS" "Got ${VS_TOOL_COUNT:-null} tools"
  fi
fi

# =============================================
# 7. TOOL CALLS
# =============================================

# Determine which tools source to use (VS or root)
if [ -n "${VS_TOOL_COUNT:-}" ] && [ "${VS_TOOL_COUNT:-0}" -gt 0 ]; then
  ALL_TOOLS="$VS_TOOLS"
  MCP_PATH="/servers/$VS_ID/mcp"
elif [ -n "${TOOL_COUNT:-}" ] && [ "${TOOL_COUNT:-0}" -gt 0 ]; then
  ALL_TOOLS="$TOOLS"
  MCP_PATH="/mcp"
else
  ALL_TOOLS=""
  MCP_PATH="/mcp"
fi

if [ -n "$ALL_TOOLS" ]; then
  echo "--- 7. Tool Calls (via $MCP_PATH) ---"

  # 7a. Find and call an Apollo/Shopify tool (orders query)
  SHOPIFY_TOOL=$(echo "$ALL_TOOLS" | jq -r '.result.tools[] | select(.name | test("order|Order|customer|Customer|product|Product|apollo"; "i")) | .name' 2>/dev/null | head -1)
  if [ -n "$SHOPIFY_TOOL" ]; then
    echo "  Calling Shopify tool: $SHOPIFY_TOOL"
    # Get tool schema to understand required args
    TOOL_SCHEMA=$(echo "$ALL_TOOLS" | jq ".result.tools[] | select(.name==\"$SHOPIFY_TOOL\") | .inputSchema" 2>/dev/null)
    REQUIRED=$(echo "$TOOL_SCHEMA" | jq -r '.required // [] | join(", ")' 2>/dev/null)
    echo "  Required args: ${REQUIRED:-none}"

    CALL_RESP=$(mcp_post "$MCP_PATH" "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"$SHOPIFY_TOOL\",\"arguments\":{}}}")
    if echo "$CALL_RESP" | jq -e '.result' > /dev/null 2>&1; then
      result "PASS" "Shopify tool call ($SHOPIFY_TOOL)"
      echo "  Response (first 300 chars):"
      echo "$CALL_RESP" | jq -r '.result.content[0].text // .result | tostring' 2>/dev/null | head -c 300
      echo ""
    elif echo "$CALL_RESP" | jq -e '.error' > /dev/null 2>&1; then
      ERR_MSG=$(echo "$CALL_RESP" | jq -r '.error.message // .error' 2>/dev/null)
      result "FAIL" "Shopify tool call" "$ERR_MSG"
    else
      result "FAIL" "Shopify tool call" "$(echo "$CALL_RESP" | head -c 200)"
    fi
  else
    result "FAIL" "Shopify tool" "No Shopify-related tool found in tools/list"
  fi

  # 7b. Find and call a dev-mcp tool (Shopify docs)
  DEVMCP_TOOL=$(echo "$ALL_TOOLS" | jq -r '.result.tools[] | select(.name | test("search|doc|fetch|learn"; "i")) | .name' 2>/dev/null | head -1)
  if [ -n "$DEVMCP_TOOL" ]; then
    echo "  Calling dev-mcp tool: $DEVMCP_TOOL"
    CALL_RESP=$(mcp_post "$MCP_PATH" "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"$DEVMCP_TOOL\",\"arguments\":{\"query\":\"Shopify orders API\"}}}")
    if echo "$CALL_RESP" | jq -e '.result' > /dev/null 2>&1; then
      result "PASS" "dev-mcp tool call ($DEVMCP_TOOL)"
    elif echo "$CALL_RESP" | jq -e '.error' > /dev/null 2>&1; then
      ERR_MSG=$(echo "$CALL_RESP" | jq -r '.error.message // .error' 2>/dev/null)
      result "FAIL" "dev-mcp tool call ($DEVMCP_TOOL)" "$ERR_MSG"
    else
      result "FAIL" "dev-mcp tool call" "$(echo "$CALL_RESP" | head -c 200)"
    fi
  else
    result "FAIL" "dev-mcp tool" "No docs/search tool found"
  fi

  # 7c. Find and call a google-sheets tool
  SHEETS_TOOL=$(echo "$ALL_TOOLS" | jq -r '.result.tools[] | select(.name | test("sheet|Sheet|spreadsheet"; "i")) | .name' 2>/dev/null | head -1)
  if [ -n "$SHEETS_TOOL" ]; then
    echo "  Calling sheets tool: $SHEETS_TOOL"
    CALL_RESP=$(mcp_post "$MCP_PATH" "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"$SHEETS_TOOL\",\"arguments\":{}}}")
    if echo "$CALL_RESP" | jq -e '.result' > /dev/null 2>&1; then
      result "PASS" "Sheets tool call ($SHEETS_TOOL)"
    elif echo "$CALL_RESP" | jq -e '.error' > /dev/null 2>&1; then
      ERR_MSG=$(echo "$CALL_RESP" | jq -r '.error.message // .error' 2>/dev/null)
      result "FAIL" "Sheets tool call ($SHEETS_TOOL)" "$ERR_MSG"
    else
      result "FAIL" "Sheets tool call" "$(echo "$CALL_RESP" | head -c 200)"
    fi
  else
    result "FAIL" "Sheets tool" "No sheets-related tool found"
  fi
else
  echo "--- 7. Tool Calls ---"
  result "FAIL" "Tool calls" "Skipped — no tools available"
fi

# =============================================
# 8. MCP RESOURCES & PROMPTS
# =============================================
echo "--- 8. MCP Resources & Prompts ---"

RESOURCES=$(mcp_post "$MCP_PATH" '{"jsonrpc":"2.0","id":20,"method":"resources/list","params":{}}')
if echo "$RESOURCES" | jq -e '.result' > /dev/null 2>&1; then
  RES_COUNT=$(echo "$RESOURCES" | jq '.result.resources | length' 2>/dev/null)
  result "PASS" "resources/list: ${RES_COUNT:-0} resources"
else
  result "FAIL" "resources/list" "No .result in response: $(echo "$RESOURCES" | head -c 200)"
fi

PROMPTS=$(mcp_post "$MCP_PATH" '{"jsonrpc":"2.0","id":21,"method":"prompts/list","params":{}}')
if echo "$PROMPTS" | jq -e '.result' > /dev/null 2>&1; then
  PROMPT_COUNT=$(echo "$PROMPTS" | jq '.result.prompts | length' 2>/dev/null)
  result "PASS" "prompts/list: ${PROMPT_COUNT:-0} prompts"
else
  result "FAIL" "prompts/list" "No .result in response: $(echo "$PROMPTS" | head -c 200)"
fi

# =============================================
# SUMMARY
# =============================================
echo ""
echo "========================================="
if [ "$FAILED" -eq 0 ]; then
  echo "  ✅ ALL TESTS PASSED: $PASSED/$TOTAL"
else
  echo "  ❌ $FAILED FAILURES out of $TOTAL tests"
  printf "  Failures:%b\n" "$FAILURES"
fi
echo "========================================="

# Cap exit code at 1 to avoid special shell meanings (126=not executable, 128+N=signal)
exit $(( FAILED > 0 ? 1 : 0 ))
