#!/bin/bash
# Unit tests for Fluid Intelligence shell scripts
# Tests validation logic, parsing, and edge cases locally (no deployed service needed)
# Usage: ./scripts/test-unit.sh
set -uo pipefail

# Derive repo root from script location (portable — no hardcoded paths)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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
  # Must match entrypoint.sh production regex exactly: each label starts with alphanumeric, no dots in labels
  [[ "$val" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*(\.[a-zA-Z0-9][a-zA-Z0-9_-]*)+$ ]]
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
is_success 299 && pass "299 is success" || fail "299 is success" "rejected"
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
TRAP_EXIT_LINE=$(sed -n '/^cleanup()/,/^}/p' $REPO_ROOT/scripts/entrypoint.sh | grep '^\s*exit ' | head -1)
# Extract just the number right after "exit "
TRAP_EXIT=$(echo "$TRAP_EXIT_LINE" | sed 's/.*exit \([0-9]*\).*/\1/')
assert_eq "Trap exits with 143 (not 0)" "143" "$TRAP_EXIT"

# =============================================
# REVIEW ROUND 1: BOOTSTRAP_PID removal from PIDS
# =============================================
echo "--- R1: BOOTSTRAP_PID cleanup ---"

# After bootstrap completes, its PID should be removed from PIDS
# Check that entrypoint.sh removes BOOTSTRAP_PID after wait completes
BOOTSTRAP_CLEANUP=$(grep -c 'BOOTSTRAP_PID' $REPO_ROOT/scripts/entrypoint.sh | head -1)
# After the wait block, there should be a line that removes BOOTSTRAP_PID from PIDS
HAS_PID_REMOVAL=$(grep -c 'PIDS.*BOOTSTRAP_PID' $REPO_ROOT/scripts/entrypoint.sh 2>/dev/null || echo 0)
# Should have at least one line that filters/removes BOOTSTRAP_PID
# We want: PIDS that are set to exclude BOOTSTRAP_PID AFTER the wait block
REMOVES_BOOTSTRAP=$(sed -n '/wait.*BOOTSTRAP_PID/,/All services/p' $REPO_ROOT/scripts/entrypoint.sh | grep -c 'PIDS=' || echo "0")
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
CLEANUP_BODY=$(sed -n '/^cleanup()/,/^}/p' $REPO_ROOT/scripts/entrypoint.sh)
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
HAS_URL_ENCODE=$(grep -B2 'DATABASE_URL=' $REPO_ROOT/scripts/entrypoint.sh | grep -c 'urllib.parse.quote\|urlencode\|encoded_pw\|percent_encode' 2>/dev/null || echo 0)
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

# validate_external_url now matches production regex (alphanumeric label start, no dots in labels)
# So it inherently rejects double dots — test using the same function
validate_external_url "foo..bar.com" && fail "Double dots: foo..bar.com" "accepted" || pass "Double dots: foo..bar.com rejected"
validate_external_url "...com" && fail "Triple dots: ...com" "accepted" || pass "Triple dots rejected"
validate_external_url ".leading-dot.com" && fail "Leading dot" "accepted" || pass "Leading dot rejected"
validate_external_url "-leading-hyphen.com" && fail "Leading hyphen" "accepted" || pass "Leading hyphen rejected"

# Now test that the CURRENT code in entrypoint.sh uses the strict regex
CURRENT_REGEX=$(grep 'EXTERNAL_URL.*=~' $REPO_ROOT/scripts/entrypoint.sh | head -1)
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
  HANDLES_MULTI=$(grep -c 'while read' $REPO_ROOT/scripts/bootstrap.sh 2>/dev/null || echo 0)
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
HAS_INIT=$(grep -c 'RETURNED_STATE=""' $REPO_ROOT/scripts/test-e2e.sh 2>/dev/null || echo 0)
if [ "$HAS_INIT" -gt 0 ]; then
  pass "RETURNED_STATE initialized before conditional use"
else
  # Check if it uses ${RETURNED_STATE:-} syntax
  HAS_DEFAULT=$(grep -c 'RETURNED_STATE:-' $REPO_ROOT/scripts/test-e2e.sh 2>/dev/null || echo 0)
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

check_endcursor "$REPO_ROOT/graphql/products/GetProducts.graphql" "GetProducts"
check_endcursor "$REPO_ROOT/graphql/products/GetProduct.graphql" "GetProduct"
check_endcursor "$REPO_ROOT/graphql/orders/GetOrders.graphql" "GetOrders"
check_endcursor "$REPO_ROOT/graphql/orders/GetOrder.graphql" "GetOrder"
check_endcursor "$REPO_ROOT/graphql/orders/CreateDraftOrder.graphql" "CreateDraftOrder"
check_endcursor "$REPO_ROOT/graphql/fulfillments/CreateFulfillment.graphql" "CreateFulfillment"
check_endcursor "$REPO_ROOT/graphql/products/CreateProduct.graphql" "CreateProduct"
check_endcursor "$REPO_ROOT/graphql/orders/CreateDiscountCode.graphql" "CreateDiscountCode"
check_endcursor "$REPO_ROOT/graphql/inventory/GetInventoryLevels.graphql" "GetInventoryLevels"

# =============================================
# REVIEW ROUND 6: CreateProduct wrong variant type
# =============================================
echo "--- R6: CreateProduct variant input type ---"

PROD_FILE="$REPO_ROOT/graphql/products/CreateProduct.graphql"
if [ -f "$PROD_FILE" ]; then
  if grep -q 'ProductVariantSetInput' "$PROD_FILE"; then
    pass "CreateProduct uses correct variant type (ProductVariantSetInput)"
  else
    fail "CreateProduct uses correct variant type" "should use ProductVariantSetInput (not ProductSetVariantInput which doesn't exist)"
  fi
