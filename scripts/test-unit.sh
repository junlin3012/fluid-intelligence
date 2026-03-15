#!/bin/bash
# Unit tests for Fluid Intelligence shell scripts
# Tests validation logic, parsing, and edge cases locally (no deployed service needed)
# Usage: ./scripts/test-unit.sh
set -uo pipefail

PASSED=0
FAILED=0
TOTAL=0
FAILURES=""

pass() {
  TOTAL=$((TOTAL + 1))
  PASSED=$((PASSED + 1))
  echo "  PASS: $1"
}

fail() {
  TOTAL=$((TOTAL + 1))
  FAILED=$((FAILED + 1))
  echo "  FAIL: $1 — $2"
  FAILURES="${FAILURES}\n  - $1: $2"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc" "expected '$expected', got '$actual'"
  fi
}

assert_match() {
  local desc="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    pass "$desc"
  else
    fail "$desc" "'$actual' does not match /$pattern/"
  fi
}

assert_no_match() {
  local desc="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    fail "$desc" "'$actual' unexpectedly matches /$pattern/"
  else
    pass "$desc"
  fi
}

assert_exit_code() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" -eq "$actual" ]; then
    pass "$desc"
  else
    fail "$desc" "expected exit code $expected, got $actual"
  fi
}

echo "========================================="
echo "  Fluid Intelligence — Unit Tests"
echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "========================================="
echo ""

# =============================================
# SHOPIFY_STORE VALIDATION
# =============================================
echo "--- SHOPIFY_STORE validation ---"

validate_shopify_store() {
  local val="$1"
  [[ "$val" =~ ^[a-zA-Z0-9._-]+\.myshopify\.com$ ]]
}

# Valid stores
validate_shopify_store "my-store.myshopify.com" && pass "Valid: my-store.myshopify.com" || fail "Valid: my-store.myshopify.com" "rejected valid store"
validate_shopify_store "store123.myshopify.com" && pass "Valid: store123.myshopify.com" || fail "Valid: store123.myshopify.com" "rejected valid store"
validate_shopify_store "my.store.myshopify.com" && pass "Valid: my.store.myshopify.com" || fail "Valid: my.store.myshopify.com" "rejected valid store"

# Invalid stores — injection attempts
validate_shopify_store "store.myshopify.com; rm -rf /" && fail "Injection: semicolon" "accepted injection" || pass "Injection: semicolon rejected"
validate_shopify_store 'store.myshopify.com$(whoami)' && fail "Injection: command sub" "accepted injection" || pass "Injection: command sub rejected"
validate_shopify_store "store.myshopify.com\`id\`" && fail "Injection: backtick" "accepted injection" || pass "Injection: backtick rejected"
validate_shopify_store "" && fail "Empty string" "accepted empty" || pass "Empty string rejected"
validate_shopify_store "notashopifydomain.com" && fail "Wrong domain" "accepted non-myshopify" || pass "Wrong domain rejected"
validate_shopify_store "store.myshopify.com/extra" && fail "Path traversal" "accepted path" || pass "Path traversal rejected"

# =============================================
# MCPGATEWAY_PORT VALIDATION
# =============================================
echo "--- MCPGATEWAY_PORT validation ---"

validate_port() {
  local val="$1"
  [[ "$val" =~ ^[0-9]+$ ]]
}

validate_port "4444" && pass "Valid port: 4444" || fail "Valid port: 4444" "rejected"
validate_port "8080" && pass "Valid port: 8080" || fail "Valid port: 8080" "rejected"
validate_port "abc" && fail "Alpha port: abc" "accepted" || pass "Alpha port rejected"
validate_port "44; rm -rf /" && fail "Injection port" "accepted" || pass "Injection port rejected"
validate_port "" && fail "Empty port" "accepted" || pass "Empty port rejected"

# =============================================
# EXTERNAL_URL VALIDATION
# =============================================
echo "--- EXTERNAL_URL validation ---"

validate_external_url() {
  local val="$1"
  [[ "$val" =~ ^[a-zA-Z0-9._-]+(\.[a-zA-Z0-9._-]+)+$ ]]
}

