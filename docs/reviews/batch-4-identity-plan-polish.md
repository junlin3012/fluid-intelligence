# Mirror Polish Batch 4 — Identity RBAC Plan

**Date**: 2026-03-17
**Target**: `docs/superpowers/plans/2026-03-17-identity-rbac.md`
**Mode**: Code-only
**Method**: Brainstorming + Systematic Debugging
**Clean batch counter**: 0/3

## Review Angles (10 rounds)

| Round | Angle | Status |
|-------|-------|--------|
| R31 | gh release create uses existing pushed tag | CLEAN |
| R32 | set -euo pipefail vs RBAC function exit codes | CLEAN |
| R33 | Cloud Run env var count limit (33 total) | CLEAN |
| R34 | jq availability in container (Dockerfile.base) | CLEAN |
| R35 | Base image rebuild ordering (sequential gcloud builds) | CLEAN |
| R36 | TRUST_PROXY_AUTH_DANGEROUSLY in logs (not a secret) | CLEAN |
| R37 | stderr from RBAC functions appears in Cloud Run logs | CLEAN |
| R38 | services/shopify_oauth/ unaffected by identity changes | CLEAN |
| R39 | Rollback command `--format='value(REVISION)'` fragile | ISSUE FOUND |
| R40 | FEDERATION_TIMEOUT independent of AUTH_REQUIRED | CLEAN |

## Fixes Applied

| Round | Severity | Issue | Fix | Verification |
|-------|----------|-------|-----|-------------|
| R39 | Low | `value(REVISION)` maps display column, not field path | Changed to `value(metadata.name)` + explicit `--sort-by='~metadata.creationTimestamp'` | Canonical gcloud format specifier for revision names |

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable Corrections |
|-------|-------|--------|-------------------|
| Pre | 5 | — | stdout capture bug, fork command |
| 1 | 3 | No | JWT expiry, line numbers, log filter |
| 2 | 7 | No | Admin API JWT mismatch (HIGH), dependency graph, rollback |
| 3 | 4 | No | Spec criteria coverage, AUTH_REQUIRED edit precision |
| 4 | 1 | No | Rollback command format |

**Clean batch counter: 0/3**
**Accumulated verified-clean angles:** R2-R6, R8-R9, R16, R18, R21-R22, R25-R28, R31-R38, R40
