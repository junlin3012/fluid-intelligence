# Repo Reorganization — Professional-Grade Structure

**Date**: 2026-03-15
**Status**: Approved

## Goal

Transform the flat deployment repo into a well-organized, professional-grade codebase that's clear for contributors, productive for AI agents, and production-ready.

## Target Structure

```
fluid-intelligence/
├── README.md                  ← Project overview, architecture, quickstart
├── LICENSE                    ← Apache 2.0
├── .env.example               ← All env vars documented
├── .gitignore                 ← Updated (add schema, config patterns)
├── CLAUDE.md                  ← Updated paths
│
├── deploy/                    ← Infrastructure-as-code
│   ├── Dockerfile
│   ├── Dockerfile.base
│   ├── cloudbuild.yaml
│   └── cloudbuild-base.yaml
│
├── scripts/                   ← Runtime scripts
│   ├── entrypoint.sh
│   └── bootstrap.sh
│
├── config/                    ← Service configuration
│   └── mcp-config.yaml
│
├── graphql/                   ← Shopify GraphQL operations (unchanged)
│   ├── customers/
│   ├── orders/
│   ├── products/
│   ├── inventory/
│   ├── fulfillments/
│   ├── metafields/
│   └── transfers/
│
├── shopify-schema.graphql     ← GITIGNORED (98K lines, regeneratable)
│
└── docs/
    ├── architecture.md        ← Clean 1-page system overview
    ├── runbook.md             ← Deploy, troubleshoot, rotate secrets
    ├── agent-behavior/        ← Agent self-improvement docs (kept as-is)
    ├── research/              ← Market research (kept as-is)
    ├── specs/                 ← Design specs (flattened from superpowers/specs/)
    └── plans/                 ← Implementation plans (flattened from superpowers/plans/)
```

## Changes

### Moves
- `Dockerfile` → `deploy/Dockerfile`
- `Dockerfile.base` → `deploy/Dockerfile.base`
- `cloudbuild.yaml` → `deploy/cloudbuild.yaml`
- `cloudbuild-base.yaml` → `deploy/cloudbuild-base.yaml`
- `entrypoint.sh` → `scripts/entrypoint.sh`
- `bootstrap.sh` → `scripts/bootstrap.sh`
- `mcp-config.yaml` → `config/mcp-config.yaml`
- `docs/superpowers/specs/*` → `docs/specs/*`
- `docs/superpowers/plans/*` → `docs/plans/*`
- `.dockerignore` and `.gcloudignore` stay at repo root (required by Docker/gcloud)

### Path Updates Required
- `deploy/Dockerfile`: COPY paths for scripts/, config/, graphql/
- `deploy/cloudbuild.yaml`: `-f deploy/Dockerfile .` (context = repo root)
- `deploy/cloudbuild-base.yaml`: `-f deploy/Dockerfile.base .`
- `CLAUDE.md`: all doc path references

### New Files
- `README.md`: project overview, architecture diagram, quickstart, deploy
- `LICENSE`: Apache 2.0
- `.env.example`: all env vars with descriptions
- `docs/architecture.md`: extracted from system-understanding.md
- `docs/runbook.md`: deploy, troubleshoot, rotate secrets

### Gitignore Additions
- `shopify-schema.graphql` (98K lines, regeneratable via Apollo introspection)

### Agent-Behavior Docs Decision
Keep as-is. After review, the content is high-quality accumulated wisdom, not noise. The insights.md (17K lines) contains genuine competitive analysis and hard-won deployment lessons that would be expensive to re-learn.

### patterns.md Staleness
`docs/agent-behavior/patterns.md` has stale info (references `deploy.sh`, Node.js entrypoint, RS256 JWT — all from v2 architecture). Will be updated to reflect v3 reality.
