# Mirror Polish Batch 7 — v4 Design Spec

**Date**: 2026-03-20
**Target**: `docs/specs/2026-03-19-fluid-intelligence-v4-design.md`
**Mode**: Skill-framework review (3 strategic skills)
**Skills**: `insecure-defaults` + `configuring-oauth2-authorization-flow` + `testing-oauth2-implementation-flaws`
**Method**: Brainstorming + Parallel Agents (10) + Systematic Debugging + Web Research Verification
**Clean batch counter**: 0/5

## Review Dimensions (10 rounds)

| Round | Dimension | Skill Domain | Status |
|-------|-----------|-------------|--------|
| R1 | Fail-open config audit (every default if unset) | insecure-defaults | ISSUE FOUND (4 issues) |
| R2 | Missing env var blast radius | insecure-defaults | ISSUE FOUND (4 issues) |
| R3 | Keycloak feature flag defaults vs actual | insecure-defaults | ISSUE FOUND (5 issues, 1 false positive) |
| R4 | DCR RFC 7591 completeness | configuring-oauth2 | ISSUE FOUND (10 gaps) |
| R5 | RFC 8414 OAuth metadata completeness | configuring-oauth2 | ISSUE FOUND (7 gaps) |
| R6 | PKCE edge cases (RFC 7636) | configuring-oauth2 | ISSUE FOUND (4 issues) |
| R7 | Token lifecycle gaps (all token types) | configuring-oauth2 | ISSUE FOUND (5 gaps) |
| R8 | Redirect URI manipulation attacks | testing-oauth2-flaws | ISSUE FOUND (3 issues) |
| R9 | Token theft blast radius analysis | testing-oauth2-flaws | ISSUE FOUND (4 issues) |
| R10 | Client confusion / impersonation attacks | testing-oauth2-flaws | ISSUE FOUND (4 issues, 1 CRITICAL) |

## Fixes Applied to Spec

| # | Severity | Source | Issue | Fix | Verification |
|---|----------|--------|-------|-----|-------------|
| 1 | **CRITICAL** | R10 | Audience confusion: `aud` check impossible with DCR model — each client gets unique client_id, no single "gateway client ID" exists | Added Keycloak audience mapper requirement: fixed `fluid-gateway` audience value on all tokens. Updated both Section 4.1 (claims) and JWT validation (Section 4.2) | Web research confirmed this is the standard resource-server pattern for Keycloak + DCR |
| 2 | **HIGH** | R6 | PKCE method omission: RFC 7636 §4.3 says server MUST default to `plain` if `code_challenge_method` is omitted — defeats PKCE | Changed PKCE enforcement to require BOTH `pkce.code.challenge.required=true` AND `pkce.code.challenge.method=S256` | RFC 7636 §4.3 verified |
| 3 | **HIGH** | R3 | Wrong token-exchange feature: spec disabled V1 (preview, already off). V2 (`token-exchange-standard`) is enabled by default in 26.2+ | Fixed to `token-exchange-standard:disabled` + belt-and-suspenders V1 disable. Added version note | Web search confirmed: Keycloak 26.2 blog post |
| 4 | **HIGH** | R3 | Missing feature disables: device-flow and CIBA enabled by default, unnecessary attack surface | Added `device-flow:disabled` and `ciba:disabled` to feature hardening | Keycloak features page confirmed both enabled by default |
| 5 | **HIGH** | R4 | No DCR Client Registration Policy: Keycloak's default DCR accepts whatever client requests | Added comprehensive policy: force public clients, restrict grant/response types to auth_code/code only, restrict scopes, ignore software_statement, add client cleanup | RFC 7591 Section 2 cross-referenced |
| 6 | **HIGH** | R5 | OAuth metadata path blocker: Keycloak serves OIDC discovery, not RFC 8414 OAuth metadata. No MCP client can discover auth server | Elevated from open item to explicit blocker in spec. Added required metadata field list | Keycloak docs confirmed: only serves `openid-configuration` natively |
| 7 | **MEDIUM** | R8 | Redirect URI says `https://localhost` but RFC 8252 §7.3 requires `http://` for native loopback (TLS on localhost breaks clients) | Changed to `http://localhost:*`, `http://127.0.0.1:*`, `http://[::1]:*` | RFC 8252 §7.3 verified |
| 8 | **MEDIUM** | R2 | KC_DB_POOL_MAX_SIZE default stated as 20, likely ~100 in production mode | Corrected to "~100" with note to verify exact value | Keycloak docs indicate 100 as upper bound |
| 9 | **MEDIUM** | R4 | DCR rate limiting has no implementation mechanism (Keycloak has no native DCR rate limiting) | Added implementation note: Cloud Armor WAF or ALB rate limit policy | Added as open item |
| 10 | **MEDIUM** | R7 | Refresh token behavior for disabled users: spec only covers access tokens | Added explicit note: Keycloak rejects refresh grants for disabled users (verify at implementation) | Added as open item |
| 11 | **MEDIUM** | R9/R10 | Bootstrap JWT: rogue backend persists beyond 5-min token lifetime. Bootstrap client scope undefined | Added scope restriction (not full realm-admin), timeout recovery (re-authenticate), acceptance test | Design fix |
| 12 | **MEDIUM** | R4 | DCR registration_access_token (RFC 7592) lifecycle undefined | Added lifecycle options: disable management endpoint or restrict to read-only | RFC 7592 referenced |

