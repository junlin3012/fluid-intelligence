# Mono-Repo Folder Reorganization

**Date**: 2026-03-24
**Status**: Approved
**Scope**: File moves + path updates only. No code changes.

## Principle

The platform is the product. Verticals are consumers of the platform.

## Structure

```
services/
├── platform/                    ← Gateway infrastructure (provider-agnostic)
│   ├── contextforge/              MCP gateway + admin UI
│   ├── keycloak/                  Identity broker (SSO)
│   ├── token-service/             Credential lifecycle manager
│   └── credential-proxy/          Token injection sidecar
├── verticals/                   ← Third-party API integrations (consumers of platform)
│   ├── shopify/
│   │   ├── apollo/                Shopify GraphQL execution
│   │   └── devmcp/                Shopify docs/learning
│   └── google/
│       └── sheets/                Google Sheets read/write
└── db-init.sh                   ← Shared DB bootstrap
```

## Changes

| Action | Target |
|---|---|
| `mkdir` | `services/platform/`, `services/verticals/shopify/`, `services/verticals/google/` |
| `git mv` | contextforge, keycloak, token-service, credential-proxy → `services/platform/` |
| `git mv` | apollo, devmcp → `services/verticals/shopify/` |
| `git mv` | sheets → `services/verticals/google/` |
| Delete | `services/shopify_oauth/`, `services/__pycache__/` |
| Update | `docker-compose.yml` — all `build.context` and `volumes` paths |
| Update | `services/db-init.sh` mount path in docker-compose postgres volumes |
| Update | `CLAUDE.md` — project structure tree |
| Update | `docs/architecture.md` — custom code inventory file paths |
| Update | `services/token-service/cloudbuild.yaml` — `dir` path |
| Update | `services/credential-proxy/cloudbuild.yaml` — `dir` path |
| Update | `shopify.app.toml` — no path changes needed (app-level config) |

## What does NOT change

- No code changes (only file moves + path updates)
- Cloud Run deployments (Dockerfiles are self-contained)
- `.env.example`, `docs/`, `docker-compose.yml` stay at root
- `db-init.sh` stays in `services/` (shared across all verticals)

## Future verticals

Adding a new vertical:
```
services/verticals/meta/
services/verticals/quickbooks/
services/verticals/klaviyo/
```

Each vertical is a consumer of `services/platform/`. The platform never references verticals.