else
  fail "CreateProduct exists" "file not found"
fi

# =============================================
# REVIEW ROUND 6: CreateDiscountCode invalid context field
# =============================================
echo "--- R6: CreateDiscountCode context field ---"

DISC_FILE="$REPO_ROOT/graphql/orders/CreateDiscountCode.graphql"
if [ -f "$DISC_FILE" ]; then
  if grep -q 'customerSelection' "$DISC_FILE"; then
    fail "CreateDiscountCode uses context (not deprecated customerSelection)" "still using deprecated customerSelection"
  else
    pass "CreateDiscountCode uses context (not deprecated customerSelection)"
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
HAS_LIVENESS=$(grep -c 'kill -0' $REPO_ROOT/scripts/bootstrap.sh 2>/dev/null || echo 0)
if [ "$HAS_LIVENESS" -gt 0 ]; then
  pass "Bootstrap checks bridge process liveness"
else
  fail "Bootstrap checks bridge process liveness" "no kill -0 or PID checks — crashed bridges waste full timeout"
fi

# =============================================
# REVIEW ROUND 11: ContextForge health poll --connect-timeout
# =============================================
echo "--- R11: curl --connect-timeout on health poll ---"

# The ContextForge health poll should have --connect-timeout to avoid one hung connect exhausting the 120s budget
CF_HEALTH_CURL=$(grep 'CONTEXTFORGE_PORT.*health' $REPO_ROOT/scripts/entrypoint.sh | head -1)
if echo "$CF_HEALTH_CURL" | grep -q 'connect-timeout'; then
  pass "ContextForge health poll has --connect-timeout"
else
  fail "ContextForge health poll has --connect-timeout" "missing --connect-timeout; one stalled connect can exhaust 120s budget"
fi

# =============================================
# REVIEW ROUND 14: env var validation BEFORE use
# =============================================
echo "--- R14: env var validation ordering ---"

# DB_PASSWORD is used for URL-encoding (python3 line) BEFORE the `: "${DB_PASSWORD:?...}"` check
# The validation should come BEFORE the DATABASE_URL construction
ENTRYPOINT="$REPO_ROOT/scripts/entrypoint.sh"
ENCODE_LINE=$(grep -n 'encoded_pw\|urllib.*DB_PASSWORD' "$ENTRYPOINT" | head -1 | cut -d: -f1)
VALIDATE_LINE=$(grep -n 'DB_PASSWORD:?' "$ENTRYPOINT" | head -1 | cut -d: -f1)
if [ -n "$ENCODE_LINE" ] && [ -n "$VALIDATE_LINE" ]; then
  if [ "$VALIDATE_LINE" -lt "$ENCODE_LINE" ]; then
    pass "DB_PASSWORD validated before use in URL encoding"
  else
    fail "DB_PASSWORD validated before use in URL encoding" "validation at line $VALIDATE_LINE, used at line $ENCODE_LINE"
  fi
else
  fail "DB_PASSWORD validation check" "could not find encode or validate lines"
fi

# =============================================
# REVIEW ROUND 14: Error messages include variable values
# =============================================
echo "--- R14: Error messages include context ---"

# MCPGATEWAY_PORT error should include the actual value
PORT_ERR=$(grep 'MCPGATEWAY_PORT must be numeric' "$ENTRYPOINT")
if echo "$PORT_ERR" | grep -q 'MCPGATEWAY_PORT'; then
  # Check if it includes "got:" or the variable value
  if echo "$PORT_ERR" | grep -qE 'got|MCPGATEWAY_PORT\}'; then
    pass "PORT error includes value"
  else
    fail "PORT error includes value" "error says 'must be numeric' but doesn't show the bad value"
  fi
else
  fail "PORT error exists" "no port validation error found"
fi

# EXTERNAL_URL error should include the actual value
URL_ERR=$(grep 'EXTERNAL_URL contains invalid' "$ENTRYPOINT")
if echo "$URL_ERR" | grep -qE 'got|EXTERNAL_URL'; then
  if echo "$URL_ERR" | grep -qE 'got:?\s*\$'; then
    pass "URL error includes value"
  else
    fail "URL error includes value" "error doesn't show the offending value"
  fi
else
  fail "URL error exists" "no URL validation error found"
fi

# =============================================
# REVIEW ROUND 14: Shopify token failure includes response body
# =============================================
echo "--- R14: Token failure includes body ---"

TOKEN_FATAL=$(sed -n '/attempt.*eq 5/,/exit 1/p' "$ENTRYPOINT")
if echo "$TOKEN_FATAL" | grep -q 'body\|response'; then
  pass "Token failure logs response body"
else
  fail "Token failure logs response body" "only logs HTTP status, not the error body from Shopify"
fi

# =============================================
# REVIEW ROUND 14: Monitor exit tagged as FATAL
# =============================================
echo "--- R14: Monitor exit tagged FATAL ---"

# When a process dies in the monitor loop, the message should be FATAL/ERROR level
MONITOR_MSG=$(grep 'Process.*exited.*code' "$ENTRYPOINT")
if echo "$MONITOR_MSG" | grep -qiE 'FATAL|ERROR'; then
  pass "Monitor exit message tagged as FATAL/ERROR"
else
  fail "Monitor exit message tagged as FATAL/ERROR" "message looks informational but container is about to die"
fi

# =============================================
# REVIEW ROUND 12: Unquoted variables in bootstrap.sh
# =============================================
echo "--- R12: Variable quoting in bootstrap ---"

