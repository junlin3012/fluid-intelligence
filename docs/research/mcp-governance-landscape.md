# MCP Governance & Security — Market Research

> Date: 2026-03-12
> Context: Research into open-source tools for MCP governance, security, and policy enforcement to inform JunLin MCP server hardening and potential SaaS product direction.

## Problem Statement

MCP servers expose powerful capabilities (Shopify mutations, database access, etc.) directly to AI agents. Without governance:
- AI can execute destructive operations ("delete all customers")
- No audit trail of what the AI did and why
- No rate limiting or policy enforcement at the tool level
- No human-in-the-loop approval for high-risk operations

## Five Categories of Solutions Found

### 1. Progressive MCP (PMCP) — Context Bloat Prevention
**Pattern**: Progressive disclosure of tools via meta-tools.

- Instead of exposing all tools at once (our 341KB problem), expose ~5 meta-tools: `search_tools`, `get_tool_details`, `execute_tool`
- Claude discovers tools in phases: browse categories → get specific tool schema → execute
- Directly addresses our introspection bloat issue
- **Key Repo**: [anthropics/pmcp](https://github.com/anthropics/pmcp) — 16 meta-tools reference implementation

### 2. mcpwall — Security Policy Enforcement
**Pattern**: YAML-defined policies with bidirectional scanning.

- Define policies in YAML: which tools can be called, with what parameters, by whom
- Scans both input (what Claude sends) and output (what the server returns)
- Blocks operations that violate policies before they reach the backend
- Example policy: "CancelOrder only allowed for orders < 24h old"
- **Key Repo**: [nicobailey/mcpwall](https://github.com/nicobailey/mcpwall)

### 3. AuthMCP Gateway — Authentication & Authorization
**Pattern**: OAuth + RBAC gateway in front of MCP servers.

- Dynamic Client Registration (DCR) per RFC 7591
- Role-based access control (RBAC) on MCP tools
- Token-scoped permissions: some clients get read-only, others get full access
- **Key Repo**: [pcarion/authmcp](https://github.com/pcarion/authmcp)

### 4. GIA — Enterprise Governance (MAI Framework)
**Pattern**: Hash-chained audit logs + comprehensive governance.

- Every AI action recorded with tamper-proof hash chain
- Policy engine evaluates requests against rules before execution
- Compliance reporting (SOC2, GDPR audit requirements)
- Agent identity management (which AI agent did what)
- **Concept**: Model-Agent Interaction (MAI) framework — governance layer between model and tools

### 5. MCP-Dandan — Threat Detection
**Pattern**: Multi-engine threat scanning on MCP traffic.

- 5 threat detection engines (pattern matching, anomaly detection, YARA rules, reputation, behavioral)
- Catches prompt injection attempts flowing through MCP tools
- Detects unusual access patterns (e.g., sudden bulk reads before a delete)
- Real-time alerting on suspicious MCP activity

## Architecture Insight: The Intelligence Layer

The research revealed a common pattern — a **governance proxy** that sits between Claude and MCP servers:

```
Claude → [Governance Proxy] → MCP Server → Backend API
              │
              ├── Policy Engine (allow/deny/require-approval)
              ├── Audit Log (hash-chained, tamper-proof)
              ├── Rate Limiter (per-tool, per-user, per-time-window)
              ├── Input Sanitizer (prevent injection)
              ├── Human-in-the-Loop (Slack/webhook approval for destructive ops)
              └── Auth/AuthZ (OAuth 2.1, RBAC, scoped tokens)
```

This is distinct from nginx rate limiting (which is per-request). The governance layer understands MCP semantics — it knows the difference between a `CreateCustomer` and a `CancelOrder` and can apply different policies.

## Key Takeaway

No single tool covers everything. A production-grade solution combines:
1. **PMCP** concepts for context management (DONE — our introspection fix)
2. **mcpwall** concepts for tool-level policy enforcement
3. **OAuth 2.1** for authentication (DONE — our OAuth server)
4. **Audit logging** for compliance
5. **Human-in-the-loop** for destructive operations (NEXT priority)

## Relevance to JunLin

| Need | Status | Solution |
|------|--------|----------|
| Reduce 341KB introspection | ✅ Fixed | Disabled full schema dump, kept search+execute |
| OAuth 2.1 for Claude.ai | ✅ Built | oauth-server/server.js |
| Block destructive mutations | ⬜ TODO | Policy engine (mcpwall pattern) |
| Human approval for deletes | ⬜ TODO | Slack/Google Chat webhook integration |
| Audit trail | ⬜ TODO | Structured logging → BigQuery pipeline |
| Prompt injection defense | ⬜ Later | Input scanning on MCP tool arguments |
