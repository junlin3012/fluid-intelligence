# Per-User Identity + RBAC via Forked Auth-Proxy

**Date**: 2026-03-17
**Status**: Proposed
**Author**: Claude + Jun Lin
**Depends on**: Fluid Intelligence v3 (current deployment)

---

## Problem

mcp-auth-proxy authenticates users via OAuth 2.1 (Google login, password fallback) but strips the JWT before proxying to ContextForge. ContextForge sees every request as anonymous. This breaks:

- **Per-user audit trail** — tool calls logged without user identity
- **Per-user tool access** — everyone sees the same 27 tools regardless of role
- **RBAC** — ContextForge's built-in role system is unused

This was identified as Architecture Issue #12 ("Identity Lost at Proxy Boundary") during the design review and confirmed during Live Mode Mirror Polish.

## Solution

**One code change + config.** Fork mcp-auth-proxy, add 10 lines to extract the user email from the validated JWT and forward it as an `X-Authenticated-User` header. Configure ContextForge to consume it.

No changes to Apollo, dev-mcp, google-sheets, or the MCP protocol layer.

---

## Architecture

### Before (anonymous)

```
Client → auth-proxy (validates JWT, strips it) → ContextForge (sees nobody) → backends
```

### After (identity-aware)

```
Client → auth-proxy (validates JWT, extracts sub, sets X-Authenticated-User)
       → ContextForge (resolves user, checks RBAC, logs audit)
       → backends
```

### Component Changes

| Component | Change | Type |
|-----------|--------|------|
| mcp-auth-proxy | +10 lines in `proxy.go` — extract `sub` from JWT, set `X-Authenticated-User` | Code (Go fork) |
| ContextForge | 7 env vars in cloudbuild.yaml | Config |
| bootstrap.sh | Append team/user/role setup (~80 lines) | Script |
| Dockerfile.base | Use forked auth-proxy binary | Build |

### Components NOT changed

Apollo MCP Server, dev-mcp bridge, google-sheets bridge, entrypoint.sh, mcp-config.yaml, OAuth flow, MCP protocol.

---

## Detailed Design

### 1. Auth-Proxy Patch (proxy.go)

After JWT validation succeeds (line 82) and before the Authorization header is stripped (line 85), extract the `sub` claim and set it as a header:

```go
if claims, ok := token.Claims.(jwt.MapClaims); ok {
    if sub, ok := claims["sub"].(string); ok && sub != "" {
        c.Request.Header.Set("X-Authenticated-User", sub)
    } else if clientID, ok := claims["client_id"].(string); ok && clientID != "" {
        c.Request.Header.Set("X-Authenticated-User", clientID)
    }
}
```

**Verified from source**: `sub` claim contains the user's email address. Google OAuth flow in `pkg/auth/google.go` returns `userInfo.Email`, which becomes the JWT `Subject` in `pkg/idp/idp.go:NewJWTSessionWithKey()`.

**Security**: The header is set AFTER JWT validation. Only requests with valid RSA-signed JWTs reach this code. Header injection is impossible because auth-proxy is the only exposed port (8080); ContextForge on 4444 is internal.

**Defense-in-depth**: The patch should also strip any pre-existing `X-Authenticated-User` header from the incoming request BEFORE JWT validation, preventing header passthrough if the validation logic is ever refactored:

```go
// At the top of handleProxy(), before JWT validation:
c.Request.Header.Del("X-Authenticated-User")
```

**Missing identity fallback**: If the JWT has neither `sub` nor `client_id`, the request is proxied without an identity header. ContextForge with `AUTH_REQUIRED=true` and `TRUST_PROXY_AUTH=true` will reject it (no user resolved → 401). This is the correct behavior — a valid JWT without identity claims is unusual and should fail loudly.

### 2. ContextForge Configuration

New env vars added to `cloudbuild.yaml --set-env-vars`:

