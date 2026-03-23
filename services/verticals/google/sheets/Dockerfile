# Google Sheets sidecar — Google Sheets access via service account
#
# Uses the ContextForge base image because mcpgateway.translate imports from
# mcpgateway.services, mcpgateway.transports, and mcpgateway.config — a
# standalone lightweight Python image is NOT viable.
#
# How it works:
#   mcpgateway.translate spawns mcp-google-sheets as a stdio subprocess and
#   bridges stdio ↔ SSE on port 8004. ContextForge connects to the SSE
#   endpoint to discover and route tools.
#
# Source: https://github.com/xing5/mcp-google-sheets
# LICENSE: TODO — verify xing5/mcp-google-sheets license is MIT/Apache/BSD
#   before shipping. Check https://github.com/xing5/mcp-google-sheets/blob/main/LICENSE
#
# TODO: Replace PLACEHOLDER_DIGEST with the verified sha256 digest before
#   promoting to production.
#   Run: docker pull ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2 \
#          && docker inspect --format='{{index .RepoDigests 0}}' \
#               ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2

FROM ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2

USER root
WORKDIR /sidecar

COPY requirements.txt ./

# Install mcp-google-sheets into the existing ContextForge venv.
# Translate needs mcpgateway modules so we cannot use a separate venv.
# ContextForge image has no pip — bootstrap it first, then install
RUN /app/.venv/bin/python -m ensurepip --upgrade && \
    /app/.venv/bin/python -m pip install --no-cache-dir -r requirements.txt

# Strip SUID/SGID bits from all system binaries (defence-in-depth).
RUN find / -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

# Run as non-root user matching the ContextForge base image convention.
USER 1001

EXPOSE 8004

# Bridge: translate spawns mcp-google-sheets via stdio, serves SSE on port 8004.
# The translate binary lives inside the ContextForge venv already present in
# the base image at /app/.venv/.
# WORKDIR is /sidecar but mcpgateway lives at /app/mcpgateway
ENV PYTHONPATH=/app
CMD ["/app/.venv/bin/python", "-m", "mcpgateway.translate", \
     "--port", "8004", "--host", "0.0.0.0", "--expose-sse", \
     "--stdio", "/app/.venv/bin/mcp-google-sheets"]
