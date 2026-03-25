# Current State

> Last updated: 2026-03-25.
> This is how the system actually works TODAY. Not aspirational — real.

---

## How You Use It

Claude Code connects to **two MCP servers** for Shopify work:

```
Claude Code (your terminal)
  │
  ├── apollo-shopify (via mcp-remote)
  │     Executes Shopify GraphQL queries against your real store.
  │     Authenticated with Keycloak.
  │     2 tools: execute, validate
  │
  └── shopify-dev (local, via npx)
        Shopify docs, schema introspection, validation.
        No auth needed (runs locally).
        5 tools: learn_shopify_api, search_docs_chunks, introspect_graphql_schema,
                 validate_graphql_codeblocks, validate_theme
```

**That's it.** 7 tools total. One remote (authenticated), one local.

---

## Apollo Connection — Full Auth Flow

When Claude Code starts, `mcp-remote` connects to Apollo on Cloud Run:

```
1. mcp-remote → POST /mcp → auth-proxy returns 401
                             + WWW-Authenticate: Bearer resource_metadata=".../.well-known/oauth-protected-resource/mcp"

2. mcp-remote → GET /.well-known/oauth-protected-resource/mcp
                → auth-proxy returns: { authorization_servers: ["https://keycloak-...a.run.app/realms/fluid"] }

3. mcp-remote → discovers Keycloak OIDC configuration
                → registers a client via DCR
                → opens your browser for Keycloak login (Google/Microsoft SSO)

4. You log in → Keycloak issues a JWT token → mcp-remote receives it

5. mcp-remote → POST /mcp with Bearer <keycloak-token>
                → auth-proxy validates JWT signature against Keycloak JWKS
                → forwards to Apollo on port 8001
                → Apollo processes MCP request
                → credential-proxy injects Shopify token
                → Shopify API responds

6. Connected. Token is cached — no browser login on next start.
```

### What's in the 3-container Apollo service

```
Cloud Run service: apollo
┌─────────────────────────────────────────────────────┐
│                                                     │
│  auth-proxy (:8000)  →  Apollo (:8001)  →  credential-proxy (:8080)  →  Shopify API
│  Keycloak JWT ✓         MCP server          Injects access token
│  RFC 9728 metadata      GraphQL engine      Fetches from token-service
│  INGRESS                execute + validate   30s token cache
│                                                     │
└─────────────────────────────────────────────────────┘
```

### MCP config in ~/.claude.json

```json
{
  "apollo-shopify": {
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "mcp-remote", "https://apollo-apanptkfaq-as.a.run.app/mcp"]
  },
  "shopify-dev": {
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "@shopify/dev-mcp@latest"]
  }
}
```

---

## Credential Flow — How Shopify Tokens Work

You never touch Shopify credentials. The system handles it:

```
                    ┌─────────────────────────┐
                    │ token-service            │
                    │ (always-on, Cloud Run)   │
                    │                          │
                    │ • Stores OAuth tokens    │
                    │   (AES-256-GCM encrypted)│
                    │ • Refreshes every 45 min │
                    │ • API key required       │
                    └────────────┬─────────────┘
                                 │
                    ┌────────────┴─────────────┐
                    │ credential-proxy          │
                    │ (sidecar inside Apollo)   │
                    │                          │
                    │ • Fetches token on each  │
                    │   request (30s cache)    │
                    │ • Injects header:        │
                    │   X-Shopify-Access-Token │
                    │ • Forwards to Shopify    │
                    └──────────────────────────┘
```

Token-service manages the Shopify OAuth app "Claude MCP" (client ID: `f597c0aaa...`). The app has scopes for products, customers, orders, draft_orders, inventory, fulfillments, discounts, and locations.

---

## Endpoint Security — What's Locked, What's Not

