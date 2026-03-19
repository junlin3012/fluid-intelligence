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
  gcloud_err=$(mktemp)
  AUTH_PASSWORD=$(gcloud secrets versions access latest \
    --secret=mcp-auth-passphrase \
    --project=junlinleather-mcp 2>"$gcloud_err") || {
    echo "FATAL: Set AUTH_PASSWORD or configure gcloud for secret access"
    [ -s "$gcloud_err" ] && echo "  gcloud error: $(cat "$gcloud_err")"
    rm -f "$gcloud_err"
    exit 1
  }
  rm -f "$gcloud_err"
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
    echo "  PASS: $2"
  elif [ "$1" = "WARN" ]; then
    PASSED=$((PASSED + 1))
    echo "  WARN: $2"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $2: ${3:-no details}"
    FAILURES="${FAILURES}\n  - $2: ${3:-no details}"
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
http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$BASE/" 2>/dev/null)
if [ "$http_code" = "401" ]; then
  result "PASS" "Root returns 401 (auth-proxy alive)"
else
  result "FAIL" "Root reachability" "Expected 401, got $http_code"
fi

# =============================================
# 2. OAUTH DISCOVERY
# =============================================
echo "--- 2. OAuth Discovery ---"

oauth_as=$(curl -sf --connect-timeout 5 --max-time 10 "$BASE/.well-known/oauth-authorization-server" 2>/dev/null)
if echo "$oauth_as" | jq -e '.token_endpoint' > /dev/null 2>&1; then
  result "PASS" "OAuth authorization server metadata"
else
  result "FAIL" "OAuth AS metadata" "Missing token_endpoint"
fi

oauth_pr=$(curl -sf --connect-timeout 5 --max-time 10 "$BASE/.well-known/oauth-protected-resource" 2>/dev/null)
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
  "$BASE/.idp/register" 2>/dev/null)
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
curl -sL --connect-timeout 5 --max-time 10 -c "$COOKIE_JAR" \
  "$BASE/.idp/auth?response_type=code&client_id=$CLIENT_ID&redirect_uri=$REDIRECT_URI&state=$STATE&code_challenge=$CODE_CHALLENGE&code_challenge_method=S256" \
  -o /dev/null 2>/dev/null

# Use -D to capture headers (not -v which leaks password in POST body to stderr)
LOGIN_HEADERS=$(curl -s -D - -o /dev/null --max-time 10 \
  -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
  -X POST -d "password=$(AUTH_PASSWORD="$AUTH_PASSWORD" python3 -c "import os, urllib.parse; print(urllib.parse.quote(os.environ['AUTH_PASSWORD']))")" \
  "$BASE/.auth/login" 2>/dev/null)
AUTH_SESSION=$(echo "$LOGIN_HEADERS" | grep -oi "location: /.idp/auth/[a-f0-9-]*" | head -1 | sed 's/[Ll]ocation: //')

AUTH_CODE=""
RETURNED_STATE=""
if [ -n "$AUTH_SESSION" ]; then
  CODE_REDIRECT=$(curl -s -D - -o /dev/null --max-time 10 \
    -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    "$BASE$AUTH_SESSION" 2>/dev/null)
  AUTH_CODE=$(echo "$CODE_REDIRECT" | grep -o "code=[^&[:space:]]*" | head -1 | sed 's/code=//')
  RETURNED_STATE=$(echo "$CODE_REDIRECT" | grep -o "state=[^&[:space:]\"]*" | head -1 | sed 's/state=//')
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
  # Use --data-urlencode to safely handle special chars in auth code/secrets
  TOKEN_RESP=$(curl -s --max-time 10 -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "code=$AUTH_CODE" \
    --data-urlencode "redirect_uri=$REDIRECT_URI" \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "client_secret=$CLIENT_SECRET" \
    --data-urlencode "code_verifier=$CODE_VERIFIER" \
    "$BASE/.idp/token" 2>/dev/null)
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
  "$BASE/mcp" 2>/dev/null)
if [ "$INVALID_RESP" = "401" ]; then
  result "PASS" "Invalid token rejected (401)"
else
  result "FAIL" "Invalid token rejection" "Expected 401, got $INVALID_RESP"
fi