# $attempt and $max_attempts should be quoted in [ ] test
UNQUOTED_TEST=$(grep 'while \[' $REPO_ROOT/scripts/bootstrap.sh | head -1)
if echo "$UNQUOTED_TEST" | grep -qE '\$attempt\b' && ! echo "$UNQUOTED_TEST" | grep -q '"\$attempt"'; then
  fail "bootstrap while-test quotes variables" "\$attempt unquoted in [ ] test — word splitting risk"
else
  pass "bootstrap while-test quotes variables"
fi

# sleep $attempt should be quoted
UNQUOTED_SLEEP=$(grep 'sleep \$attempt' $REPO_ROOT/scripts/bootstrap.sh | head -1)
if [ -n "$UNQUOTED_SLEEP" ] && ! echo "$UNQUOTED_SLEEP" | grep -q 'sleep "\$'; then
  fail "bootstrap sleep quotes variable" "sleep \$attempt unquoted"
else
  pass "bootstrap sleep quotes variable"
fi

# =============================================
# REVIEW ROUND 18: Dockerfile COPY --chmod
# =============================================
echo "--- R18: Dockerfile permissions ---"

DOCKERFILE="$REPO_ROOT/deploy/Dockerfile"
# Scripts must be made executable (either via COPY --chmod or RUN chmod)
if grep -q 'chmod.*755.*entrypoint' "$DOCKERFILE" || grep -q 'COPY --chmod=755' "$DOCKERFILE"; then
  pass "Dockerfile sets script permissions (chmod 755 or COPY --chmod)"
else
  fail "Dockerfile sets script permissions" "scripts not made executable"
fi

# =============================================
# REVIEW ROUND 18: Dockerfile layer ordering
# =============================================
echo "--- R18: Dockerfile layer ordering ---"

# Scripts (change often) should be copied AFTER schema (change rarely)
SCHEMA_LINE=$(grep -n 'shopify-schema' "$DOCKERFILE" | head -1 | cut -d: -f1)
SCRIPT_LINE=$(grep -n 'entrypoint.sh' "$DOCKERFILE" | head -1 | cut -d: -f1)
if [ -n "$SCHEMA_LINE" ] && [ -n "$SCRIPT_LINE" ]; then
  if [ "$SCHEMA_LINE" -lt "$SCRIPT_LINE" ]; then
    pass "Schema copied before scripts (correct layer order)"
  else
    fail "Schema copied before scripts" "scripts at line $SCRIPT_LINE, schema at line $SCHEMA_LINE"
  fi
else
  fail "Layer ordering check" "could not find COPY lines"
fi

# =============================================
# REVIEW ROUND 16: MCP negative tests in E2E
# =============================================
echo "--- R16: MCP negative tests ---"

E2E="$REPO_ROOT/scripts/test-e2e.sh"
# Should have a test for invalid JSON-RPC method
HAS_INVALID_METHOD=$(grep -cE 'nonexistent|invalid.*method|Method Not Found|-32601' "$E2E" 2>/dev/null) || HAS_INVALID_METHOD=0
if [ "$HAS_INVALID_METHOD" -gt 0 ]; then
  pass "E2E tests invalid JSON-RPC method"
else
  fail "E2E tests invalid JSON-RPC method" "no negative test for unknown MCP method"
fi

# Should have a test for malformed JSON
HAS_MALFORMED_JSON=$(grep -cE 'broken.*json|Parse Error|-32700|malformed' "$E2E" 2>/dev/null) || HAS_MALFORMED_JSON=0
if [ "$HAS_MALFORMED_JSON" -gt 0 ]; then
  pass "E2E tests malformed JSON"
else
  fail "E2E tests malformed JSON" "no negative test for invalid JSON body"
fi

# =============================================
# REVIEW ROUND 21: start_and_verify crash hint
# =============================================
echo "--- R21: start_and_verify crash diagnostics ---"

CRASH_MSG=$(grep -A2 'crashed on startup' "$ENTRYPOINT")
if echo "$CRASH_MSG" | grep -qi 'log\|stderr\|check\|above'; then
  pass "start_and_verify crash message hints at where to look"
else
  fail "start_and_verify crash message hints at where to look" "no hint about checking container logs"
fi

# =============================================
# REVIEW ROUND 21: FIRST_EXIT printed in monitor
# =============================================
echo "--- R21: Monitor prints FIRST_EXIT ---"

MONITOR_SECTION=$(sed -n '/wait -n/,/exit 1$/p' "$ENTRYPOINT")
if echo "$MONITOR_SECTION" | grep -q 'FIRST_EXIT'; then
  # Check it's actually printed, not just captured
  if echo "$MONITOR_SECTION" | grep -q 'echo.*FIRST_EXIT'; then
    pass "Monitor section prints FIRST_EXIT code"
  else
    fail "Monitor section prints FIRST_EXIT code" "FIRST_EXIT captured but never echoed"
  fi
else
  fail "Monitor section prints FIRST_EXIT code" "FIRST_EXIT not referenced in monitor"
fi

# =============================================
# REVIEW ROUND 22: register_gateway FATAL includes context
# =============================================
echo "--- R22: register_gateway FATAL includes HTTP context ---"

BOOTSTRAP="$REPO_ROOT/scripts/bootstrap.sh"
REG_FATAL=$(grep 'FATAL.*Failed to register' "$BOOTSTRAP")
if echo "$REG_FATAL" | grep -qE 'http_code|HTTP|body'; then
  pass "register_gateway FATAL includes HTTP context"
else
  fail "register_gateway FATAL includes HTTP context" "FATAL message doesn't include last HTTP code or body"
fi

# =============================================
# REVIEW ROUND 22: Virtual server failure is FATAL
# =============================================
echo "--- R22: Virtual server creation failure severity ---"

VS_FAIL=$(grep -A1 'Virtual server creation failed' "$BOOTSTRAP")
if echo "$VS_FAIL" | grep -qi 'FATAL'; then
  pass "Virtual server creation failure is FATAL"
