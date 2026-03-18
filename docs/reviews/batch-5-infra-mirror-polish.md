# Mirror Polish Batch 5 — Deployment Infrastructure

**Date**: 2026-03-18
**Target**: Deployment infrastructure (esoteric — nounset, process groups, JWT types, OTEL, token regex)
**Mode**: Code-only verification
**Method**: Brainstorming + Single Comprehensive Agent + Systematic Debugging
**Clean batch counter**: 0/6

## Review Dimensions (10 rounds)

| Round | Dimension | Status |
|-------|-----------|--------|
| R41 | bash set -u + optional variables — unguarded references | CLEAN |
| R42 | tini -g process group side effects on npx/uv children | CLEAN |
| R43 | HMAC JWT (bootstrap) vs RS256 JWT (auth-proxy) — dual JWT types | CLEAN |
| R44 | CREDENTIALS_CONFIG JSON in env var — newline preservation | CLEAN |
| R45 | OTEL_EXPORTER_OTLP_ENDPOINT for Cloud Trace — correct endpoint? | ISSUE FOUND |
| R46 | Shopify token regex validation — shp* glob coverage | CLEAN |
| R47 | register_gateway backoff — attempt incremented before sleep | CLEAN (intentional) |
| R48 | Cloud SQL proxy socket availability — graceful fallback | CLEAN |
| R49 | SHOPIFY_STORE in URL without encoding — safe characters | CLEAN |
| R50 | CREDENTIALS_CONFIG format validation — malformed JSON handling | CLEAN |

## Fixes Applied (1 issue)

| Round | Severity | Issue | Fix | Verification |
|-------|----------|-------|-----|-------------|
| R45 | Low | OTEL_EXPORTER_OTLP_ENDPOINT=https://cloudtrace.googleapis.com silently drops traces. Cloud Trace doesn't speak generic OTLP protocol. | Changed OTEL_TRACES_EXPORTER from `otlp` to `none` (explicit disable). Added comment explaining Cloud Trace requires GCP-specific exporter. | No more silent failure — tracing is explicitly off until properly configured. |

## Observations (not flaws)

| Finding | Assessment |
|---------|-----------|
| R43: Dual JWT types (HMAC for internal, RS256 for external) | Architecturally sound — different paths, different audiences, never cross |
| R47: 10s first-retry backoff | Comment explicitly documents "attempt incremented before sleep" — intentional design |

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable Corrections |
|-------|-------|--------|-------------------|
| 1 | 6 | No | SHA256 hash, bare python3, PIDS race, transport docs |
| 2 | 4 | No | JWT expiry, SSE probe logic, decrypt validation, flock error |
| 3 | 0 | YES | First clean — deep security/error/race review |
| 4 | 2 | No | Token lifetime warning, curl -L consistency |
| 5 | 1 | No | OTEL endpoint silently dropping traces |

**Fix trend: 6→4→0→2→1** (declining with spikes when entering new review domains)
**Clean batch counter: 0/6**
**Accumulated verified-clean dimensions: 49 of 50 reviewed**
