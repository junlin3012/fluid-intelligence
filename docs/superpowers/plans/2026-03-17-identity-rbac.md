# Identity + RBAC Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Forward authenticated user identity from mcp-auth-proxy to ContextForge so every MCP request is attributed to a real user, with team-based RBAC infrastructure set up (enforcement via per-team virtual servers is a follow-up).

**Architecture:** Fork mcp-auth-proxy to add 10 lines that extract `sub` (email) from the validated JWT and set `X-Authenticated-User` header. Configure ContextForge to trust that header via env vars. Bootstrap teams and roles in `bootstrap.sh`.

**Tech Stack:** Go (auth-proxy fork), bash (bootstrap), Cloud Build YAML (env vars), Docker (base image rebuild)

**Spec:** `docs/superpowers/specs/2026-03-17-identity-rbac-design.md`
**POC:** `poc/approach-a-identity-forwarding/` (verified viable)

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `deploy/Dockerfile.base:21-25` | Modify | Point auth-proxy download at forked release |
| `deploy/cloudbuild.yaml:27` | Modify | Add 7 env vars to `--set-env-vars` |
| `scripts/bootstrap.sh` (append) | Modify | Add team/user/role bootstrap after virtual server creation |
| `scripts/entrypoint.sh:57` | Modify | Add security boundary documentation comment (stripping done in auth-proxy Go code, Task 1) |

**External (not in this repo):**

| What | Action | Purpose |
|------|--------|---------|
| `junlin3012/mcp-auth-proxy` (new GitHub repo) | Create | Fork of `sigbit/mcp-auth-proxy` with identity patch |
| `pkg/proxy/proxy.go` (in fork) | Modify | The 10-line identity forwarding patch |

---

## Task 1: Fork and Patch mcp-auth-proxy

**Context:** The upstream `sigbit/mcp-auth-proxy` v2.5.4 validates JWTs but strips them before proxying. We add 10 lines to extract the user email and forward it as a header. The exact patch has already been verified in `poc/approach-a-identity-forwarding/proxy.go.patch`.

**External repo work — done via GitHub + local Go build.**

- [ ] **Step 1: Fork the upstream repo**

```bash
# Fork sigbit/mcp-auth-proxy to junlin3012/mcp-auth-proxy on GitHub
cd ~/Projects/Claude
gh repo fork sigbit/mcp-auth-proxy --clone
cd mcp-auth-proxy
git checkout -b identity-forwarding v2.5.4
```

- [ ] **Step 2: Apply the defense-in-depth header strip**

In `pkg/proxy/proxy.go`, at the top of `handleProxy()` (line 58, right after the function signature), add:

```go
// Defense-in-depth: strip identity header from incoming requests to prevent spoofing.
// Only auth-proxy should set this header, never external clients.
c.Request.Header.Del("X-Authenticated-User")
```

This goes BEFORE JWT validation so that even if validation logic is refactored later, spoofed headers can't leak through.

- [ ] **Step 3: Apply the identity forwarding patch**

In `pkg/proxy/proxy.go`, after JWT validation succeeds (after `if err != nil || !token.Valid` block, before `httpStreamingOnly` check), add:

```go
// Extract user identity from validated JWT and forward to upstream.
// ContextForge consumes this via TRUST_PROXY_AUTH + PROXY_USER_HEADER.
if claims, ok := token.Claims.(jwt.MapClaims); ok {
    if sub, ok := claims["sub"].(string); ok && sub != "" {
        c.Request.Header.Set("X-Authenticated-User", sub)
    } else if clientID, ok := claims["client_id"].(string); ok && clientID != "" {
        c.Request.Header.Set("X-Authenticated-User", clientID)
    }
}
```

Reference: `poc/approach-a-identity-forwarding/proxy.go` has the identity forwarding patch (Step 3 only). Step 2 (header strip) must be applied separately — the POC does not include it.

- [ ] **Step 4: Verify the Go code compiles**

```bash
cd ~/Projects/Claude/mcp-auth-proxy
go build ./...
```

Expected: No errors.

