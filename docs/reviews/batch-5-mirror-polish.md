# Mirror Polish Batch 5 — v4 Design Spec

**Date**: 2026-03-19
**Target**: `docs/specs/2026-03-19-fluid-intelligence-v4-design.md`
**Mode**: Full-spec consistency review (6th pass)
**Clean batch counter**: 0/5

## Findings

| # | Severity | Issue | Fix |
|---|----------|-------|-----|
| 1 | MEDIUM | Keycloak ingress contradicts itself: "Network boundary" says `--ingress=all` for both services, "Network policy" says `--ingress=internal-and-cloud-load-balancing` for Keycloak | Updated Network boundary to match Network policy — Keycloak via ALB only |

## 25 Angles Checked CLEAN

Section numbering, port map, PostgreSQL topology, RBAC role derivation, JWT algorithm, token lifetimes, fail-closed, bootstrap flow, connection pool math, admin console, audit retention, SSRF approach, design principles traceability, Batch 3+4 fix completeness, Cloud Run factual accuracy, Keycloak factual accuracy, ContextForge factual accuracy, terminology usage, open items coverage, Dockerfile correctness, scaling tiers, migration completeness, acceptance criteria, cross-references, Docker multi-stage builds.

## Convergence

| Batch | Fixes | HIGHs | Domain |
|-------|-------|-------|--------|
| 1 | 27 | 7 | Auth, container, RBAC, supply chain |
| 2 | 18 | 1 | Keycloak hardening, factual errors |
| 3 | 5 | 0 | Operational edge cases |
| 4 | 5 | 0 | Regulatory, incident response |
| 5 | 1 | 0 | Internal consistency |

**Fix trend: 27 → 18 → 5 → 5 → 1. Converging to zero.**
**Clean batch counter: 0/5**

## Process note

Batches 1-5 used general-purpose agents without invoking installed cybersecurity skills or Trail of Bits skills. Batch 6 will invoke specialized skills (testing-jwt-token-security, auditing-gcp-iam-permissions, insecure-defaults, hardening-docker-containers-for-production) via the Skill tool to validate with structured frameworks rather than freestyle reasoning.
