# Mirror Polish Batch 2 — v4 Design Spec

**Date**: 2026-03-19
**Target**: `docs/specs/2026-03-19-fluid-intelligence-v4-design.md`
**Mode**: Design review (5 parallel security audit agents, 3rd pass)
**Clean batch counter**: 0/5

## Review Agents

| Agent | Dimensions | Findings |
|-------|-----------|----------|
| Auth (3rd pass) | Token exchange, offline tokens, CORS, introspection, event logging, mTLS | 1 HIGH, 2 MEDIUM, 1 LOW |
| Container (3rd pass) | Seccomp, capabilities, layer leaks, signal propagation, DNS, revision history | 1 LOW (5 of 6 CLEAN) |
| RBAC + supply chain (3rd pass) | Plugin RBAC bypass, tool description injection, scope escape, audit tampering, trace correlation, licenses | 3 MEDIUM, 1 LOW |
| Lessons (3rd pass) | Internal contradictions from Batch 1 fixes | 1 GENUINE CONTRADICTION, 2 BORDERLINE |
| Formal (3rd pass) | Implementability, Cloud Run feature verification | 2 FACTUAL ERRORS, 1 RISK, 3 GAPS |

## Fixes Applied

| # | Severity | Issue | Fix |
|---|----------|-------|-----|
| 1 | HIGH | Offline tokens bypass all token controls | Disabled `offline_access` scope, added Keycloak feature hardening section |
| 2 | FACTUAL ERROR | TCP liveness probes don't exist on Cloud Run | Changed to HTTP liveness for main containers, startup TCP for sidecars + circuit breaker fallback |
| 3 | FACTUAL ERROR | `*.run.internal` URL doesn't exist | Replaced with Direct VPC Egress + `--ingress=internal-and-cloud-load-balancing` |
| 4 | CONTRADICTION | Session termination claims 10min revocation (wrong — it's 1hr) | Corrected to 1-hour access token lifetime, explained JWKS cache is for key rotation only |
| 5 | MEDIUM | Token exchange/impersonation enabled by default | Added `--features=token-exchange:disabled,impersonation:disabled` |
| 6 | MEDIUM | Keycloak event logging disabled by default | Added full event logging config with LOGIN/LOGOUT/DCR/etc. capture |
| 7 | MEDIUM | Bootstrap JWT chicken-and-egg | Redesigned: two-phase bootstrap with pre-configured realm JSON + `--import-realm` |
| 8 | MEDIUM | Plugin execution order vs RBAC | Added plugin execution order section |
| 9 | MEDIUM | Tool description injection | Added tool description security section |
| 10 | MEDIUM | Audit log tampering | Added INSERT-only permissions, Cloud Logging secondary store |
| 11 | RISK | Container dependency `condition: healthy` Pre-GA | Added fallback note (circuit breaker retry) |
| 12 | LOW | Old Cloud Run revisions accessible | Added revision hygiene post-deploy step |
| 13 | LOW | CORS no Web Origins policy | Added to open items |
| 14 | LOW | Cross-service trace correlation | Added `sid` JWT claim for Keycloak-ContextForge correlation |
| 15 | LOW | License verification for google-sheets | Added to open items |
| 16 | GAP | No acceptance criteria | Added Section 15: Acceptance Criteria with 14 checkboxes |
| 17 | GAP | Open items unprioritized | Acknowledged — will prioritize in writing-plans phase |
| 18 | GAP | Cost table doesn't match resource limits | Acknowledged — will verify during implementation |

## Convergence

| Batch | Fixes | Clean? | Trend |
|-------|-------|--------|-------|
| Pre-protocol | 60+ | No | Initial security audit |
| 1 | 27 | No | 7 HIGH |
| 2 | 18 | No | 1 HIGH + 2 factual errors (down from 7 HIGH) |

**Fix trend: 27 → 18. HIGH count: 7 → 1. Converging.**

**Clean batch counter: 0/5**
