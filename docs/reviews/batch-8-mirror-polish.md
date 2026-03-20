# Mirror Polish Batch 8 — v4 Design Spec

**Date**: 2026-03-20
**Target**: `docs/specs/2026-03-19-fluid-intelligence-v4-design.md`
**Mode**: Skill-framework review (3 strategic skills)
**Skills**: `hardening-docker-containers-for-production` + `supply-chain-risk-auditor` + `entry-point-analyzer`
**Method**: Brainstorming + Parallel Agents (10) + Systematic Debugging + Cross-Agent Triangulation
**Clean batch counter**: 0/5

## Review Dimensions (10 rounds)

| Round | Dimension | Skill Domain | Status |
|-------|-----------|-------------|--------|
| R1 | Dockerfile CIS benchmark (dev-mcp) | hardening-docker | ISSUE FOUND (1) |
| R2 | Missing container specs (5 containers) | hardening-docker | ISSUE FOUND (4 of 5) |
| R3 | Container runtime security (seccomp, capabilities, /proc) | hardening-docker | ISSUE FOUND (5) |
| R4 | Multi-stage build hygiene (cache, .dockerignore, staleness) | hardening-docker | ISSUE FOUND (5) |
| R5 | Dependency pinning completeness (14 deps audited) | supply-chain | ISSUE FOUND (4 unpinned) |
| R6 | supergateway trust assessment | supply-chain | **ISSUE FOUND (CRITICAL)** |
| R7 | CI/CD pipeline supply chain | supply-chain | ISSUE FOUND (7) |
| R8 | Attack surface map (all external endpoints) | entry-point | ISSUE FOUND (5 HIGH/MEDIUM) |
| R9 | Sidecar escape paths (compromise analysis) | entry-point | ISSUE FOUND (12 paths, 3 CLEAN) |
| R10 | Cloud Run-specific attack surface | entry-point | ISSUE FOUND (5) |

## Fixes Applied to Spec

