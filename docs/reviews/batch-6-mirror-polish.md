# Mirror Polish Batch 6 — v4 Design Spec

**Date**: 2026-03-19
**Target**: `docs/specs/2026-03-19-fluid-intelligence-v4-design.md`
**Mode**: Skill-framework review (first batch using installed cybersecurity skills)
**Skills invoked**: `testing-jwt-token-security`, `auditing-gcp-iam-permissions`
**Clean batch counter**: 0/5

## Review Agents

| Agent | Skill Framework | Result |
|-------|----------------|--------|
| JWT Security | `testing-jwt-token-security` (13-point checklist) | 9 PASS, 1 FAIL, 3 PARTIAL |
| GCP IAM | `auditing-gcp-iam-permissions` (12-point checklist) | 3 PASS, 4 FAIL, 5 PARTIAL |
| Consistency | Final structural sweep | **CLEAN** |

## Findings Fixed (spec-level)

| # | Source | Issue | Fix |
|---|--------|-------|-----|
| 1 | JWT skill | JKU/x5u header injection — spec didn't restrict JWT header URLs | Added header restriction: ignore jku/x5u/x5c/x5t, always use configured JWKS endpoint |
| 2 | JWT skill | KID cache-busting DoS — unlimited JWKS refreshes on unknown kid | Added rate limit: max 1 refresh per 60s, kid used only for key matching |
| 3 | JWT skill | Token reuse after logout — 1hr window undocumented | Added explicit risk acceptance with mitigations |
| 4 | JWT skill | PII in JWT payload — email readable in base64 | Added explicit PII acknowledgment with justification for no JWE |
| 5 | GCP IAM | No SA role bindings specified | Added GCP IAM model section with per-SA role table |
| 6 | GCP IAM | SA impersonation unaddressed | Added impersonation policy (only Cloud Build SA) |
| 7 | GCP IAM | Cloud SQL connection method unspecified | Added Direct VPC Egress + private IP |
| 8 | GCP IAM | Cloud Build SA undefined | Added to IAM role table |
| 9 | GCP IAM | Cloud Run invoker bindings undocumented | Added invoker table |
| 10 | GCP IAM | No IAM Recommender | Added post-deployment hygiene step |

## Findings tracked as open items (implementation-level)

- Exact Secret Manager IAM condition expressions (resource-level scoping)
- Artifact Registry reader/writer role assignments
- IAM Recommender 30-day review schedule
- Keycloak Cloud Run invoker binding for ALB
- ContextForge JWT library behavior with jku/x5u headers (verify, don't assume)

## Convergence

| Batch | Fixes | HIGHs | Method |
|-------|-------|-------|--------|
| 1 | 27 | 7 | Freestyle agents |
| 2 | 18 | 1 | Freestyle agents |
| 3 | 5 | 0 | Freestyle adversarial |
| 4 | 5 | 0 | Freestyle regulatory |
| 5 | 1 | 0 | Freestyle consistency |
| 6 | 10 | 0 | **Skill-framework** (JWT + GCP IAM) |

**Fix trend: 27 → 18 → 5 → 5 → 1 → 10.**

Batch 6 spiked from 1 to 10 because the skill frameworks checked dimensions that freestyle agents systematically missed (JKU injection, SA impersonation, Cloud Build permissions). This validates the user's feedback: skills find what freestyle doesn't.

**Clean batch counter: 0/5**

## Key insight

Freestyle agents converged to near-zero (Batch 5: 1 finding). Switching to skill frameworks (Batch 6) found 10 more issues. The lesson: **framework-driven review and freestyle review are complementary, not redundant.** Future Mirror Polish batches should alternate between freestyle angles and skill-framework checks.
