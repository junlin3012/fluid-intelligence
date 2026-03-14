# MCP Market Research — March 2026

> Research conducted 2026-03-14. 93+ products identified across 7 categories.

## Market Overview

- **4,574+ GitHub repos** tagged `model-context-protocol`
- **99 repos** tagged `mcp-gateway`, **40 repos** tagged `mcp-proxy`
- Market is young, fragmented, in land-grab mode
- Most projects < 1 year old
- Open source dominates (MIT/Apache 2.0)
- Two convergence patterns: AI gateways adding MCP vs. MCP-native gateways

## Top Competitors (MCP Gateways)

| Product | Stars | Auth | Multi-user | Key Feature |
|---------|-------|------|------------|-------------|
| Archestra | 3,500 | OAuth, API keys | Teams, orgs | CNCF/LF, dual security sub-agents, 45ms p95 |
| IBM ContextForge | 3,400 | JWT, SSO | Multi-cluster | MCP + A2A + REST/gRPC, 400+ tests, OpenTelemetry |
| MetaMCP | 2,100 | OAuth, OIDC, API keys | Multi-tenant | Tool overrides, MCP-to-OpenAPI conversion |
| Unla | 2,100 | OAuth, JWT | Multi-tenant | Zero-code REST → MCP via YAML config |
| MCPHub | 1,900 | OAuth 2.0, social login | PostgreSQL | Smart semantic routing |
| agentgateway | 1,900 | RBAC, multi-tenant | K8s-native | Linux Foundation, Rust, xDS config |
| MCPJungle | 903 | Bearer tokens | Enterprise mode | Go binary, OpenTelemetry |
| mcp-gateway-registry | 485 | Keycloak, Entra ID | Full IAM | SOC 2/GDPR, A2A federation |
| 1MCP | 396 | OAuth 2.1 | Scoped | Hot-reload, standalone binaries |

## AI Gateways with MCP Support

| Product | Stars | MCP Feature |
|---------|-------|-------------|
| Kong | 42,900 | MCP auth plugin, auto-generate MCP from Kong APIs |
| LiteLLM | 39,000 | MCP bridge, tools via /chat/completions |
| Portkey | 10,900 | MCP Gateway, identity forwarding, SOC2/HIPAA |
| Bifrost | 2,900 | 11us overhead, enterprise MCP gateway |

## Identity/Auth Products

| Product | Stars | Approach |
|---------|-------|----------|
| Casdoor | 13,100 | Full IAM (OIDC/SAML/LDAP) + MCP gateway |
| Traefik Hub | N/A | TBAC (per-task/tool/transaction auth), NASA/Siemens |
| Arcade.dev | 824 | Per-user OAuth, ex-Okta team |
| mcp-auth-proxy | 74 | Drop-in OAuth 2.1 for any MCP server |
| SGNL | N/A | Acquired by CrowdStrike for $740M (Jan 2026) |

## API-to-MCP Bridges

| Tool | Stars | Protocols |
|------|-------|-----------|
| fastapi_mcp | 11,700 | FastAPI → MCP (zero-config) |
| mcp-link | 603 | Dynamic proxy: any OpenAPI → MCP via URL |
| openapi-mcp-generator | 539 | OpenAPI → full MCP server code |
| mcp-graphql | 365 | Generic GraphQL → MCP |
| Apollo MCP Server | 271 | GraphQL → MCP (persisted ops, Rust) |
| anythingmcp | 6 | REST + SOAP + GraphQL + databases |
| skyline-mcp | 3 | 17+ protocols including WSDL/SOAP |
| mcp2ws | 4 | SOAP/WSDL → MCP (primitive types only) |

## MCP Marketplaces/Registries

| Platform | Scale |
|----------|-------|
| Glama | 19,252+ servers cataloged |
| Smithery | 5,000+ servers, managed OAuth |
| Docker MCP Catalog | 300+ verified servers |

## Key Market Insights

1. **Identity is the highest-value gap.** SGNL acquired for $740M. Casdoor at 13K stars. Identity-first design is validated.
2. **No dominant winner yet.** 93+ products, highest MCP-native gateway at 3.5K stars. Land-grab phase.
3. **TBAC is emerging.** Traefik's per-task/tool/transaction auth is a new pattern beyond RBAC.
4. **A2A + MCP convergence.** AgentGateway, IBM ContextForge, Casdoor support both protocols.
5. **OpenAPI auto-import is table stakes.** Multiple tools convert Swagger specs to MCP tools automatically.
6. **SOAP is severely underserved.** Best dedicated tool has 4 stars. Huge gap for enterprise legacy systems.
7. **Config-driven is the winning pattern.** Unla (YAML config, zero code) has 2.1K stars. Users don't want to write backend adapter code.

## Fluid Intelligence Positioning

### Differentiation
- **Identity-first**: Per-user names, not token hashes (most competitors use generic API keys)
- **Config-driven backends**: YAML config to add any backend, no code changes
- **Per-user per-backend access**: User A sees Shopify + Sheets, User B sees only Sheets
- **Vertical expertise**: Shopify knowledge (dev-mcp) + operations (Apollo) in one endpoint
- **Branded UX**: Custom OAuth form, helpful errors, not bare HTML

### Gaps to Close for Product Viability
1. Web admin dashboard (MCPHub, MetaMCP, Archestra have this)
2. OpenAPI auto-import (Unla, mcp-link have this)
3. OpenTelemetry (IBM ContextForge, MCPJungle have this)
4. YAML policy engine (Traefik Hub, PolicyLayer have this)
5. Terraform/Helm (Archestra, mcp-gateway-registry have this)
