# Mirror Polish Batch 11 — v4 Design Spec (Final Planned Batch)

**Date**: 2026-03-20
**Target**: `docs/specs/2026-03-19-fluid-intelligence-v4-design.md`
**Mode**: Cross-cutting final sweep (3 skills combined)
**Skills**: `sharp-edges` + `spec-to-code-compliance` + `second-opinion`
**Method**: Single comprehensive agent (10 dimensions, adversarial posture)
**Clean batch counter**: 0/5

## Review Dimensions (10 rounds)

| Round | Dimension | Status |
|-------|-----------|--------|
| R1 | Sharp edges in dependencies | **CLEAN** |
| R2 | Spec-to-code compliance | ISSUE FOUND (1 LOW) |
| R3 | Second opinion: audience mapper (Batch 7) | **CLEAN** — verified correct |
| R4 | Second opinion: mcpgateway.translate (Batch 8) | ISSUE FOUND (1 MEDIUM — known open item) |
| R5 | Open items audit | ISSUE FOUND (1 LOW — stale items) |
| R6 | Acceptance criteria audit | **CLEAN** — all 21 testable |
| R7 | Section numbering / cross-references | **CLEAN** |
| R8 | Factual accuracy sweep | **CLEAN** |
| R9 | Migration section completeness | ISSUE FOUND (1 MEDIUM) |
| R10 | Final adversarial read | ISSUE FOUND (1 LOW) |

**5 CLEAN, 5 ISSUE FOUND (0 CRITICAL, 0 HIGH, 2 MEDIUM, 3 LOW)**

## Fixes Applied to Spec

| # | Severity | Issue | Fix |
|---|----------|-------|-----|
| 1 | LOW | v3 characterization says `AUTH_REQUIRED=false` but v3 prod.env has `AUTH_REQUIRED=true`. Actual issue was `MCP_CLIENT_AUTH_ENABLED=false` | Corrected to `MCP_CLIENT_AUTH_ENABLED=false` |
| 2 | LOW | Two OBSOLETE supergateway open items still present as strikethrough | Deleted them entirely |
| 3 | MEDIUM | Migration section "What's new" listed 6 items, missing 7 significant additions from Batches 7-10 | Updated with all new components (audience mapper, DCR policy, HTTP headers, secret rotation, image signing, Cloud Armor, feature hardening) |
| 4 | LOW | Readiness probe timing not specified — lean tier could restart-loop during Keycloak cold start | Added timing guidance: failureThreshold:20, periodSeconds:3 (60s window) |

## Findings NOT Fixed (Already Tracked)

| Finding | Status |
|---------|--------|
| R4: mcpgateway.translate sidecar resource estimates may be underestimated | Already tracked as open item (line 946) — resolve during implementation |

## Key Decisions & Rationale

1. **Batch 7 audience mapper VERIFIED.** The second-opinion agent confirmed Keycloak's built-in "Audience" protocol mapper works at realm level for DCR clients. The `aud` claim becomes an array containing both the DCR client_id and `fluid-gateway`. The spec's "must contain" validation is correct.

2. **Agent's final assessment:** "After 11 batches and 100+ fixes, this spec is in strong shape. No security vulnerabilities, no architectural gaps, no broken cross-references. The remaining issues are editorial accuracy and documentation completeness. The spec is ready for implementation."

## Cumulative Protocol Status

| Batch | Fixes | Severity | Clean Dims | Method |
|-------|-------|----------|-----------|--------|
| 1 | 27 | 7 HIGH | — | Freestyle |
| 2 | 18 | 1 HIGH | — | Freestyle |
| 3 | 5 | 0 HIGH | — | Freestyle adversarial |
| 4 | 5 | 0 HIGH | — | Freestyle regulatory |
| 5 | 1 | 0 HIGH | — | Freestyle consistency |
| 6 | 10 | 0 HIGH | — | Skill (JWT + GCP IAM) |
| 7 | 12 | 5 HIGH | — | Skill (insecure-defaults + oauth2) |
| 8 | 11 | 7 HIGH | — | Skill (docker + supply-chain + entry-point) |
| 9 | 6 | 1 HIGH | 1/4 | Skill (secrets + serverless + zero-trust) |
| 10 | 4 | 0 HIGH | 2/10 | Skill (devsecops + owasp + headers) |
| 11 | **4** | **0 HIGH** | **5/10** | **Skill (sharp-edges + compliance + second-opinion)** |

**Fix trend: 27 → 18 → 5 → 5 → 1 → 10 → 12 → 11 → 6 → 4 → 4**
**Total fixes across 11 batches: 103**
**Total review dimensions: ~90**

Batch 11 has the same fix count as Batch 10 (4), but critically: **0 HIGH severity** and **half the dimensions came back CLEAN**. The spec is converging. No security vulnerabilities remain. Remaining fixes are editorial accuracy.

**Clean batch counter: 0/5** (4 editorial fixes still reset the counter)

The protocol requires 5 consecutive clean batches (0 fixes). The spec needs to survive further review rounds to achieve this. However, the agent's final adversarial assessment found no security vulnerabilities — the remaining fixes are documentation quality, not design safety.
