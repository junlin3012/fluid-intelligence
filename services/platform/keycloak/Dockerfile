# syntax=docker/dockerfile:1.7
# ============================================================
# Keycloak 26.1.4 — Optimized build for Fluid Intelligence v6
# ============================================================
# Security posture:
#   - Dangerous features disabled at build time (token-exchange,
#     impersonation, device-flow, CIBA)
#   - SUID/SGID bits stripped from the final image
#   - Runs as non-root UID 1000
#   - Realm JSON baked in for deterministic first-boot import
# ============================================================

# ── Stage 1: Build optimized Keycloak ───────────────────────
FROM quay.io/keycloak/keycloak:26.1.4@sha256:044a457e04987e1fff756be3d2fa325a4ef420fa356b7034ecc9f1b693c32761 AS builder

ENV KC_DB=postgres

# Disable features that increase attack surface
# Keycloak 26.x uses --features-disabled flag (not KC_FEATURES=feature:disabled)
# See: https://github.com/keycloak/keycloak/blob/main/docs/documentation/upgrading/topics/changes/changes-26_0_0.adoc
RUN /opt/keycloak/bin/kc.sh build \
    --features-disabled=token-exchange,impersonation,device-flow,ciba \
    --health-enabled=true

# ── Stage 2: Runtime image ──────────────────────────────────
FROM quay.io/keycloak/keycloak:26.1.4@sha256:044a457e04987e1fff756be3d2fa325a4ef420fa356b7034ecc9f1b693c32761

# Copy the pre-built, optimized Keycloak from the builder stage
COPY --from=builder /opt/keycloak/ /opt/keycloak/

# Bake the realm configuration in for first-boot import
COPY realm-fluid.json /opt/keycloak/data/import/realm-fluid.json

# ── Security hardening ──────────────────────────────────────
# Strip SUID/SGID bits to prevent privilege escalation via
# set-user-ID or set-group-ID executables
USER root
RUN find / -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

# Drop back to non-root user for runtime
USER 1000

EXPOSE 8080

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized", "--import-realm", \
     "--hostname-strict=false", \
     "--http-enabled=true", \
     "--spi-events-listener-jboss-logging-success-level=info"]
