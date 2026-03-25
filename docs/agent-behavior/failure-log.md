# Failure Log

> Distilled rules from past failures. Full narratives: `docs/archive/failure-log-raw.md`
> Agents: add new entries as they happen. Keep them short — rule + context.

---

## Rules (v3-v6)

1. **Inventory before designing.** Check what ContextForge/Cloud Run already provide before proposing features. (v3: designed observability that already existed)

2. **Identity before plumbing.** Answer WHO before HOW. Without user identity, logging, admin tools, and security audits are useless. (v3: entire gateway had no concept of users)

3. **No hardcoded business values.** Emails, domains, project IDs, URLs must come from env vars. 47 hardcoded values found in v3. (v3: `ourteam@junlinleather.com` in scripts)

4. **Read source code before writing config.** Apollo flags, ContextForge port variables, health endpoints — all were wrong when guessed. (v3: 3 wrong assumptions in one entrypoint)

5. **Fix ALL issues before deploying.** One thorough log read beats five guess-and-check deploys. Each Cloud Build costs ~$0.50-1.00. (v3: 5+ wasted builds)

6. **Don't pip install into third-party venvs.** `uv pip install` into ContextForge venv broke CLI entry points while leaving imports working. (v3: psycopg2 install was redundant AND destructive)

7. **`AUTH_REQUIRED` and `TRUST_PROXY_AUTH` are independent.** `AUTH_REQUIRED=true` rejects requests without Bearer token. Proxy auth only provides identity. With header stripping, `AUTH_REQUIRED=true` always fails. (v3: broke twice)

8. **When a tool silently drops inputs, bypass it.** Apollo's file-loading dropped 5/7 queries silently. `introspection.execute` is the correct approach. (v3: 8+ deploys debugging the wrong layer)

9. **Search for known client bugs before debugging server.** Claude.ai OAuth DCR succeeds but auth popup never opens — this is a Claude.ai bug, not server. (v3: hours debugging server-side)

10. **Use `json.loads(strict=False)` for MCP responses.** ContextForge tool descriptions contain unescaped newlines. (v3)

## v6 Additions

11. **`FORWARDED_ALLOW_IPS=*` required on all Cloud Run sidecars.** Without it, Uvicorn returns `http://` URLs in SSE endpoints behind Cloud Run's TLS termination. MCP handshake times out. (v6: devmcp/sheets registration failed)

12. **Apollo v1.10.0 dropped SSE.** Only `streamable_http` or `stdio`. Config must use `type: streamable_http`. (v6: container crash on startup)

13. **Apollo `host_validation` rejects unknown Cloud Run hostnames.** Must whitelist both URL formats in `allowed_hosts`. (v6: 403 Forbidden on all requests)

14. **Cloud SQL `db-f1-micro` has only 25 max_connections.** Keycloak + ContextForge exhaust the pool. Bumped to 50. (v6: Keycloak crash)

15. **Cloud Run URL formats must be consistent.** SSO config, ALLOWED_ORIGINS, Keycloak redirect URIs, and browser address bar must all use the same format. (v6: SSO 400 error)

## v6.2 Additions (2026-03-25 — Auth hardening session)

16. **ContextForge rejects external IdP tokens by default.** Stock 1.0.0-RC-2 only verifies `iss: "mcpgateway"`. Applied community PR #3715 as a patch — adds JWKS verification for Keycloak tokens. Verified locally + Cloud Run. (v6.2: 401 on every MCP request through ContextForge)

17. **Claude Code crashes on ContextForge tool responses.** Multi-line tool descriptions (1000+ chars with newlines) trigger Anthropic API error: `cache_control cannot be set for empty text blocks`. Not a ContextForge bug — tool responses are clean when tested via curl. Workaround: use Apollo directly instead of through ContextForge. (v6.2: session-killing crash)

18. **Claude.ai OAuth is fundamentally broken for external IdPs.** Bug #82: ignores `authorization_endpoint` from metadata, hardcodes `/authorize` on MCP domain. Even with a reverse proxy routing OAuth paths to Keycloak, Claude.ai completes DCR but skips the authorize step entirely. No server-side fix possible. (v6.2: 4 proxy iterations before discovering the client bug)

19. **Keycloak DCR has cascading policy rejections.** Each policy (Trusted Hosts, Allowed Client Scopes, etc.) rejects independently with different 403 messages. Check Keycloak logs, not proxy logs, for the specific rejection reason. Claude.ai requests `service_account` scope which must be explicitly allowed. (v6.2: 3 deploy iterations fixing one policy at a time)

20. **Auth-proxy health must be independent of upstream.** Cloud Run multi-container startup probes run before all sidecars are ready. Proxying `/health` to an upstream that hasn't started = startup probe failure = deploy failure. Return 200 directly. (v6.2: 2 failed deploys)

21. **Apollo config changed between v1.9.0 and v1.10.0.** `mutation_mode` is no longer a valid config key (not top-level, not under `introspection.execute`). Don't trust cached knowledge about config schemas — check the actual binary's error messages. (v6.2: 2 failed deploys with wrong config)
