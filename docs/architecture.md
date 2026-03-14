# Architecture

Fluid Intelligence runs as a single Cloud Run container with 5 processes orchestrated by `tini` + `entrypoint.sh`.

## Service Map

```
Cloud Run container (:8080 exposed)
├── tini (PID 1, init process)
└── entrypoint.sh (orchestrator)
    ├── 1. Apollo MCP Server (Rust)        :8000  — Shopify GraphQL ops
    ├── 2. ContextForge (Python/FastAPI)    :4444  — MCP gateway core
    ├── 3. dev-mcp bridge (Python+Node)     :8003  — Shopify docs (stdio→SSE)
    ├── 4. google-sheets bridge (Python)    :8004  — Google Sheets (stdio→SSE)
    └── 5. mcp-auth-proxy (Go)             :8080  — OAuth 2.1 front door
```

## Request Flow

```
Client request
  → :8080 mcp-auth-proxy (validates OAuth token or password)
  → :4444 ContextForge (routes to backend, applies RBAC, logs audit trail)
  → :8000/:8003/:8004 backend MCP servers
  → response aggregated back to client
```

## Startup Sequence

1. `entrypoint.sh` fetches Shopify access token (client credentials flow, 5 retries)
2. Apollo starts on :8000 (Rust, ~1s cold start)
3. ContextForge starts on :4444 (Python/Gunicorn, ~10-15s cold start)
4. stdio bridges start on :8003 (dev-mcp) and :8004 (google-sheets)
5. Script waits for ContextForge health check (up to 180s)
6. mcp-auth-proxy starts on :8080 (Go, ~1s)
7. `bootstrap.sh` registers all 3 backends with ContextForge via JWT-authenticated API
8. Process monitor: if any process dies, all are killed and the container exits

## Base Image

IBM ContextForge 1.0.0-RC-2 on Red Hat UBI 10 Minimal:
- Package manager: `microdnf` (not apt, not apk)
- Python venv: `/app/.venv/` — do NOT modify with pip/uv
- Entry point: direct `main()` invocation (CLI script is broken after venv modification)
- `file` command not available (minimal image)

## Two-Layer Docker Build

| Layer | Image | Rebuild When | Build Time |
|-------|-------|-------------|------------|
| Base | `fluid-intelligence-base` | Apollo version changes | ~20 min (Rust compile) |
| App | `fluid-intelligence` | Config/script changes | ~60s |

## Database

Cloud SQL PostgreSQL (`db-f1-micro`, ~$8/mo):
- Instance: `junlinleather-mcp:asia-southeast1:contextforge`
- Connected via Cloud SQL proxy (Unix socket at `/cloudsql/...`)
- Stores: gateway registrations, tool cache, session state, audit logs

## Authentication

Two modes, handled by mcp-auth-proxy:
- **Google OAuth**: For browser-based clients (Claude.ai). Allowlist: `GOOGLE_ALLOWED_USERS`
- **Password**: For CLI clients (Claude Code). Set via `AUTH_PASSWORD`

## Key Environment Variables

| Variable | Component | Notes |
|----------|-----------|-------|
| `MCG_PORT` | ContextForge | Listen port. NOT `PORT` (Cloud Run reserves that) |
| `MCG_HOST` | ContextForge | Must be `0.0.0.0` in containers |
| `EXTERNAL_URL` | mcp-auth-proxy | Public URL for OAuth redirects |
| `AUTH_PASSWORD` | mcp-auth-proxy | CLI authentication |
| `JWT_SECRET_KEY` | ContextForge | Signs admin JWT tokens |

See [../.env.example](../.env.example) for the complete list.

## Cloud Run Configuration

- Region: `asia-southeast1`
- CPU: 2 vCPU, 2Gi memory
- `--no-cpu-throttling` (REQUIRED for background processes)
- `--min-instances=1` (avoid cold starts)
- `--max-instances=1` (in-memory auth state prevents horizontal scaling)
- Startup probe: TCP :8080, 48 failures x 5s = 240s timeout
