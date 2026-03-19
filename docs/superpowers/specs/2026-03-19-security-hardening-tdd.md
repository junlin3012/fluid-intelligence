# Security Hardening — TDD Specification

**Date**: 2026-03-19
**Source**: OWASP API Security Top 10 audit (2026-03-19)
**Method**: Test-Driven Development — failing tests first, then fixes

---

## Fix 1: Rate Limiting (CRITICAL)

### Failing Tests

```bash
# TEST-RL-1: Token endpoint rate limit (max 10 requests/minute per IP)
# Expected: After 10 rapid requests, subsequent requests return 429 Too Many Requests
for i in $(seq 1 15); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -d "grant_type=authorization_code&code=fake" "$BASE/.idp/token")
  echo "Request $i: HTTP $CODE"
done
# PASS criteria: Requests 11-15 return 429

# TEST-RL-2: Login endpoint rate limit (max 5 attempts/minute per IP)
for i in $(seq 1 8); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -d "password=wrong" "$BASE/.auth/login" -b "$COOKIE_JAR" -c "$COOKIE_JAR")
  echo "Attempt $i: HTTP $CODE"
done
# PASS criteria: Attempts 6-8 return 429

# TEST-RL-3: DCR rate limit (max 5 registrations/minute per IP)
for i in $(seq 1 8); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"redirect_uris":["http://localhost/cb"],"client_name":"test-'$i'"}' \
    "$BASE/.idp/register")
  echo "Registration $i: HTTP $CODE"
done
# PASS criteria: Registrations 6-8 return 429

# TEST-RL-4: MCP endpoint rate limit (max 60 requests/minute per token)
# (Higher limit — legitimate tool calls can be frequent)
for i in $(seq 1 65); do
  curl -s -o /dev/null -X POST -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"ping"}' "$BASE/mcp"
done
# PASS criteria: Requests 61-65 return 429
```

### Implementation

**Where**: auth-proxy Go fork — add `golang.org/x/time/rate` middleware

**Justification for Go approach**: Cloud Armor requires Compute Engine API (not enabled, adds cost). ContextForge has no built-in rate limiter. auth-proxy is the single entry point for ALL traffic — rate limiting here covers all endpoints.

```go
// middleware/ratelimit.go
// Per-IP token bucket rate limiter
// Endpoints: /.idp/token (10/min), /.auth/* (5/min), /.idp/register (5/min), /mcp (60/min)
```

