# Fluid Intelligence

A universal MCP gateway that gives AI clients (Claude, Codex, Cursor) a single intelligent endpoint to access any combination of APIs — GraphQL, REST, SOAP, MCP servers, databases — with per-user identity, role-based access, config-driven backends, and full audit trails.

Shopify is the first vertical. It is not the last.

## Architecture

```
Client (Claude Code / Claude.ai / Cursor)
  │
  ▼
┌─────────────────────────────────────────────────┐
│  Cloud Run Container (:8080)                     │
│                                                  │
│  mcp-auth-proxy (Go)           :8080             │
│  ├── OAuth 2.1 + Google login                    │
│  ├── Per-user allowlists                         │
│  └── Proxies to ContextForge                     │
│                                                  │
│  IBM ContextForge (Python)     :4444             │
│  ├── MCP gateway core                            │
│  ├── Tool aggregation + RBAC                     │
│  └── PostgreSQL-backed state                     │
│                                                  │
│  Apollo MCP Server (Rust)      :8000             │
│  └── Shopify GraphQL operations                  │
│                                                  │
│  dev-mcp bridge (Node.js)      :8003             │
│  └── Shopify docs + schema introspection         │
│                                                  │
│  google-sheets bridge (Python) :8004             │
│  └── Google Sheets via service account           │
└─────────────────────────────────────────────────┘
```

**Traffic flow**: `Client → :8080 (auth-proxy) → :4444 (ContextForge) → backends`

## Project Structure

```
├── deploy/          Infrastructure (Dockerfile, Cloud Build configs)
├── scripts/         Runtime scripts (entrypoint, bootstrap)
├── config/          Service configuration (MCP config)
├── graphql/         Shopify GraphQL operations
├── docs/            Architecture, runbook, research, specs
└── CLAUDE.md        Agent instructions
```

## Quickstart

### Prerequisites

- Google Cloud SDK (`gcloud`) authenticated to `junlinleather-mcp`
- Docker (for local builds)
- `shopify-schema.graphql` — generate via Apollo introspection (not committed, 98K lines)

### Deploy

Push to `main` triggers Cloud Build automatically:

```bash
git push origin main
```

Manual deploy:

```bash
gcloud builds submit --config deploy/cloudbuild.yaml --project junlinleather-mcp
```

Rebuild base image (only when Apollo version changes, ~20 min):

```bash
gcloud builds submit --config deploy/cloudbuild-base.yaml --project junlinleather-mcp --region asia-southeast1
```

### Verify

```bash
# Health check (returns 401 = auth proxy working)
curl https://fluid-intelligence-1056128102929.asia-southeast1.run.app/health

# Check Cloud Run status
gcloud run services describe fluid-intelligence --region asia-southeast1 --project junlinleather-mcp
```

### Connect as MCP Client

Add to `~/.claude.json` under `mcpServers`:

```json
{
  "Fluid-Intelligence": {
    "type": "http",
    "url": "https://fluid-intelligence-1056128102929.asia-southeast1.run.app"
  }
}
```

## Stack

| Component | Technology | Version | Purpose |
|-----------|-----------|---------|---------|
| Gateway | IBM ContextForge | 1.0.0-RC-2 | MCP aggregation, RBAC, audit |
| Auth | mcp-auth-proxy | v2.5.4 | OAuth 2.1, Google login |
| Shopify API | Apollo MCP Server | v1.9.0 | GraphQL operations |
| Shopify Docs | @shopify/dev-mcp | latest | Docs + schema |
| Sheets | mcp-google-sheets | latest | Google Sheets |
| Database | Cloud SQL PostgreSQL | - | Persistent state |
| Runtime | Google Cloud Run | - | asia-southeast1 |

## Configuration

See [.env.example](.env.example) for all environment variables.
See [docs/architecture.md](docs/architecture.md) for detailed system overview.
See [docs/runbook.md](docs/runbook.md) for operations guide.

## License

Apache 2.0 — see [LICENSE](LICENSE).