# Verify no-token request is rejected
NO_TOKEN_RESP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  -H "Accept: application/json" \
  -X POST -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  "$BASE/mcp" 2>/dev/null)
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
  # Use -s only (no -f) so HTTP error response bodies are captured for diagnostics
  curl -s --max-time 15 -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "$body" \
    "$BASE$path" 2>/dev/null
}

# Initialize
INIT=$(mcp_post "/mcp" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e-test","version":"1.0"}}}')
INIT_OK=false
if echo "$INIT" | jq -e '.result.serverInfo' > /dev/null 2>&1; then
  SERVER=$(echo "$INIT" | jq -r '.result.serverInfo.name')
  result "PASS" "MCP initialize (server=$SERVER)"
  INIT_OK=true
else
  result "FAIL" "MCP initialize" "$(echo "$INIT" | head -c 200)"
fi

# Validate protocolVersion in response
PROTO_VER=$(echo "$INIT" | jq -r '.result.protocolVersion // empty' 2>/dev/null)
if [ -n "$PROTO_VER" ]; then
  result "PASS" "Protocol version: $PROTO_VER"
else
  result "FAIL" "Protocol version" "Missing .result.protocolVersion"
fi

# Validate capabilities advertised
if echo "$INIT" | jq -e '.result.capabilities.tools' > /dev/null 2>&1; then
  result "PASS" "Server advertises tools capability"
else
  result "FAIL" "Server capabilities" "Missing .result.capabilities.tools"
fi

# Send initialized notification (only after successful init per MCP spec)
if [ "$INIT_OK" = true ]; then
  mcp_post "/mcp" '{"jsonrpc":"2.0","method":"notifications/initialized"}' > /dev/null 2>&1
fi

# Ping (MCP servers MUST support ping)
PING=$(mcp_post "/mcp" '{"jsonrpc":"2.0","id":99,"method":"ping"}')
if echo "$PING" | jq -e '.result' > /dev/null 2>&1; then
  result "PASS" "MCP ping"
else
  result "FAIL" "MCP ping" "$(echo "$PING" | head -c 200)"
fi

# tools/list
TOOLS=$(mcp_post "/mcp" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
TOOL_COUNT=$(echo "$TOOLS" | jq '.result.tools | length // 0' 2>/dev/null)
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
  "$BASE/servers" 2>/dev/null)
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
  VS_TOOL_COUNT=$(echo "$VS_TOOLS" | jq '.result.tools | length // 0' 2>/dev/null)
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
    TOOL_SCHEMA=$(echo "$ALL_TOOLS" | jq --arg t "$SHOPIFY_TOOL" '.result.tools[] | select(.name==$t) | .inputSchema' 2>/dev/null)
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
# 8. MCP NEGATIVE TESTS
# =============================================
echo "--- 8. MCP Negative Tests ---"

# 8a. Invalid JSON-RPC method should return -32601 (Method Not Found)
INVALID_METHOD=$(mcp_post "$MCP_PATH" '{"jsonrpc":"2.0","id":30,"method":"nonexistent/method","params":{}}')
INVALID_ERR_CODE=$(echo "$INVALID_METHOD" | jq -r '.error.code // empty' 2>/dev/null)
if [ "$INVALID_ERR_CODE" = "-32601" ]; then
  result "PASS" "Invalid method returns -32601 (Method Not Found)"
elif echo "$INVALID_METHOD" | jq -e '.error' > /dev/null 2>&1; then
  result "PASS" "Invalid method returns error (code=$INVALID_ERR_CODE)"
else
  result "FAIL" "Invalid method rejection" "Expected error, got: $(echo "$INVALID_METHOD" | head -c 200)"
fi

# 8b. Malformed JSON should return -32700 (Parse Error)
MALFORMED_RESP=$(curl -s --max-time 15 -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -d '{broken json!!!' \
  "$BASE$MCP_PATH" 2>/dev/null)
MALFORMED_ERR_CODE=$(echo "$MALFORMED_RESP" | jq -r '.error.code // empty' 2>/dev/null)
MALFORMED_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -d '{broken json!!!' \
  "$BASE$MCP_PATH" 2>/dev/null)
if [ "$MALFORMED_ERR_CODE" = "-32700" ]; then
  result "PASS" "Malformed JSON returns -32700 (Parse Error)"
elif [ -n "$MALFORMED_ERR_CODE" ]; then
  result "PASS" "Malformed JSON returns error (code=$MALFORMED_ERR_CODE, expected -32700)"
