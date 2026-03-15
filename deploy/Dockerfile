# syntax=docker/dockerfile:1
# Fluid Intelligence — Thin app layer
# Build time: ~5 seconds (just COPY scripts/config onto pre-built base)
# Base image (Dockerfile.base): ContextForge, Apollo, auth-proxy, tini, all system deps

FROM asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence-base:latest

USER root

# Layer ordering: least-changed first → most-changed last (maximizes cache reuse)
# 1. Schema (rarely changes — only on Shopify API version bump)
COPY shopify-schema.graphql /app/shopify-schema.graphql

# 2. Config (changes occasionally)
COPY config/mcp-config.yaml /app/mcp-config.yaml

# 3. GraphQL operations (change moderately)
COPY graphql/ /app/graphql/

# 4. OAuth crypto module (needed by entrypoint.sh to decrypt tokens from Cloud SQL)
COPY services/shopify_oauth/__init__.py /app/services/shopify_oauth/__init__.py
COPY services/shopify_oauth/crypto.py /app/services/shopify_oauth/crypto.py
RUN touch /app/services/__init__.py

# 5. Scripts (change most often during development)
COPY scripts/entrypoint.sh /app/entrypoint.sh
COPY scripts/bootstrap.sh /app/bootstrap.sh

# Set permissions in a single layer (BuildKit COPY --chmod not available in Cloud Build)
RUN chmod 755 /app/entrypoint.sh /app/bootstrap.sh && \
    chown -R root:0 /app/entrypoint.sh /app/bootstrap.sh /app/mcp-config.yaml /app/shopify-schema.graphql /app/graphql/

USER 1001
EXPOSE 8080

# -g: forward signals to the entire process group (reaches grandchild processes
# like npx, uv, apollo spawned by the translate bridges)
ENTRYPOINT ["/usr/local/bin/tini", "-g", "--"]
CMD ["/app/entrypoint.sh"]
