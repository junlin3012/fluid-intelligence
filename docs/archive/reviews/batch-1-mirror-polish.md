# Mirror Polish Batch 1 — v4 Design Spec

**Date**: 2026-03-19
**Target**: `docs/specs/2026-03-19-fluid-intelligence-v4-design.md`
**Mode**: Design review (5 parallel security audit agents)
**Clean batch counter**: 0/5

## Review Agents (5 parallel)

| Agent | Dimensions | Findings |
|-------|-----------|----------|
| Auth security (2nd pass) | DPoP, CSRF, token storage, logout, admin console, claim injection, JWKS path | 3 HIGH, 3 MEDIUM, 1 LOW |
| Container + infra (2nd pass) | Resource limits, startup ordering, graceful shutdown, logging, crash-loops, tmpfs, scaling, network policy | 2 HIGH, 4 MEDIUM, 2 LOW |
| RBAC + supply chain (2nd pass) | Admin API bypass, missing roles default, supergateway trust, bootstrap creds, CVE allowlist, realm JSON secrets | 2 HIGH, 4 MEDIUM |
| Lessons carry-forward (2nd pass) | Verify 18 prior fixes, find contradictions | NEAR-CLEAN (1 minor: trace propagation) |
| Formal spec review (2nd pass) | Section numbering, cross-refs, open items, specificity, terminology, testability | 3 MEDIUM, 4 LOW |

## Fixes Applied

| # | Severity | Issue | Fix |
|---|----------|-------|-----|
| 1 | HIGH | No logout/session revocation flow | Added "Session termination / logout" section to 4.1 |
| 2 | HIGH | Keycloak admin console publicly accessible | Added "Keycloak admin console security" section — KC_HOSTNAME_ADMIN restriction |
| 3 | HIGH | JWT claim injection via Google IdP | Added "Identity Provider claim filtering" — admin-only-writable tenant_id/roles |
| 4 | HIGH | No sidecar startup ordering | Added "Sidecar orchestration" section with Cloud Run dependency annotations |
| 5 | HIGH | No graceful shutdown drain | Added terminationGracePeriodSeconds: 30, drain sequence |
| 6 | HIGH | Admin API role gate uses DB not JWT | Rewritten RBAC to use HTTP_AUTH_RESOLVE_USER plugin hook, per-request role derivation |
| 7 | HIGH | Missing roles claim = no default-deny | Added explicit default-deny: no roles claim → deny all tool invocations |
| 8 | MEDIUM | No token storage guidance | Added "Client implementer guidance" section |
| 9 | MEDIUM | JWKS over public internet | Added "Network policy" section — use Cloud Run internal URL |
| 10 | MEDIUM | No DPoP | Added as future open item (when MCP spec adopts it) |
| 11 | MEDIUM | Duplicate section number | Renumbered: Future=14, Open items=15, added Terminology=13 |
| 12 | MEDIUM | Body issues not in open items | Added rate limit headers, VPC-SC, Binary Auth to open items |
| 13 | MEDIUM | Config keys unspecified | Added HTTP_AUTH_RESOLVE_USER, KC_HOSTNAME_ADMIN, internal URL specifics |
| 14 | MEDIUM | No per-sidecar resource limits | Added resource allocation table |
| 15 | MEDIUM | No crash-loop policy | Added failureThreshold: 3, documented Cloud Run replacement behavior |
| 16 | MEDIUM | No tmpfs mounts | Added tmpfs mount table per container |
| 17 | MEDIUM | supergateway trust | Added trust note with vendor/alternative mitigations |
| 18 | MEDIUM | Bootstrap credential lifecycle | Added bootstrap service account JWT, idempotency, separate secret |
| 19 | MEDIUM | CVE allowlist governance | Added required fields, CI warnings, approval process to open items |
| 20 | MEDIUM | Realm JSON secrets | Added --no-credentials, placeholders, gitleaks to open items |
| 21 | LOW | DCR client impersonation | Acknowledged — low risk for developer users |
| 22 | LOW | "Virtual server" undefined | Added Terminology section (13) |
| 23 | LOW | Security claims lack tests | Added acceptance test open items |
| 24 | LOW | Multi-tenant flow needs diagram | Acknowledged — add during implementation |
| 25 | LOW | No structured logging for sidecars | Added sidecar logging section in observability |
| 26 | LOW | Sidecar multiplication cost | Added note in crash-loop section |
| 27 | LOW | Trace context propagation | Added traceparent header requirement in observability |

## Cumulative Status

| Batch | Fixes | Clean? |
|-------|-------|--------|
| Pre-protocol | 60+ | No (3 security audits + lessons + formal) |
| 1 | 27 | No |

**Clean batch counter: 0/5**
**Verified-clean dimensions from pre-protocol:** OAuth flow, PKCE, DCR basics, refresh rotation, JWT algorithm, audience, JWKS caching, trust model (TRUST_PROXY_AUTH removed), auto-admin removed, dependency integrity, OTEL config, alerting, error sanitization, liveness probes, cold start ordering, bootstrap design, query cost control
