# Contributing

> How to operate Fluid Intelligence — add backends, deploy, troubleshoot.

---

## Add a New MCP Backend

1. **Create the service directory:**
   ```
   services/<name>/
   ├── Dockerfile
   ├── .dockerignore
   └── (config files)
   ```

2. **Write the Dockerfile.** Two patterns:

   **Native MCP server** (like Apollo — runs its own HTTP server):
   ```dockerfile
   FROM <base-image>
   COPY config.yaml /app/config.yaml
   CMD ["mcp-server", "/app/config.yaml"]
   ```

   **Translate bridge** (like devmcp/sheets — wraps a stdio server):
   ```dockerfile
   FROM ghcr.io/ibm/mcp-context-forge:1.0.0-RC-2
   # Install the stdio MCP server
   RUN pip install <package>
   ENV PYTHONPATH=/app
   CMD ["/app/.venv/bin/python", "-m", "mcpgateway.translate", \
        "--port", "8005", "--host", "0.0.0.0", "--expose-sse", \
        "--stdio", "<command>"]
   ```

3. **Build and push:**
   ```bash
   docker build --platform linux/amd64 -t asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/<name>:v6 ./services/<name>
   docker push asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/<name>:v6
   ```

4. **Deploy to Cloud Run:**
   ```bash
   gcloud run deploy <name> \
     --project=junlinleather-mcp \
     --region=asia-southeast1 \
     --image=asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/<name>:v6 \
     --port=<port> \
     --cpu=1 --memory=512Mi \
     --min-instances=1 --max-instances=1 \
     --allow-unauthenticated \
     --set-env-vars="FORWARDED_ALLOW_IPS=*"
   ```

   **Do not forget `FORWARDED_ALLOW_IPS=*`** — without it, SSE/Streamable HTTP endpoints return `http://` URLs and ContextForge registration times out.

5. **Register in ContextForge Admin UI:**
   - Log in at `https://contextforge-apanptkfaq-as.a.run.app`
   - MCP Servers → Add New
   - URL: `https://<name>-apanptkfaq-as.a.run.app/sse` (SSE) or `/mcp` (Streamable HTTP)
   - Transport: match what the server supports

6. **Add to docker-compose.yml** for local dev.

7. **Update docs:** Add service to `docs/architecture.md` and `docs/config-reference.md`.

---

## Deploy a New Version

Each service deploys independently. No monolith rebuild needed.

### Rebuild and deploy a single service

```bash
# Example: update Apollo
cd services/apollo
docker build --platform linux/amd64 -t asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/apollo:v6 .
docker push asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/apollo:v6
gcloud run deploy apollo \
  --project=junlinleather-mcp \
  --region=asia-southeast1 \
  --image=asia-southeast1-docker.pkg.dev/junlinleather-mcp/junlin-mcp/apollo:v6
```

### Update ContextForge env vars only (no rebuild)

```bash
gcloud run services update contextforge \
  --project=junlinleather-mcp \
  --region=asia-southeast1 \
  --update-env-vars="KEY=value"
```

Note: for values with commas (like `ALLOWED_ORIGINS`), use `--set-env-vars` with pipe delimiter:
```bash
gcloud run services update contextforge \
  --set-env-vars="^|^ALLOWED_ORIGINS=https://url1,https://url2|OTHER_VAR=value"
```

---

## Troubleshoot SSO

### "SSO authentication failed"

1. Check ContextForge logs: `gcloud run services logs read contextforge --project=junlinleather-mcp --region=asia-southeast1 --limit=20`
2. Look for the HTTP status code on `/auth/sso/login/keycloak`
3. Common causes:
   - **400**: `SSO_KEYCLOAK_BASE_URL` points to wrong Keycloak URL, or `ALLOWED_ORIGINS` missing a URL
   - **401**: `SSO_KEYCLOAK_CLIENT_SECRET` doesn't match Keycloak client secret
   - **403**: User exists but missing `platform_admin` RBAC role
   - **302 loop**: JWT validation failing — check `JWT_ALGORITHM` matches key type

### "Gateway initialization timed out after 30s"

Backend registration in ContextForge admin UI times out. Causes:
- Missing `FORWARDED_ALLOW_IPS=*` on the sidecar → returns `http://` URLs
- Sidecar cold start too slow → set `--min-instances=1`
- Wrong transport type in registration → SSE for translate bridges, Streamable HTTP for Apollo

### "Access denied" when registering gateways

Your SSO user doesn't have the `platform_admin` RBAC role. Fix:
- Keycloak Admin → Users → your user → Role Mapping → assign `platform_admin`
- Log out and back in via SSO

### Keycloak "Server Error" / 503

Usually database connection pool exhaustion. Check:
- `gcloud run services logs read keycloak` for "remaining connection slots"
- Cloud SQL `max_connections` may need bumping: `gcloud sql instances patch contextforge --database-flags=max_connections=50`

---

## Rotate Secrets

### Keycloak admin credentials

1. Change in Secret Manager: `gcloud secrets versions add keycloak-admin-password --data-file=-`
2. Redeploy Keycloak: `gcloud run services update keycloak --project=junlinleather-mcp --region=asia-southeast1`

### SSO client secret

1. Keycloak Admin → Clients → fluid-gateway-sso → Credentials → Regenerate
2. Copy the new secret
3. Update ContextForge: `gcloud run services update contextforge --update-env-vars="SSO_KEYCLOAK_CLIENT_SECRET=<new>"`

### JWT secret key

1. Update Secret Manager: `gcloud secrets versions add mcp-jwt-secret --data-file=-`
2. Redeploy ContextForge (picks up new secret automatically)
3. Note: all existing sessions are invalidated

### Shopify access token

1. Generate new token in Shopify Partners dashboard
2. Update Apollo: `gcloud run services update apollo --update-env-vars="SHOPIFY_ACCESS_TOKEN=<new>"`
