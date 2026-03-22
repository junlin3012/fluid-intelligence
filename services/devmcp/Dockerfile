# dev-mcp sidecar — Shopify learning layer (docs, schema, query building)
#
# Uses the ContextForge base image because mcpgateway.translate imports from
# mcpgateway.services, mcpgateway.transports, and mcpgateway.config — a
# standalone lightweight Python image is NOT viable.
#
# How it works:
#   mcpgateway.translate spawns @shopify/dev-mcp as a stdio subprocess and
#   bridges stdio ↔ SSE on port 8003. ContextForge connects to the SSE
#   endpoint to discover and route tools.
#
# NOTE: The ContextForge base image (Red Hat UBI 10 Minimal) already installs
#   nodejs + npm via microdnf. We install them explicitly here for correctness
#   and to guard against future base image changes.
#
# TODO: Replace PLACEHOLDER_DIGEST with the verified sha256 digest before
#   promoting to production.
#   Run: docker pull ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2 \
#          && docker inspect --format='{{index .RepoDigests 0}}' \
#               ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2

FROM ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2

USER root

# Install Node.js (required for @shopify/dev-mcp via npx).
# microdnf is the package manager for Red Hat UBI 10 Minimal.
# nodejs may already be present in the base image but installing explicitly
# makes the dependency explicit and guards against upstream removal.
RUN microdnf install -y nodejs npm && microdnf clean all

# Install dev-mcp with a pinned version for reproducible builds.
WORKDIR /sidecar
COPY package.json package-lock.json ./
RUN npm ci --production

# Strip SUID/SGID bits from all system binaries (defence-in-depth).
RUN find / -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

# Run as non-root user matching the ContextForge base image convention.
USER 1001

EXPOSE 8003

# Bridge: translate spawns @shopify/dev-mcp via stdio, serves SSE on port 8003.
# The translate binary lives inside the ContextForge venv already present in
# the base image at /app/.venv/.
# WORKDIR is /sidecar but mcpgateway lives at /app/mcpgateway
ENV PYTHONPATH=/app
CMD ["/app/.venv/bin/python", "-m", "mcpgateway.translate", \
     "--port", "8003", "--host", "0.0.0.0", "--expose-sse", \
     "--stdio", "npx @shopify/dev-mcp"]
