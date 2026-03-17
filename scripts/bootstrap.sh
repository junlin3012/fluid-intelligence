#!/bin/bash
set -euo pipefail

# Extract numeric HTTP code from curl response; defaults to 0 if non-numeric
# curl -w "\n%{http_code}" appends status as last line, but edge cases (empty body,
# connection failure) can produce non-numeric output that breaks arithmetic comparisons.
parse_http_code() {
  local code
  code=$(echo "$1" | tail -1)
  [[ "$code" =~ ^[0-9]+$ ]] && echo "$code" || echo "0"
}

# Generate admin JWT for registration (15 min expiry to cover slow starts + RBAC setup:
# worst case: Apollo 60s + dev-mcp 120s + sheets 60s + convergence 60s + RBAC 30s = ~6 min
# plus registration retries if backends are slow to respond)
# Pass secrets via env vars to avoid shell injection (quotes in values would break inline Python)
PRIMARY_ERR=""
TOKEN=$(ADMIN_EMAIL="$PLATFORM_ADMIN_EMAIL" SECRET_KEY="$JWT_SECRET_KEY" /app/.venv/bin/python -c "
import os, sys
sys.argv = ['create_jwt_token', '--username', os.environ['ADMIN_EMAIL'], '--exp', '15', '--secret', os.environ['SECRET_KEY']]
from mcpgateway.utils.create_jwt_token import main
main()
" 2>/tmp/jwt-primary-err-$$.log) || {
  PRIMARY_ERR=$(cat /tmp/jwt-primary-err-$$.log 2>/dev/null)
  # Fallback: try the module directly (use env var to avoid secret in /proc/cmdline)
  TOKEN=$(ADMIN_EMAIL="$PLATFORM_ADMIN_EMAIL" SECRET_KEY="$JWT_SECRET_KEY" python3 -c "
import os, sys
sys.argv = ['create_jwt_token', '--username', os.environ['ADMIN_EMAIL'], '--exp', '15', '--secret', os.environ['SECRET_KEY']]
from mcpgateway.utils.create_jwt_token import main
main()
" 2>/tmp/jwt-fallback-err-$$.log)
}

if [ -z "$TOKEN" ]; then
  echo "[bootstrap] FATAL: Could not generate JWT token"
  [ -n "$PRIMARY_ERR" ] && echo "[bootstrap]   Primary: $PRIMARY_ERR"
  [ -f /tmp/jwt-fallback-err-$$.log ] && echo "[bootstrap]   Fallback: $(cat /tmp/jwt-fallback-err-$$.log)"
  rm -f /tmp/jwt-primary-err-$$.log /tmp/jwt-fallback-err-$$.log
  exit 1
fi
rm -f /tmp/jwt-primary-err-$$.log /tmp/jwt-fallback-err-$$.log
# Validate JWT format (header.payload.signature) — catch Python warnings/garbage in stdout
if ! [[ "$TOKEN" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
  echo "[bootstrap] FATAL: JWT token has invalid format (possible Python warning in stdout)"
  echo "[bootstrap]   Token starts with: $(echo "$TOKEN" | head -c 50)"
  exit 1
fi
echo "[bootstrap] JWT token generated"

# File lock: prevent concurrent bootstrap from multiple instances or restarts.
# flock is non-blocking (-n): if lock is held, exit 0 (let the other instance finish).
# Lock is automatically released when the process exits (including SIGTERM).
BOOTSTRAP_LOCK="/tmp/bootstrap.lock"
if ! command -v flock >/dev/null 2>&1; then
  echo "[bootstrap] WARNING: flock not available — skipping advisory lock (install util-linux)"
else
  exec 9>"$BOOTSTRAP_LOCK"
  if ! flock -n 9; then
    echo "[bootstrap] Another instance is running bootstrap — skipping (flock held)"
    exit 0
  fi
fi
# Lock acquired — fd 9 stays open for the lifetime of this script

CF="http://127.0.0.1:${CONTEXTFORGE_PORT:-4444}"

# Identity header for proxy auth mode (TRUST_PROXY_AUTH=true).
# ContextForge expects X-Authenticated-User on all endpoints when proxy auth is active.
# SSO_AUTO_CREATE_USERS + SSO_GOOGLE_ADMIN_DOMAINS auto-create and auto-promote on first request.
PROXY_AUTH_HEADER="X-Authenticated-User: ${PLATFORM_ADMIN_EMAIL}"

# Service ports (inherit from entrypoint.sh exports or use defaults)
APOLLO_PORT="${APOLLO_PORT:-8000}"
DEVMCP_PORT="${DEVMCP_PORT:-8003}"
SHEETS_PORT="${SHEETS_PORT:-8004}"

# Primary user for team/role assignment (set via env var, never hardcoded)
PRIMARY_USER_EMAIL="${PRIMARY_USER_EMAIL:-${GOOGLE_ALLOWED_USERS%%,*}}"

# Virtual server name
VIRTUAL_SERVER_NAME="${VIRTUAL_SERVER_NAME:-fluid-intelligence}"

# Fast-fail: verify ContextForge is still alive before expensive registration attempts
check_contextforge() {
  if ! curl -sf --connect-timeout 2 --max-time 3 "$CF/health" > /dev/null 2>&1; then
    echo "[bootstrap] FATAL: ContextForge health check failed — process may have crashed"
    exit 1
  fi
}

# Register a backend MCP server with ContextForge via /gateways endpoint
# /gateways triggers tool auto-discovery; /servers is for virtual server composition only
# Always re-registers to pick up URL/transport changes across deployments
register_gateway() {
  local name="$1" url="$2" transport="$3"

  # Delete any existing registrations (stale URL/transport from previous deploy)
  # Use head -1 to handle multiple entries with the same name (delete each individually)
  local existing_ids
  existing_ids=$(curl -sf --connect-timeout 2 --max-time 10 -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" \
    "$CF/gateways" 2>/dev/null | \
    jq -r --arg n "$name" '.[] | select(.name==$n) | .id' 2>/dev/null) || true
  if [ -n "$existing_ids" ]; then
    echo "$existing_ids" | while read -r eid; do
      [ -z "$eid" ] || [ "$eid" = "null" ] && continue
      echo "[bootstrap] Deleting stale $name (id=$eid)"
      del_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 10 -X DELETE \
        -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" "$CF/gateways/$eid" 2>/dev/null) || del_code=0
      if [ "$del_code" -ne 200 ] && [ "$del_code" -ne 204 ] && [ "$del_code" -ne 404 ]; then
        echo "[bootstrap] WARNING: DELETE gateway $eid returned HTTP $del_code"
      fi
    done
  fi

  local max_attempts=6 attempt=1 http_code=0 payload response body
  while [ "$attempt" -le "$max_attempts" ]; do
    payload=$(jq -n --arg n "$name" --arg u "$url" --arg t "$transport" \
      '{name: $n, url: $u, transport: $t}')
    local curl_err="/tmp/bootstrap-curl-err-$$.log"
    response=$(curl -s -w "\n%{http_code}" --connect-timeout 2 --max-time 60 -X POST \
      -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$CF/gateways" 2>"$curl_err")
    http_code=$(parse_http_code "$response")
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
      rm -f "$curl_err"
      echo "[bootstrap] Registered $name via /gateways (tools auto-discovered)"
      return 0
    fi

    # 409 = already exists
    if [ "$http_code" -eq 409 ]; then
      rm -f "$curl_err"
      echo "[bootstrap] $name already exists (409)"
      return 0
    fi

    echo "[bootstrap] $name registration attempt $attempt/$max_attempts failed (HTTP $http_code): $(echo "$body" | head -c 200)"
    [ -s "$curl_err" ] && echo "[bootstrap]   curl error: $(cat "$curl_err")"
    attempt=$((attempt + 1))
    # Linear backoff: 10s, 15s, 20s, 25s, 30s (attempt incremented before sleep)
    sleep "$((attempt * 5))"
  done

  echo "[bootstrap] FATAL: Failed to register $name after $max_attempts attempts (last HTTP $http_code): $(echo "$body" | head -c 200)"
  [ -s "$curl_err" ] && echo "[bootstrap]   curl error: $(cat "$curl_err")"
  rm -f "$curl_err"
  return 1
}

# Wait for Apollo (native streamable_http on port 8000)
# Apollo serves MCP directly — no translate bridge. Check /mcp endpoint.
echo "[bootstrap] Waiting for Apollo..."
for i in $(seq 1 60); do
  if [ -f /tmp/apollo.pid ]; then
    APOLLO_PID_CHECK=$(cat /tmp/apollo.pid 2>/dev/null)
    if [ -n "$APOLLO_PID_CHECK" ] && [[ "$APOLLO_PID_CHECK" =~ ^[0-9]+$ ]] && ! kill -0 "$APOLLO_PID_CHECK" 2>/dev/null; then
      echo "[bootstrap] FATAL: Apollo process (PID $APOLLO_PID_CHECK) crashed"
      exit 1
    fi
  fi
  # Apollo streamable_http: check if port 8000 accepts connections
  # Use -s (no -f) so any HTTP response = server is up (even 404/405)
  rc=0; curl -s --connect-timeout 2 --max-time 3 -o /dev/null -w "%{http_code}" http://127.0.0.1:${APOLLO_PORT}/mcp 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] && { echo "[bootstrap] Apollo ready after ${i}s"; break; }
  [ "$i" -eq 60 ] && { echo "[bootstrap] FATAL: Apollo not ready after 60s (last curl rc=$rc)"; exit 1; }
  sleep 1
done

check_contextforge
echo "[bootstrap] Registering Apollo MCP (Shopify GraphQL)..."
register_gateway "apollo-shopify" "http://127.0.0.1:${APOLLO_PORT}/mcp" "STREAMABLEHTTP"

# Wait for dev-mcp bridge (npx install can take 30-60s on cold start)
# healthz only checks the bridge HTTP server, not the underlying MCP subprocess.
# We also probe the SSE endpoint to verify the MCP subprocess is actually connected.
echo "[bootstrap] Waiting for dev-mcp bridge..."
for i in $(seq 1 120); do
  if [ -f /tmp/devmcp.pid ]; then
    BRIDGE_PID=$(cat /tmp/devmcp.pid 2>/dev/null)
    if [ -n "$BRIDGE_PID" ] && [[ "$BRIDGE_PID" =~ ^[0-9]+$ ]] && ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      echo "[bootstrap] FATAL: dev-mcp bridge process (PID $BRIDGE_PID) crashed"
      exit 1
    fi
  fi
  # Check both healthz AND SSE endpoint (SSE returns 200 only when MCP subprocess is connected)
  rc=0; curl -sf --connect-timeout 2 --max-time 3 http://127.0.0.1:${DEVMCP_PORT}/healthz > /dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    # Bridge HTTP is up — now verify MCP subprocess is actually ready via SSE probe
    sse_rc=0; curl -s --connect-timeout 2 --max-time 3 http://127.0.0.1:${DEVMCP_PORT}/sse -o /dev/null 2>&1 || sse_rc=$?
    # SSE returns 200 (streaming) which curl sees as timeout (28) = subprocess ready
    if [ "$sse_rc" -eq 0 ] || [ "$sse_rc" -eq 28 ]; then
      echo "[bootstrap] dev-mcp bridge ready (healthz + SSE confirmed) after ${i}s"
      break
    fi
  fi
  [ "$i" -eq 120 ] && { echo "[bootstrap] FATAL: dev-mcp bridge not ready after 120s (last curl rc=$rc, sse_rc=${sse_rc:-n/a})"; exit 1; }
  sleep 1
done

check_contextforge
echo "[bootstrap] Registering dev-mcp (Shopify docs)..."
register_gateway "shopify-dev-mcp" "http://127.0.0.1:${DEVMCP_PORT}/sse" "SSE"

# Wait for google-sheets bridge
echo "[bootstrap] Waiting for google-sheets bridge..."
for i in $(seq 1 60); do
  if [ -f /tmp/sheets.pid ]; then
    BRIDGE_PID=$(cat /tmp/sheets.pid 2>/dev/null)
    if [ -n "$BRIDGE_PID" ] && [[ "$BRIDGE_PID" =~ ^[0-9]+$ ]] && ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      echo "[bootstrap] FATAL: google-sheets bridge process (PID $BRIDGE_PID) crashed"
      exit 1
    fi
  fi
  rc=0; curl -sf --connect-timeout 2 --max-time 3 http://127.0.0.1:${SHEETS_PORT}/healthz > /dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && { echo "[bootstrap] google-sheets bridge ready after ${i}s"; break; }
  [ "$i" -eq 60 ] && { echo "[bootstrap] FATAL: google-sheets bridge not ready after 60s (last curl rc=$rc)"; exit 1; }
  sleep 1
done

check_contextforge
echo "[bootstrap] Registering google-sheets..."
register_gateway "google-sheets" "http://127.0.0.1:${SHEETS_PORT}/sse" "SSE"

# Verify tools discovered — poll until count stabilizes (async discovery race)
echo "[bootstrap] All 3 backends registered, waiting for tool discovery..."
# Minimum expected tool count: Apollo ~7 + dev-mcp ~50+ + sheets ~17 = ~74
# Use conservative floor of 70 to catch broken backend registrations
MIN_TOOL_COUNT=${MIN_TOOL_COUNT:-70}
prev_count=-1
stable=0
for i in $(seq 1 30); do
  TOOL_COUNT=$(curl -sf --connect-timeout 2 --max-time 10 -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" "$CF/tools" 2>/dev/null | jq 'length' 2>/dev/null) || TOOL_COUNT=0
  [[ "$TOOL_COUNT" =~ ^[0-9]+$ ]] || TOOL_COUNT=0
  if [ "$TOOL_COUNT" -eq "$prev_count" ] && [ "$TOOL_COUNT" -gt 0 ]; then
    stable=$((stable + 1))
    [ "$stable" -ge 2 ] && break
  else
    stable=0
  fi
  prev_count=$TOOL_COUNT
  sleep 2
done
if [ "$stable" -ge 2 ]; then
  echo "[bootstrap] $TOOL_COUNT tools in catalog (stabilized after $((i * 2))s)"
else
  echo "[bootstrap] $TOOL_COUNT tools in catalog (did NOT stabilize after $((i * 2))s)"
fi
if [ "$TOOL_COUNT" -lt "$MIN_TOOL_COUNT" ]; then
  echo "[bootstrap] WARNING: Only $TOOL_COUNT tools discovered (expected >= $MIN_TOOL_COUNT)"
  echo "[bootstrap]   This suggests a backend failed to register or tool discovery is incomplete"
  echo "[bootstrap]   Expected: Apollo ~7 + dev-mcp ~50+ + sheets ~17 = ~74+"
  # Don't exit — partial service is better than no service. But log loudly.
fi

# --- Create virtual server bundling ALL discovered tools ---
# MCP clients connect to /servers/<UUID>/mcp (or /servers/<UUID>/sse)
# Without a virtual server, tools/list via MCP returns empty.
echo "[bootstrap] Creating virtual server..."

# Delete existing virtual servers (stale from previous deploy — could be multiple)
existing_vs_ids=$(curl -sf --connect-timeout 2 --max-time 10 -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" \
  "$CF/servers" 2>/dev/null | \
  jq -r '.[] | select(.name=="'"$VIRTUAL_SERVER_NAME"'") | .id' 2>/dev/null) || true
if [ -n "$existing_vs_ids" ]; then
  echo "$existing_vs_ids" | while read -r vs_id; do
    [ -z "$vs_id" ] || [ "$vs_id" = "null" ] && continue
    echo "[bootstrap] Deleting stale virtual server (id=$vs_id)"
    vs_del_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 10 -X DELETE \
      -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" "$CF/servers/$vs_id" 2>/dev/null) || vs_del_code=0
    if [ "$vs_del_code" -ne 200 ] && [ "$vs_del_code" -ne 204 ] && [ "$vs_del_code" -ne 404 ]; then
      echo "[bootstrap] WARNING: DELETE virtual server $vs_id returned HTTP $vs_del_code"
    fi
  done
fi

# Get all tool IDs from the catalog
TOOL_IDS=$(curl -sf --connect-timeout 2 --max-time 10 -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" "$CF/tools" 2>/dev/null | \
  jq -r 'if type == "array" then [.[].id | select(. != null)] | @json else "[]" end' 2>/dev/null) || TOOL_IDS="[]"
if [ "$TOOL_IDS" = "[]" ]; then
  echo "[bootstrap] WARNING: No tool IDs found — virtual server will expose zero tools"
  echo "[bootstrap] MCP clients will get empty tools/list"
fi

# Create virtual server with all tools
vs_payload=$(jq -n --argjson tools "$TOOL_IDS" --arg name "$VIRTUAL_SERVER_NAME" \
  '{server: {name: $name, description: "All registered backend tools", associated_tools: $tools}}')
vs_curl_err="/tmp/bootstrap-vs-curl-err-$$.log"
vs_response=$(curl -s -w "\n%{http_code}" --connect-timeout 2 --max-time 10 -X POST \
  -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" \
  -H "Content-Type: application/json" \
  -d "$vs_payload" \
  "$CF/servers" 2>"$vs_curl_err")
vs_code=$(parse_http_code "$vs_response")
vs_body=$(echo "$vs_response" | sed '$d')

if [ "$vs_code" -ge 200 ] && [ "$vs_code" -lt 300 ]; then
  VS_ID=$(echo "$vs_body" | jq -r '.id // .server.id // empty' 2>/dev/null)
  if [ -z "$VS_ID" ] || [ "$VS_ID" = "null" ]; then
    echo "[bootstrap] FATAL: Virtual server created (HTTP $vs_code) but could not extract ID"
    echo "[bootstrap]   Response: $(echo "$vs_body" | head -c 300)"
    echo "[bootstrap]   MCP clients will not be able to connect"
    exit 1
  fi
  rm -f "$vs_curl_err"
  echo "[bootstrap] Virtual server created (id=$VS_ID)"
  echo "[bootstrap] MCP endpoint: /servers/$VS_ID/mcp"
  echo "[bootstrap] SSE endpoint: /servers/$VS_ID/sse"
else
  echo "[bootstrap] FATAL: Virtual server creation failed (HTTP $vs_code): $(echo "$vs_body" | head -c 200)"
  [ -s "$vs_curl_err" ] && echo "[bootstrap]   curl error: $(cat "$vs_curl_err")"
  rm -f "$vs_curl_err"
  echo "[bootstrap] MCP tools/list will be empty — clients cannot discover tools"
  exit 1
fi

# --- Debug dump ---
echo "[bootstrap] --- Debug: /gateways ---"
curl -sf --connect-timeout 2 --max-time 5 -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" "$CF/gateways" 2>/dev/null | jq '[.[] | {name, id, url}]' 2>/dev/null || echo "  /gateways failed"
echo "[bootstrap] --- Debug: /servers ---"
curl -sf --connect-timeout 2 --max-time 5 -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" "$CF/servers" 2>/dev/null | jq '[.[] | {name, id}]' 2>/dev/null || echo "  /servers failed"
echo "[bootstrap] --- Debug: tool names ---"
curl -sf --connect-timeout 2 --max-time 5 -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" "$CF/tools" 2>/dev/null | jq '[.[].name]' 2>/dev/null | head -30 || echo "  /tools failed"

# ============================================================
# RBAC: Team + User + Role Setup
# ============================================================
# Identity integration: after gateway + virtual server setup,
# create teams and assign users so access is ready on first login.
# Users auto-created on first request via SSO_AUTO_CREATE_USERS=true.

# --- Create team (idempotent) ---
create_team() {
  local name="$1" description="$2"
  local payload
  payload=$(jq -n --arg n "$name" --arg d "$description" \
    '{name: $n, description: $d, visibility: "private"}')

  response=$(curl -s -L -w "\n%{http_code}" --connect-timeout 2 --max-time 10 -X POST \
    -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$CF/teams/" 2>/dev/null) || true

  http_code=$(parse_http_code "$response")
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    team_id=$(echo "$body" | jq -r '.id // empty' 2>/dev/null)
    if [ -z "$team_id" ] || [ "$team_id" = "null" ]; then
      echo "[bootstrap] WARNING: Team '$name' created (HTTP $http_code) but ID is empty — response: $(echo "$body" | head -c 200)" >&2
    else
      echo "[bootstrap] Created team '$name' (id=$team_id)" >&2
    fi
    echo "$team_id"
  elif [ "$http_code" -eq 409 ]; then
    team_id=$(curl -sf -L --connect-timeout 2 --max-time 10 \
      -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" \
      "$CF/teams/" 2>/dev/null | \
      jq -r --arg n "$name" '.[] | select(.name==$n) | .id' 2>/dev/null | head -1) || true
    echo "[bootstrap] Team '$name' already exists (id=$team_id)" >&2
    echo "$team_id"
  else
    echo "[bootstrap] WARNING: Failed to create team '$name' (HTTP $http_code)" >&2
    echo ""
  fi
}

# --- Add user to team (idempotent) ---
add_user_to_team() {
  local team_id="$1" email="$2" role="$3"
  local payload
  payload=$(jq -n --arg e "$email" --arg r "$role" \
    '{email: $e, role: $r}')

  response=$(curl -s -L -w "\n%{http_code}" --connect-timeout 2 --max-time 10 -X POST \
    -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$CF/teams/$team_id/members/" 2>/dev/null) || true

  http_code=$(parse_http_code "$response")
  body=$(echo "$response" | sed '$d')
  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "[bootstrap] Added $email to team (role=$role)"
  elif [ "$http_code" -eq 409 ]; then
    echo "[bootstrap] $email already in team"
  else
    echo "[bootstrap] WARNING: Failed to add $email to team (HTTP $http_code): $(echo "$body" | head -c 200)"
  fi
}

# --- Look up role ID by name ---
get_role_id() {
  local role_name="$1"
  curl -sf -L --connect-timeout 2 --max-time 10 \
    -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" \
    "$CF/rbac/roles/" 2>/dev/null | \
    jq -r --arg n "$role_name" '.[] | select(.name==$n) | .id' 2>/dev/null | head -1
}

# --- Assign role to user (idempotent) ---
assign_role() {
  local email="$1" role_name="$2" scope="$3" scope_id="${4:-}"

  # ContextForge RBAC API requires role_id, not role_name
  local role_id
  role_id=$(get_role_id "$role_name")
  if [ -z "$role_id" ] || [ "$role_id" = "null" ]; then
    echo "[bootstrap] WARNING: Role '$role_name' not found — cannot assign to $email"
    echo "[bootstrap]   Available roles:"
    curl -sf -L --connect-timeout 2 --max-time 10 \
      -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" \
      "$CF/rbac/roles/" 2>/dev/null | jq -r '.[].name' 2>/dev/null | sed 's/^/    /' || echo "    (failed to list)"
    return
  fi

  local payload
  payload=$(jq -n --arg r "$role_id" --arg s "$scope" --arg si "$scope_id" \
    '{role_id: $r, scope: $s, scope_id: (if $si == "" then null else $si end)}')

  response=$(curl -s -L -w "\n%{http_code}" --connect-timeout 2 --max-time 10 -X POST \
    -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$CF/rbac/users/$email/roles/" 2>/dev/null) || true

  http_code=$(parse_http_code "$response")
  body=$(echo "$response" | sed '$d')
  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "[bootstrap] Assigned role '$role_name' ($scope) to $email"
  elif [ "$http_code" -eq 409 ]; then
    echo "[bootstrap] $email already has role '$role_name'"
  else
    echo "[bootstrap] WARNING: Failed to assign role '$role_name' to $email (HTTP $http_code): $(echo "$body" | head -c 200)"
  fi
}

# === Team Setup ===
check_contextforge
echo "[bootstrap] Setting up teams and RBAC..."

ADMIN_TEAM_ID=$(create_team "admin" "Full access to all backends")
VIEWER_TEAM_ID=$(create_team "viewer" "Read-only Shopify access")

# === User + Role Assignment ===
# SSO_AUTO_CREATE_USERS=true auto-creates users on first OAuth login.
# SSO_GOOGLE_ADMIN_DOMAINS auto-promotes matching domain users to admin.
# Bootstrap only pre-assigns team membership IF the user already exists.

if [ -n "$PRIMARY_USER_EMAIL" ]; then
  user_exists=$(curl -sf -L --connect-timeout 2 --max-time 10 \
    -H "Authorization: Bearer $TOKEN" -H "$PROXY_AUTH_HEADER" \
    "$CF/rbac/users/$PRIMARY_USER_EMAIL/" 2>/dev/null | jq -r '.email // empty' 2>/dev/null) || true

  if [ "$user_exists" = "$PRIMARY_USER_EMAIL" ]; then
    echo "[bootstrap] User $PRIMARY_USER_EMAIL exists — assigning team + role"
    if [ -n "$ADMIN_TEAM_ID" ]; then
      add_user_to_team "$ADMIN_TEAM_ID" "$PRIMARY_USER_EMAIL" "owner"
    fi
    assign_role "$PRIMARY_USER_EMAIL" "platform_admin" "global"
  else
    echo "[bootstrap] User $PRIMARY_USER_EMAIL not yet created (will be auto-created on first OAuth login)"
    echo "[bootstrap]   SSO_GOOGLE_ADMIN_DOMAINS will auto-promote to admin"
  fi
else
  echo "[bootstrap] PRIMARY_USER_EMAIL not set — skipping user/role assignment"
fi

# Example: add a viewer later
# if [ -n "$VIEWER_TEAM_ID" ]; then
#   add_user_to_team "$VIEWER_TEAM_ID" "contractor@example.com" "member"
#   assign_role "contractor@example.com" "viewer" "team" "$VIEWER_TEAM_ID"
# fi

echo "[bootstrap] RBAC setup complete"
