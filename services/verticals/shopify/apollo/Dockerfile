# Apollo MCP Server sidecar — Shopify GraphQL execution layer
# Builds Apollo MCP Server from source and packages it in a minimal runtime image.
#
# NOTE: Binary name — the compiled binary may be `apollo-mcp-server` or
# `apollo_mcp_server` depending on the Cargo.toml [[bin]] name field.
# Verify with: `cargo metadata --no-deps | jq '.packages[].targets[].name'`
# Update the COPY --from=builder line and CMD below if the name differs.

ARG REPO_URL=https://github.com/apollographql/apollo-mcp-server.git
# v1.10.0 (2026-03-19) — latest release, requires APOLLO_GRAPH_REF (GraphOS)
ARG COMMIT_HASH=babbf011874bc25651ded5b0a358e3a6e74b1936

# ── Stage 1: Build ──────────────────────────────────────────────────────────
FROM rust:1.83-slim AS builder

ARG REPO_URL
ARG COMMIT_HASH

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        pkg-config \
        libssl-dev \
        make \
        perl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone "${REPO_URL}" . \
    && git checkout "${COMMIT_HASH}"

RUN cargo build --release

# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
# TODO: Replace PLACEHOLDER_DIGEST with the verified sha256 digest of
#       debian:bookworm-slim before pinning this image for production.
#       Run: docker pull debian:bookworm-slim && docker inspect --format='{{index .RepoDigests 0}}' debian:bookworm-slim
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        tini \
    && rm -rf /var/lib/apt/lists/*

# Strip SUID/SGID bits from all system binaries (defence-in-depth).
RUN find / -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

# NOTE: Update the source path below if the binary name is apollo_mcp_server
#       (underscore) rather than apollo-mcp-server (hyphen).
COPY --from=builder /build/target/release/apollo-mcp-server /usr/local/bin/apollo-mcp-server

# Copy config + Shopify schema
COPY config.yaml /app/config.yaml
COPY shopify-schema.graphql /app/shopify-schema.graphql

# Run as non-root user (UID 1001, no corresponding /etc/passwd entry needed).
USER 1001

EXPOSE 8000

ENTRYPOINT ["tini", "--"]
# Apollo takes a config file path as its only argument
CMD ["apollo-mcp-server", "/app/config.yaml"]
