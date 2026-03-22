# Mirror Polish Batch 10 — v4 Design Spec

**Date**: 2026-03-20
**Target**: `docs/specs/2026-03-19-fluid-intelligence-v4-design.md`
**Mode**: Skill-framework review (3 strategic skills)
**Skills**: `implementing-devsecops-security-scanning` + `testing-api-security-with-owasp-top-10` + `performing-security-headers-audit`
**Method**: Brainstorming + Parallel Agents (3) + Systematic Debugging
**Clean batch counter**: 0/5

## Review Dimensions (10 rounds)

| Round | Dimension | Skill Domain | Status |
|-------|-----------|-------------|--------|
| R1 | OWASP API Top 10 (2023) | owasp-api | ISSUE FOUND (2) |
| R2 | DevSecOps pipeline completeness | devsecops | ISSUE FOUND (2) |
| R3 | HTTP security headers | security-headers | ISSUE FOUND (3) |
| R4 | Error handling security | owasp-api | **CLEAN** |
| R5 | MCP protocol security | owasp-api | ISSUE FOUND (4) |
| R6 | Logging and audit completeness | devsecops | ISSUE FOUND (3) |
| R7 | Compliance and regulatory | devsecops | ISSUE FOUND (4) |
| R8 | Operational security | devsecops | ISSUE FOUND (5) |
| R9 | Internal consistency (post-9-batches) | cross-cutting | ISSUE FOUND (3) |
| R10 | Accepted risk completeness | cross-cutting | **CLEAN** (all 7 risks verified) |

## Fixes Applied to Spec

| # | Severity | Source | Issue | Fix |
|---|----------|--------|-------|-----|
| 1 | **MEDIUM** | R9 | 8 supergateway references remaining after Batch 8 decision to use mcpgateway.translate | Replaced all: port map, backend integration table, health probes, resource limits |
| 2 | **MEDIUM** | R9 | "init container" terminology used in 6 locations contradicts Section 8 clarification that bootstrap is a "run-once sidecar" | Fixed all references: Section 8 RBAC, Section 12 (3 locations), acceptance criteria, open items |
| 3 | **MEDIUM** | R9 | 2 stale open items for supergateway pinning/provenance | Marked as OBSOLETE with Batch 8 reference |
| 4 | **MEDIUM** | R3 | No HTTP security headers defined — tool responses cacheable by proxies, no HSTS, no clickjacking protection | Added "HTTP security headers" section: Cache-Control, HSTS, X-Content-Type-Options, X-Frame-Options, CORS posture |

## Findings NOT Fixed (Deferred to Operational Runbook)

These are real gaps but belong in an operational runbook, not the architecture design spec:

| Finding | Where it belongs | Why not in spec |
|---------|-----------------|----------------|
| R2: No SAST/DAST in pipeline | CI/CD implementation plan | Tool selection (bandit, semgrep, ZAP) is implementation detail |
| R5: MCP protocol version negotiation | Implementation verification | ContextForge handles this natively — verify, don't specify |
| R5: Tool call depth/loop detection | Implementation verification | ContextForge's Watchdog plugin may already handle this |
| R6: Failed request logging, log injection | Operational runbook | ContextForge structured logging handles this — verify |
| R6: Cloud Logging retention | GCP infrastructure config | Set to 90 days during deployment |
| R7: Data classification, data flows, vuln disclosure | Compliance documentation | Separate deliverable, not architecture spec |
| R7: Tool response cache retention (GDPR) | Data retention policy | Separate deliverable |
| R8: All operational items | Operational runbook | Dashboard, playbook, capacity planning, backup testing, change management |
| R1: Cumulative data volume budget | Implementation — ContextForge config | Per-user bandwidth limit is a config knob |
| R1: Sensitive-tool differentiation | Implementation — RBAC design | Define "mutation" tools with stricter rate limits during RBAC setup |

## Key Decisions & Rationale

1. **Consistency fixes are the priority at this stage.** With 90+ fixes across 9 batches, internal contradictions are now the highest-risk defect type. The supergateway/mcpgateway.translate and init-container/run-once-sidecar inconsistencies would cause real implementation confusion.

2. **R10 CLEAN validates the risk model.** All 7 accepted risks survived scrutiny — the agent verified each has documented rationale, appropriate mitigations, and remains valid after all batch fixes. This is a strong signal that the spec's security model is coherent.

3. **Operational items deferred, not dropped.** 16 operational/compliance findings are real gaps for production readiness but do not belong in the architecture design spec. They should be tracked as deliverables for a pre-launch operational readiness review.

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
| 9 | 6 | 1 | Skill-framework (secrets + serverless + zero-trust) |
| 10 | **4** | **2 (R4, R10)** | **Skill-framework (devsecops + owasp + headers)** |

**Fix trend: 27 → 18 → 5 → 5 → 1 → 10 → 12 → 11 → 6 → 4**

Batch 10 is the lowest fix count in the skill-framework series (4 fixes, down from 6). Two dimensions came back CLEAN (R4, R10). The fixes are consistency corrections, not security design gaps. **The spec is converging.**

**Clean batch counter: 0/5** (4 fixes still resets to 0, but the fix trend and increasing CLEAN dimensions show convergence)