validate_external_url "junlinleather.com" && pass "Valid URL: junlinleather.com" || fail "Valid URL: junlinleather.com" "rejected"
validate_external_url "my.site.example.com" && pass "Valid URL: subdomains" || fail "Valid URL: subdomains" "rejected"
validate_external_url "singleword" && fail "No TLD: singleword" "accepted" || pass "No TLD rejected"
validate_external_url "evil.com; curl attacker.com" && fail "Injection URL" "accepted" || pass "Injection URL rejected"
validate_external_url 'evil.com$(whoami)' && fail "Command sub URL" "accepted" || pass "Command sub URL rejected"

# =============================================
# TOOL_COUNT NUMERIC GUARD
# =============================================
echo "--- TOOL_COUNT numeric guard ---"

validate_tool_count() {
  local val="$1"
  [[ "$val" =~ ^[0-9]+$ ]]
}

validate_tool_count "42" && pass "Numeric tool count: 42" || fail "Numeric tool count: 42" "rejected"
validate_tool_count "0" && pass "Zero tool count" || fail "Zero tool count" "rejected"
validate_tool_count "not a number" && fail "Non-numeric tool count" "accepted" || pass "Non-numeric tool count rejected"
validate_tool_count '$(rm -rf /)' && fail "Injection tool count" "accepted" || pass "Injection tool count rejected"

# =============================================
# JWT TOKEN GENERATION (mock test)
# =============================================
echo "--- JWT token empty check ---"

check_token() {
  local token="$1"
  [ -n "$token" ]
}

check_token "eyJhbGciOiJIUzI1NiJ9.test" && pass "Non-empty token accepted" || fail "Non-empty token" "rejected"
check_token "" && fail "Empty token accepted" "should reject" || pass "Empty token rejected"

# =============================================
# HTTP STATUS CODE PARSING
# =============================================
echo "--- HTTP status code parsing ---"

# Simulates: response=$(curl -s -w "\n%{http_code}" ...)
# http_code=$(echo "$response" | tail -1)
# body=$(echo "$response" | sed '$d')
parse_curl_response() {
  local response="$1"
  local http_code body
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')
  echo "$http_code|$body"
}

