# Mirror Polish Batch 3 — v4 Design Spec

**Date**: 2026-03-19
**Target**: `docs/specs/2026-03-19-fluid-intelligence-v4-design.md`
**Mode**: Adversarial review (4th pass) — operational edge cases
**Clean batch counter**: 0/5

## Findings

| # | Severity | Issue | Fix |
|---|----------|-------|-----|
| 1 | MEDIUM | Backend credential expiry unhandled (Shopify token expires mid-operation) | Added credential lifecycle requirements to tenant context injection section |
| 2 | MEDIUM | No disaster recovery for PostgreSQL (backups, RPO/RTO, DROP protection) | Added Data Protection subsection under PostgreSQL |
| 3 | MEDIUM | No upgrade strategy for schema-migrating services | Added Section 14: Upgrade Strategy |
| 4 | LOW | Multi-instance tool registry divergence | Added re-discovery note to Bootstrap section |
| 5 | LOW | No JWT clock skew tolerance | Added 30s tolerance to JWT validation requirements |

## Convergence

| Batch | Fixes | HIGHs | Trend |
|-------|-------|-------|-------|
| Pre-protocol | 60+ | many | Initial |
| 1 | 27 | 7 | First deep pass |
| 2 | 18 | 1 | Keycloak hardening + factual errors |
| 3 | 5 | 0 | Operational edge cases only |

**Fix trend: 27 → 18 → 5. Strongly converging. No HIGH findings.**
**Clean batch counter: 0/5**

## Verified-clean dimensions (accumulated)

Auth, Container, RBAC, Supply chain, Formal structure, Lessons carry-forward, Keycloak hardening, Cloud Run feature verification, Sidecar orchestration, Network policy, Session termination, IdP claim filtering, Offline tokens, Event logging, Audit integrity, Tool description security, Plugin execution order, Acceptance criteria, Data protection, Upgrade strategy, Backend credential lifecycle, Clock skew tolerance
