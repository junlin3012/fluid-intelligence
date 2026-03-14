# Codebase Patterns

> Proven patterns specific to this project. Agents should follow these when implementing.

---

## Deployment

- **Platform**: Google Cloud Run (asia-southeast1)
- **Secrets**: All sensitive values in GCP Secret Manager, injected as env vars by Cloud Run
- **Two-layer build**: Base image (Rust compile, ~18 min) + App image (config/code, ~60s)
- **Health checks**: deploy.sh polls `/health` after deploy, rolls back on failure
- **Min instances**: 1 (avoid cold starts), max: 3

## Authentication

- **Dual auth**: API key (Claude Code) + OAuth 2.1 Bearer JWT (Claude.ai)
- **User identity**: Per-user API keys and passphrases, stored in Secret Manager as JSON
- **Roles**: admin (all + admin tools), operator (read + write), viewer (read only)
- **JWT**: RS256 via `jose`, private key in Secret Manager, public key at `/.well-known/jwks.json`

## Logging

- **Format**: JSON structured for Cloud Logging
- **Required fields**: severity, timestamp, component, user (id + role + auth_method + IP), event details
- **Security events**: elevated to WARNING/ERROR severity for admin tool queries

## Process Management

- **Entrypoint**: Single Node.js process manages everything
- **Child processes**: Apollo (Rust binary, HTTP), dev-mcp (Node.js, stdio)
- **Restart policy**: Exponential backoff, max 5 crashes per process
- **Shutdown**: SIGTERM → drain → kill children → exit within 25s

## Testing

- **E2E test script**: `test-oauth.sh` — automated flow testing against live deployment
- **Test before manual**: Always run automated tests before asking the user to test in Claude.ai
- **User feedback on testing**: "any way for you to do this without wasting my time?" → automate everything possible

## Secrets & Keys

- **HMAC and RS256 keys are separate**: `mcp-auth-hmac-key` (auth codes) and `mcp-jwt-signing-key` (JWTs) — rotate independently, compromise of one doesn't compromise the other
- **All secrets in Secret Manager**: never hardcode, never commit, never echo to stdout
- **Key rotation**: generate new key → update secret → deploy → grace period for old key (24h for RS256)

## Scaling

- **max-instances=1 for in-memory state**: if auth state is in-memory (refresh tokens, DCR clients), max-instances must be 1. Document the upgrade path (session affinity → Redis) but don't implement it until needed.
- **Honest scale claims**: state the actual tested scale (2-5 users), not aspirational numbers. Document the upgrade path separately.