result=$(parse_curl_response '{"ok":true}
200')
assert_eq "Parse 200 response" "200|{\"ok\":true}" "$result"

result=$(parse_curl_response '{"error":"bad"}
400')
assert_eq "Parse 400 response" "400|{\"error\":\"bad\"}" "$result"

# Multi-line body — test that tail -1 gets the last line correctly
multiline_response='{"a":1,
"b":2}
201'
ml_code=$(echo "$multiline_response" | tail -1)
ml_body=$(echo "$multiline_response" | sed '$d')
assert_eq "Parse multi-line body status" "201" "$ml_code"
assert_match "Parse multi-line body content" '"a":1' "$ml_body"

# Empty body
result=$(parse_curl_response '
500')
http_code=$(echo "$result" | cut -d'|' -f1)
assert_eq "Parse empty body status" "500" "$http_code"

# =============================================
# REGISTER_GATEWAY SUCCESS/FAILURE LOGIC
# =============================================
echo "--- HTTP status range checks ---"

is_success() {
  local code="$1"
  [ "$code" -ge 200 ] && [ "$code" -lt 300 ]
}

is_success 200 && pass "200 is success" || fail "200 is success" "rejected"
is_success 201 && pass "201 is success" || fail "201 is success" "rejected"
is_success 204 && pass "204 is success" || fail "204 is success" "rejected"
is_success 199 && fail "199 is success" "accepted" || pass "199 is not success"
is_success 300 && fail "300 is success" "accepted" || pass "300 is not success"
is_success 404 && fail "404 is success" "accepted" || pass "404 is not success"
is_success 500 && fail "500 is success" "accepted" || pass "500 is not success"

# =============================================
# TEMP FILE PID ISOLATION
# =============================================
echo "--- PID-suffixed temp files ---"

# Verify $$ produces a numeric PID
assert_match "PID is numeric" "^[0-9]+$" "$$"

# Verify two subshells get different PIDs (tests isolation)
PID1=$(bash -c 'echo $$')
PID2=$(bash -c 'echo $$')
if [ "$PID1" != "$PID2" ]; then
  pass "Subshell PIDs are different"
else
  fail "Subshell PIDs are different" "both got $PID1"
fi

# =============================================
# AUTH CODE REGEX (from test-e2e.sh)
# =============================================
echo "--- Auth code regex extraction ---"

extract_code() {
  echo "$1" | grep -o "code=[^&[:space:]]*" | head -1 | sed 's/code=//'
}

result=$(extract_code "Location: http://localhost:29999/callback?code=abc123&state=xyz")
assert_eq "Extract simple auth code" "abc123" "$result"

result=$(extract_code "Location: http://localhost:29999/callback?code=a1b2-c3d4&state=xyz")
assert_eq "Extract auth code with dash" "a1b2-c3d4" "$result"

result=$(extract_code "Location: http://localhost:29999/callback?state=xyz")
assert_eq "No code parameter" "" "$result"

# Code with special chars should be bounded
result=$(extract_code "Location: http://localhost:29999/callback?code=abc 123&state=xyz")
assert_eq "Code stops at whitespace" "abc" "$result"

# =============================================
# STATE PARAMETER EXTRACTION
# =============================================
echo "--- State parameter extraction ---"

extract_state() {
  echo "$1" | grep -o 'state=[^&[:space:]"]*' | head -1 | sed 's/state=//'
}

result=$(extract_state "Location: http://localhost/callback?code=abc&state=mystate123")
assert_eq "Extract state" "mystate123" "$result"

result=$(extract_state "Location: http://localhost/callback?code=abc")
assert_eq "Missing state" "" "$result"

# =============================================
# JQ SAFE JSON CONSTRUCTION
# =============================================
echo "--- jq safe JSON construction ---"

# Test that jq --arg properly escapes injection attempts
MALICIOUS_NAME='"; curl evil.com #'
payload=$(jq -n --arg n "$MALICIOUS_NAME" --arg u "http://localhost" --arg t "SSE" \
  '{name: $n, url: $u, transport: $t}')
# The name should be a properly escaped JSON string, not shell-interpreted
extracted=$(echo "$payload" | jq -r '.name')
assert_eq "jq escapes injection in name" "$MALICIOUS_NAME" "$extracted"

MALICIOUS_URL='http://localhost"; DROP TABLE gateways; --'
payload=$(jq -n --arg n "test" --arg u "$MALICIOUS_URL" --arg t "SSE" \
  '{name: $n, url: $u, transport: $t}')
extracted=$(echo "$payload" | jq -r '.url')
assert_eq "jq escapes injection in URL" "$MALICIOUS_URL" "$extracted"

# =============================================
# REVIEW ROUND 1: SIGTERM exit code (should be 143, not 0)
# =============================================
echo "--- R1: SIGTERM exit code ---"

# The cleanup trap in entrypoint.sh should exit 143 (128+15) on SIGTERM
# Verify the exit code constant is correct
SIGTERM_EXIT=$((128 + 15))
assert_eq "SIGTERM exit code = 143" "143" "$SIGTERM_EXIT"

# Grep entrypoint.sh for the trap exit code — should be 143, not 0
# Extract the exit code inside the cleanup function
TRAP_EXIT_LINE=$(sed -n '/^cleanup()/,/^}/p' /Users/junlin/Projects/Shopify/fluid-intelligence/scripts/entrypoint.sh | grep '^\s*exit ' | head -1)
# Extract just the number right after "exit "
TRAP_EXIT=$(echo "$TRAP_EXIT_LINE" | sed 's/.*exit \([0-9]*\).*/\1/')
assert_eq "Trap exits with 143 (not 0)" "143" "$TRAP_EXIT"

# =============================================
# REVIEW ROUND 1: BOOTSTRAP_PID removal from PIDS
# =============================================
echo "--- R1: BOOTSTRAP_PID cleanup ---"

# After bootstrap completes, its PID should be removed from PIDS
# Check that entrypoint.sh removes BOOTSTRAP_PID after wait completes
BOOTSTRAP_CLEANUP=$(grep -c 'BOOTSTRAP_PID' /Users/junlin/Projects/Shopify/fluid-intelligence/scripts/entrypoint.sh | head -1)
# After the wait block, there should be a line that removes BOOTSTRAP_PID from PIDS
HAS_PID_REMOVAL=$(grep -c 'PIDS.*BOOTSTRAP_PID' /Users/junlin/Projects/Shopify/fluid-intelligence/scripts/entrypoint.sh 2>/dev/null || echo 0)
# Should have at least one line that filters/removes BOOTSTRAP_PID
# We want: PIDS that are set to exclude BOOTSTRAP_PID AFTER the wait block
REMOVES_BOOTSTRAP=$(sed -n '/wait.*BOOTSTRAP_PID/,/All services/p' /Users/junlin/Projects/Shopify/fluid-intelligence/scripts/entrypoint.sh | grep -c 'PIDS=' || echo "0")
if [ "$REMOVES_BOOTSTRAP" -gt 0 ]; then
  pass "BOOTSTRAP_PID removed from PIDS after completion"
else
  fail "BOOTSTRAP_PID removed from PIDS after completion" "PID stays in PIDS array (kill-0 on dead/reused PID)"
fi

# =============================================
# REVIEW ROUND 1: cleanup waits on tracked PIDs only
# =============================================
echo "--- R1: cleanup waits on tracked PIDs ---"

# The cleanup function should wait on each PID individually, not bare `wait`
CLEANUP_BODY=$(sed -n '/^cleanup()/,/^}/p' /Users/junlin/Projects/Shopify/fluid-intelligence/scripts/entrypoint.sh)
# Check: has `wait "$pid"` (per-PID wait) and NOT bare `wait` without arguments
HAS_PER_PID_WAIT=$(echo "$CLEANUP_BODY" | grep -c 'wait "\$pid"' || true)
HAS_PER_PID_WAIT=${HAS_PER_PID_WAIT:-0}
HAS_BARE_WAIT=$(echo "$CLEANUP_BODY" | grep -cE '^\s+wait\s*$' || true)
HAS_BARE_WAIT=${HAS_BARE_WAIT:-0}
if [ "$HAS_PER_PID_WAIT" -gt 0 ] && [ "$HAS_BARE_WAIT" -eq 0 ]; then
  pass "cleanup() waits per-PID, no bare wait"
else
  fail "cleanup() waits per-PID, no bare wait" "per_pid=$HAS_PER_PID_WAIT, bare=$HAS_BARE_WAIT"
fi

# =============================================
# REVIEW ROUND 4: DB_PASSWORD URL-encoding
# =============================================
echo "--- R4: DB_PASSWORD URL-encoding ---"

# DATABASE_URL should URL-encode DB_PASSWORD to handle special chars
# Check if DATABASE_URL construction includes URL-encoding of DB_PASSWORD
HAS_URL_ENCODE=$(grep -B2 'DATABASE_URL=' /Users/junlin/Projects/Shopify/fluid-intelligence/scripts/entrypoint.sh | grep -c 'urllib.parse.quote\|urlencode\|encoded_pw\|percent_encode' 2>/dev/null || echo 0)
if [ "$HAS_URL_ENCODE" -gt 0 ]; then
  pass "DB_PASSWORD is URL-encoded in DATABASE_URL"
else
  fail "DB_PASSWORD is URL-encoded in DATABASE_URL" "special chars (@, ?, /) in password break connection string"
fi

# Test: password with @ sign would break naive interpolation
TEST_PW='p@ss/word?foo'
# Naive approach (current code):
NAIVE_URL="postgresql://user:${TEST_PW}@/db?host=/cloudsql/test"
# The @ in the password creates ambiguity — URL parser sees "user:p" as credentials and "ss/word?foo" as host
# A properly encoded URL would have %40 instead of @
ENCODED_PW=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${TEST_PW}', safe=''))")
SAFE_URL="postgresql://user:${ENCODED_PW}@/db?host=/cloudsql/test"
assert_match "Encoded password has %40 for @" "%40" "$ENCODED_PW"
assert_no_match "Naive URL has raw @ in password section" "user:p@ss" "$SAFE_URL"

# =============================================
# REVIEW ROUND 4: EXTERNAL_URL double-dot rejection
# =============================================
echo "--- R4: EXTERNAL_URL double-dot rejection ---"

# Current regex: ^[a-zA-Z0-9._-]+(\.[a-zA-Z0-9._-]+)+$
# This allows "foo..bar.com" — should reject consecutive dots
validate_external_url_strict() {
  local val="$1"
  # Each label must start with alphanumeric, no consecutive dots
  [[ "$val" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*(\.[a-zA-Z0-9][a-zA-Z0-9_-]*)+$ ]]
}

# The strict version should reject double dots
validate_external_url_strict "foo..bar.com" && fail "Double dots: foo..bar.com" "accepted" || pass "Double dots: foo..bar.com rejected"
validate_external_url_strict "...com" && fail "Triple dots: ...com" "accepted" || pass "Triple dots rejected"
validate_external_url_strict "junlinleather.com" && pass "Valid: junlinleather.com (strict)" || fail "Valid: junlinleather.com (strict)" "rejected"

# Now test that the CURRENT code in entrypoint.sh uses the strict regex
CURRENT_REGEX=$(grep 'EXTERNAL_URL.*=~' /Users/junlin/Projects/Shopify/fluid-intelligence/scripts/entrypoint.sh | head -1)
if echo "$CURRENT_REGEX" | grep -q '\[a-zA-Z0-9\]\[a-zA-Z0-9'; then
  pass "EXTERNAL_URL regex requires alphanumeric label start"
else
  fail "EXTERNAL_URL regex requires alphanumeric label start" "current regex allows consecutive dots"
fi

# =============================================
# REVIEW ROUND 2: Multiple gateway IDs handling
# =============================================
echo "--- R2: Multiple gateway IDs from jq ---"

# Simulate: jq returns multiple IDs on separate lines
MOCK_GATEWAYS='[{"name":"test","id":"id1"},{"name":"test","id":"id2"}]'
MULTI_IDS=$(echo "$MOCK_GATEWAYS" | jq -r '.[] | select(.name=="test") | .id')
ID_COUNT=$(echo "$MULTI_IDS" | wc -l | tr -d ' ')
if [ "$ID_COUNT" -gt 1 ]; then
  # The current code only deletes one ID — this is the bug
  # Check if bootstrap.sh handles multiple IDs
  HANDLES_MULTI=$(grep -c 'while read' /Users/junlin/Projects/Shopify/fluid-intelligence/scripts/bootstrap.sh 2>/dev/null || echo 0)
  if [ "$HANDLES_MULTI" -gt 0 ]; then
    pass "Bootstrap handles multiple gateway IDs"
  else
    fail "Bootstrap handles multiple gateway IDs" "jq returns $ID_COUNT IDs but only first is deleted"
  fi
else
  fail "Test setup" "expected multiple IDs from jq"
fi

# =============================================
# REVIEW ROUND 3: RETURNED_STATE unbound variable
# =============================================
echo "--- R3: RETURNED_STATE initialization ---"

# test-e2e.sh uses RETURNED_STATE at line 135 but it's only set inside a conditional block
# Under set -uo pipefail, this would cause an unbound variable error
HAS_INIT=$(grep -c 'RETURNED_STATE=""' /Users/junlin/Projects/Shopify/fluid-intelligence/scripts/test-e2e.sh 2>/dev/null || echo 0)
if [ "$HAS_INIT" -gt 0 ]; then
  pass "RETURNED_STATE initialized before conditional use"
else
  # Check if it uses ${RETURNED_STATE:-} syntax
  HAS_DEFAULT=$(grep -c 'RETURNED_STATE:-' /Users/junlin/Projects/Shopify/fluid-intelligence/scripts/test-e2e.sh 2>/dev/null || echo 0)
  if [ "$HAS_DEFAULT" -gt 0 ]; then
    pass "RETURNED_STATE uses default syntax"
  else
    fail "RETURNED_STATE initialized before conditional use" "unbound variable under set -u if auth code block skipped"
  fi
fi

# =============================================
# REVIEW ROUND 6: Missing endCursor in pageInfo
# =============================================
echo "--- R6: endCursor in GraphQL pageInfo ---"

check_endcursor() {
  local file="$1" label="$2"
  if [ ! -f "$file" ]; then
    fail "$label has endCursor" "file not found: $file"
    return
  fi
  if grep -q 'pageInfo' "$file"; then
    if grep -A3 'pageInfo' "$file" | grep -q 'endCursor'; then
      pass "$label has endCursor"
    else
      fail "$label has endCursor" "pageInfo block missing endCursor (cannot paginate)"
    fi
  else
    pass "$label — no pageInfo (no pagination needed)"
  fi
}

check_endcursor "/Users/junlin/Projects/Shopify/fluid-intelligence/graphql/products/GetProducts.graphql" "GetProducts"
check_endcursor "/Users/junlin/Projects/Shopify/fluid-intelligence/graphql/products/GetProduct.graphql" "GetProduct"
check_endcursor "/Users/junlin/Projects/Shopify/fluid-intelligence/graphql/orders/GetOrders.graphql" "GetOrders"
check_endcursor "/Users/junlin/Projects/Shopify/fluid-intelligence/graphql/orders/GetOrder.graphql" "GetOrder"

# =============================================
# REVIEW ROUND 6: CreateProduct wrong variant type
# =============================================
echo "--- R6: CreateProduct variant input type ---"

PROD_FILE="/Users/junlin/Projects/Shopify/fluid-intelligence/graphql/products/CreateProduct.graphql"
if [ -f "$PROD_FILE" ]; then
  if grep -q 'ProductVariantSetInput' "$PROD_FILE"; then
    fail "CreateProduct uses correct variant type" "uses non-existent ProductVariantSetInput (should be ProductSetVariantInput)"
  else
    pass "CreateProduct uses correct variant type"
  fi
else
  fail "CreateProduct exists" "file not found"
fi

# =============================================
# REVIEW ROUND 6: CreateDiscountCode invalid context field
# =============================================
echo "--- R6: CreateDiscountCode context field ---"

DISC_FILE="/Users/junlin/Projects/Shopify/fluid-intelligence/graphql/orders/CreateDiscountCode.graphql"
if [ -f "$DISC_FILE" ]; then
  if grep -q 'context' "$DISC_FILE"; then
    fail "CreateDiscountCode has no invalid context field" "uses non-existent 'context' field (should be customerSelection)"
  else
    pass "CreateDiscountCode has no invalid context field"
  fi
else
  fail "CreateDiscountCode exists" "file not found"
fi

# =============================================
# REVIEW ROUND 7: Bootstrap bridge liveness check
# =============================================
echo "--- R7: Bootstrap bridge liveness checks ---"

# bootstrap.sh should check if bridge processes are alive during wait loops
# Currently it doesn't — if a bridge crashes, it waits the full timeout
# Check for kill -0 in bootstrap wait loops (not in register_gateway which is different)
HAS_LIVENESS=$(grep -c 'kill -0' /Users/junlin/Projects/Shopify/fluid-intelligence/scripts/bootstrap.sh 2>/dev/null || echo 0)
if [ "$HAS_LIVENESS" -gt 0 ]; then
  pass "Bootstrap checks bridge process liveness"
else
  fail "Bootstrap checks bridge process liveness" "no kill -0 or PID checks — crashed bridges waste full timeout"
fi

# =============================================
# SUMMARY
# =============================================
echo ""
echo "========================================="
if [ "$FAILED" -eq 0 ]; then
  echo "  ALL TESTS PASSED: $PASSED/$TOTAL"
else
  echo "  $FAILED FAILURES out of $TOTAL tests"
  printf "  Failures:%b\n" "$FAILURES"
fi
echo "========================================="

exit $(( FAILED > 0 ? 1 : 0 ))
