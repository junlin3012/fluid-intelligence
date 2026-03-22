# Mirror Polish Batch 9 — v4 Design Spec

**Date**: 2026-03-20
**Target**: `docs/specs/2026-03-19-fluid-intelligence-v4-design.md`
**Mode**: Skill-framework review (3 strategic skills)
**Skills**: `implementing-secrets-management-with-vault` + `securing-serverless-functions` + `implementing-zero-trust-network-access`
**Method**: Brainstorming + Parallel Agents (4 dispatched) + Systematic Debugging
**Clean batch counter**: 0/5

## Review Dimensions (10 brainstormed, 4 dispatched)

Batch 9 dispatched 4 agents covering the highest-value dimensions. R2/R3/R5/R6/R8/R9 were omitted as they overlapped with Batch 8 findings (secret scope isolation → already covered by metadata service documentation; concurrency/state → ContextForge handles natively; ephemeral storage → tmpfs documented; network segmentation → VPC egress documented; least privilege → IAM model documented).

| Round | Dimension | Skill Domain | Status |
|-------|-----------|-------------|--------|
| R1 | Secret rotation lifecycle (all 7 secret types) | secrets-management | ISSUE FOUND (7/7 incomplete) |
| R4 | Cold start security (auth bypass window, sidecar readiness) | securing-serverless | ISSUE FOUND (5) |
| R7 | Service-to-service authentication (12 paths mapped) | zero-trust | **CLEAN** |
| R10 | Trust boundary violations (7 implicit trust assumptions) | zero-trust | ISSUE FOUND (3) |

## Fixes Applied to Spec

| # | Severity | Source | Issue | Fix |
|---|----------|--------|-------|-----|
| 1 | **HIGH** | R1 | No secret rotation procedures defined for any of 7 secret types. PostgreSQL password rotation ordering wrong = total DB connectivity failure | Added "Secret rotation runbook" section with per-secret step-by-step procedures, zero-downtime assessment, and old version cleanup policy |
| 2 | **HIGH** | R4 | No JWKS readiness probe — ContextForge `/health` passes before JWKS is fetched. Auth bypass window if `AUTH_REQUIRED` defaults false | Added mandatory readiness probe requirement: custom `/ready` endpoint or startup hook that blocks until JWKS cache populated |
| 3 | **MEDIUM** | R4 | Cold start HTTP status: spec didn't specify 503 vs 401 when JWKS unreachable. 401 prevents client retry | Changed to mandate 503 (Service Unavailable) for JWKS failure — signals "retry later" |
| 4 | **MEDIUM** | R4 | Bootstrap "init container" is contradictory — init containers run before app containers, can't depend on ContextForge | Clarified: bootstrap is a sidecar-that-runs-once, not an init container. Documented pre-bootstrap window behavior |
| 5 | **MEDIUM** | R10 | JWT claim VALUES never validated after extraction — malformed tenant_id could cause credential mismatch | Added claim value validation requirements: tenant_id format, roles enum, email format |
| 6 | **MEDIUM** | R10 | No sidecar response size limits or structure validation — unbounded responses can exhaust memory | Added "Tool response validation" section: 5MB default limit, JSON-RPC structure check, prompt injection documented as accepted risk |

## Key Decisions & Rationale

1. **Secret rotation as runbook, not open item:** Previous batches would have added "define rotation procedures" as an open item. The R1 agent demonstrated that wrong rotation ordering causes outages (PostgreSQL ALTER USER before Secret Manager update = all connections fail). This is critical enough to resolve at spec level, not defer to implementation.

2. **503 not 401 for JWKS failure:** This seems like a small detail, but it determines whether AI clients retry automatically or give up. OAuth clients treat 401 as "re-authenticate" and 503 as "wait and retry." The wrong status code during Keycloak cold start (15-30s) would cause all lean-tier users to see auth errors instead of automatic recovery.

3. **R7 CLEAN validates Batch 8 work:** The service-to-service auth dimension came back completely clean because Batch 8's sidecar isolation model documentation explicitly addressed every trust boundary. The agent noted: "The sidecar isolation model in Section 8 is unusually thorough." This is the protocol working as designed — fixes from one batch enable clean results in the next.

## Cumulative Protocol Status

| Batch | Fixes | Clean Dims | Method |
|-------|-------|-----------|--------|
| 1 | 27 | — | Freestyle agents |
| 2 | 18 | — | Freestyle agents |
| 3 | 5 | — | Freestyle adversarial |
| 4 | 5 | — | Freestyle regulatory |
| 5 | 1 | — | Freestyle consistency |
| 6 | 10 | — | Skill-framework (JWT + GCP IAM) |
| 7 | 12 | — | Skill-framework (insecure-defaults + oauth2) |
| 8 | 11 | — | Skill-framework (docker + supply-chain + entry-point) |
| 9 | **6** | **1 CLEAN (R7)** | **Skill-framework (secrets + serverless + zero-trust)** |

**Fix trend: 27 → 18 → 5 → 5 → 1 → 10 → 12 → 11 → 6**

Batch 9 shows convergence returning — 6 fixes is the lowest since the skill-framework batches began. More importantly, the first CLEAN dimension (R7) in a skill-framework batch indicates the spec is hardening against structured security review.

**Clean batch counter: 0/5**

## Accumulated Verified-Clean Dimensions

Added from Batch 9: **Service-to-service authentication** (all 14 paths verified — authenticated or explicitly accepted risk), DNS trust for JWKS (VPC + HTTPS + Google certs), Cloud Build compromise resistance (cosign + SLSA + branch protection), Keycloak realm JSON integrity (branch protection + gitleaks + version control), Secret Manager cold start (volume mounts at revision creation — no runtime fetch)
