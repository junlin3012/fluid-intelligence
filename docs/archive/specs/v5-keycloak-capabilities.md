# Keycloak 26.x — Admin API Capabilities for v5

> Phase 0 deliverable. Everything configurable post-import via Admin API.
> Source: context7 queries against /keycloak/keycloak (2026-03-21)
> Supplemented by v4 deployment lessons (docs/archive/v4/v4-challenges-for-v5.md)

---

## What CAN Be Imported via Realm JSON

These fields work in `--import-realm` (proven in v4):
- Realm settings (name, enabled, timeouts, brute force, events)
- Clients (clientId, enabled, publicClient, serviceAccountsEnabled, redirectUris)
- Client scopes (protocol mappers, audience mappers, session mappers)
- Identity providers (Google IdP with placeholder credentials)
- Identity provider mappers (google-user-attribute-idp-mapper for email/name)
- Roles (realm roles: gateway-admin, gateway-user, gateway-readonly)
- Default client scopes (defaultDefaultClientScopes, defaultOptionalClientScopes)

## What CANNOT Be Imported (configure via Admin API)

These fields were rejected during v4 realm import:
- `userProfile` → "Unrecognized field"
- `clientProfiles` → executor providers not found during import
- `clientPolicies` → depends on clientProfiles

**All of the below must be configured post-import via REST API.**

---

## Client Policies & PKCE (Admin API)

### Global Profiles (pre-built, always available)

Keycloak ships with global client profiles that include the executors we need:

| Global Profile | Includes | Use For |
|---------------|----------|---------|
| `fapi-1-baseline` | `pkce-enforcer` (S256) | PKCE enforcement |
| `fapi-1-advanced` | Secure response type, confidential client | Advanced security |
| `oauth-2-1` | PKCE + other OAuth 2.1 requirements | Full OAuth 2.1 |

**v5 approach:** Bind the `fapi-1-baseline` global profile to a client policy with `any-client` condition. This gives us PKCE S256 without creating custom profiles.

### Admin API Endpoints

```
GET  /admin/realms/{realm}/client-policies/policies    — list policies
PUT  /admin/realms/{realm}/client-policies/policies    — update policies
GET  /admin/realms/{realm}/client-policies/profiles    — list profiles (includes globals)
PUT  /admin/realms/{realm}/client-policies/profiles    — update profiles
```

### Example: Bind PKCE policy via Admin API

```bash
# Get admin token
TOKEN=$(curl -s -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=admin" -d "password=$PASS" -d "grant_type=password" | jq -r '.access_token')

# Set client policy binding fapi-1-baseline (which includes pkce-enforcer)
curl -X PUT "$KC_URL/admin/realms/fluid/client-policies/policies" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "policies": [{
      "name": "pkce-enforcement",
      "enabled": true,
      "conditions": [{"condition": "any-client", "configuration": {}}],
      "profiles": ["fapi-1-baseline"]
    }]
  }'
```

**This replaces the v4 approach** of creating custom `pkce-s256-profile` with `pkce-enforcer` executor (which failed on import).

---

## MFA / TOTP (Admin API)

### Required Actions API

```
GET  /admin/realms/{realm}/authentication/required-actions              — list all
GET  /admin/realms/{realm}/authentication/required-actions/{alias}      — get one
PUT  /admin/realms/{realm}/authentication/required-actions/{alias}      — update one
```

### Enable TOTP as Default Required Action

```bash
# Get current CONFIGURE_TOTP action
ACTION=$(curl -s "$KC_URL/admin/realms/fluid/authentication/required-actions/CONFIGURE_TOTP" \
  -H "Authorization: Bearer $TOKEN")

# Enable it as default (all new users must set up TOTP)
echo "$ACTION" | jq '.defaultAction = true | .enabled = true' | \
curl -X PUT "$KC_URL/admin/realms/fluid/authentication/required-actions/CONFIGURE_TOTP" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @-
```

