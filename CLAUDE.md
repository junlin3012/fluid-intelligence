# CLAUDE.md — Agent Instructions for Fluid Intelligence

## What is Fluid Intelligence?

A universal MCP gateway that gives AI clients (Claude, Codex, Cursor) a single intelligent endpoint to access any combination of APIs — GraphQL, REST, SOAP, MCP servers, databases — with per-user identity, role-based access, config-driven backends, and full audit trails.

Shopify is the first vertical. It is not the last.

## Required Reading

Before proposing any design or architecture, agents MUST read:
- `docs/agent-behavior/introspect.md` — Introspection protocol. How to think, challenge assumptions, catch blind spots.
- `docs/agent-behavior/failure-log.md` — Past failures. Learn from them, don't repeat them.
- `docs/agent-behavior/insights.md` — What worked well. Patterns to reuse.
- `docs/agent-behavior/patterns.md` — Codebase-specific conventions and patterns.

Before writing code, agents MUST read:
- `docs/superpowers/specs/` — Active design specs. Never implement without checking for an approved spec first.

## Agent Behavior

- **Think from first principles.** Do not anchor on existing code. The current architecture is a POC — challenge every assumption.
- **Identity before plumbing.** Every security design must answer WHO before HOW. Users are humans with names, not token hashes.
- **Think big, build small.** The architecture should support a universal MCP gateway. Each phase delivers a working product.
- **No premature "done."** Run the Magnum Opus Test checklist (in introspect.md) before declaring any design complete.
- **Act autonomously.** No confirmation needed before running commands, deploying, or making changes. The user trusts you to act.

## Agent Self-Improvement (Required)

Agents MUST write back to `docs/agent-behavior/` — not just read from it:

- **After a failure**: Add the failure and root cause to `failure-log.md`. Update `introspect.md` if a new trap or anti-pattern was discovered.
- **After a success**: Add the insight to `insights.md`. What pattern worked? What should future agents reuse?
- **After learning a codebase pattern**: Add it to `patterns.md`.
- **After finding introspect.md is wrong or incomplete**: Fix it. The document is a living system, not sacred text.
- **At session end**: Reflect — "did I learn something that should be recorded?" If yes, write it down.

The goal: each agent session leaves this system smarter than it found it.

## Project Context

- **Product**: Fluid Intelligence — Universal MCP Gateway
- **First vertical**: Shopify (junlinleather-5148.myshopify.com)
- GCP Project: `junlinleather-mcp` (asia-southeast1)
- Cloud Run URL: `https://junlin-shopify-mcp-1056128102929.asia-southeast1.run.app`
- GitHub: `junlin3012/junlin-shopify-mcp` (public, branch protection on main)
- Architecture: Config-driven MCP Gateway (Node.js) aggregating any number of backends (Apollo, dev-mcp, Google Sheets, REST, future)
- See `docs/superpowers/specs/2026-03-14-mcp-gateway-design.md` for the active design spec

## Competitive Landscape

- 93+ MCP gateway/proxy products exist (as of March 2026)
- Top competitors: MetaMCP (2.1k stars), MCPHub (1.9k), Unla (2.1k), Archestra (3.5k), IBM ContextForge (3.4k)
- Market research: `docs/research/mcp-market-research-2026-03.md`
- Differentiation: identity-first, config-driven backends, per-user access per backend, Shopify vertical expertise
