# v4 Code Map — Useful vs Redundant

> Written 2026-03-20. Use this to decide what to carry forward to v5.

## USEFUL — Carry Forward to v5

### Infrastructure Scripts (keep all — battle-tested)
| File | Purpose | Notes |
|------|---------|-------|
| `scripts/setup-cloud-sql-v4.sh` | Create Keycloak DB + user | Idempotent, zero hardcoded values |
| `scripts/setup-iam-v4.sh` | Create gateway-sa + keycloak-sa SAs | Least-privilege bindings |
| `scripts/setup-alb.sh` | ALB + Cloud Armor for Keycloak | Path allowlist + DCR rate limiting |
| `scripts/setup-monitoring.sh` | Alert policies + audit permissions | Error rate, latency, restart alerts |
| `scripts/setup-cloud-sql-security.sh` | Disable public IP + restrict AR | Production hardening |
| `scripts/init-postgres.sql` | Docker-compose DB init | Creates both databases |
| `scripts/init-postgres-wrapper.sh` | Passes passwords to SQL | Docker entrypoint-initdb.d compatible |
| `scripts/test-v4-regression.sh` | Full regression test suite | Unit tests + live service checks |

### Keycloak (keep — proven working after 8 deploy iterations)
| File | Purpose | Notes |
|------|---------|-------|
| `keycloak/Dockerfile` | Optimized Keycloak build | `--features-disabled`, `--health-enabled`, SUID stripped |
| `keycloak/.dockerignore` | Build context filter | |
| `keycloak/realm-fluid.json` | Realm config | Stripped to importable fields only. clientProfiles/clientPolicies/userProfile removed (configure post-import via Admin API) |

### Cloud Run YAMLs (keep templates, update for v5)
| File | Purpose | Notes |
|------|---------|-------|
| `deploy/cloud-run-keycloak.yaml` | Template with placeholders | Good structure, needs DEPLOY comments updated |
| `deploy/cloud-run-gateway.yaml` | Multi-container template | 598 lines, all 5 containers, thoroughly reviewed |
| `deploy/cloud-run-keycloak-live.yaml` | Actual deployed config | Has the WORKING values (HTTPS hostname, DB URL, startup probe) |
| `deploy/cloud-run-gateway-live.yaml` | Actual deployed config | Has SSO config, JWKS URL, correct env vars |
| `deploy/cloud-armor.yaml` | WAF rules documentation | |

### Sidecar Dockerfiles (keep — not yet tested but structurally sound)
| File | Purpose | Notes |
|------|---------|-------|
| `sidecars/apollo/Dockerfile` | Apollo MCP Server | Multi-stage Rust build, needs real commit hash |
| `sidecars/devmcp/Dockerfile` | dev-mcp bridge | ContextForge base + Node.js |
| `sidecars/devmcp/package.json` | dev-mcp deps | Needs `npm install` for lockfile |
| `sidecars/sheets/Dockerfile` | Google Sheets bridge | ContextForge base + pip |
| `sidecars/sheets/requirements.txt` | Sheets deps | Version needs verification |

### Configuration (keep — correct v4 values)
| File | Purpose | Notes |
|------|---------|-------|
| `config/prod.env` | Production env vars | v4 auth values (AUTH_REQUIRED, SSRF, OTEL) |
| `config/defaults.env` | Default env vars | Fail-safe defaults |
| `config/dev.env` | Dev mode overrides | Auth off, SSRF relaxed, DEBUG logging |
| `config/.digests` | Image digest registry | Keycloak digest verified |
| `.env.example` | Env var documentation | v4 variables documented |

### CI/CD (keep — comprehensive pipeline)
| File | Purpose | Notes |
|------|---------|-------|
| `deploy/cloudbuild.yaml` | 10-step build pipeline | Secret scan → lint → build → CVE → SBOM → sign → push → deploy → verify → health |

### Docker Compose (keep)
| File | Purpose | Notes |
|------|---------|-------|
| `docker-compose.yml` | 6-service local dev stack | Should have been used BEFORE Cloud Run deploys |

### Documentation (keep all)
| File | Purpose |
|------|---------|
| `docs/agent-behavior/failure-log.md` | 20+ documented failures with root causes |
| `docs/decisions/2026-03-20-translate-sidecar-topology.md` | mcpgateway.translate requires full ContextForge base |
| `docs/specs/2026-03-20-tenant-context-injection.md` | Tenant injection design (439 lines) |
| `docs/plans/v4-remaining-work.md` | Deployment handoff document |

### Tests (keep keycloak + bootstrap, delete plugin tests)
| File | Purpose | Keep? |
|------|---------|-------|
| `tests/keycloak/test_realm_json.py` | Validates realm JSON structure | ✅ Keep (18 passing, 5 skipped) |
| `tests/bootstrap/test_bootstrap.py` | Validates bootstrap sidecar | ✅ Keep (16 passing) |

---

## REDUNDANT — Delete or Replace with Configuration

### Custom Plugin (DELETE — replaced by SSO_KEYCLOAK_ENABLED)
| File | Lines | Why redundant |
|------|-------|---------------|
| `plugins/resolve_user.py` | 277 | `SSO_KEYCLOAK_ENABLED=true` + `SSO_KEYCLOAK_MAP_REALM_ROLES=true` does everything this plugin does |
| `plugins/config.yaml` | 25 | Only exists to register the redundant plugin |
| `plugins/__init__.py` | 0 | Package init for redundant plugin |
| `tests/plugins/test_resolve_user.py` | 419 | Tests for redundant plugin |
| `tests/plugins/__init__.py` | 0 | Package init for redundant tests |
| **Total** | **721** | **Replaced by 2 env vars** |

### Gateway Entrypoint (REPLACE — should be one env var)
| File | Lines | Why redundant |
|------|-------|---------------|
| `scripts/gateway-entrypoint.sh` | 20 | Exists only to construct DATABASE_URL. Set it directly as env var instead. |
| `deploy/Dockerfile.gateway-v4` | 43 | Copies the entrypoint + plugin. v5 should use ContextForge image directly with env vars. |

### JWKS Check Script (MARGINAL)
| File | Lines | Why |
|------|-------|-----|
| `scripts/check-jwks-ready.sh` | ~50 | Useful for CI/CD but not needed if startup probe is configured correctly |

---

## LIVE GCP RESOURCES (from v4 deployment)

| Resource | Status | Keep for v5? |
|----------|--------|-------------|
| Cloud SQL instance `contextforge` | Running | ✅ Yes — reuse |
| Cloud SQL database `keycloak` | Created | ✅ Yes — reuse |
| Cloud SQL database `contextforge` | Exists from v3 | ✅ Yes — reuse |
| Secret: `keycloak-db-password` | Created | ✅ Yes |
| Secret: `keycloak-admin-password` | Created | ✅ Yes |
| SA: `gateway-sa` | Created | ✅ Yes |
| SA: `keycloak-sa` | Created | ✅ Yes |
| Cloud Run: `keycloak` service | v4.0.4, live | ✅ Yes — working |
| Cloud Run: `fluid-intelligence-v4` service | v4.0.7, live | ⚠️ Review — may redeploy |
| Keycloak client: `fluid-gateway-sso` | Created via Admin API | ✅ Yes |
| Keycloak realm role mapper on `fluid-bootstrap` | Created via Admin API | ✅ Yes |
| Cloud SQL authorized networks: 0.0.0.0/0 | TEMP | ❌ Restrict in v5 |
| Artifact Registry images | keycloak:v4.0.0-v4.0.4, fluid-intelligence:v4.0.0-v4.0.7 | ✅ Keep |
