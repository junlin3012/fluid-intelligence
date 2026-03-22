# Fluid Intelligence

A universal MCP gateway that gives AI clients (Claude, Codex, Cursor) a single intelligent endpoint to access any combination of APIs — with per-user identity, role-based access, config-driven backends, and full audit trails.

Shopify is the first vertical. It is not the last.

## Architecture

5 Cloud Run services, zero custom application code:

```
┌──────────────────────────────────────────────────────────┐
│  Cloud Run                                               │
│                                                          │
│  contextforge (:8080)  ◄──── keycloak (:8080)            │
│  IBM ContextForge           Keycloak 26.1.4              │
│  MCP gateway + admin UI     Google + Microsoft SSO       │
│       │                                                  │
│       ├── apollo (:8000)    Shopify GraphQL execution     │
│       ├── devmcp (:8003)    Shopify docs + learning      │
│       └── sheets (:8004)    Google Sheets access          │
│                                                          │
└──────────────────────────────────────────────────────────┘
         │
    Cloud SQL PostgreSQL (shared by contextforge + keycloak)
```

**Auth**: Keycloak SSO (Google + Microsoft identity providers) → ContextForge RBAC
**Transport**: Streamable HTTP (Apollo), SSE (devmcp, sheets)
**Custom code**: None — Dockerfiles + config files only

## Project Structure

```
├── services/                 One folder per Cloud Run service
│   ├── contextforge/           Stock image, DB init only
│   ├── keycloak/               Custom Dockerfile (realm import)
│   ├── apollo/                 Custom Dockerfile (Rust build)
│   ├── devmcp/                 Custom Dockerfile (translate bridge)
│   └── sheets/                 Custom Dockerfile (translate bridge)
├── docs/                     Documentation
│   ├── architecture.md         System overview (start here)
│   ├── config-reference.md     All env vars across services
│   ├── known-gotchas.md        Distilled lessons from v3-v6
│   └── contributing.md         How to add backends, deploy, troubleshoot
├── docker-compose.yml        Local dev stack (all 6 services)
└── CLAUDE.md                 Agent instructions
```

## Quickstart (local)

```bash
cp .env.example .env
# Fill in secrets (generate with: openssl rand -base64 32)
docker compose up
# Open http://localhost:8080 → log in with email/password
```

## Docs

- **[Architecture](docs/architecture.md)** — how everything connects
- **[Config Reference](docs/config-reference.md)** — every env var
- **[Known Gotchas](docs/known-gotchas.md)** — things that will bite you
- **[Contributing](docs/contributing.md)** — deploy, add backends, troubleshoot