else
  fail "Virtual server creation failure is FATAL" "tagged as WARNING but should be FATAL — gateway non-functional without it"
fi

# =============================================
# REVIEW ROUND 23: Predictable temp files
# =============================================
echo "--- R23: Temp file safety ---"

# entrypoint.sh should use mktemp or $$ for temp files
ENTRYPOINT_TEMPS=$(grep -n '/tmp/.*\.log' "$ENTRYPOINT" | grep -v 'rm -f' | head -5)
if echo "$ENTRYPOINT_TEMPS" | grep -qE 'mktemp|\$\$'; then
  pass "entrypoint.sh temp files use mktemp or PID suffix"
else
  fail "entrypoint.sh temp files use mktemp or PID suffix" "predictable temp file names — symlink attack vector"
fi

# =============================================
# REVIEW ROUND 24: mcp_post hides error responses
# =============================================
echo "--- R24: mcp_post error visibility ---"

E2E="$REPO_ROOT/scripts/test-e2e.sh"
MCP_POST_DEF=$(sed -n '/^mcp_post()/,/^}/p' "$E2E")
# Check curl command line (not comments) for -sf or -f flags
if echo "$MCP_POST_DEF" | grep -v '^[[:space:]]*#' | grep -qE 'curl.*-[a-z]*f'; then
  fail "mcp_post does not use -f flag" "curl -f hides HTTP error response bodies"
else
  pass "mcp_post does not use -f flag"
fi

# =============================================
# REVIEW ROUND 24: E2E section numbering
# =============================================
echo "--- R24: E2E section numbering ---"

SECTION_3B_COUNT=$(grep -c 'echo.*3b\.' "$E2E" 2>/dev/null) || SECTION_3B_COUNT=0
if [ "$SECTION_3B_COUNT" -le 1 ]; then
  pass "E2E has no duplicate section numbers"
else
  fail "E2E has no duplicate section numbers" "section '3b' appears $SECTION_3B_COUNT times"
fi

# =============================================
# REVIEW ROUND 28: Tool discovery stabilization
# =============================================
echo "--- R28: Tool discovery waits for stabilization ---"

TOOL_DISCOVERY=$(sed -n '/Verify tools discovered/,/virtual server/p' "$BOOTSTRAP")
if echo "$TOOL_DISCOVERY" | grep -qE 'stable|poll|sleep|prev.*count|for.*seq'; then
  pass "Tool discovery waits for count to stabilize"
else
  fail "Tool discovery waits for count to stabilize" "tools queried once immediately — race with async discovery"
fi

# =============================================
# REVIEW ROUND 30: patterns.md JWT expiry
# =============================================
echo "--- R30: Documentation accuracy ---"

PATTERNS="$REPO_ROOT/docs/agent-behavior/patterns.md"
if [ -f "$PATTERNS" ]; then
  JWT_DOC=$(grep -i 'short.*lived.*min' "$PATTERNS" 2>/dev/null || true)
  if echo "$JWT_DOC" | grep -q '5 min'; then
    fail "patterns.md JWT expiry matches code" "doc says 5 min but bootstrap.sh uses --exp 10"
  else
    pass "patterns.md JWT expiry matches code"
  fi
else
  pass "patterns.md JWT expiry matches code (file not found, skip)"
fi

# =============================================
# REVIEW ROUND 31: mcp-auth-proxy checksum
# =============================================
echo "--- R31: Supply chain security ---"

DOCKERFILE_BASE="$REPO_ROOT/deploy/Dockerfile.base"
if [ -f "$DOCKERFILE_BASE" ]; then
  if grep -q 'mcp-auth-proxy' "$DOCKERFILE_BASE" && grep -q 'sha256sum' "$DOCKERFILE_BASE"; then
    pass "mcp-auth-proxy binary has SHA-256 checksum verification"
  else
    fail "mcp-auth-proxy binary has SHA-256 checksum verification" "downloaded without integrity check"
  fi
else
  pass "mcp-auth-proxy checksum (Dockerfile.base not found, skip)"
fi

# =============================================
# REVIEW ROUND 32: Cloud Run env vars
# =============================================
echo "--- R32: Cloud Run config ---"

CLOUDBUILD="$REPO_ROOT/deploy/cloudbuild.yaml"
if grep -q 'PYTHONUNBUFFERED=1' "$CLOUDBUILD"; then
  pass "PYTHONUNBUFFERED=1 set in Cloud Run env vars"
else
  fail "PYTHONUNBUFFERED=1 set in Cloud Run env vars" "Python log buffering can hide output"
fi

if grep -q 'DB_POOL_SIZE=' "$CLOUDBUILD"; then
  pass "DB_POOL_SIZE explicitly set in Cloud Run env vars"
else
  fail "DB_POOL_SIZE explicitly set in Cloud Run env vars" "default 200 exceeds Cloud SQL db-f1-micro limit of 25"
fi

# =============================================
# REVIEW ROUND 33: SSE casing consistency
# =============================================
echo "--- R33: Documentation consistency ---"

PATTERNS="$REPO_ROOT/docs/agent-behavior/patterns.md"
if [ -f "$PATTERNS" ]; then
  LOWERCASE_SSE=$(grep -c '`sse`' "$PATTERNS" 2>/dev/null) || LOWERCASE_SSE=0
  if [ "$LOWERCASE_SSE" -gt 0 ]; then
    fail "patterns.md uses consistent SSE casing" "lowercase sse found — code uses uppercase SSE"
  else
    pass "patterns.md uses consistent SSE casing"
  fi
else
  pass "patterns.md SSE casing (file not found, skip)"
fi

