# Known Gotchas

> Distilled lessons from v3-v6. Each rule was learned the hard way.
> Raw narratives: `docs/archive/failure-log-raw.md`, `docs/archive/insights-raw.md`

---

## Cloud Run

**FORWARDED_ALLOW_IPS=\* on all sidecars.**
Cloud Run terminates TLS and forwards HTTP internally. Without this, Uvicorn returns `http://` URLs in SSE endpoints, breaking MCP handshake with 30s timeout. Set on devmcp, sheets, apollo.

**Cloud Run gives two URL formats — pick one and use it everywhere.**
New: `*-apanptkfaq-as.a.run.app`. Old: `*-1056128102929.asia-southeast1.run.app`. If OAuth config uses one and the browser uses the other, SSO breaks silently.

**Cloud Run PORT=8080 is immutable.**
Cannot be overridden by `export`. Use `MCG_PORT` for ContextForge, not `PORT`.

**`--no-cpu-throttling` required for background processes.**
Default request-based billing freezes CPU between requests, killing child processes silently.

**Cloud Build iterations are expensive (~$0.50-1.00 each).**
After 2 failed deploys testing the same hypothesis, stop deploying and change strategy. One thorough log read beats five guess-and-check deploys.

## ContextForge

**`MCP_CLIENT_AUTH_ENABLED=false` disables ALL JWT auth.**
Not just MCP clients — also admin panel SSO cookies. Name is misleading.

**`AUTH_REQUIRED=false` allows anonymous access.**
Both this and MCP_CLIENT_AUTH_ENABLED must be carefully considered together.

**`WORKERS=16` (default) exhausts DB connections.**
16 workers × 200 pool size = 3200 connections. Set `WORKERS=2` and `DB_POOL_SIZE=5` for small instances.

**`MCG_HOST` defaults to `127.0.0.1`.**
Must be `0.0.0.0` in containers. Loopback-only means unreachable from outside.

**Health endpoint is `/health`, not `/healthz`.**

**`ALLOWED_ORIGINS` must include BOTH ContextForge AND Keycloak URLs.**
Missing either causes silent SSO redirect failure. Must use consistent URL format.

**`JWT_ALGORITHM` must match key type.**
Default `RS256` with an HMAC secret = silent JWT validation failure. Set `HS256` when using a symmetric key.

**ContextForge JSON responses may have unescaped newlines.**
Use `json.loads(data, strict=False)` when parsing tool descriptions.

## Keycloak

**SSO user needs `platform_admin` RBAC role, not just `is_admin=true`.**
`SSO_TRUSTED_DOMAINS` sets `is_admin` but the user also needs the `platform_admin` role in `user_roles` table. Without it, admin UI returns 403.

**`SSO_KEYCLOAK_MAP_REALM_ROLES=true` only extracts roles from JWTs.**
You also need role_mappings configured so ContextForge knows which Keycloak role maps to which RBAC role.

**Trust Email must be ON for Google/Microsoft IdPs.**
Otherwise Keycloak asks users to verify their email after IdP login — pointless since Google already verified it.

**Keycloak realm JSON `secret` field must match `SSO_CLIENT_SECRET`.**
Both sides must agree from the start. Mismatch = silent auth failure.

## Apollo

**Apollo v1.10.0 dropped SSE transport.**
Only `streamable_http` or `stdio`. Config must use `type: streamable_http`.

**Apollo rejects unknown Host headers (DNS rebinding protection).**
Must add Cloud Run hostnames to `host_validation.allowed_hosts` in config.yaml.

**Apollo file-loading silently drops valid queries.**
Use `introspection.execute.enabled: true` instead of predefined `.graphql` files. The execute tool is more powerful — AI composes queries dynamically.

## Database

**Cloud SQL `db-f1-micro` default `max_connections` is 25.**
With ContextForge (pool 5+5) and Keycloak (pool 2-5) sharing one instance, bump to 50 minimum.

## Process

**Inventory existing capabilities before designing anything.**
ContextForge already ships OpenTelemetry, rate limiting, circuit breakers, caching, 42 plugins, admin UI. Check what exists before proposing new features.

**Read actual source code / `--help` before writing config.**
Every v3 deployment failure came from config written based on assumptions, not docs. Apollo flags, ContextForge port variables, health endpoints — all were wrong.

**Test locally before deploying to Cloud Run.**
Every v3-v5 deployment failure could have been caught with `docker-compose up` + browser test.

**When a client reports an error, the bug might be in the client.**
Claude.ai OAuth bug caused us to debug the server side for hours. Search for known client issues first.

## Auth (added 2026-03-25)

**ContextForge only verifies its own JWTs by default.**
Stock 1.0.0-RC-2 rejects any token with `iss != "mcpgateway"`. PR #3715 adds JWKS verification for external IdP tokens. Without it, Keycloak-issued tokens are rejected even when SSO is configured.

**Claude Code crashes on multi-line MCP tool descriptions.**
ContextForge returns tool descriptions with 1000+ chars and newlines. This triggers Anthropic API error: `cache_control cannot be set for empty text blocks`. The tools work (verified via curl), but Claude Code can't use them. This is a Claude Code bug, not ContextForge.

**Claude.ai skips the OAuth authorize step.**
Claude.ai does DCR (201), reads metadata (200), but never redirects the user to `/authorize`. It loops back to the MCP endpoint without a token. This is bug #82 — the OAuth state machine is incomplete. No server-side fix possible.

**Keycloak DCR has multiple policy layers.**
Anonymous DCR requires passing: Trusted Hosts, Allowed Client Scopes, Max Clients, and Protocol Mapper policies. Claude.ai requests `service_account` scope which must be explicitly allowed. Each policy rejects independently — check Keycloak logs for the specific policy name.

**ContextForge listens on port 4444 locally, not 8080.**
Despite `MCG_PORT=8080` being set, the stock image binds to 4444 in Docker. Map `8080:4444` in docker-compose. On Cloud Run, `PORT=8080` is injected by the platform and works correctly.

**Auth-proxy health check must not depend on upstream.**
In multi-container Cloud Run, the ingress container's startup probe runs before sidecars are ready. Auth-proxy must return 200 on `/health` independently, not proxy to the upstream.