**Plus 8 new acceptance tests and 12 new open items added to spec.**

## Findings Not Fixed (Accepted Risk or Implementation-Level)

| Finding | Assessment |
|---------|-----------|
| R1: AUTH_REQUIRED defaults to false if unset | Documented as open item — needs source code verification, not spec fix |
| R1: HTTP_AUTH_RESOLVE_USER plugin failure mode | Implementation-level — spec can't dictate ContextForge internals |
| R2: OTEL_EXPORTER_OTLP_ENDPOINT silent failure | Observability is non-critical — silent disable is acceptable |
| R2: --set-secrets blocks deployment if secret missing | Cloud Run platform behavior — operational knowledge, not spec gap |
| R3: admin2 feature name "wrong" | FALSE POSITIVE — `admin2` is a valid Keycloak feature flag. Agent's web research was incorrect |
| R5: Metadata fields not enumerated | Fixed by adding field list inline rather than separate section |
| R9: No IP anomaly detection for stolen access tokens | Accepted risk — 1-hour lifetime bounds blast radius, DPoP is future item |
| R10: azp claim listed but never validated | Minor — bearer tokens are accepted risk, DPoP deferred |

## Key Decisions & Rationale

1. **Audience mapper pattern**: Chose fixed resource-server audience (`fluid-gateway`) over per-client audience validation. This is the standard Keycloak pattern for resource servers behind DCR. Without it, `aud` validation is architecturally impossible.

2. **PKCE method enforcement vs rejection**: Changed from "reject plain" to "require S256". These sound similar but are different — RFC 7636's default-to-plain trap means "rejecting plain" still allows method omission. "Requiring S256" closes the gap.

3. **DCR permissiveness**: The biggest thematic finding — the spec treated DCR as "Keycloak provides this natively" without recognizing that Keycloak's default DCR is intentionally permissive. Every restriction needs explicit Client Registration Policy configuration.

4. **OAuth metadata blocker**: Elevated from verification open item to design decision. This is not a "check if it works" — it definitively does NOT work out of the box. Needs a design solution (ALB rewrite, SPI, or proxy).

## Cumulative Protocol Status

| Batch | Fixes | Clean? | Notable Corrections |
|-------|-------|--------|-------------------|
| 1 | 27 | No | Auth, container, RBAC, supply chain (freestyle) |
| 2 | 18 | No | Keycloak hardening, factual errors (freestyle) |
| 3 | 5 | No | Operational edge cases (freestyle adversarial) |
| 4 | 5 | No | Regulatory, incident response (freestyle regulatory) |
| 5 | 1 | No | Internal consistency (freestyle consistency) |
| 6 | 10 | No | JWT security + GCP IAM (skill-framework) |
| 7 | **12** | No | **Audience confusion (CRITICAL), PKCE method trap, DCR policy, feature flags, OAuth metadata blocker** |

**Fix trend: 27 → 18 → 5 → 5 → 1 → 10 → 12**

Batch 7 spiked because the 3 security skills checked OAuth from an attacker's perspective — previous batches checked from a builder's perspective. The audience confusion finding (CRITICAL) would have been a showstopper in production.

**Clean batch counter: 0/5**

## Accumulated Verified-Clean Dimensions

From batches 1-6: Auth (most angles), Container (most angles), RBAC, Supply chain, Formal structure, Lessons carry-forward, Operational (DR, upgrades, credentials), Regulatory (GDPR, incident response), GCP IAM (role bindings), JWT (JKU/KID/clock skew)

From batch 7: Redirect URI path traversal, fragment injection, redirect URI mismatch, DCR client_id collision, tenant isolation via JWT, authorization code reuse, JWKS fail-closed, key rotation overlap, refresh token rotation/reuse detection, token binding via aud, access token revocation model (accepted risk), admin2 feature flag (valid name)