# =============================================
# REVIEW ROUND 46: All GraphQL connections must have pageInfo
# =============================================
echo "--- R46: Connections have pageInfo ---"

check_connection_has_pageinfo() {
  local file="$1" label="$2"
  if [ ! -f "$file" ]; then
    fail "$label connections have pageInfo" "file not found: $file"
    return
  fi
  # Find edges blocks and check if pageInfo follows within the same connection
  if grep -q 'edges' "$file"; then
    if grep -q 'pageInfo' "$file"; then
      pass "$label connections have pageInfo"
    else
      fail "$label connections have pageInfo" "has edges but no pageInfo"
    fi
  else
    pass "$label — no connections"
  fi
}

check_connection_has_pageinfo "$REPO_ROOT/graphql/orders/CreateDraftOrder.graphql" "CreateDraftOrder"
check_connection_has_pageinfo "$REPO_ROOT/graphql/fulfillments/CreateFulfillment.graphql" "CreateFulfillment"
check_connection_has_pageinfo "$REPO_ROOT/graphql/products/CreateProduct.graphql" "CreateProduct"
check_connection_has_pageinfo "$REPO_ROOT/graphql/orders/CreateDiscountCode.graphql" "CreateDiscountCode"
check_connection_has_pageinfo "$REPO_ROOT/graphql/inventory/GetInventoryLevels.graphql" "GetInventoryLevels"

# =============================================
# REVIEW ROUND 47: Race condition defenses
# =============================================
echo "--- R47: Race condition defenses ---"

# Bash version guard
if grep -q 'BASH_VERSINFO' $REPO_ROOT/scripts/entrypoint.sh; then
  pass "entrypoint.sh has bash version guard"
else
  fail "entrypoint.sh has bash version guard" "no BASH_VERSINFO check found"
fi

# Trap-responsive sleep (sleep & wait pattern)
if grep -A1 'sleep 2' $REPO_ROOT/scripts/entrypoint.sh | grep -q 'wait'; then
  pass "start_and_verify sleep is trap-responsive"
else
  fail "start_and_verify sleep is trap-responsive" "sleep 2 not followed by wait (SIGTERM blocked during sleep)"
fi

# =============================================
# REVIEW ROUND 48: Error handling improvements
# =============================================
echo "--- R48: Error handling ---"

# Bridge processes use venv python
BRIDGE_PYTHON_COUNT=$(grep -c '/app/.venv/bin/python -m mcpgateway.translate' $REPO_ROOT/scripts/entrypoint.sh) || BRIDGE_PYTHON_COUNT=0
if [ "$BRIDGE_PYTHON_COUNT" -eq 3 ]; then
  pass "All 3 bridges use venv python"
else
  fail "All 3 bridges use venv python" "found $BRIDGE_PYTHON_COUNT (expected 3)"
fi

# No bare python3 for mcpgateway.translate
BARE_PYTHON_COUNT=$(grep -cE '^python3 -m mcpgateway' $REPO_ROOT/scripts/entrypoint.sh) || BARE_PYTHON_COUNT=0
if [ "$BARE_PYTHON_COUNT" -eq 0 ]; then
  pass "No bare python3 for mcpgateway.translate"
else
  fail "No bare python3 for mcpgateway.translate" "found $BARE_PYTHON_COUNT bare python3 calls"
fi

# DELETE operations log HTTP status
if grep -q 'DELETE.*gateway' $REPO_ROOT/scripts/bootstrap.sh && \
   grep -q 'WARNING.*DELETE.*gateway' $REPO_ROOT/scripts/bootstrap.sh; then
  pass "bootstrap.sh logs DELETE gateway failures"
else
  fail "bootstrap.sh logs DELETE gateway failures" "DELETE failures silently swallowed"
fi

# gcloud stderr not discarded in test-e2e.sh
if grep -A2 'gcloud secrets' $REPO_ROOT/scripts/test-e2e.sh | grep -q 'gcloud_err\|gcloud error'; then
  pass "test-e2e.sh surfaces gcloud errors"
else
  fail "test-e2e.sh surfaces gcloud errors" "gcloud stderr still discarded"
fi

# =============================================
# REVIEW ROUND 49: curl pattern hardening
# =============================================
echo "--- R49: curl patterns ---"

# test-e2e.sh should not use 2>&1 on curl calls that capture JSON
E2E_CURL_2REDIR=$(grep -c 'curl.*2>&1' $REPO_ROOT/scripts/test-e2e.sh) || E2E_CURL_2REDIR=0
if [ "$E2E_CURL_2REDIR" -eq 0 ]; then
  pass "test-e2e.sh no curl 2>&1 contamination"
else
  fail "test-e2e.sh no curl 2>&1 contamination" "found $E2E_CURL_2REDIR instances"
fi

# bootstrap.sh all curl calls have --connect-timeout
BOOT_CURL_TOTAL=$(grep -v '^[[:space:]]*#' $REPO_ROOT/scripts/bootstrap.sh | grep -v 'echo\|FATAL' | grep -c 'curl ') || BOOT_CURL_TOTAL=0
BOOT_CURL_TIMEOUT=$(grep -v '^[[:space:]]*#' $REPO_ROOT/scripts/bootstrap.sh | grep -v 'echo\|FATAL' | grep -c 'connect-timeout') || BOOT_CURL_TIMEOUT=0
if [ "$BOOT_CURL_TOTAL" -eq "$BOOT_CURL_TIMEOUT" ]; then
  pass "bootstrap.sh all $BOOT_CURL_TOTAL curl calls have --connect-timeout"
else
  fail "bootstrap.sh all curl calls have --connect-timeout" "$BOOT_CURL_TIMEOUT/$BOOT_CURL_TOTAL have it"
fi

# =============================================
# REVIEW ROUND 50: PID array safety + token guard
# =============================================
echo "--- R50: PID array + token guard ---"

