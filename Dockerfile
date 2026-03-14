# Fluid Intelligence v3 — ContextForge + mcp-auth-proxy
# Build time: ~60s (uses pre-built base image + ContextForge image)

# Stage 1: Apollo pre-compiled (from base image, rebuilt rarely)
FROM asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/fluid-intelligence-base:latest AS apollo-base

# Stage 2: mcp-auth-proxy binary (v2.5.4)
FROM alpine:3.20 AS authproxy
ADD https://github.com/sigbit/mcp-auth-proxy/releases/download/v2.5.4/mcp-auth-proxy-linux-amd64 /mcp-auth-proxy
RUN chmod +x /mcp-auth-proxy

# Stage 3: Runtime — based on ContextForge (Red Hat UBI 10 Minimal)
FROM ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2

USER root

# Install runtime dependencies
RUN microdnf install -y nodejs npm curl jq tar gzip && microdnf clean all

# Install uv as standalone binary (avoids venv conflicts)
RUN curl -fsSL https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz \
    | tar -xz --strip-components=1 -C /usr/local/bin

# NOTE: Do NOT run "uv pip install" into the ContextForge venv — it corrupts
# the mcpgateway entry point (ModuleNotFoundError). ContextForge already
# ships psycopg2 for PostgreSQL support.

# tini (PID 1 init)
RUN curl -fsSL https://github.com/krallin/tini/releases/download/v0.19.0/tini-amd64 \
      -o /usr/local/bin/tini && \
    echo "93dcc18adc78c65a028a84799ecf8ad40c936fdfc5f2a57b1acda5a8117fa82c  /usr/local/bin/tini" | sha256sum -c - && \
    chmod +x /usr/local/bin/tini

# Copy binaries
COPY --from=apollo-base /usr/local/bin/apollo /usr/local/bin/apollo
COPY --from=authproxy /mcp-auth-proxy /usr/local/bin/mcp-auth-proxy

# Copy config and scripts
COPY entrypoint.sh /app/entrypoint.sh
COPY bootstrap.sh /app/bootstrap.sh
COPY mcp-config.yaml /app/mcp-config.yaml
COPY graphql/ /app/graphql/

# Create data directory and set ownership for all app files
RUN mkdir -p /app/data && chown -R 1001:0 /app
RUN chmod +x /app/entrypoint.sh /app/bootstrap.sh

# Verify ContextForge venv is intact (catches Dockerfile regressions at build time)
RUN /app/.venv/bin/python -c "from mcpgateway.cli import main; print('✓ mcpgateway entry point OK')"
RUN /app/.venv/bin/python -c "import psycopg2; print('✓ psycopg2 OK')" || \
    echo "⚠ psycopg2 not found — ContextForge may need it for PostgreSQL"

USER 1001
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/tini", "--"]
CMD ["/app/entrypoint.sh"]