| # | Severity | Source | Issue | Fix |
|---|----------|--------|-------|-----|
| 1 | **CRITICAL** | R6 | supergateway is unnecessary — v3 already uses `mcpgateway.translate` successfully. Introducing a third-party npm package into the shared trust boundary is a security regression | Replaced all supergateway references with `mcpgateway.translate`. Updated dev-mcp Dockerfile, Google Sheets section, sidecar logging reference, and sidecar isolation model |
| 2 | **HIGH** | R3,R9,R10 | GCP metadata service (169.254.169.254) not mentioned anywhere — all sidecars can steal SA tokens, access Secret Manager, Cloud SQL | Added explicit metadata service documentation to sidecar isolation model with accepted risk rationale |
| 3 | **HIGH** | R3 | `/proc/1/environ` leaks secrets injected via `--set-secrets` as env vars — v3 fix only moved the problem from /proc/cmdline to /proc/environ | Changed secrets management to mandate volume mounts instead of env vars |
| 4 | **HIGH** | R8 | `/metrics/prometheus` endpoint publicly reachable on port 8080 — exposes tool names, request rates, backend health | Added security note requiring JWT auth or disabling external metrics |
| 5 | **HIGH** | R9 | Sidecar-to-sidecar unauthenticated access bypasses all RBAC, rate limiting, audit | Documented explicitly in sidecar isolation model as accepted risk for trusted sidecars |
| 6 | **HIGH** | R7 | No image signing, no SLSA provenance, no post-deploy digest verification | Added cosign + Cloud KMS + SLSA + digest verification to CI/CD pipeline |
| 7 | **HIGH** | R7 | No Cloud Build trigger security — any branch could trigger production deploy | Added branch protection requirements and trigger filtering |
| 8 | **MEDIUM** | R8 | Keycloak ALB path rules: /js/ and /resources/ needed for login pages but not listed. Blocklist vs allowlist not specified | Changed to explicit allowlist with /js/* and /resources/* included |
| 9 | **MEDIUM** | R3 | no-new-privileges not set; SUID binaries in node:22-slim exploitable | Added allowPrivilegeEscalation:false + SUID stripping to container security |
| 10 | **MEDIUM** | R4 | .dockerignore incomplete (8+ paths missing) | Expanded .dockerignore list in spec |
| 11 | **MEDIUM** | R4 | Base image staleness — no rebuild cadence defined for Dockerfile.base | Added weekly scheduled rebuild trigger |

**Plus 13 new open items added.**

## Key Decisions & Rationale

1. **mcpgateway.translate over supergateway**: This is the strongest finding of Batch 8. Three independent agents (R5, R6, R9) flagged supergateway as a supply chain risk. R6 discovered the clincher: v3 *already uses* mcpgateway.translate in production. The spec was proposing to replace a working first-party solution with a riskier third-party one. This violates two design principles ("configure, don't build" and "direct effort toward unsolved problems").

2. **Metadata service as accepted risk**: Three agents independently identified the GCP metadata service as the most dangerous sidecar escape path. Cloud Run cannot restrict per-container metadata access. The only real mitigation is separate Cloud Run services for untrusted code. For trusted sidecars (Apollo + mcpgateway.translate), this is an accepted risk — documented explicitly.

3. **Volume mounts over env vars for secrets**: The v3 /proc fix (commit 08646f3) moved secrets from CLI args to env vars, but both are readable via /proc. Volume mounts are the correct fix — per-container, not in /proc/environ, and Cloud Run supports them natively.

4. **Image signing chain**: Without cosign + SLSA + Binary Authorization, there is no cryptographic guarantee that reviewed code is what runs in production. The CI/CD pipeline now has a complete signing chain from build to deploy.

## Cumulative Protocol Status

| Batch | Fixes | HIGHs | Method |
|-------|-------|-------|--------|
| 1 | 27 | 7 | Freestyle agents |
| 2 | 18 | 1 | Freestyle agents |
| 3 | 5 | 0 | Freestyle adversarial |
| 4 | 5 | 0 | Freestyle regulatory |
| 5 | 1 | 0 | Freestyle consistency |
| 6 | 10 | 0 | Skill-framework (JWT + GCP IAM) |
| 7 | 12 | 5 | Skill-framework (insecure-defaults + oauth2 + oauth2-flaws) |
| 8 | **11** | **7** | **Skill-framework (docker + supply-chain + entry-point)** |

**Fix trend: 27 → 18 → 5 → 5 → 1 → 10 → 12 → 11**

Skill-framework batches (6-8) consistently find 10+ issues that freestyle batches missed. The supergateway→mcpgateway.translate finding alone justifies the redesigned protocol.

**Clean batch counter: 0/5**

## Accumulated Verified-Clean Dimensions

From batches 1-7: Auth (most angles), Container (most angles), RBAC, Supply chain (general), Formal structure, Lessons carry-forward, Operational (DR, upgrades, credentials), Regulatory (GDPR, incident response), GCP IAM (role bindings), JWT (JKU/KID/clock skew/audience), DCR (policy defined), PKCE (method enforcement), OAuth metadata (blocker identified), Token lifecycle (all types), Redirect URI (all forms), Feature flags (corrected)

From batch 8: CIS Docker 4.1/4.3/4.6/4.7/4.9/4.10 (CLEAN), COPY scope (CLEAN), build-time secrets (CLEAN), Cloud Run PID namespace isolation (CLEAN), Cloud Run filesystem isolation (CLEAN), Cloud Run OOM enforcement (CLEAN), Keycloak container spec (CLEAN), Cloud Run service URL (not sensitive — CLEAN), Gateway-to-Keycloak VPC egress (correctly designed — CLEAN), Seccomp profile (Cloud Run gVisor default — CLEAN), npm lockfile integrity mechanism (CLEAN), pip hash verification mechanism (CLEAN)
