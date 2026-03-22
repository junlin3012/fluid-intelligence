# Operations Runbook

## Deploy

### Automatic (push to main)

```bash
git push origin main
# Cloud Build trigger fires automatically
```

### Manual

```bash
# App image (~60s)
gcloud builds submit --config deploy/cloudbuild.yaml --project junlinleather-mcp

# Base image (~20 min, only when Apollo version changes)
gcloud builds submit --config deploy/cloudbuild-base.yaml --project junlinleather-mcp --region asia-southeast1
```

### Verify Deployment

```bash
# Check service status
gcloud run services describe fluid-intelligence --region asia-southeast1 --project junlinleather-mcp --format="yaml(status.conditions)"

# Check latest revision
gcloud run revisions list --service fluid-intelligence --region asia-southeast1 --project junlinleather-mcp --limit=3

# Health check (401 = auth proxy working correctly)
curl -s -o /dev/null -w "%{http_code}" https://fluid-intelligence-1056128102929.asia-southeast1.run.app/health
```

## View Logs

```bash
# All logs
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=fluid-intelligence" --project junlinleather-mcp --limit=50 --format="table(timestamp,textPayload)"

# Errors only
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=fluid-intelligence AND severity>=ERROR" --project junlinleather-mcp --limit=20

# Specific component (grep for log prefix)
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=fluid-intelligence AND textPayload:\"[bootstrap]\"" --project junlinleather-mcp --limit=20
```

## Common Issues

### Container crashes on startup

1. Check logs for `[fluid-intelligence] FATAL:` messages
2. Common causes:
   - Shopify token fetch fails (check `SHOPIFY_CLIENT_ID` / `SHOPIFY_CLIENT_SECRET` secrets)
   - ContextForge not ready in 120s (check `DATABASE_URL`, Cloud SQL connection)
   - Bootstrap fails (ContextForge API unreachable or JWT generation fails)

### 401 on all requests

This is **normal** — the auth proxy requires authentication. Use password or OAuth flow.

### Cloud Build fails

```bash
# Check recent builds
gcloud builds list --project junlinleather-mcp --limit=5

# Get build logs
gcloud builds log <BUILD_ID> --project junlinleather-mcp
```

## Secret Rotation

All secrets are in GCP Secret Manager. To rotate:

```bash
# 1. Create new secret version
echo -n "new-value" | gcloud secrets versions add SECRET_NAME --data-file=- --project junlinleather-mcp

# 2. Redeploy to pick up new secret
gcloud builds submit --config deploy/cloudbuild.yaml --project junlinleather-mcp
```

**CAUTION**: `shopify-token-encryption-key` rotation requires re-encrypting all tokens in the `shopify_installations` database table BEFORE creating a new secret version. Simply rotating the key makes existing encrypted tokens permanently undecryptable, causing the gateway to fall back to 24h client_credentials tokens. See Architecture Issue #10.

Secrets:
| Secret Name | Purpose |
|-------------|---------|
| `shopify-client-id` | Shopify app client ID |
| `shopify-client-secret` | Shopify app client secret |
| `mcp-auth-passphrase` | CLI auth password |
| `mcp-jwt-secret` | JWT signing key |
| `google-oauth-client-id` | Google login client ID |
| `google-oauth-client-secret` | Google login client secret |
| `google-sheets-credentials` | Service account JSON for Sheets |
| `db-password` | PostgreSQL password |
| `shopify-token-encryption-key` | AES-256-GCM key for Shopify token encryption |

## Shopify OAuth Service

Separate Cloud Run service that handles Shopify app install/uninstall flows. Changes are rare — deployed manually.

### Deploy

```bash
gcloud builds submit --config deploy/shopify-oauth/cloudbuild.yaml --project junlinleather-mcp --region asia-southeast1
```

### View Logs

```bash
# All logs
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=shopify-oauth" --project junlinleather-mcp --limit=50 --format="table(timestamp,textPayload)"

# Errors only
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=shopify-oauth AND severity>=ERROR" --project junlinleather-mcp --limit=20
```

### Common Issues

- **OAuth callback fails**: Check `CALLBACK_URL` env var matches the URL registered in Shopify Partner Dashboard
- **Token encryption errors**: Verify `shopify-token-encryption-key` secret is set and base64-encoded
- **Database connection errors**: Same Cloud SQL instance as gateway — check `DB_PASSWORD`, Cloud SQL proxy

## Scaling

Current: `max-instances=1` (required for in-memory auth state in mcp-auth-proxy).

To scale beyond 1 instance:
1. Move auth state to Redis or PostgreSQL
2. Set `--max-instances=N`
3. Consider session affinity as intermediate step
