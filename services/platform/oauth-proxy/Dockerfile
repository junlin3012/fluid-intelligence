# OAuth Proxy — Caddy reverse proxy for Claude.ai bug #82 workaround
#
# Routes /authorize, /token, /register → Keycloak
# Routes everything else → ContextForge
#
# Build:
#   docker build -t oauth-proxy services/platform/oauth-proxy/
#
# Required env vars:
#   KEYCLOAK_URL        — e.g. https://keycloak-apanptkfaq-as.a.run.app
#   CONTEXTFORGE_URL    — e.g. https://contextforge-apanptkfaq-as.a.run.app
#   KEYCLOAK_REALM      — default: fluid
#   PORT                — default: 8080
#
# Remove when: https://github.com/anthropics/claude-ai-mcp/issues/82 is fixed

FROM caddy:2-alpine

COPY Caddyfile /etc/caddy/Caddyfile