# PIDS cleanup uses exact match (not substring replacement)
if grep -A3 'Remove completed bootstrap' $REPO_ROOT/scripts/entrypoint.sh | grep -q 'for p in'; then
  pass "PIDS cleanup uses exact match loop"
else
  fail "PIDS cleanup uses exact match loop" "still using substring replacement (corrupts PIDs)"
fi

# Post-loop token guard
if grep -q 'SHOPIFY_ACCESS_TOKEN:?' $REPO_ROOT/scripts/entrypoint.sh; then
  pass "SHOPIFY_ACCESS_TOKEN has post-loop guard"
else
  fail "SHOPIFY_ACCESS_TOKEN has post-loop guard" "no guard after token fetch loop"
fi

# =============================================
# REVIEW ROUND 51: JWT secret not leaked via CLI args
# =============================================
echo "--- R51: JWT secret safety ---"

# Neither primary nor fallback JWT generation should pass secrets via --secret $VARIABLE on the CLI
# Both paths should use os.environ inside inline Python
JWT_CLI_LEAK=$(grep -cE '^\s*--secret "\$' scripts/bootstrap.sh) || JWT_CLI_LEAK=0
if [ "$JWT_CLI_LEAK" -eq 0 ]; then
  pass "bootstrap.sh JWT generation passes secrets via env vars only"
else
  fail "bootstrap.sh JWT generation passes secrets via env vars only" "$JWT_CLI_LEAK paths leak secret via CLI arg"
fi

# Both JWT paths use inline Python with os.environ
JWT_ENVIRON_COUNT=$(grep -c "os.environ\['SECRET_KEY'\]" scripts/bootstrap.sh) || JWT_ENVIRON_COUNT=0
if [ "$JWT_ENVIRON_COUNT" -ge 2 ]; then
  pass "Both JWT paths (primary + fallback) use os.environ for secret"
else
  fail "Both JWT paths use os.environ for secret" "found $JWT_ENVIRON_COUNT (expected 2)"
fi

# =============================================
# MIRROR-SHINE D1: Timeout arithmetic
# =============================================
echo "--- D1: Timeout arithmetic ---"

# ContextForge health timeout must be <= 120s (was 180s, exceeds 240s probe budget)
CF_TIMEOUT=$(grep 'CF_HEALTH_TIMEOUT=' scripts/entrypoint.sh | head -1 | sed 's/.*CF_HEALTH_TIMEOUT=//' | grep -o '^[0-9]*') || CF_TIMEOUT=0
if [ "$CF_TIMEOUT" -le 120 ] && [ "$CF_TIMEOUT" -gt 0 ]; then
  pass "ContextForge health timeout ($CF_TIMEOUT s) fits within startup probe budget"
else
  fail "ContextForge health timeout fits within startup probe" "CF_HEALTH_TIMEOUT=$CF_TIMEOUT (must be <= 120)"
fi

# Startup probe allows 240s (48 * 5s). Auth-proxy must start before that.
# Token fetch worst case: 5 * 15s (max_time) + 4 sleeps (2+4+6+8=20s) = 95s
# (No sleep after 5th attempt — it either exits or succeeds)
# Process starts: 4 * 2s = 8s
# ContextForge health: CF_TIMEOUT
# Auth-proxy start: 2s
# Total must be < 240s (startup probe budget)
WORST_CASE=$((95 + 8 + CF_TIMEOUT + 2))
if [ "$WORST_CASE" -lt 240 ]; then
  pass "Worst-case startup (${WORST_CASE}s) fits within 240s probe"
else
  fail "Worst-case startup fits within 240s probe" "${WORST_CASE}s >= 240s"
fi

# Cleanup trap includes temp file removal
if grep -A10 'cleanup()' scripts/entrypoint.sh | grep -q 'shopify-curl-err'; then
  pass "cleanup trap removes orphaned temp files"
else
  fail "cleanup trap removes orphaned temp files" "temp files not cleaned on SIGTERM"
fi

# =============================================
# MIRROR-SHINE D4: Contract compliance
# =============================================
echo "--- D4: Contract compliance ---"

# bootstrap.sh should use parse_http_code (not raw tail -1) for HTTP status extraction
# Exclude the tail -1 inside parse_http_code itself (that's the safe wrapper)
BOOTSTRAP_RAW_TAIL=$(grep 'tail -1' scripts/bootstrap.sh | grep -vc 'parse_http_code\|code=') || BOOTSTRAP_RAW_TAIL=0
if [ "$BOOTSTRAP_RAW_TAIL" -eq 0 ]; then
  pass "bootstrap.sh uses parse_http_code (no raw tail -1)"
else
  fail "bootstrap.sh uses parse_http_code" "$BOOTSTRAP_RAW_TAIL raw tail -1 calls remain"
fi

# parse_http_code helper exists in bootstrap.sh
if grep -q 'parse_http_code()' scripts/bootstrap.sh; then
  pass "bootstrap.sh has parse_http_code helper"
else
  fail "bootstrap.sh has parse_http_code helper" "function not found"
fi

# entrypoint.sh validates http_code is numeric after extraction
if grep -A1 'tail -1' scripts/entrypoint.sh | grep -q '\[0-9\]'; then
  pass "entrypoint.sh validates http_code is numeric"
else
  fail "entrypoint.sh validates http_code is numeric" "no numeric check after tail -1"
fi

# =============================================
# MIRROR-SHINE D2: Failure cascade analysis
# =============================================
echo "--- D2: Failure cascade ---"

