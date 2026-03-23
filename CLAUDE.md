# CLAUDE.md — Agent Instructions for Fluid Intelligence

## What is Fluid Intelligence?

A universal MCP gateway that gives AI clients (Claude, Codex, Cursor) a single intelligent endpoint to access any combination of APIs — with per-user identity, role-based access, config-driven backends, and full audit trails.

Shopify is the first vertical. It is not the last.

## Required Reading

Before ANY work, agents MUST read:
- `docs/architecture.md` — How the system works. Start here.
- `docs/known-gotchas.md` — Things that will bite you. Read before changing config.
- `docs/config-reference.md` — Every env var across all services.
- `docs/agent-behavior/introspect.md` — How to think, challenge assumptions.
- `docs/agent-behavior/failure-log.md` — Distilled rules from past failures.
- `docs/agent-behavior/insights.md` — Patterns that work.

Before writing code, agents MUST read:
- `docs/specs/` — Active design specs. Never implement without checking for an approved spec first.

## Project Structure

```
├── services/                 One folder per Cloud Run service
│   ├── contextforge/           Stock image, DB init only
│   ├── keycloak/               Custom Dockerfile (realm import)
│   ├── apollo/                 Custom Dockerfile (Rust build) + credential-proxy sidecar
│   ├── devmcp/                 Custom Dockerfile (translate bridge)
│   ├── sheets/                 Custom Dockerfile (translate bridge)
│   ├── token-service/          Credential lifecycle manager (Python/FastAPI)
│   └── credential-proxy/       Token injection sidecar (Python/FastAPI)
├── docs/
│   ├── architecture.md         System overview (start here)
│   ├── config-reference.md     All env vars across services
│   ├── known-gotchas.md        Distilled lessons from v3-v6
│   ├── contributing.md         How to add backends, deploy, troubleshoot
│   ├── agent-behavior/         Introspection, failure log, insights
│   ├── research/               Market research, capabilities analysis
│   ├── specs/                  Active design specs
│   └── archive/                Superseded docs (v3 operations, old specs, reviews)
├── docker-compose.yml          Local dev stack (all 8 services)
├── .env.example                Template for local dev secrets
├── CLAUDE.md                   This file
├── README.md
└── LICENSE
```

## Agent Behavior

- **Inventory before designing.** Check what ContextForge/Cloud Run already provide before proposing features.
- **Identity before plumbing.** Answer WHO before HOW. Users are humans with names, not token hashes.
- **Configure, don't code.** This system is config-first. The only application code is token-service + credential-proxy (~525 lines) — justified because no existing component handles OAuth token lifecycle. Everything else is config. Keep it that way.
- **Read source before writing config.** Never guess env var names, CLI flags, or API endpoints.
- **Test locally before Cloud Run.** `docker compose up` + browser test catches everything.
- **Act autonomously.** No confirmation needed before running commands or making changes.

## Agent Self-Improvement (Required)

Agents MUST write back to `docs/agent-behavior/` — not just read from it:

- **After a failure**: Add a distilled rule to `failure-log.md`.
- **After a success**: Add a pattern to `insights.md`.
- **After learning something**: Update `known-gotchas.md` if it's a gotcha, or `architecture.md` if it's structural.
- **At session end**: Reflect — "did I learn something that should be recorded?"

## Project Context

- **Product**: Fluid Intelligence — Universal MCP Gateway
- **First vertical**: Shopify (junlinleather-5148.myshopify.com)
- GCP Project: `junlinleather-mcp` (asia-southeast1)
- Cloud Run URLs: `*-apanptkfaq-as.a.run.app` (contextforge, keycloak, apollo, devmcp, sheets)
- GitHub: `junlin3012/fluid-intelligence` (public)
- Architecture: 5 separate Cloud Run services — see `docs/architecture.md`
- Active spec: `docs/specs/2026-03-21-fluid-intelligence-v6-design.md`
- Confluence: `junlinleather.atlassian.net/wiki/spaces/FI` (Fluid Intelligence knowledge base)

## Competitive Landscape

- 93+ MCP gateway/proxy products exist (as of March 2026)
- Market research: `docs/research/mcp-market-research-2026-03.md`
- Differentiation: identity-first, config-driven backends, per-user access per backend, Shopify vertical expertise
