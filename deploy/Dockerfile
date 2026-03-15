# Fluid Intelligence — Thin app layer
# Build time: ~5 seconds (just COPY scripts/config onto pre-built base)
# Base image (Dockerfile.base): ContextForge, Apollo, auth-proxy, tini, all system deps

FROM asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence-base:latest

USER root

# Copy ONLY our code — scripts, config, GraphQL operations
COPY scripts/entrypoint.sh /app/entrypoint.sh
COPY scripts/bootstrap.sh /app/bootstrap.sh
COPY config/mcp-config.yaml /app/mcp-config.yaml
COPY shopify-schema.graphql /app/shopify-schema.graphql
COPY graphql/ /app/graphql/

# Scripts/config owned by root (read-only to 1001), only /app/data writable
RUN chmod +x /app/entrypoint.sh /app/bootstrap.sh && \
    chown -R root:0 /app && \
    chmod -R a+r /app && \
    chown -R 1001:0 /app/data

USER 1001
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/tini", "--"]
CMD ["/app/entrypoint.sh"]