# Bootstrap should check ContextForge health before each registration (fast-fail on CF death)
CF_HEALTH_CHECKS=$(grep -c 'check_contextforge' scripts/bootstrap.sh) || CF_HEALTH_CHECKS=0
if [ "$CF_HEALTH_CHECKS" -ge 3 ]; then
  pass "bootstrap.sh checks ContextForge health before each registration ($CF_HEALTH_CHECKS checks)"
else
  fail "bootstrap.sh checks ContextForge health before each registration" "only $CF_HEALTH_CHECKS checks (need >= 3)"
fi

# check_contextforge function exists
if grep -q 'check_contextforge()' scripts/bootstrap.sh; then
  pass "bootstrap.sh has check_contextforge fast-fail function"
else
  fail "bootstrap.sh has check_contextforge fast-fail function" "function not found"
fi

# =============================================
# MIRROR-SHINE D3: Data flow integrity
# =============================================
echo "--- D3: Data flow integrity ---"

# encoded_pw must be guarded against empty result
if grep -A3 'encoded_pw=' scripts/entrypoint.sh | grep -q 'FATAL.*empty'; then
  pass "entrypoint.sh guards against empty encoded_pw"
else
  fail "entrypoint.sh guards against empty encoded_pw" "empty password produces password-less DATABASE_URL"
fi

# Shopify token request uses --data-urlencode (not raw printf)
if grep -q 'data-urlencode.*client_id' scripts/entrypoint.sh; then
  pass "entrypoint.sh URL-encodes Shopify credentials in token request"
else
  fail "entrypoint.sh URL-encodes Shopify credentials" "raw printf with %s — special chars in client_id/secret break form body"
fi

# =============================================
# MIRROR-SHINE D5: Validation completeness
# =============================================
echo "--- D5: Validation completeness ---"

# VS_ID must be validated after extraction (empty/null = fatal)
if grep -A5 'VS_ID=' scripts/bootstrap.sh | grep -q '"null"'; then
  pass "bootstrap.sh validates VS_ID is not empty/null"
else
  fail "bootstrap.sh validates VS_ID" "no null check after VS_ID extraction"
fi

# GOOGLE_OAUTH env vars validated at startup
if grep -q 'GOOGLE_OAUTH_CLIENT_ID:?' scripts/entrypoint.sh && \
   grep -q 'GOOGLE_OAUTH_CLIENT_SECRET:?' scripts/entrypoint.sh; then
  pass "entrypoint.sh validates GOOGLE_OAUTH env vars"
else
  fail "entrypoint.sh validates GOOGLE_OAUTH env vars" "missing required var check"
fi

# DB_USER and DB_NAME validated as alphanumeric before DATABASE_URL interpolation
if grep -q 'DB_USER.*alphanumeric\|DB_USER.*\[a-zA-Z0-9_\]' scripts/entrypoint.sh; then
  pass "entrypoint.sh validates DB_USER format"
else
  fail "entrypoint.sh validates DB_USER format" "DB_USER interpolated into DATABASE_URL without validation"
fi

# PID file reads validated as numeric before kill
PID_NUMERIC_CHECKS=$(grep -c 'BRIDGE_PID.*\[0-9\]' scripts/bootstrap.sh) || PID_NUMERIC_CHECKS=0
if [ "$PID_NUMERIC_CHECKS" -ge 3 ]; then
  pass "bootstrap.sh validates PID file contents as numeric ($PID_NUMERIC_CHECKS checks)"
else
  fail "bootstrap.sh validates PID file contents as numeric" "only $PID_NUMERIC_CHECKS checks (need 3)"
fi

# JWT token format validated after generation
if grep -q 'JWT.*invalid format\|TOKEN.*header\.payload\.signature' scripts/bootstrap.sh; then
  pass "bootstrap.sh validates JWT token format"
else
  fail "bootstrap.sh validates JWT token format" "no format check after JWT generation"
fi

# Virtual server deletion handles multiple IDs (while read loop)
if grep -A5 'existing_vs' scripts/bootstrap.sh | grep -q 'while read'; then
  pass "bootstrap.sh handles multiple stale virtual server IDs"
else
  fail "bootstrap.sh handles multiple stale virtual server IDs" "single-value assumption"
fi

# =============================================
# MIRROR-SHINE D6: Observability gaps
# =============================================
echo "--- D6: Observability ---"

# register_gateway should log curl errors on failure (not 2>/dev/null)
if grep -A30 'register_gateway()' scripts/bootstrap.sh | grep -q 'curl_err'; then
  pass "register_gateway captures curl stderr for diagnostics"
else
  fail "register_gateway captures curl stderr" "curl errors silently discarded"
fi

# =============================================
# BATCH 7: Mirror polish
# =============================================
echo "--- B7: Mirror polish ---"

# R1: tini uses -g flag for process group signal forwarding
if grep -q 'tini.*-g' deploy/Dockerfile; then
  pass "Dockerfile: tini uses -g flag (signals reach grandchild processes)"
else
  fail "Dockerfile: tini uses -g flag" "grandchild processes orphaned on SIGTERM"
fi

# R5: PID files cleaned at startup (idempotency)
if head -40 scripts/entrypoint.sh | grep -q 'rm.*apollo.pid'; then
  pass "entrypoint.sh cleans stale PID files at startup"
else
  fail "entrypoint.sh cleans stale PID files at startup" "stale PID files from previous run cause false crash detection"
fi

# R5: PID files cleaned in cleanup trap
if grep -A15 'cleanup()' scripts/entrypoint.sh | grep -q 'apollo.pid'; then
  pass "cleanup trap removes PID files on shutdown"
else
  fail "cleanup trap removes PID files on shutdown" "PID files persist after shutdown"
fi

# =============================================
# B7-R6: DB_USER/DB_NAME functional validation
# =============================================
echo "--- B7-R6: DB_USER/DB_NAME validation ---"

