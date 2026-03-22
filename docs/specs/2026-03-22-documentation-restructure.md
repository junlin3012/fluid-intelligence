# Documentation & Project Restructure — Design Spec

> Status: APPROVED
> Date: 2026-03-22
> Authors: junlin + Claude

---

## Goal

Restructure the Fluid Intelligence repo from a stale v3 monolith layout to a clean v6 multi-service layout. Reorganize all documentation so three audiences (developer, AI agent, stakeholder) can each find what they need.

## What Changed from v3 to v6

| v3 (current main branch) | v6 (current production) |
|---------------------------|-------------------------|
| Single monolith container (5 processes) | 5 separate Cloud Run services |
| mcp-auth-proxy (Go) for OAuth | Keycloak SSO (no custom auth code) |
| entrypoint.sh process supervisor | No orchestrator needed |
| deploy/Dockerfile + Dockerfile.base | Per-service Dockerfiles |
| bootstrap.sh for backend registration | ContextForge Admin UI |
| Custom shopify_oauth Python service | Removed (Keycloak handles auth) |
| config/mcp-config.yaml | Cloud Run env vars |

## Documentation Strategy

### Principle: Each location has ONE job

| Location | Purpose | Audience | Changes when |
|----------|---------|----------|--------------|
| Repo `docs/` | How to work on this codebase | Agents + developers | Code changes |
| Confluence | How the product works, decisions, guides | Humans + stakeholders | Architecture or process changes |
| Claude memory | Cross-session state, preferences | Agents only | Session learnings |

### Principle: No duplication

| Knowledge | Lives in | NOT in |
|-----------|----------|--------|
| How services connect | `docs/architecture.md` | Confluence (link to it) |
| Why we chose Keycloak | Confluence Decisions | Repo |
| How to add a backend | `docs/contributing.md` | Confluence |
| Current Cloud Run URLs | Claude memory | Repo |
| v3 failure analysis | `docs/archive/` (distilled rules in known-gotchas.md) | Raw narratives removed from active docs |

### Approach: Layered — overview + deep dives

One `docs/architecture.md` gives the complete picture (~300 lines). Separate deep-dive files only where detail can't fit (e.g., `config-reference.md` for 25+ env vars per service).

### Historical docs: Distill + archive

Universal lessons extracted as crisp rules in `known-gotchas.md`. Raw failure narratives archived. Agents get the rule; humans get the story in Confluence Retrospectives.

## Project Structure (target)

```
fluid-intelligence/
├── CLAUDE.md                     # Agent instructions
├── README.md                     # Project overview + architecture diagram
├── LICENSE
├── docker-compose.yml            # Local dev stack (all 6 services)
├── .env.example                  # Template for local dev secrets
│
├── services/                     # One folder per deployable Cloud Run service
│   ├── contextforge/             # Stock image, config-only
│   │   └── db/
│   │       └── init.sql            Creates contextforge DB + user
│   ├── keycloak/                 # Custom Dockerfile (realm import)
│   │   ├── Dockerfile
│   │   ├── .dockerignore
│   │   ├── realm-fluid.json
│   │   ├── db/
│   │   │   └── init.sql            Creates keycloak DB + user
│   │   └── tests/
│   │       └── test_realm_json.py
│   ├── apollo/                   # Custom Dockerfile (Rust build)
│   │   ├── Dockerfile
│   │   ├── .dockerignore
│   │   ├── config.yaml
│   │   └── shopify-schema.graphql
│   ├── devmcp/                   # Custom Dockerfile (translate bridge)
│   │   ├── Dockerfile
│   │   ├── .dockerignore
│   │   ├── package.json
│   │   └── package-lock.json
│   └── sheets/                   # Custom Dockerfile (translate bridge)
│       ├── Dockerfile
│       ├── .dockerignore
│       └── requirements.txt
│
├── docs/
│   ├── architecture.md           # System topology, auth flow, service details
│   ├── config-reference.md       # Every env var across all services
│   ├── known-gotchas.md          # Distilled lessons from v3-v6
│   ├── contributing.md           # How to: add backend, deploy, troubleshoot
│   ├── agent-behavior/
│   │   ├── introspect.md           Thinking framework (kept as-is)
│   │   ├── failure-log.md          Distilled to rules
│   │   └── insights.md            Distilled to rules
│   ├── research/                 # Historical research (kept as-is)
│   └── archive/                  # Superseded docs
│       ├── v3/
│       ├── v4/
│       ├── specs/
│       ├── plans/
│       ├── reviews/
│       ├── failure-log-raw.md      Full narrative entries
│       └── insights-raw.md        Full narrative entries
│
└── .postman/                     # API collections (tooling)
```

