# Fluid Intelligence v3 — ContextForge + mcp-auth-proxy
# Build time: ~60s (uses pre-built base image + ContextForge image)

# Stage 1: Apollo pre-compiled (from base image, rebuilt rarely)
FROM asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence-base:latest AS apollo-base

# Stage 2: mcp-auth-proxy binary (v2.5.4)
FROM alpine:3.20 AS authproxy
ADD https://github.com/sigbit/mcp-auth-proxy/releases/download/v2.5.4/mcp-auth-proxy-linux-amd64 /mcp-auth-proxy
RUN chmod +x /mcp-auth-proxy

# Stage 3: Runtime — based on ContextForge (Red Hat UBI 10 Minimal)
# Preserves Python 3.12 venv at /app/.venv with PATH already set
FROM ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2

USER root

# Install Node.js (for dev-mcp via npx) and curl (for health checks)
RUN microdnf install -y nodejs npm curl && microdnf clean all

# Install uv (for mcp-google-sheets via uvx)
RUN pip install uv

# tini (PID 1 init — not in UBI repos)
ADD https://github.com/krallin/tini/releases/download/v0.19.0/tini-amd64 /usr/local/bin/tini
RUN chmod +x /usr/local/bin/tini

# Copy Apollo binary
COPY --from=apollo-base /usr/local/bin/apollo /usr/local/bin/apollo

# Copy mcp-auth-proxy binary
COPY --from=authproxy /mcp-auth-proxy /usr/local/bin/mcp-auth-proxy

# Copy config and scripts
COPY entrypoint.sh /app/entrypoint.sh
COPY bootstrap.sh /app/bootstrap.sh
COPY mcp-config.yaml /app/mcp-config.yaml
COPY graphql/ /app/graphql/

# Create data directory for mcp-auth-proxy BoltDB
RUN mkdir -p /app/data && chown -R 1001:0 /app/data /app/entrypoint.sh /app/bootstrap.sh

RUN chmod +x /app/entrypoint.sh /app/bootstrap.sh

USER 1001
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/tini", "--"]
CMD ["/app/entrypoint.sh"]
