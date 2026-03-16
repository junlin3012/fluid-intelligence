# Live Mode Mirror Polish Batch 1

**Date**: 2026-03-16
**Target**: Live gateway at `https://fluid-intelligence-1056128102929.asia-southeast1.run.app`
**Mode**: Live system validation
**Method**: Deploy + E2E probes
**Clean batch counter**: 0/8

## Issues Found

| # | Severity | Issue | Fix | Status |
|---|----------|-------|-----|--------|
| 1 | Critical | Liveness probe hits auth-proxy port 8080 → 401 → crash loop | Changed probe to ContextForge port 4444 | **FIXED + DEPLOYED** |
| 2 | Critical | `flock` not in base image (Dockerfile.base not rebuilt) | Rebuilt base image | **FIXED + DEPLOYED** |
| 3 | Critical | `flock` absence silently skips bootstrap (`! flock` = `! 127` = true) | Added `command -v flock` check with graceful degradation | **FIXED + DEPLOYED** |
| 4 | Critical | Apollo crashes on startup: `timeout` key unsupported in mcp-config.yaml | Removed `timeout: 30` from config | **FIXED + DEPLOYED** |
| 5 | High | Cloud Build regional trigger needs `logging: CLOUD_LOGGING_ONLY` | Added to cloudbuild.yaml | **FIXED + DEPLOYED** |
| 6 | High | `shopify-schema.graphql` in .gitignore but Dockerfile COPYs it | Un-gitignored, committed to repo | **FIXED + DEPLOYED** |
| 7 | High | `auth-encryption-secret` missing from GCP Secret Manager | Created secret + granted IAM | **FIXED** |
| 8 | Blocking | ContextForge `/gateways` tool discovery hangs (Apollo registered but discovery timeout) | **INVESTIGATING** | OPEN |

## Observations

| Finding | Assessment |
|---------|-----------|
| OAuth discovery (`/.well-known/oauth-authorization-server`) returns correct PKCE/S256 config | Working correctly |
| Auth-proxy returns proper OAuth error messages (401, 400 with RFC-compliant error codes) | Working correctly |
| ContextForge health (`/health` on port 4444) responding after liveness fix | Working correctly |
| Container starts all 5 processes in ~21s consistently | Healthy startup |
| MCP handshake probe works — Apollo subprocess responds to `initialize` after config fix | Working correctly |

## Current Status

Gateway starts, all processes run, Apollo subprocess is alive and responds to MCP initialize. But ContextForge's `/gateways` tool discovery hangs during backend registration. The registration POST never returns within 60s. This blocks all backend registration and leaves the MCP endpoint with zero tools.

**Next investigation**: Why does `/gateways` tool discovery hang? The MCP initialize works (200 response via `/message`), so the subprocess is alive. But ContextForge's internal tool discovery mechanism may use a different code path than the SSE `/message` endpoint.

## Fix trend: 7 fixes in batch 1 (plus 1 open blocker)