- [ ] **Step 5: Cross-compile for linux/amd64**

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o mcp-auth-proxy-linux-amd64 .
```

Expected: Binary `mcp-auth-proxy-linux-amd64` in current directory.

- [ ] **Step 6: Generate SHA-256 checksum**

```bash
sha256sum mcp-auth-proxy-linux-amd64
```

Save the hash — needed for `Dockerfile.base`.

- [ ] **Step 7: Commit and tag**

```bash
git add pkg/proxy/proxy.go
git commit -m "feat: forward X-Authenticated-User from validated JWT sub claim"
git tag v2.5.4-identity
git push origin identity-forwarding --tags
```

- [ ] **Step 8: Create GitHub release with binary**

```bash
gh release create v2.5.4-identity \
  --repo junlin3012/mcp-auth-proxy \
  --title "v2.5.4-identity: Forward user identity header" \
  --notes "Adds X-Authenticated-User header forwarding from JWT sub claim. Based on upstream v2.5.4." \
  mcp-auth-proxy-linux-amd64
```

---

## Task 2: Update Dockerfile.base

**Files:**
- Modify: `deploy/Dockerfile.base:21-25`

- [ ] **Step 1: Update auth-proxy download URL and checksum**

Replace the Stage 2 block in `deploy/Dockerfile.base`:

```dockerfile
# Stage 2: mcp-auth-proxy binary (FORKED — identity forwarding patch)
FROM alpine:3.20 AS authproxy
ADD https://github.com/junlin3012/mcp-auth-proxy/releases/download/v2.5.4-identity/mcp-auth-proxy-linux-amd64 /mcp-auth-proxy
RUN echo "<SHA256_FROM_TASK_1_STEP_6>  /mcp-auth-proxy" | sha256sum -c - && \
    chmod +x /mcp-auth-proxy
