# ContextForge PR #3715 Patches

These Python files are extracted from `ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2`
with PR #3715 changes applied (OAuth JWKS verification for virtual server MCP).

## How to regenerate

1. Extract originals from the IBM image:
   ```
   docker run --rm --entrypoint cat ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2 \
     /app/mcpgateway/transports/streamablehttp_transport.py > patches/streamablehttp_transport.py
   docker run --rm --entrypoint cat ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2 \
     /app/mcpgateway/utils/verify_credentials.py > patches/verify_credentials.py
   ```

2. Apply PR #3715 diff:
   - https://github.com/IBM/mcp-context-forge/pull/3715

## When to remove

When ContextForge >= 1.0.0-GA includes PR #3715, delete these patches
and revert the Dockerfile to use the stock image.

## Files (gitignored — regenerate from steps above)

- `streamablehttp_transport.py` — adds issuer-based routing + `_try_oauth_access_token()`
- `verify_credentials.py` — adds `verify_oauth_access_token()` + OIDC discovery + JWKS cache
