# Mirror Polish Batch 15 — v4 Design Spec

**Date**: 2026-03-20
**Mode**: Adversarial (10 fresh dimensions)
**Clean batch counter**: 0/5 (reset — 1 fix)

## Review Dimensions

| Round | Dimension | Status |
|-------|-----------|--------|
| R1 | JWT aud array validation semantics | CLEAN |
| R2 | Keycloak admin MFA enforcement | CLEAN |
| R3 | Cloud SQL db-f1-micro backup support | CLEAN |
| R4 | ContextForge GA vs RC-2 compatibility | CLEAN |
| R5 | **Keycloak SSO Session Idle timeout** | **ISSUE FOUND** |
| R6 | Docker multi-stage FROM ordering | CLEAN |
| R7 | Cloud Run health probe port | CLEAN |
| R8 | Keycloak IdP mapper "import" mode | CLEAN |
| R9 | HMAC vs RS256 config carry-forward | CLEAN |
| R10 | Spec version/date accuracy | CLEAN |

## Fix Applied

| Severity | Issue | Fix |
|----------|-------|-----|
| **HIGH** | Keycloak SSO Session Idle defaults to 30 minutes. Spec sets refresh token lifetime to 24 hours. Whichever expires first wins — 30-minute idle timeout silently invalidates refresh tokens after inactivity, despite the 24-hour lifetime. | Added SSO Session Idle: 1 hour, SSO Session Max: 24 hours to Keycloak config. Documented the interaction. |

Fix trend: 27→18→5→5→1→10→12→11→6→4→4→0→0→1→**1**