**Config**: Rate limits via environment variables (ContextForge-first postulate: don't hardcode)
```env
RATE_LIMIT_TOKEN=10     # /.idp/token requests per minute per IP
RATE_LIMIT_LOGIN=5      # /.auth/* requests per minute per IP
RATE_LIMIT_DCR=5        # /.idp/register requests per minute per IP
RATE_LIMIT_MCP=60       # /mcp requests per minute per token
```

---

## Fix 2: Password Auth Sub Claim (HIGH)

### Failing Test

```bash
# TEST-SUB-1: Password-auth JWT contains sub claim
TOKEN=$(... acquire token via password auth ...)
SUB=$(echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.sub // "MISSING"')
echo "sub claim: $SUB"
# PASS criteria: sub is NOT "MISSING" — should be "password-user" or the configured admin email
```

### Implementation

**Where**: auth-proxy Go fork — `handlePasswordAuth()` in auth flow

Currently, password auth creates a session but doesn't set the user's email as the subject. The fix: when password auth succeeds, set `JWTClaims.Subject` to the configured `PLATFORM_ADMIN_EMAIL` (since password auth doesn't have a user identifier, use the admin email as the identity).

```go
// In the password auth handler, after validating the password:
session.JWTClaims.Subject = os.Getenv("PLATFORM_ADMIN_EMAIL")
// Fallback if not set:
if session.JWTClaims.Subject == "" {
    session.JWTClaims.Subject = "password-user"
}
```

**Config**: `PLATFORM_ADMIN_EMAIL` already set in cloudbuild.yaml

---

## Fix 3: Disable PKCE Plain Method (MEDIUM)

### Failing Test

```bash
# TEST-PKCE-1: PKCE plain method rejected
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "$BASE/.idp/auth?response_type=code&client_id=$CID&redirect_uri=http://localhost/cb&state=test&code_challenge=plaintext&code_challenge_method=plain")
echo "PKCE plain: HTTP $CODE"
# PASS criteria: Returns 400 (invalid_request), not 302 (redirect)

# TEST-PKCE-2: PKCE S256 still works
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "$BASE/.idp/auth?response_type=code&client_id=$CID&redirect_uri=http://localhost/cb&state=test&code_challenge=$S256_CHALLENGE&code_challenge_method=S256")
echo "PKCE S256: HTTP $CODE"
# PASS criteria: Returns 302 (redirect to login)

# TEST-PKCE-3: OAuth metadata no longer advertises plain
METHODS=$(curl -s "$BASE/.well-known/oauth-authorization-server" | jq -r '.code_challenge_methods_supported[]')
echo "Supported methods: $METHODS"
# PASS criteria: Only "S256", no "plain"
```

### Implementation

**Where**: auth-proxy Go fork — fosite OAuth2 provider config

```go
// In OAuth2 provider setup, configure PKCE:
config.EnforcePKCEForPublicClients = true
// Remove "plain" from supported methods — only allow S256
config.EnablePKCEPlainChallengeMethod = false
```

---

## Fix 4: Token Lifetime 24h → 1h (MEDIUM)

### Failing Test

```bash
# TEST-TTL-1: Token expires_in is ~3600 (1 hour), not 86400 (24 hours)
EXPIRES=$(curl -s -X POST ... "$BASE/.idp/token" | jq '.expires_in')
echo "expires_in: $EXPIRES"
# PASS criteria: expires_in <= 3600
```

### Implementation

**Where**: auth-proxy Go fork — fosite config

```go
config.AccessTokenLifespan = 1 * time.Hour  // was 24 * time.Hour
config.RefreshTokenLifespan = 7 * 24 * time.Hour  // keep refresh tokens longer
```

---

## Fix 5: JWT Audience Claim (MEDIUM)

### Failing Test

```bash
# TEST-AUD-1: JWT contains non-empty audience claim
AUD=$(echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.aud')
echo "aud: $AUD"
# PASS criteria: aud is NOT empty array or null — should be the external URL
```

### Implementation

**Where**: auth-proxy Go fork — fosite token config

```go
// Set audience to the external URL of the gateway
config.TokenURL = externalURL + "/.idp/token"
// In token creation, set audience:
session.JWTClaims.Audience = []string{externalURL}
```

---

## Fix 6: Pydantic Error Suppression (LOW)

### Failing Test

```bash
# TEST-ERR-1: Error responses don't reveal framework name
ERROR_BODY=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"apollo-shopify-execute","arguments":{"invalid_field":true}}}' \
  "$BASE/mcp")
echo "$ERROR_BODY" | grep -i "pydantic" && echo "FAIL: pydantic exposed" || echo "PASS: no framework leak"
# PASS criteria: No mention of "pydantic" in error response
```

### Implementation

**Where**: ContextForge config — check if there's a DEBUG or error verbosity setting

```env
# Try these ContextForge settings:
DEBUG=false
FASTAPI_DEBUG=false
```

**Fallback**: If no config option, add error sanitization via ContextForge's `HTTP_POST_RESPONSE` plugin hook to strip framework references from error responses.

---

## Fix 7: Cookie Secure Flag (LOW)

### Failing Test

```bash
# TEST-COOKIE-1: Session cookie has Secure flag
HEADERS=$(curl -s -D - -o /dev/null "$BASE/.auth/login" -c /dev/null)
echo "$HEADERS" | grep -i 'set-cookie' | grep -i 'secure' && echo "PASS" || echo "FAIL: missing Secure flag"
# PASS criteria: Set-Cookie header contains "Secure"
```

### Implementation

**Where**: auth-proxy Go fork — session cookie config

```go
// In session setup:
store.Options.Secure = true  // Cloud Run provides HTTPS externally
```

---

## Implementation Plan

| Phase | Fixes | Approach | Deploy |
|-------|-------|----------|--------|
| **A: ContextForge config** | Fix 6 (Pydantic) | Config/env var change | Thin deploy |
| **B: Auth-proxy fork v2.5.5** | Fix 1-5, 7 (rate limit, sub, PKCE, TTL, aud, cookie) | Go code changes, new release | Base + thin deploy |

### Phase B: Go Fork Development Workflow

1. Clone fork: `git clone junlin3012/mcp-auth-proxy`
2. Branch: `security-hardening`
3. Write Go tests for each fix
4. Implement fixes
5. `go test ./...`
6. Build: `GOOS=linux GOARCH=amd64 go build -o mcp-auth-proxy-linux-amd64`
7. Create GitHub release: `v2.5.5-security`
8. Compute SHA256 hash
9. Update `Dockerfile.base` with new binary URL + hash
10. Rebuild base image + deploy

### E2E Verification Script Addition

All tests above will be added to `scripts/test-e2e.sh` as a new section:
```bash
# --- 10. Security Hardening Tests ---
echo "--- 10. Security Hardening ---"
# Rate limiting, PKCE, token lifetime, audience, cookie flags
```

---

## Not Fixed (Accepted Tradeoffs)

| Finding | Status | Rationale |
|---------|--------|-----------|
| CSP `unsafe-inline` | Accepted | ContextForge UI disabled (`MCPGATEWAY_UI_ENABLED=false`) — CSP only applies to admin UI pages |
| CSRF on login form | Accepted | `SameSite=Lax` cookie mitigates. Login is a fallback path (Google OAuth is primary) |
| 1.5MB payload accepted | Accepted | No crash, ContextForge handles gracefully. 1MB limit is ContextForge default. |
| GraphQL schema exposed via execute | By design | execute tool IS the product — AI needs schema access to compose queries |