```

Replace `<SHA256_FROM_TASK_1_STEP_6>` with the actual hash from Task 1 Step 6.

- [ ] **Step 2: Commit**

```bash
git add deploy/Dockerfile.base
git commit -m "build: use forked mcp-auth-proxy with identity forwarding"
```

---

## Task 3: Add ContextForge Identity Env Vars

**Files:**
- Modify: `deploy/cloudbuild.yaml:27` (the `--set-env-vars` line)

- [ ] **Step 1: Add 7 env vars to cloudbuild.yaml**

Append these to the existing `--set-env-vars` comma-separated list:

```
TRUST_PROXY_AUTH=true,TRUST_PROXY_AUTH_DANGEROUSLY=true,MCP_CLIENT_AUTH_ENABLED=false,PROXY_USER_HEADER=X-Authenticated-User,SSO_AUTO_CREATE_USERS=true,SSO_GOOGLE_ADMIN_DOMAINS=junlinleather.com,AUTH_REQUIRED=true
```

**IMPORTANT:** This changes `AUTH_REQUIRED` from `false` to `true`. Do a precise text replacement — find `AUTH_REQUIRED=false` in the existing line and replace with `AUTH_REQUIRED=true`. Do NOT add a second `AUTH_REQUIRED` entry (duplicates cause undefined behavior in Cloud Run).

**Exact edit:** In the `--set-env-vars` string, replace `AUTH_REQUIRED=false` → `AUTH_REQUIRED=true`, then append these 6 new vars at the end of the comma-separated list:
```
,TRUST_PROXY_AUTH=true,TRUST_PROXY_AUTH_DANGEROUSLY=true,MCP_CLIENT_AUTH_ENABLED=false,PROXY_USER_HEADER=X-Authenticated-User,SSO_AUTO_CREATE_USERS=true,SSO_GOOGLE_ADMIN_DOMAINS=junlinleather.com
```

- [ ] **Step 2: Commit**

```bash
git add deploy/cloudbuild.yaml
git commit -m "ci: add identity + RBAC env vars for ContextForge proxy auth"
```

---

## Task 4: Add Defense-in-Depth Header Stripping to entrypoint.sh

**Files:**
- Modify: `scripts/entrypoint.sh:57` (EXTERNAL_URL validation area)

**Context:** While auth-proxy strips the header internally (Task 1 Step 2), we also validate at the ContextForge boundary. ContextForge's `TRUST_PROXY_AUTH_DANGEROUSLY=true` means it trusts the header unconditionally. Since ContextForge listens on `:4444` (internal only, not exposed to Cloud Run), this is defense-in-depth — if someone ever exposes `:4444` directly, the entrypoint documents that the header is security-sensitive.

- [ ] **Step 1: Add comment documenting the security boundary**

In `entrypoint.sh`, after the env var format validation block (after line 70), add:

```bash
# --- Security: X-Authenticated-User header ---
# auth-proxy (Go) strips this header from incoming requests and only sets it after JWT validation.
# ContextForge trusts it unconditionally (TRUST_PROXY_AUTH_DANGEROUSLY=true).
# Safety: ContextForge on :4444 is NOT exposed to Cloud Run — only auth-proxy on :8080 is.
# If this assumption ever changes, add header validation here.
```

This is documentation, not code. The actual stripping happens in auth-proxy (Task 1).

- [ ] **Step 2: Commit**

```bash
git add scripts/entrypoint.sh
git commit -m "docs: document X-Authenticated-User security boundary in entrypoint"
```

---

## Task 5: Add Team + RBAC Bootstrap

**Files:**
- Modify: `scripts/bootstrap.sh` (append after debug dump, before end of file)

**Context:** ContextForge has built-in team/role APIs. We create two teams (admin, viewer), assign the primary user, and set roles. The POC already has the complete script at `poc/approach-a-identity-forwarding/bootstrap-teams.sh`.

**AUTH_REQUIRED=true compatibility note:** Bootstrap calls ContextForge admin API at `127.0.0.1:4444` (bypassing auth-proxy) using an HMAC JWT signed with `JWT_SECRET_KEY`. With `AUTH_REQUIRED=true`, ContextForge will require auth on these calls. The HMAC JWT should still be accepted (Phase 2 of ContextForge auth pipeline validates JWT against the same secret). If bootstrap starts getting 401s after deployment, this is the first thing to check — temporarily set `AUTH_REQUIRED=false` to isolate.

**JWT expiry warning:** The admin `$TOKEN` is generated at the top of bootstrap.sh with 10-minute expiry. Worst-case, existing registration steps consume ~596s (Apollo 60s + registration retries + dev-mcp 120s + sheets 60s + tool discovery 60s). RBAC runs after all of this. If bootstrap takes worst-case timing, the JWT may expire mid-RBAC. **Mitigation:** Increase JWT expiry from `--exp 10` to `--exp 15` in bootstrap.sh (line 20). This is a separate change from this plan — file a follow-up or apply it here in Step 1.

- [ ] **Step 1: Add helper functions to bootstrap.sh**

After the existing debug dump section (after line 311), append the team/user/role helper functions:

```bash
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

  response=$(curl -s -w "\n%{http_code}" --connect-timeout 2 --max-time 10 -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$CF/teams" 2>/dev/null) || true

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
    team_id=$(curl -sf --connect-timeout 2 --max-time 10 \
      -H "Authorization: Bearer $TOKEN" \
      "$CF/teams" 2>/dev/null | \
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

  response=$(curl -s -w "\n%{http_code}" --connect-timeout 2 --max-time 10 -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$CF/teams/$team_id/members" 2>/dev/null) || true

  http_code=$(parse_http_code "$response")
  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "[bootstrap] Added $email to team (role=$role)"
  elif [ "$http_code" -eq 409 ]; then
    echo "[bootstrap] $email already in team"
  else
    echo "[bootstrap] WARNING: Failed to add $email to team (HTTP $http_code)"
  fi
}

# --- Assign role to user (idempotent) ---
assign_role() {
  local email="$1" role_name="$2" scope="$3" scope_id="${4:-}"
  local payload
  payload=$(jq -n --arg r "$role_name" --arg s "$scope" --arg si "$scope_id" \
    '{role_name: $r, scope: $s, scope_id: (if $si == "" then null else $si end)}')

  response=$(curl -s -w "\n%{http_code}" --connect-timeout 2 --max-time 10 -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$CF/rbac/users/$email/roles" 2>/dev/null) || true

  http_code=$(parse_http_code "$response")
  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "[bootstrap] Assigned role '$role_name' ($scope) to $email"
  elif [ "$http_code" -eq 409 ]; then
    echo "[bootstrap] $email already has role '$role_name'"
  else
    echo "[bootstrap] WARNING: Failed to assign role to $email (HTTP $http_code)"
  fi
}
```

- [ ] **Step 2: Add team setup calls**

Immediately after the helper functions, add:

```bash
# === Team Setup ===
check_contextforge
echo "[bootstrap] Setting up teams and RBAC..."

ADMIN_TEAM_ID=$(create_team "admin" "Full access to all backends")
VIEWER_TEAM_ID=$(create_team "viewer" "Read-only Shopify access")

# === User Assignment ===
if [ -n "$ADMIN_TEAM_ID" ]; then
  add_user_to_team "$ADMIN_TEAM_ID" "ourteam@junlinleather.com" "owner"
fi

# === Role Assignment ===
assign_role "ourteam@junlinleather.com" "platform_admin" "global"

# Example: add a viewer later
# if [ -n "$VIEWER_TEAM_ID" ]; then
#   add_user_to_team "$VIEWER_TEAM_ID" "contractor@example.com" "member"
#   assign_role "contractor@example.com" "viewer" "team" "$VIEWER_TEAM_ID"
# fi

echo "[bootstrap] RBAC setup complete"
```

- [ ] **Step 3: Commit**

```bash
git add scripts/bootstrap.sh
git commit -m "feat: bootstrap team + RBAC setup for identity integration"
```

---

## Task 6: Rebuild Base Image + Deploy

**Context:** Task 1 (fork) must be complete with a GitHub release before this task. Tasks 2-5 must be committed.

- [ ] **Step 1: Rebuild base image (new auth-proxy binary)**

```bash
cd ~/Projects/Shopify/fluid-intelligence
gcloud builds submit --config=deploy/cloudbuild-base.yaml
```

Expected: Build succeeds in ~20 min. New base image pushed to Artifact Registry.

Wait for completion before proceeding.

- [ ] **Step 2: Deploy (thin image with all changes)**

```bash
gcloud builds submit --config=deploy/cloudbuild.yaml
```

Expected: Build + deploy in ~2 min. New Cloud Run revision created.

- [ ] **Step 3: Check Cloud Run logs for startup**

```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="fluid-intelligence" AND severity>=DEFAULT' \
  --project=junlinleather-mcp --limit=50 --format='value(textPayload)' \
  --freshness=5m
```

Look for:
- `[fluid-intelligence] All services running`
- `[bootstrap] RBAC setup complete`
- No `FATAL` messages

---

## Task 7: Verify Identity Flow End-to-End

**Spec success criteria coverage:**
| # | Criterion | Tested here? | Why/Why not |
|---|-----------|-------------|-------------|
| 1 | `GET /tools` returns tools filtered by team | No | Only admin user provisioned — no second user to compare filtered vs full tool lists |
| 2 | Audit trail shows `user_email` | Yes | Steps 3+5 check logs for identity attribution |
| 3 | Non-admin cannot see dev-mcp/sheets tools | No | No viewer user provisioned yet (commented out in bootstrap) |
| 4 | Adding user via admin API changes access without redeploy | No | Requires viewer user + admin API access (blocked by auth-proxy, see R17) |

Criteria #1, #3, #4 require a second user with viewer role. They become testable when the viewer team is activated (uncomment in bootstrap + add a real user). This is a follow-up, not a blocker for the identity integration itself.

- [ ] **Step 1: Connect from Claude Desktop via mcp-remote**

Use Claude Desktop or Claude Code with the gateway URL. The MCP client will:
1. Discover OAuth endpoints
2. Register via DCR (new client_id)
3. Authenticate via Google OAuth
4. Get Bearer token
5. Make MCP requests

- [ ] **Step 2: Make a tool call (e.g., list products)**

Execute any tool through the MCP connection.

- [ ] **Step 3: Check Cloud Run logs for identity attribution**

```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="fluid-intelligence" AND textPayload=~"auth_method|user_email|X-Authenticated"' \
  --project=junlinleather-mcp --limit=20 --format='value(textPayload)' \
  --freshness=10m
```

Look for:
- `auth_method: proxy` (not `anonymous`)
- `user_email: ourteam@junlinleather.com`

**Note:** ContextForge logs to stdout as plain text (`PYTHONUNBUFFERED=1`), which Cloud Run captures as `textPayload`. The regex pattern above assumes ContextForge logs these exact field names. If no results, inspect raw logs first (`--format='value(textPayload)' --limit=20` without the filter) to discover the actual log format, then adjust the filter.

- [ ] **Step 4: Verify RBAC bootstrap worked (via Cloud Run logs)**

**Important:** The admin API (`/teams`, `/audit-trail`) is behind auth-proxy, which only accepts its own RS256 JWTs (from the OAuth flow). You cannot use ContextForge's HMAC JWT to call admin endpoints through the public URL. Instead, verify via bootstrap logs:

```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="fluid-intelligence" AND textPayload=~"bootstrap.*team|bootstrap.*RBAC"' \
  --project=junlinleather-mcp --limit=20 --format='value(textPayload)' \
  --freshness=10m
```

Look for:
- `[bootstrap] Created team 'admin'` (or `already exists`)
- `[bootstrap] Created team 'viewer'` (or `already exists`)
- `[bootstrap] Added ourteam@junlinleather.com to team`
- `[bootstrap] Assigned role 'platform_admin'`
- `[bootstrap] RBAC setup complete`

- [ ] **Step 5: Verify audit trail has user identity (via Cloud Run logs)**

After making a tool call in Step 2, check for identity attribution in the logs:

```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="fluid-intelligence" AND severity>=DEFAULT' \
  --project=junlinleather-mcp --limit=50 --format='value(textPayload)' \
  --freshness=10m | grep -i "user\|auth\|identity\|email"
```

Look for any log entries showing the authenticated user email rather than "anonymous" or missing user fields. The exact log format depends on ContextForge's logging — inspect the raw output first if the grep returns nothing.

---

## Task 8: Update Documentation

**Files:**
- Modify: `docs/architecture.md`
- Modify: `docs/agent-behavior/system-understanding.md`
- Delete: `poc/approach-a-identity-forwarding/` (served its purpose, contains known stdout bug)

- [ ] **Step 1: Update architecture.md**

1. In "Known Limitations" section, mark Issue #12 (Identity Lost at Proxy Boundary) as **RESOLVED** with reference to this spec.
2. In "Phase structure" section, note that identity propagation is Phase 1 (proxy auth, no plugins needed).
3. In auth-proxy launch config, add comment noting the forked version with identity forwarding.

- [ ] **Step 2: Update system-understanding.md**

Add to the "OAuth 2.1 Flow" section:

```
### Identity Forwarding (v2.5.4-identity fork)
- Auth-proxy extracts `sub` (email) from validated JWT
- Sets `X-Authenticated-User` header before proxying
- ContextForge reads header via TRUST_PROXY_AUTH mode
- Audit trail shows user_email for every request
```

- [ ] **Step 3: Delete POC directory**

The POC at `poc/approach-a-identity-forwarding/` has served its purpose. It contains a known stdout capture bug in `bootstrap-teams.sh` that was fixed in Task 5. Delete to prevent confusion:

```bash
rm -rf poc/approach-a-identity-forwarding/
# If poc/ is now empty, remove it too
rmdir poc/ 2>/dev/null || true
```

- [ ] **Step 4: Commit**

```bash
git add docs/architecture.md docs/agent-behavior/system-understanding.md
git rm -r poc/approach-a-identity-forwarding/
git commit -m "docs: update architecture for identity integration (Issue #12 resolved), remove POC"
```

---

## Dependency Graph

```
Task 1 (fork + build + release)
    ↓
Task 2 (Dockerfile.base) ──→ Task 6 Step 1 (rebuild base)
                                  ↓
Task 3 (cloudbuild env vars) ─┐
Task 4 (entrypoint docs) ────┼→ Task 6 Step 2 (deploy)
Task 5 (bootstrap RBAC) ─────┘
                                  ↓
                              Task 7 (verify)
                                  ↓
                              Task 8 (docs + POC cleanup)
```

## Rollback Plan

If the deployment breaks (e.g., `AUTH_REQUIRED=true` causes bootstrap to fail, or the forked auth-proxy crashes):

```bash
# 1. Revert to the previous Cloud Run revision
gcloud run services update-traffic fluid-intelligence \
  --to-revisions=$(gcloud run revisions list --service=fluid-intelligence --region=asia-southeast1 --format='value(metadata.name)' --sort-by='~metadata.creationTimestamp' --limit=2 | tail -1)=100 \
  --region=asia-southeast1

# 2. If needed, revert AUTH_REQUIRED in cloudbuild.yaml and redeploy
# Change AUTH_REQUIRED=true back to AUTH_REQUIRED=false in deploy/cloudbuild.yaml
# Then: gcloud builds submit --config=deploy/cloudbuild.yaml
```

**Dependencies:**
- Only Task 2 depends on Task 1 (needs the release URL and SHA256 hash).
- Tasks 3, 4, 5 are fully independent — they can start immediately, in parallel with Task 1.
- Task 6 Step 1 (base image rebuild) depends on Tasks 1+2. Task 6 Step 2 (deploy) depends on all of 2-5.
- Task 7 depends on Task 6.
- Task 8 depends on Task 7 (verify before documenting). Task 8 should also delete or update the POC directory (`poc/approach-a-identity-forwarding/`) since it contains a known stdout capture bug that was fixed in Task 5.