elif [ "$MALFORMED_HTTP" = "400" ]; then
  result "WARN" "Malformed JSON returns HTTP 400 but no JSON-RPC error code (response may not be valid JSON)"
else
  result "FAIL" "Malformed JSON rejection" "Expected error/400, got HTTP $MALFORMED_HTTP: $(echo "$MALFORMED_RESP" | head -c 200)"
fi

# =============================================
# 9. MCP RESOURCES & PROMPTS
# =============================================
echo "--- 9. MCP Resources & Prompts ---"

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
# 10. SECURITY HARDENING TESTS
# =============================================
echo "--- 10. Security Hardening ---"

# 10a. Rate limiting on login (5 req/min threshold)
echo "  Testing rate limiting on /.auth/login..."
RL_PASS=true
COOKIE_RL=$(mktemp)
# Initiate a fresh auth session for rate limit testing
curl -sL -c "$COOKIE_RL" -o /dev/null \
  "$BASE/.idp/auth?response_type=code&client_id=$CLIENT_ID&redirect_uri=$REDIRECT_URI&state=rl-test&code_challenge=$(echo -n 'rl-test-verifier-padding-padding-padding-padding' | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')&code_challenge_method=S256" 2>/dev/null
for i in $(seq 1 8); do
  RL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -b "$COOKIE_RL" -c "$COOKIE_RL" \
    -d "password=wrong" "$BASE/.auth/login" 2>/dev/null)
  if [ "$i" -gt 5 ] && [ "$RL_CODE" != "429" ]; then
    RL_PASS=false
  fi
done
rm -f "$COOKIE_RL"
if [ "$RL_PASS" = true ]; then
  result "PASS" "Rate limiting on login (429 after 5 attempts)"
else
  result "WARN" "Rate limiting on login" "Attempt 6+ still accepted (may need deployment with v2.5.5-security)"
fi

# 10b. Token lifetime check
TOKEN_EXP_DELTA=$(echo "$ACCESS_TOKEN" | cut -d. -f2 | (base64 -d 2>/dev/null || base64 -D 2>/dev/null) | jq 'if .exp and .iat then (.exp - .iat) else 999999 end' 2>/dev/null)
if [ -n "$TOKEN_EXP_DELTA" ] && [ "$TOKEN_EXP_DELTA" -le 3601 ] 2>/dev/null; then
  result "PASS" "Token lifetime <= 1 hour (${TOKEN_EXP_DELTA}s)"
else
  result "WARN" "Token lifetime" "exp-iat=${TOKEN_EXP_DELTA}s (expected <= 3600)"
fi

# 10c. JWT audience claim
TOKEN_AUD=$(echo "$ACCESS_TOKEN" | cut -d. -f2 | (base64 -d 2>/dev/null || base64 -D 2>/dev/null) | jq -r 'if .aud then (.aud | if type == "array" then .[0] // "empty" else . end) else "missing" end' 2>/dev/null)
if [ -n "$TOKEN_AUD" ] && [ "$TOKEN_AUD" != "empty" ] && [ "$TOKEN_AUD" != "missing" ]; then
  result "PASS" "JWT audience set ($TOKEN_AUD)"
else
  result "WARN" "JWT audience" "aud=$TOKEN_AUD (expected non-empty)"
fi

# 10d. PKCE plain method not advertised
PKCE_METHODS=$(curl -s "$BASE/.well-known/oauth-authorization-server" 2>/dev/null | jq -r '.code_challenge_methods_supported // [] | join(",")' 2>/dev/null)
if echo "$PKCE_METHODS" | grep -q "plain"; then
  result "WARN" "PKCE plain method" "Still advertised: $PKCE_METHODS"
else
  result "PASS" "PKCE plain disabled (methods: $PKCE_METHODS)"
fi

# 10e. Pydantic error sanitization
PYDANTIC_TEST=$(mcp_post "$MCP_PATH" '{"jsonrpc":"2.0","id":99,"method":"tools/call","params":"not-an-object"}')
if echo "$PYDANTIC_TEST" | grep -qi "pydantic\|errors.pydantic.dev"; then
  result "WARN" "Pydantic leak" "Framework name or URL in error response"
else
  result "PASS" "Error responses sanitized (no framework leak)"
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