## architecture.md Outline

```
# Architecture

## System Topology
  - 5 Cloud Run services + 1 Cloud SQL PostgreSQL
  - Diagram showing connections

## Auth Flow
  - Keycloak as identity broker (Google + Microsoft IdPs)
  - ContextForge SSO_KEYCLOAK_ENABLED (native, no custom code)
  - Browser flow diagram
  - Keycloak client config (fluid-gateway-sso)

## Service Details
  For each service:
  - What it does (one sentence)
  - Image source (stock vs custom Dockerfile)
  - Cloud Run URL
  - Key env vars (summary, details in config-reference.md)
  - What's custom code vs configuration

## Inter-Service Communication
  - ContextForge → sidecars: registered via admin UI
  - ContextForge → Keycloak: JWKS fetch
  - FORWARDED_ALLOW_IPS=* requirement

## Custom Code Inventory
  - Per-service: what files, what they do, why custom
  - Explicit: ZERO application code, everything is configuration
```

## config-reference.md Outline

Per-service env var tables with columns: Name, Value/Default, Source (env/secret), Description, Dangerous?

## known-gotchas.md Outline

Distilled one-liner rules with brief context. Example:
```
### FORWARDED_ALLOW_IPS=* on all sidecars
Cloud Run terminates TLS. Without this, Uvicorn returns http:// URLs
in SSE endpoints, breaking MCP handshake. Set on devmcp, sheets, apollo.
```

## contributing.md Outline

```
# Contributing

## Add a New MCP Backend
  1. Create services/<name>/Dockerfile
  2. Build and push image
  3. Deploy to Cloud Run with FORWARDED_ALLOW_IPS=*
  4. Register in ContextForge admin UI

## Deploy a New Version
  Per-service deploy commands

## Rotate Secrets
  Which secrets, where stored, how to rotate

## Troubleshoot SSO
  Common errors and fixes
```

## What Gets Archived

| Current location | Archive to | Why |
|------------------|-----------|-----|
| `docs/agent-behavior/system-understanding.md` | `docs/archive/v3/` | Entirely v3 monolith |
| `docs/agent-behavior/patterns.md` | `docs/archive/v3/` | Entirely v3 patterns |
| `docs/plans/` | `docs/archive/plans/` | Historical |
| `docs/specs/` (v4, v5, OAuth, TDD) | `docs/archive/specs/` | Already done |
| `docs/reviews/` (26 batches) | `docs/archive/reviews/` | Already done |
| `failure-log.md` raw entries | `docs/archive/failure-log-raw.md` | Distilled version replaces |
| `insights.md` raw entries | `docs/archive/insights-raw.md` | Distilled version replaces |

## docker-compose.yml

Replace the v3 docker-compose on main with the v6 version from the worktree. Update paths from `sidecars/` and `keycloak/` to `services/`.

## Files Brought from Worktree to Main

These files currently only exist in `feature/v5-implementation` worktree and need to be on main:

| File | From worktree path | To main path |
|------|-------------------|--------------|
| All service Dockerfiles | `keycloak/`, `sidecars/*/` | `services/*/` |
| realm-fluid.json | `keycloak/` | `services/keycloak/` |
| Apollo config + schema | `sidecars/apollo/` | `services/apollo/` |
| devmcp package files | `sidecars/devmcp/` | `services/devmcp/` |
| sheets requirements | `sidecars/sheets/` | `services/sheets/` |
| init-postgres.sql | `scripts/` | Split into `services/contextforge/db/` and `services/keycloak/db/` |
| docker-compose.yml | root | root (updated paths) |
| .env.example | root | root |
| test_realm_json.py | `tests/keycloak/` | `services/keycloak/tests/` |
| v6 design spec | `docs/specs/` | `docs/specs/` |
| Postman collections | `postman/` | `.postman/` |