### Authentication Flows

MFA can also be configured at the authentication flow level:
```
GET  /admin/realms/{realm}/authentication/flows                    — list flows
GET  /admin/realms/{realm}/authentication/flows/{id}/executions    — list executions
POST /admin/realms/{realm}/authentication/flows/{id}/executions    — add execution
PUT  /admin/realms/{realm}/authentication/executions/{id}          — update execution
```

The `browser` flow can be modified to add OTP as a required step after password.

---

## User Profile (Admin API)

### Endpoint

```
GET  /admin/realms/{realm}/users/profile    — get current profile config
PUT  /admin/realms/{realm}/users/profile    — update profile config
```

### Add tenant_id and roles attributes

```bash
# Get current profile
PROFILE=$(curl -s "$KC_URL/admin/realms/fluid/users/profile" \
  -H "Authorization: Bearer $TOKEN")

# Add custom attributes (merge with existing)
echo "$PROFILE" | jq '.attributes += [
  {
    "name": "tenant_id",
    "displayName": "Tenant ID",
    "permissions": {"view": ["admin"], "edit": ["admin"]},
    "validations": {"length": {"max": 255}}
  },
  {
    "name": "roles",
    "displayName": "Custom Roles",
    "multivalued": true,
    "permissions": {"view": ["admin"], "edit": ["admin"]},
    "validations": {"length": {"max": 255}}
  }
]' | curl -X PUT "$KC_URL/admin/realms/fluid/users/profile" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @-
```

---

## DCR (Dynamic Client Registration)

### Trusted Hosts

DCR is controlled by client registration policies and trusted hosts in Keycloak's client registration settings. The v4 error was "Host not trusted."

```
GET  /admin/realms/{realm}/clients-initial-access    — list initial access tokens
POST /admin/realms/{realm}/clients-initial-access    — create initial access token
```

DCR trusted hosts are configured as part of the realm's client registration policies:
```
GET  /admin/realms/{realm}/client-registration-policy/providers    — list policy providers
```

### Alternative: Use Initial Access Tokens

Instead of open DCR, create an initial access token that must be presented during registration:
```bash
curl -X POST "$KC_URL/admin/realms/fluid/clients-initial-access" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"count": 10, "expiration": 86400}'
```

---

## Token Mappers

### Realm Role Mapper (proven in v4)

Already configured via Admin API in v4. Adds `realm_access.roles` to client_credentials JWTs.

```bash
# Add realm roles protocol mapper to a client
curl -X POST "$KC_URL/admin/realms/fluid/clients/{client-uuid}/protocol-mappers/models" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "realm roles",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-usermodel-realm-role-mapper",
    "config": {
      "multivalued": "true",
      "access.token.claim": "true",
      "claim.name": "realm_access.roles",
      "jsonType.label": "String"
    }
  }'
```

---

## Keycloak 26.x Specific Gotchas (from v4)

| Gotcha | Correct Approach |
|--------|-----------------|
| Feature flags | `--features-disabled=token-exchange,impersonation,device-flow,ciba` as CLI flag to `kc.sh build` |
| Health endpoints | `--health-enabled=true` at BUILD time in Dockerfile |
| Admin bootstrap | `KC_BOOTSTRAP_ADMIN_USERNAME` + `KC_BOOTSTRAP_ADMIN_PASSWORD` env vars |
| Hostname for HTTPS | `KC_HOSTNAME=https://full-url` + `KC_PROXY_HEADERS=xforwarded` |
| Liveness probe | HTTP on `/realms/fluid` (not `/health/live` — may 404 even with health enabled) |
| Cloud SQL (JDBC) | Direct public IP: `jdbc:postgresql://IP:5432/keycloak` (not Unix socket) |
| Realm import | Only core fields (see "What CAN Be Imported" above) |
| `KC_HOSTNAME_STRICT_HTTPS` | Deprecated in 26.x — use `KC_HOSTNAME` instead |