validate_db_identifier() {
  local val="$1"
  [[ "$val" =~ ^[a-zA-Z0-9_]+$ ]]
}

validate_db_identifier "contextforge" && pass "DB identifier: alphanumeric" || fail "DB identifier: alphanumeric" "rejected"
validate_db_identifier "my_db_01" && pass "DB identifier: underscores + digits" || fail "DB identifier: underscores + digits" "rejected"
validate_db_identifier "user@host" && fail "DB identifier: @ char" "accepted" || pass "DB identifier rejects @"
validate_db_identifier "db?name" && fail "DB identifier: ? char" "accepted" || pass "DB identifier rejects ?"
validate_db_identifier "db/name" && fail "DB identifier: / char" "accepted" || pass "DB identifier rejects /"
validate_db_identifier "" && fail "DB identifier: empty" "accepted" || pass "DB identifier rejects empty"
validate_db_identifier "name with spaces" && fail "DB identifier: spaces" "accepted" || pass "DB identifier rejects spaces"

# =============================================
# B7-R6: JWT format boundary tests
# =============================================
echo "--- B7-R6: JWT format boundary tests ---"

validate_jwt_format() {
  local val="$1"
  [[ "$val" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]
}

# Valid JWTs
validate_jwt_format "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" \
  && pass "JWT format: valid 3-part token" || fail "JWT format: valid 3-part token" "rejected"
validate_jwt_format "a.b.c" && pass "JWT format: minimal 3-part" || fail "JWT format: minimal 3-part" "rejected"
validate_jwt_format "a-b_c.d-e_f.g-h_i" && pass "JWT format: hyphens and underscores" || fail "JWT format: hyphens and underscores" "rejected"

# Invalid JWTs
validate_jwt_format "only-two.parts" && fail "JWT format: 2 parts" "accepted" || pass "JWT format rejects 2-part token"
validate_jwt_format "four.parts.are.bad" && fail "JWT format: 4 parts" "accepted" || pass "JWT format rejects 4-part token"
validate_jwt_format "has spaces.in.token" && fail "JWT format: spaces" "accepted" || pass "JWT format rejects spaces"
validate_jwt_format "has+plus.in.token" && fail "JWT format: plus sign" "accepted" || pass "JWT format rejects + sign"
validate_jwt_format "" && fail "JWT format: empty" "accepted" || pass "JWT format rejects empty"
validate_jwt_format "WARNING: something
eyJ.eyJ.sig" && fail "JWT format: multiline (Python warning)" "accepted" || pass "JWT format rejects multiline"

# =============================================
# B8: Curl exit code capture consistency
# =============================================
echo "--- B8: Curl exit code capture ---"

# Dev-mcp and sheets wait loops should capture curl exit code in $rc (like Apollo does)
# Previously used bare $? which gets overwritten by the [ ] test
if grep 'curl.*8003.*healthz' scripts/bootstrap.sh | grep -q 'rc=0.*|| rc='; then
  pass "dev-mcp wait captures curl exit code in \$rc"
else
  fail "dev-mcp wait captures curl exit code in \$rc" "uses bare \$? (overwritten by [ ] test)"
fi

if grep 'curl.*8004.*healthz' scripts/bootstrap.sh | grep -q 'rc=0.*|| rc='; then
  pass "sheets wait captures curl exit code in \$rc"
else
  fail "sheets wait captures curl exit code in \$rc" "uses bare \$? (overwritten by [ ] test)"
fi

# register_gateway cleans up temp file on success path (rm before echo)
if grep -B2 'Registered.*via /gateways' scripts/bootstrap.sh | grep -q 'rm -f.*curl_err'; then
  pass "register_gateway cleans temp file on success"
else
  fail "register_gateway cleans temp file on success" "orphaned temp files on success path"
fi

if grep -B2 'already exists (409)' scripts/bootstrap.sh | grep -q 'rm -f.*curl_err'; then
  pass "register_gateway cleans temp file on 409"
else
  fail "register_gateway cleans temp file on 409" "orphaned temp files on 409 path"
fi

# =============================================
# B8-R10: Test portability (no hardcoded paths)
# =============================================
echo "--- B8-R10: Test portability ---"

# Tests should use $REPO_ROOT, not hardcoded absolute paths
# Exclude the self-referencing grep line from the count
HARDCODED_COUNT=$(grep -c '/Users/junlin' scripts/test-unit.sh || true)
# Subtract 1 for this grep line itself
HARDCODED_COUNT=$((HARDCODED_COUNT > 0 ? HARDCODED_COUNT - 1 : 0))
if [ "$HARDCODED_COUNT" -eq 0 ]; then
  pass "No hardcoded absolute paths in test-unit.sh"
else
  fail "No hardcoded absolute paths in test-unit.sh" "$HARDCODED_COUNT hardcoded paths found"
fi

# REPO_ROOT should be defined near the top of the file
if head -10 scripts/test-unit.sh | grep -q 'REPO_ROOT='; then
  pass "REPO_ROOT variable defined for portable paths"
else
  fail "REPO_ROOT variable defined for portable paths" "tests use hardcoded paths"
fi

# B8-R9: register_gateway variables should be local
if grep -A2 'local max_attempts' scripts/bootstrap.sh | grep -q 'payload.*response.*body'; then
  pass "register_gateway declares payload/response/body as local"
else
  fail "register_gateway declares payload/response/body as local" "variables leak to global scope"
fi

# B8-R8: Virtual server creation captures curl stderr
if grep -B3 'CF/servers.*2>' scripts/bootstrap.sh | grep -q 'vs_curl_err'; then
  pass "POST /servers captures curl stderr for diagnostics"
else
  fail "POST /servers captures curl stderr for diagnostics" "curl errors lost with 2>/dev/null"
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
