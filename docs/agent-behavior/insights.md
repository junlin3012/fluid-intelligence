# Insights Log

> Distilled patterns from successes. Full narratives: `docs/archive/insights-raw.md`
> Agents: add new entries as they discover what works.

---

## Patterns (v3-v6)

1. **Source-verify before speccing.** Never spec CLI flags, API endpoints, or config without reading actual source code or `--help`. "Probably works like X" is a trap.

2. **Compose, don't build.** Deep-evaluate existing tools by reading source code, not README. 8 MCP gateways evaluated; marketing claims diverge from code reality.

3. **Apollo execute tool > predefined operations.** `introspection.execute` lets AI compose any GraphQL query dynamically — more powerful than static `.graphql` files.

4. **Systematic debugging beats brute-force.** One thorough log analysis finds all root causes at once. After 2 failed deploys, stop and change strategy.

5. **Separate headless vs local tools.** Not every MCP server belongs in a gateway. Service account auth + lightweight tool count = gateway. Browser OAuth + heavy tools = local IDE only.

6. **ContextForge two-tier model.** `/gateways` registers backends (tool discovery). `/servers` creates virtual servers (MCP endpoints). Without a virtual server, `tools/list` returns empty.

7. **Multi-agent review catches wiring issues.** Parallel spec + plan review finds env var mismatches, missing packages, and DB setup gaps invisible when reading either document alone.

8. **Be honest about scale.** "Designed for 2-5 users" with documented upgrade path is better than untested "scales to 50."

9. **Brand context before visuals.** Fetch the user's website before creating branded visuals. Palette tells WHAT colors; website tells HOW to use them.

10. **Agent behavior docs are infrastructure.** They need versioning, iteration, and feedback loops — not just static instructions.

## v6 Additions

11. **`FORWARDED_ALLOW_IPS=*` is the Cloud Run HTTPS fix.** Cloud Run terminates TLS; Uvicorn needs to trust `X-Forwarded-Proto` to generate correct URLs.

12. **OAuth SSO has three parties that must agree on URLs.** App (ALLOWED_ORIGINS), IdP (redirect URIs), browser (address bar). If any disagree on URL format, flow breaks.

13. **Keycloak is an identity broker, not in the hot path.** After JWKS fetch, all JWT validation is local. Keycloak only handles login redirects and key rotation.

14. **Per-user delegated access needs backend support.** The gateway knows WHO the user is, but each backend MCP server must accept delegated user tokens. Most open-source ones don't yet.

15. **Confluence API requires read-modify-write.** No PATCH or append endpoint. Read page, modify content, write back with version bump. Macros survive if you preserve the ADF/storage format.
