# Plugin Hooks & Lifecycle — Future Design Reference

> Written 2026-03-19 during v4 brainstorming. This documents the FULL vision for plugin extensibility.
> v4 ships with config-only plugins. Hooks and lifecycle are reserved in the schema for future implementation.

---

## Overview

A plugin in Fluid Intelligence has three layers of capability:

| Layer | What it does | v4 status |
|-------|-------------|-----------|
| **Config** | Declares backends, tools, env vars, auth scopes | Ship in v4.0 |
| **Hooks** | Custom code that intercepts requests/responses | Reserved in schema, implement when needed |
| **Lifecycle** | Events that fire on plugin start/stop/health | Reserved in schema, implement when needed |

## Hooks

Hooks are interception points — moments where custom code runs before or after the gateway executes a tool.

### Flow

```
Client request comes in
     │
     ▼
  ┌─────────────────┐
  │ BEFORE hook      │ ← custom code: can modify, reject, or log
  └─────────────────┘
     │
     ▼
  Gateway executes the tool
     │
     ▼
  ┌─────────────────┐
  │ AFTER hook       │ ← custom code: can modify response, log, charge
  └─────────────────┘
     │
     ▼
  Response sent to client
```

### Hook types

| Hook | When it fires | What it can do |
|------|--------------|----------------|
| `before_tool_call` | Before a tool executes | Validate input, estimate cost, check budget, reject |
| `after_tool_call` | After a tool returns | Redact PII, log usage, transform response |
| `on_auth` | After user authenticates | Enrich user context, check tenant permissions |
| `on_error` | When a tool call fails | Custom error handling, retry logic, alerting |

### Business scenarios that require hooks

**1. Usage billing (SaaS monetization)**
Selling AI-powered Shopify access as a service. Each API call costs compute + Shopify rate limit budget. An `after_tool_call` hook logs every execution with tenant ID, tool name, and estimated cost. Monthly billing aggregates this data.

**2. PII redaction (privacy compliance)**
Viewer-role users shouldn't see full customer emails. An `after_tool_call` hook scans responses for PII patterns and redacts based on user role. `john@gmail.com` → `j***@gmail.com` for viewers. Admins see full data.

**3. Query cost gate (resource protection)**
An AI composes `products(first:250){variants(first:250)}` — 62,500 nodes. A `before_tool_call` hook estimates GraphQL cost, compares to tenant budget, rejects if over limit: "This query costs ~2,000 points. Your budget allows 1,000."

**4. Audit compliance (GDPR, privacy regulations)**
Regulations require logging every access to personal data. A `before_tool_call` hook captures user identity + parameters. An `after_tool_call` hook captures whether personal data was returned. Both write to an immutable audit log.

**5. Per-tenant rate limiting (fair usage)**
Store A: free plan (100 calls/day). Store B: premium (unlimited). A `before_tool_call` hook checks the tenant's plan and usage count, returns "Rate limit exceeded" without hitting the backend.

### Future plugin YAML with hooks

```yaml
# plugins/shopify.yaml (future — when hooks are implemented)
name: shopify
description: "Shopify store management"

backends:
  - name: shopify-executor
    image: apollo-mcp-server:1.9.0
    transport: streamable_http

hooks:
  before_tool_call:
    - name: cost-gate
      handler: hooks/shopify-cost-gate.py
      config:
        max_cost_per_query: 1000

  after_tool_call:
    - name: usage-logger
      handler: hooks/usage-logger.py
      config:
        log_target: bigquery

    - name: pii-redactor
      handler: hooks/pii-redactor.py
      config:
        redact_for_roles: [viewer]
        patterns: [email, phone, address]
```

## Lifecycle Methods

Lifecycle methods fire when a plugin starts, stops, or changes state — not per-request, but per-plugin-lifetime.

### Flow

```
Plugin installed/configured
     │
     ▼
  ┌─────────────────┐
  │ onInit()         │ ← validate config, test connections, warm caches
  └─────────────────┘
     │
     ▼
  Plugin running... handling requests...
     │
     ▼
  ┌─────────────────┐
  │ onHealthCheck()  │ ← periodic: is the backend still alive?
  └─────────────────┘
     │
     ▼
  Admin removes/reconfigures plugin
     │
     ▼
  ┌─────────────────┐
  │ onShutdown()     │ ← clean up connections, flush logs, revoke tokens
  └─────────────────┘
```

### Lifecycle events

| Event | When it fires | Use case |
|-------|--------------|----------|
| `onInit()` | Plugin starts | Validate OAuth tokens, test backend connectivity, warm schema cache |
| `onHealthCheck()` | Periodic (configurable) | Verify backend is alive, detect API version changes, refresh tokens |
| `onShutdown()` | Plugin removed or container stopping | Flush buffers, close DB connections, revoke temporary tokens |
| `onConfigChange()` | Admin updates plugin config | Hot-reload without restart, validate new config before applying |

### Business scenarios that require lifecycle methods

**1. OAuth token refresh**
Shopify tokens expire. `onInit()` validates the token on startup; if expired, refreshes via client credentials flow. `onHealthCheck()` periodically re-validates. Without this, a dead token causes silent failures.

**2. Schema evolution detection**
Shopify releases API version 2026-04. `onHealthCheck()` compares the deployed schema version to Shopify's latest. If changed, alerts the admin or triggers schema reload.

**3. Graceful shutdown**
Cloud Run scales down. A plugin has pending webhook deliveries buffered in memory. `onShutdown()` flushes to database before the container dies.

**4. Connection pool management**
A database plugin opens 5 connections on startup. Admin disables the plugin. `onInit()` creates the pool; `onShutdown()` drains and closes it. Without lifecycle, connections leak on every reconfigure.

### Future plugin YAML with lifecycle

```yaml
# plugins/shopify.yaml (future — when lifecycle is implemented)
name: shopify

lifecycle:
  onInit:
    handler: lifecycle/shopify-init.py
    config:
      validate_token: true
      warm_schema_cache: true

  onHealthCheck:
    handler: lifecycle/shopify-health.py
    interval: 300  # seconds
    config:
      check_api_version: true
      refresh_token_if_expiring: true

  onShutdown:
    handler: lifecycle/shopify-shutdown.py
    config:
      flush_audit_log: true
      timeout: 30  # seconds
```

## Design Principle

The plugin schema reserves `hooks:` and `lifecycle:` fields from v4.0. The gateway ignores them until the execution engine is built. This means:

1. Plugin authors can start writing hook/lifecycle definitions in YAML today
2. The gateway validates the schema but skips execution
3. When the engine ships, existing plugin configs "light up" without changes
4. No architecture change needed — just add the execution engine

This follows the v4 principle: **code stays the same, capabilities expand through config.**

## ContextForge Integration

ContextForge 1.0.0-RC-2 already has a plugin system with 16 hook points. The v4 hook layer should delegate to ContextForge's plugin system where possible, adding a config-driven interface on top. This avoids reimplementing what ContextForge already provides.

Known ContextForge hooks (from source analysis):
- `pre_tool_call` / `post_tool_call`
- `pre_gateway_request` / `post_gateway_response`
- `on_error`
- `on_session_start` / `on_session_end`
- And 9 more (see `docs/agent-behavior/project_contextforge_plugins_deep.md`)

The mapping: our plugin YAML `hooks.before_tool_call` → ContextForge's `pre_tool_call` hook. Our config-driven interface wraps ContextForge's code-driven one.
