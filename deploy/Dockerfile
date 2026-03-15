# Fluid Intelligence — Thin app layer
# Build time: ~5 seconds (just COPY scripts/config onto pre-built base)
# Base image (Dockerfile.base): ContextForge, Apollo, auth-proxy, tini, all system deps

FROM asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence-base:latest

USER root

# Layer ordering: least-changed first → most-changed last (maximizes cache reuse)
# 1. Schema (rarely changes — only on Shopify API version bump)
COPY --chmod=644 --chown=root:0 shopify-schema.graphql /app/shopify-schema.graphql

# 2. Config (changes occasionally)
COPY --chmod=644 --chown=root:0 config/mcp-config.yaml /app/mcp-config.yaml

# 3. GraphQL operations (change moderately)
COPY --chown=root:0 graphql/ /app/graphql/

# 4. Scripts (change most often during development)
COPY --chmod=755 --chown=root:0 scripts/entrypoint.sh /app/entrypoint.sh
COPY --chmod=755 --chown=root:0 scripts/bootstrap.sh /app/bootstrap.sh

USER 1001
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/tini", "--"]
CMD ["/app/entrypoint.sh"]