| Variable | Value | Purpose |
|----------|-------|---------|
| `TRUST_PROXY_AUTH` | `true` | Enable proxy auth mode |
| `TRUST_PROXY_AUTH_DANGEROUSLY` | `true` | Acknowledge security (safe: same container) |
| `MCP_CLIENT_AUTH_ENABLED` | `false` | Let auth-proxy handle client auth |
| `PROXY_USER_HEADER` | `X-Authenticated-User` | Header name (matches Go patch). Verified configurable in `config.py`, default is `X-Authenticated-User`. |
| `SSO_AUTO_CREATE_USERS` | `true` | Auto-create EmailUser on first request |
| `SSO_GOOGLE_ADMIN_DOMAINS` | `junlinleather.com` | Auto-promote `@junlinleather.com` users to admin. **Security note**: applies to ALL users on this Google Workspace domain, not just `ourteam@`. Acceptable for small trusted team; revisit if domain grows. |
| `AUTH_REQUIRED` | `true` | Require auth on admin API (was `false`). **Breaking change**: any existing automation hitting ContextForge admin endpoints directly will get 401. Currently none exists. |

**How proxy auth activates** (from ContextForge source `verify_credentials.py:is_proxy_auth_trust_active()`):
1. `MCP_CLIENT_AUTH_ENABLED` must be `false`
2. `TRUST_PROXY_AUTH` must be `true`
3. `TRUST_PROXY_AUTH_DANGEROUSLY` must be `true`
4. All three → proxy auth active on ALL endpoints (admin + SSE + MCP)

### 3. Team + RBAC Bootstrap

Appended to `bootstrap.sh` after gateway registration:

**Teams:**
| Team | Description | Backends |
|------|-------------|----------|
| `admin` | Full access | apollo + dev-mcp + sheets |
| `viewer` | Read-only Shopify | apollo (read-only tools only) |

**Initial user assignment:**
| User | Team | Role |
|------|------|------|
| `ourteam@junlinleather.com` | admin | `platform_admin` (global) |

**Adding a new user later** (via admin API or bootstrap config):
```bash
add_user_to_team "$VIEWER_TEAM_ID" "contractor@example.com" "member"
assign_role "contractor@example.com" "viewer" "team" "$VIEWER_TEAM_ID"
```

### 4. Identity Flow (End-to-End)

```
1. Claude Code connects via mcp-remote
2. mcp-auth-proxy handles OAuth PKCE
   → User logs in with Google (ourteam@junlinleather.com)
   → JWT issued with sub=ourteam@junlinleather.com

3. User makes MCP request (e.g., tools/call GetProducts)
   a. auth-proxy validates JWT (RSA signature check) ✓
   b. auth-proxy extracts sub → sets X-Authenticated-User header
   c. auth-proxy strips Authorization header
   d. auth-proxy proxies to ContextForge :4444

4. ContextForge receives request
   a. Reads X-Authenticated-User: ourteam@junlinleather.com
   b. Looks up EmailUser in DB (auto-created if first time)
   c. Resolves team membership + role permissions
   d. Checks RBAC: does user have tools.execute permission? ✓
   e. Token scoping: filters tools by team visibility
   f. Routes to backend (Apollo on :8000)

5. Apollo executes GraphQL against Shopify API
   → Response flows back through ContextForge → auth-proxy → client

6. Audit trail records:
   - user_email: ourteam@junlinleather.com
   - action: EXECUTE
   - resource: tool/GetProducts
   - client_ip, timestamp, correlation_id
```

### 5. Per-Team Tool Access Model

ContextForge's two-layer security:

**Layer 1 — Token Scoping (what you see):**
Controlled by JWT `teams` claim. Since we use proxy auth (no JWT from ContextForge), this defaults to the user's team membership from the database.

**Layer 2 — RBAC (what you can do):**
| Role | Can do |
|------|--------|
| `platform_admin` | Everything — all tools, all backends, admin API |
| `developer` | Execute tools, read resources, no admin |
| `viewer` | Read-only tool execution, no mutations. **Note**: ContextForge RBAC operates at the permission level (`tools.execute`), not per-operation (read vs write). Read-only enforcement for Shopify is achieved by: (a) only registering read-only tools in the viewer team's virtual server, OR (b) setting Apollo `mutation_mode: none` for viewer-scoped requests. Option (a) is simpler — create a separate virtual server with only query tools for the viewer team. |

**Example access matrix:**

| User | Team | Role | Apollo | dev-mcp | sheets |
|------|------|------|--------|---------|--------|
| ourteam@junlinleather.com | admin | platform_admin | ✅ all | ✅ all | ✅ all |
| future-contractor@example.com | viewer | viewer | ✅ read-only | ❌ | ❌ |

