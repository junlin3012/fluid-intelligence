# ContextForge with PR #3715 — OAuth JWKS verification for virtual server MCP
#
# Patches IBM's stock image with issuer-based routing so IdP-issued tokens
# (from Keycloak, Authentik, etc.) are verified via OIDC discovery + JWKS.
#
# PR: https://github.com/IBM/mcp-context-forge/pull/3715
# Author: kimsehwan96 (Hayden, ABLY Corp)
# Status: Reviewed by maintainer, awaiting formal approval
#
# What this adds:
#   - _auth_jwt() peeks at token issuer before verification
#   - ContextForge-issued tokens (iss: "mcpgateway") → existing path
#   - IdP-issued tokens → OIDC discovery → JWKS signature verification
#   - Per-server issuer allowlist via oauth_config.authorization_servers
#   - User must exist in ContextForge DB (SSO login first, then MCP access)
#
# Build:
#   docker build -t contextforge-patched services/platform/contextforge/
#
# When to remove this patch:
#   When ContextForge >= 1.0.0-GA includes PR #3715, switch back to stock image.

FROM ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2

# Apply PR #3715 patches — only 2 files modified
COPY patches/streamablehttp_transport.py /app/mcpgateway/transports/streamablehttp_transport.py
COPY patches/verify_credentials.py /app/mcpgateway/utils/verify_credentials.py