| Service | URL | Auth | Secured? |
|---------|-----|------|----------|
| **apollo** | `apollo-apanptkfaq-as.a.run.app` | Keycloak JWT (auth-proxy) | **YES** |
| **contextforge** | `contextforge-apanptkfaq-as.a.run.app` | Keycloak SSO + PR #3715 JWKS | **YES** |
| **keycloak** | `keycloak-apanptkfaq-as.a.run.app` | Public (login pages) | **OK** (by design) |
| **oauth-proxy** | `oauth-proxy-apanptkfaq-as.a.run.app` | Routes to Keycloak/ContextForge | **YES** |
| **token-service** | `token-service-apanptkfaq-as.a.run.app` | API key on all endpoints | **YES** |
| **devmcp** | `devmcp-apanptkfaq-as.a.run.app` | **NONE** | **NO — wide open** |
| **sheets** | `sheets-apanptkfaq-as.a.run.app` | **NONE** | **NO — wide open** |

**TODO:** Secure devmcp and sheets with auth-proxy sidecar (same pattern as Apollo).

---

## What's Blocked

### ContextForge gateway (not usable from any client)

ContextForge aggregates all backend tools (Apollo + devmcp + sheets) behind a single authenticated endpoint. It's deployed and the auth works. Two bugs prevent using it:

| Client | Bug | What happens |
|--------|-----|-------------|
| **Claude Code** | Anthropic API: `cache_control cannot be set for empty text blocks` | Multi-line tool descriptions (devmcp tools have 1000+ char descriptions with newlines) crash the session. Tool responses are clean — the bug is in Claude Code's message formatting. |
| **Claude.ai** | Bug #82: OAuth state machine incomplete | Claude.ai does DCR (201) and reads metadata (200) but never redirects the user to the Keycloak login page. It loops back to the MCP endpoint without a token. No server-side fix possible. |

**Workaround:** Use Apollo directly (bypasses ContextForge). Works today.

**When it'll be fixed:**
- Claude Code crash: unknown — needs Anthropic fix or ContextForge to shorten tool descriptions
- Claude.ai bug #82: unknown — no Anthropic response on the issue
- ContextForge PR #3715 (our patch): expected in 1.0.0-GA (target: March 31, 2026)

### Claude.ai access (not working)

The oauth-proxy is deployed and all server-side routing works. But Claude.ai's OAuth client is broken. Until Anthropic fixes bug #82, Claude.ai cannot connect to any self-hosted MCP server that uses an external IdP (Keycloak, Auth0, Okta).

---

## What's Deployed on Cloud Run

| Service | Image | Containers | Status |
|---------|-------|-----------|--------|
| apollo | `apollo-authenticated:v4` + `auth-proxy:v4` + `credential-proxy` | 3 | Running |
| contextforge | `mcp-context-forge:1.0.0-RC-2` + PR #3715 patch | 1 | Running |
| keycloak | Custom (realm-fluid.json baked in) | 1 | Running |
| devmcp | ContextForge base + @shopify/dev-mcp | 1 | Running |
| sheets | ContextForge base + mcp-google-sheets | 1 | Running (no creds) |
| token-service | Custom Python/FastAPI | 1 | Running (always-on) |
| oauth-proxy | `caddy:2-alpine` + Caddyfile | 1 | Running |

**GCP Project:** `junlinleather-mcp` (asia-southeast1)
**Store:** `junlinleather-5148.myshopify.com`

---

## What Apollo Can Do

| Tool | What | Example |
|------|------|---------|
| **execute** | Run any Shopify GraphQL query | `{ products(first: 10) { edges { node { title } } } }` |
| **validate** | Check if a query is valid against the schema | Catches typos, wrong fields before execution |

**Not enabled yet** (config change needed):
- `introspect` — explore the schema ("what fields does Product have?")
- `search` — full-text search across the 98K-line schema
- `mutation_mode: all` — enable write operations (create orders, update products)

Currently read-only. Mutations are blocked by default (`mutation_mode: none`).