---

## Build + Deploy Plan

### Step 1: Fork and patch auth-proxy
1. Fork `sigbit/mcp-auth-proxy` → `junlin3012/mcp-auth-proxy`
2. Apply the 10-line patch to `pkg/proxy/proxy.go`
3. Cross-compile: `GOOS=linux GOARCH=amd64 go build -o mcp-auth-proxy-linux-amd64`
4. Generate SHA-256 checksum
5. Create GitHub release with binary

### Step 2: Update Dockerfile.base
Replace the upstream binary download with the forked release:
```dockerfile
ADD https://github.com/junlin3012/mcp-auth-proxy/releases/download/v2.5.4-identity/mcp-auth-proxy-linux-amd64 /mcp-auth-proxy
RUN echo "<new-sha256>  /mcp-auth-proxy" | sha256sum -c - && chmod +x /mcp-auth-proxy
```

### Step 3: Update cloudbuild.yaml env vars
Add 7 new env vars (see Section 2).

### Step 4: Update bootstrap.sh
Append team/user/role setup (see Section 3).

### Step 5: Rebuild + deploy
1. Rebuild base image (for new auth-proxy binary)
2. Push thin image (config + script changes)
3. Verify via Cloud Run logs:
   - `auth_method: proxy` in auth logs
   - `user_email: ourteam@junlinleather.com` in audit trail
   - `[bootstrap] RBAC setup complete` in bootstrap logs

---

## Risks + Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Fork maintenance burden | Low | Medium | Patch is 10 lines in one function; merge conflicts unlikely |
| Go cross-compile fails on UBI | Low | High | Test binary in Docker before deploying |
| ContextForge auto-create race | Low | Low | Bootstrap runs before user requests; first request creates user if missed |
| Header injection bypass | Very Low | High | auth-proxy is only exposed port; ContextForge on 4444 is internal |
| Upstream mcp-auth-proxy adds identity forwarding natively | Medium | Positive | We can drop the fork and switch back |

---

## Success Criteria

1. `GET /tools` via authenticated MCP session returns tools filtered by user's team
2. Audit trail shows `user_email` for every tool call (not anonymous)
3. A user NOT in the admin team cannot see dev-mcp or sheets tools
4. Adding a new user + team via admin API changes their tool access without redeploying

---

## Corrections to architecture.md

This design supersedes the following sections of `docs/architecture.md`:

1. **V4 Design Directions → Identity Propagation (lines 985-991)**: architecture.md says identity requires `http_auth_resolve_user` plugin (blocked on plugin stability). This is WRONG for our use case. ContextForge's `TRUST_PROXY_AUTH` mode consumes `X-Authenticated-User` without any plugin — it's a built-in auth path (Priority 4 in the auth pipeline, verified from `auth.py` source). The plugin approach is an alternative, not a prerequisite.

2. **Known Limitations #8 (line 783-785)**: "Identity Lost at Proxy Boundary — Elevated to Architecture Issue #12." This spec resolves Issue #12. After implementation, this limitation should be marked as RESOLVED with a reference to this spec.

3. **Phase structure (lines 974-982)**: Phase 1 was blocked because identity propagation "requires plugins." With the proxy auth approach, identity is Phase 1 compatible — no plugins needed.

These corrections should be applied to architecture.md after successful deployment and verification.

---

## Bootstrap Timing

ContextForge's team/role assignment APIs operate on email addresses. If the EmailUser doesn't exist yet, the behavior depends on `SSO_AUTO_CREATE_USERS`:

- When `true`: ContextForge auto-creates the user record when the team assignment API is called with a new email. The bootstrap can assign teams and roles before the user's first login.
- When `false`: Team/role APIs would fail for non-existent users. We set `SSO_AUTO_CREATE_USERS=true` to avoid this.

The bootstrap runs at container start (before any user requests), so teams and roles are ready before any user logs in.

---

## What We're NOT Building

- Custom auth system (using ContextForge's built-in)
- Custom RBAC (using ContextForge's built-in)
- Custom audit trail (using ContextForge's built-in)
- Custom token management (using ContextForge's built-in)
- Identity propagation to backends (not needed — Shopify uses shared token)
- Rate limiting (deferred — use ContextForge plugin when needed)
- Circuit breaker (deferred — use ContextForge plugin when needed)
