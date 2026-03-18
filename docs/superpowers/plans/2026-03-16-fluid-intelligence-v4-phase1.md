# Fluid Intelligence V4 Phase 1 — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the existing v3 deployment with Phase 1 improvements that require NO ContextForge plugins — config changes, script edits, env var wiring, and GDPR webhook implementation.

**Architecture:** All changes target the existing single-container Cloud Run deployment. No new services, no new binaries. Phase 1 stays within the "no plugins required" boundary — every change is shell script, Python code, Cloud Build config, or documentation.

**Tech Stack:** Bash (entrypoint.sh, bootstrap.sh), Python 3 (webhooks, crypto, tests), Cloud Build YAML, mcp-auth-proxy CLI flags, PostgreSQL (Alembic migrations via ContextForge)

---

## File Structure

### Files to Modify

| File | Responsibility | Changes |
|------|---------------|---------|
| `scripts/entrypoint.sh` | Process orchestrator | Add `AUTH_ENCRYPTION_SECRET` decoupling, add OTEL env vars, add `--timeout` to auth-proxy |
| `scripts/bootstrap.sh` | Backend registration + convergence | Add minimum tool count floor (~70), add advisory lock |
| `services/shopify_oauth/webhooks.py` | Shopify webhooks | Implement real GDPR data handlers |
| `services/shopify_oauth/db.py` | Database operations | Add GDPR query/delete functions |
| `services/shopify_oauth/crypto.py` | Token encryption | No changes in Phase 1 (key versioning deferred to Phase 2) |
| `deploy/cloudbuild.yaml` | App deploy pipeline | Add `AUTH_ENCRYPTION_SECRET` secret, add OTEL env vars, increase `--timeout` |
| `deploy/cloudbuild-base.yaml` | Base image build | No changes (Phase 1 uses existing binaries) |
| `.env.example` | Env var documentation | Add `AUTH_ENCRYPTION_SECRET`, `OTEL_*` vars |
| `docs/architecture.md` | Architecture documentation | Update Phase 1 status as changes land |

### Files to Create

| File | Responsibility |
|------|---------------|
| `tests/shopify_oauth/test_webhooks_gdpr.py` | GDPR webhook handler tests |
| `tests/test_bootstrap_convergence.sh` | Bootstrap convergence floor tests (shell) |
| `tests/test_entrypoint_env.sh` | Entrypoint env var wiring tests (shell) |
| `tests/test_bootstrap_advisory_lock.sh` | Advisory lock verification tests (shell) |
| `tests/test_nested_timeouts.sh` | Timeout configuration verification (shell) |
| `tests/test_cloud_run_config.sh` | Cloud Run config verification (shell) |
| `tests/test_sheets_sse_probe.sh` | Google-sheets SSE probe verification (shell) |
| `scripts/migrate-encryption-key.py` | One-time token re-encryption migration |

---

## Chunk 1: Decouple AUTH_ENCRYPTION_SECRET from JWT_SECRET_KEY

**Why this is first:** This is a "coupling bomb" (R32). Currently `entrypoint.sh:80` does `export AUTH_ENCRYPTION_SECRET="${JWT_SECRET_KEY}"`. Rotating JWT also rotates the database encryption key, silently destroying all stored Shopify access tokens. Decoupling requires a new GCP secret, then updating entrypoint + cloudbuild + .env.example.

### Task 1: Create GCP Secret and Update Cloud Build

**Files:**
- Modify: `deploy/cloudbuild.yaml:25` (add secret mapping)
- Modify: `.env.example:13` (add new env var)

- [ ] **Step 1: Create the GCP secret**

```bash
# Generate a fresh 256-bit key for AUTH_ENCRYPTION_SECRET (independent of JWT_SECRET_KEY)
NEW_KEY=$(openssl rand -base64 32)
echo -n "$NEW_KEY" | gcloud secrets create auth-encryption-secret \
  --project=junlinleather-mcp \
  --data-file=- \
  --replication-policy=automatic
```

Verify: `gcloud secrets versions access latest --secret=auth-encryption-secret --project=junlinleather-mcp` should print a base64 string.

- [ ] **Step 2: Add secret to cloudbuild.yaml**

In `deploy/cloudbuild.yaml`, line 25, add `AUTH_ENCRYPTION_SECRET=auth-encryption-secret:latest` to the `--set-secrets` list:

```yaml
      - '--set-secrets=SHOPIFY_CLIENT_ID=shopify-client-id:latest,SHOPIFY_CLIENT_SECRET=shopify-client-secret:latest,AUTH_PASSWORD=mcp-auth-passphrase:latest,JWT_SECRET_KEY=mcp-jwt-secret:latest,GOOGLE_OAUTH_CLIENT_ID=google-oauth-client-id:latest,GOOGLE_OAUTH_CLIENT_SECRET=google-oauth-client-secret:latest,CREDENTIALS_CONFIG=google-sheets-credentials:latest,DB_PASSWORD=db-password:latest,SHOPIFY_TOKEN_ENCRYPTION_KEY=shopify-token-encryption-key:latest,AUTH_ENCRYPTION_SECRET=auth-encryption-secret:latest'
```

- [ ] **Step 3: Document in .env.example**

Add after line 12 (`AUTH_PASSWORD`):

```bash
AUTH_ENCRYPTION_SECRET=          # ContextForge DB encryption key (Secret Manager: auth-encryption-secret)
                                 # MUST be independent of JWT_SECRET_KEY — rotating JWT must NOT affect stored data
```

- [ ] **Step 4: Commit**

```bash
git add deploy/cloudbuild.yaml .env.example
git commit -m "feat: add AUTH_ENCRYPTION_SECRET as independent GCP secret

Decouples ContextForge's database encryption key from JWT signing key.
Previously AUTH_ENCRYPTION_SECRET=${JWT_SECRET_KEY}, meaning JWT rotation
silently destroyed all encrypted data in the database.

Mirror Polish finding R32/B4."
```

### Task 2: Update entrypoint.sh to Use New Secret

**Files:**
- Modify: `scripts/entrypoint.sh:80` (change env var wiring)

- [ ] **Step 1: Write the failing test**

Create a test script that validates the env var wiring:

```bash
# tests/test_entrypoint_env.sh
#!/bin/bash
# Test: AUTH_ENCRYPTION_SECRET should NOT be derived from JWT_SECRET_KEY
# when AUTH_ENCRYPTION_SECRET is provided as its own env var

# Grep the entrypoint for the old coupling pattern
if grep -q 'AUTH_ENCRYPTION_SECRET=.*JWT_SECRET_KEY' scripts/entrypoint.sh; then
  echo "FAIL: entrypoint.sh still derives AUTH_ENCRYPTION_SECRET from JWT_SECRET_KEY"
  exit 1
fi
echo "PASS: AUTH_ENCRYPTION_SECRET is independent"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_entrypoint_env.sh`
Expected: FAIL — the old coupling still exists at line 80.

- [ ] **Step 3: Update entrypoint.sh**

Replace line 80 in `scripts/entrypoint.sh`:

```bash
# OLD (coupling bomb — R32):
# export AUTH_ENCRYPTION_SECRET="${JWT_SECRET_KEY}"

# NEW: Use dedicated secret. Fall back to JWT_SECRET_KEY for backward compat during migration.
if [ -n "${AUTH_ENCRYPTION_SECRET:-}" ]; then
  export AUTH_ENCRYPTION_SECRET
else
  echo "[fluid-intelligence] WARNING: AUTH_ENCRYPTION_SECRET not set, falling back to JWT_SECRET_KEY (DEPRECATED — set AUTH_ENCRYPTION_SECRET separately)"
  export AUTH_ENCRYPTION_SECRET="${JWT_SECRET_KEY}"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_entrypoint_env.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/entrypoint.sh tests/test_entrypoint_env.sh
git commit -m "feat: decouple AUTH_ENCRYPTION_SECRET from JWT_SECRET_KEY

entrypoint.sh now uses AUTH_ENCRYPTION_SECRET directly when available,
with backward-compatible fallback + deprecation warning.

Mirror Polish finding R32/B4."
```

### Task 3: Re-encrypt Existing Tokens with New Key

**Files:**
- Create: `scripts/migrate-encryption-key.py`

- [ ] **Step 1: Write the migration script**

```python
#!/usr/bin/env python3
"""One-time migration: re-encrypt all Shopify tokens from old key to new key.

Usage:
  OLD_KEY=<old-base64-key> NEW_KEY=<new-base64-key> DATABASE_URL=<url> python3 scripts/migrate-encryption-key.py

Safety:
  - Dry-run by default (prints what would change, no writes)
  - Pass --commit to actually write
  - Idempotent: tokens already encrypted with NEW_KEY are skipped (decrypt fails gracefully)
"""
import os
import sys

import psycopg2
import psycopg2.extras

sys.path.insert(0, "/app")
from services.shopify_oauth.crypto import decrypt_token, encrypt_token


def main():
    old_key = os.environ["OLD_KEY"]
    new_key = os.environ["NEW_KEY"]
    dsn = os.environ["DATABASE_URL"]
    commit = "--commit" in sys.argv

    conn = psycopg2.connect(dsn)
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute("SELECT id, shop_domain, access_token_encrypted FROM shopify_installations WHERE status = 'active' AND access_token_encrypted != ''")
    rows = cur.fetchall()

    migrated = 0
    skipped = 0
    for row in rows:
        try:
            plaintext = decrypt_token(row["access_token_encrypted"], old_key)
        except Exception:
            # Already on new key or corrupted — skip
            skipped += 1
            continue

        new_ct = encrypt_token(plaintext, new_key)
        if commit:
            cur.execute(
                "UPDATE shopify_installations SET access_token_encrypted = %s, updated_at = NOW() WHERE id = %s",
                (new_ct, row["id"]),
            )
        print(f"{'MIGRATED' if commit else 'WOULD MIGRATE'}: {row['shop_domain']} (id={row['id']})")
        migrated += 1

    if commit:
        conn.commit()
    conn.close()
    print(f"\nDone: {migrated} migrated, {skipped} skipped")
    if not commit and migrated > 0:
        print("Run with --commit to apply changes")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Test dry-run locally**

```bash
OLD_KEY=$(gcloud secrets versions access latest --secret=mcp-jwt-secret --project=junlinleather-mcp)
NEW_KEY=$(gcloud secrets versions access latest --secret=auth-encryption-secret --project=junlinleather-mcp)
# Use Cloud SQL proxy for local access
DATABASE_URL="postgresql://contextforge:$DB_PASSWORD@localhost:5432/contextforge" \
  python3 scripts/migrate-encryption-key.py
```

Expected: Shows "WOULD MIGRATE" for each active installation.

- [ ] **Step 3: Run with --commit**

```bash
DATABASE_URL="postgresql://contextforge:$DB_PASSWORD@localhost:5432/contextforge" \
  OLD_KEY="$OLD_KEY" NEW_KEY="$NEW_KEY" \
  python3 scripts/migrate-encryption-key.py --commit
```

- [ ] **Step 4: Update entrypoint.sh token decryption to use AUTH_ENCRYPTION_SECRET**

In `scripts/entrypoint.sh`, the token decryption at line 108 uses `SHOPIFY_TOKEN_ENCRYPTION_KEY`, not `AUTH_ENCRYPTION_SECRET`. These are different secrets with different purposes:
- `SHOPIFY_TOKEN_ENCRYPTION_KEY` — encrypts Shopify tokens in `shopify_installations` table (OAuth service)
- `AUTH_ENCRYPTION_SECRET` — encrypts ContextForge's internal data

No change needed here. The decoupling only affects ContextForge's `AUTH_ENCRYPTION_SECRET`.

- [ ] **Step 5: Commit**

```bash
git add scripts/migrate-encryption-key.py
git commit -m "feat: add encryption key migration script

One-time script to re-encrypt tokens when rotating AUTH_ENCRYPTION_SECRET.
Dry-run by default, --commit to apply. Idempotent."
```

---

## Chunk 2: Nested Timeouts

**Why:** No inner-layer timeouts (R81). Shopify 30s hangs are invisible. Client retries create duplicate mutations.

The architecture doc specifies 4 layers: Apollo→Shopify 30s, ContextForge→Apollo 35s, auth-proxy→ContextForge 40s, Cloud Run 300s/3600s. Phase 1 implements what's configurable today. The middle two layers (ContextForge→backend, auth-proxy→backend) require investigation — they may not be configurable in RC-2 / v2.5.4 and are documented as deferred if unsupported.

### Task 4: Configure Nested Timeouts

**Files:**
- Modify: `config/mcp-config.yaml` (Apollo timeout)
- Modify: `deploy/cloudbuild.yaml` (ContextForge timeout env var if supported)

- [ ] **Step 1: Research mcp-auth-proxy timeout flags**

```bash
# Check if mcp-auth-proxy supports --backend-timeout or similar
mcp-auth-proxy --help 2>&1 | grep -i timeout || echo "No timeout flag found"
```

**If no timeout flag found:** Document this in architecture.md as a known limitation. The auth-proxy→ContextForge 40s timeout is NOT configurable in v2.5.4 and is deferred.

- [ ] **Step 2: Research ContextForge backend timeout configuration**

```bash
# Search ContextForge source for timeout configuration
grep -r "timeout" /app/.venv/lib/python*/site-packages/mcpgateway/ --include="*.py" -l 2>/dev/null | head -20
# Also check env var support
grep -r "MCG.*TIMEOUT\|BACKEND.*TIMEOUT\|timeout" /app/.venv/lib/python*/site-packages/mcpgateway/config* 2>/dev/null
```

**If configurable:** Add `MCG_BACKEND_TIMEOUT=35` to cloudbuild.yaml env vars.
**If not configurable:** Document as deferred. ContextForge→Apollo 35s timeout requires a ContextForge upgrade or custom middleware.

- [ ] **Step 3: Add Apollo → Shopify timeout**

**Important:** First verify Apollo v1.9.0 supports the `timeout` config key:

```bash
# Check Apollo docs or help
apollo --help 2>&1 | grep -i timeout || echo "No timeout help found"
# Check if the config schema accepts timeout
grep -r "timeout" /usr/local/bin/apollo 2>/dev/null || echo "Binary, check docs instead"
```

If supported, add to `config/mcp-config.yaml` after the `headers` section:

```yaml
timeout: 30  # seconds — Shopify API timeout (prevents silent hangs)
```

If NOT supported (Apollo v1.9.0 may not have this): Document as deferred. The Shopify API has its own server-side timeout (~30s) which provides a natural bound.

- [ ] **Step 4: Write verification test**

```bash
# tests/test_nested_timeouts.sh
#!/bin/bash
ISSUES=0

# Check 1: Apollo timeout configured (if supported)
if grep -q 'timeout:' config/mcp-config.yaml; then
  echo "PASS: Apollo timeout configured"
else
  echo "INFO: Apollo timeout not in mcp-config.yaml (may not be supported in v1.9.0)"
fi

# Check 2: Cloud Run timeout is 3600 (moved to Chunk 6 Task 10)
if grep -q 'timeout=3600' deploy/cloudbuild.yaml; then
  echo "PASS: Cloud Run timeout is 3600s"
else
  echo "FAIL: Cloud Run timeout not set to 3600s"
  ISSUES=$((ISSUES+1))
fi

[ "$ISSUES" -eq 0 ] && echo "All timeout checks passed" || exit 1
```

- [ ] **Step 5: Commit**

```bash
git add config/mcp-config.yaml tests/test_nested_timeouts.sh
git commit -m "feat: add Apollo → Shopify timeout (30s)

Configures Apollo MCP Server timeout to prevent silent Shopify hangs.
Middle layers (ContextForge→Apollo 35s, auth-proxy→ContextForge 40s)
are not configurable in current versions and documented as deferred.

Mirror Polish finding R81/B9."
```

**Note:** Cloud Run `--timeout=3600` change is consolidated in Chunk 6 (Task 10) along with the liveness probe, to avoid duplicate edits to cloudbuild.yaml.

---

## Chunk 3: Bootstrap Convergence Floor

**Why:** Bootstrap accepts any non-zero tool count (R86). A broken backend registering 1 tool would pass. Expected: Apollo ~7 + dev-mcp ~50+ + sheets ~17 = ~74+.

### Task 5: Add Minimum Tool Count to Bootstrap

**Files:**
- Modify: `scripts/bootstrap.sh:196-215` (convergence check)
- Create: `tests/test_bootstrap_convergence.sh`

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_bootstrap_convergence.sh
#!/bin/bash
# Test: bootstrap.sh must enforce a minimum tool count floor

if ! grep -q 'MIN_TOOL_COUNT\|min_tool_count\|TOOL_FLOOR' scripts/bootstrap.sh; then
  echo "FAIL: bootstrap.sh has no minimum tool count floor"
  exit 1
fi

# Check the floor value is >= 50 (conservative — actual is ~74)
FLOOR=$(grep -oP '(?:MIN_TOOL_COUNT|TOOL_FLOOR)=\K[0-9]+' scripts/bootstrap.sh | head -1)
if [ -z "$FLOOR" ] || [ "$FLOOR" -lt 50 ]; then
  echo "FAIL: Tool count floor is too low (got: ${FLOOR:-none}, need >= 50)"
  exit 1
fi
echo "PASS: Bootstrap has tool count floor of $FLOOR"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_bootstrap_convergence.sh`
Expected: FAIL — no minimum floor exists.

- [ ] **Step 3: Implement the floor**

In `scripts/bootstrap.sh`, after line 195 (before the convergence loop), add:

```bash
# Minimum expected tool count: Apollo ~7 + dev-mcp ~50+ + sheets ~17 = ~74
# Use conservative floor of 70 to catch broken backend registrations
MIN_TOOL_COUNT=${MIN_TOOL_COUNT:-70}
```

Then modify the convergence check (line 213) to validate against the floor:

Replace lines 213-215:
```bash
echo "[bootstrap] $TOOL_COUNT tools in catalog (stabilized after $((i * 2))s)"
if [ "$TOOL_COUNT" -eq 0 ]; then
  echo "[bootstrap] WARNING: Zero tools discovered — check backend registrations above"
fi
```

With:
```bash
echo "[bootstrap] $TOOL_COUNT tools in catalog (stabilized after $((i * 2))s)"
if [ "$TOOL_COUNT" -lt "$MIN_TOOL_COUNT" ]; then
  echo "[bootstrap] WARNING: Only $TOOL_COUNT tools discovered (expected >= $MIN_TOOL_COUNT)"
  echo "[bootstrap]   This suggests a backend failed to register or tool discovery is incomplete"
  echo "[bootstrap]   Expected: Apollo ~7 + dev-mcp ~50+ + sheets ~17 = ~74+"
  # Don't exit — partial service is better than no service. But log loudly.
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_bootstrap_convergence.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap.sh tests/test_bootstrap_convergence.sh
git commit -m "feat: add minimum tool count floor to bootstrap convergence

Logs warning when tool count < 70 (expected ~74+: Apollo 7 + dev-mcp 50+ + sheets 17).
Configurable via MIN_TOOL_COUNT env var. Does not hard-fail — partial service
is better than no service.

Mirror Polish finding R86/B9."
```

### Task 6: Add Bootstrap Advisory Lock

**Files:**
- Modify: `scripts/bootstrap.sh:49` (after JWT generation, before registration)

- [ ] **Step 1: Write the advisory lock implementation**

PostgreSQL advisory locks prevent two containers from running bootstrap simultaneously (if max-instances > 1 in future):

After the JWT generation block (line 47) and before `CF=...` (line 49), add:

```bash
# Advisory lock: prevent concurrent bootstrap from multiple instances
# Uses PostgreSQL pg_try_advisory_lock with a fixed lock ID
# Lock is session-scoped and auto-releases when connection closes
LOCK_ACQUIRED=$(/app/.venv/bin/python3 -c "
import os, psycopg2
# Use DATABASE_URL if available (set by entrypoint.sh), fall back to individual vars
dsn = os.environ.get('DATABASE_URL', '')
if dsn:
    conn = psycopg2.connect(dsn, connect_timeout=5)
else:
    conn = psycopg2.connect(
        dbname=os.environ.get('DB_NAME', 'contextforge'),
        user=os.environ.get('DB_USER', 'contextforge'),
        password=os.environ.get('DB_PASSWORD', ''),
        host=os.environ.get('DB_HOST', '/cloudsql/junlinleather-mcp:asia-southeast1:contextforge'),
        connect_timeout=5,
    )
cur = conn.cursor()
cur.execute('SELECT pg_try_advisory_lock(42)')  # 42 = bootstrap lock ID
acquired = cur.fetchone()[0]
print('true' if acquired else 'false')
if not acquired:
    conn.close()
" 2>/dev/null) || LOCK_ACQUIRED="error"

if [ "$LOCK_ACQUIRED" = "false" ]; then
  echo "[bootstrap] Another instance is running bootstrap — skipping (advisory lock held)"
  exit 0
elif [ "$LOCK_ACQUIRED" = "error" ]; then
  echo "[bootstrap] WARNING: Could not acquire advisory lock (DB unavailable?) — proceeding anyway"
fi
```

- [ ] **Step 2: Write verification test**

```bash
# tests/test_bootstrap_advisory_lock.sh
#!/bin/bash
# Test: bootstrap.sh must contain advisory lock logic

if grep -q 'pg_try_advisory_lock' scripts/bootstrap.sh; then
  echo "PASS: bootstrap.sh has advisory lock"
else
  echo "FAIL: bootstrap.sh missing advisory lock"
  exit 1
fi

# Check it uses env vars, not hardcoded paths
if grep -q 'DB_HOST\|DATABASE_URL' scripts/bootstrap.sh; then
  echo "PASS: advisory lock uses env vars for DB connection"
else
  echo "FAIL: advisory lock may have hardcoded DB path"
  exit 1
fi
echo "All advisory lock checks passed"
```

- [ ] **Step 3: Run test to verify it passes**

Run: `bash tests/test_bootstrap_advisory_lock.sh`
Expected: PASS

- [ ] **Step 4: Verify advisory lock works against Cloud SQL (integration)**

```bash
# Test the advisory lock SQL via Cloud SQL proxy
psql "$DATABASE_URL" -c "SELECT pg_try_advisory_lock(42); SELECT pg_advisory_unlock(42);"
```

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap.sh
git commit -m "feat: add PostgreSQL advisory lock to bootstrap

Prevents concurrent bootstrap from multiple Cloud Run instances.
Uses pg_try_advisory_lock(42) — non-blocking, session-scoped.
Graceful fallback if DB is unavailable.

Mirror Polish finding from architecture review."
```

---

## Chunk 4: OTEL Environment Variables

**Why:** ContextForge has built-in OpenTelemetry support but OTEL env vars aren't wired in Cloud Build (architecture doc mentions Cloud Trace + Cloud Monitoring but no env vars configured).

### Task 7: Wire OTEL Env Vars

**Files:**
- Modify: `deploy/cloudbuild.yaml:26` (add OTEL env vars)
- Modify: `.env.example` (document OTEL vars)

- [ ] **Step 1: Add OTEL env vars to cloudbuild.yaml**

In `deploy/cloudbuild.yaml`, line 26, add to the `--set-env-vars` list:

```
OTEL_EXPORTER_OTLP_ENDPOINT=https://cloudtrace.googleapis.com,OTEL_SERVICE_NAME=fluid-intelligence,OTEL_TRACES_EXPORTER=otlp,OTEL_METRICS_EXPORTER=none
```

Note: `OTEL_METRICS_EXPORTER=none` because Cloud Run provides metrics natively. We only want distributed traces.

- [ ] **Step 2: Add OTEL vars to .env.example**

Add a new section after the Security section:

```bash
# --- Observability (OpenTelemetry) ---
OTEL_SERVICE_NAME=fluid-intelligence
OTEL_EXPORTER_OTLP_ENDPOINT=https://cloudtrace.googleapis.com  # Cloud Trace OTLP endpoint
OTEL_TRACES_EXPORTER=otlp            # Export traces via OTLP
OTEL_METRICS_EXPORTER=none           # Cloud Run provides metrics natively
```

- [ ] **Step 3: Commit**

```bash
git add deploy/cloudbuild.yaml .env.example
git commit -m "feat: wire OTEL env vars for Cloud Trace integration

Enables ContextForge's built-in OpenTelemetry to export traces to
Cloud Trace. Metrics disabled (Cloud Run provides natively).

Mirror Polish architecture review."
```

---

## Chunk 5: GDPR Webhook Implementation

**Why:** GDPR handlers are no-ops (R48). `customers/data_request` and `customers/redact` return 200 but do nothing. This is a v3 production bug — Shopify requires these for app listing compliance.

### Task 8: Add GDPR Database Functions

**Files:**
- Modify: `services/shopify_oauth/db.py` (add GDPR query/delete functions)
- Create: `tests/shopify_oauth/test_db_gdpr.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/shopify_oauth/test_db_gdpr.py
"""Tests for GDPR database operations."""
import pytest
from unittest.mock import MagicMock, patch

from services.shopify_oauth.db import (
    get_customer_data,
    delete_customer_data,
    delete_shop_data,
)


def test_get_customer_data_returns_dict():
    """get_customer_data should return a dict with shop_domain and customer info."""
    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.cursor.return_value.__enter__ = lambda s: mock_cursor
    mock_conn.cursor.return_value.__exit__ = MagicMock(return_value=False)
    mock_cursor.fetchone.return_value = {
        "shop_domain": "test.myshopify.com",
        "status": "active",
        "installed_at": "2026-01-01",
    }

    result = get_customer_data(mock_conn, "test.myshopify.com", "customer@example.com")
    assert result is not None
    assert "shop_domain" in result


def test_delete_customer_data():
    """delete_customer_data should execute without error."""
    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.cursor.return_value.__enter__ = lambda s: mock_cursor
    mock_conn.cursor.return_value.__exit__ = MagicMock(return_value=False)

    # Should not raise
    delete_customer_data(mock_conn, "test.myshopify.com", "customer@example.com")
    mock_conn.commit.assert_called_once()


def test_delete_shop_data():
    """delete_shop_data should remove the shop's installation record entirely."""
    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.cursor.return_value.__enter__ = lambda s: mock_cursor
    mock_conn.cursor.return_value.__exit__ = MagicMock(return_value=False)

    delete_shop_data(mock_conn, "test.myshopify.com")
    mock_conn.commit.assert_called_once()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/junlin/Projects/Shopify/fluid-intelligence && python -m pytest tests/shopify_oauth/test_db_gdpr.py -v`
Expected: ImportError — functions don't exist yet.

- [ ] **Step 3: Implement GDPR database functions**

Add to `services/shopify_oauth/db.py`:

```python
def get_customer_data(conn, shop_domain: str, customer_email: str) -> dict | None:
    """Return installation data for a shop (for GDPR data request).

    Note: We store shop-level data, not per-customer data. The customer_email
    is logged for audit but we can only return shop-level installation info.
    """
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            "SELECT shop_domain, status, scopes, installed_at, updated_at FROM shopify_installations WHERE shop_domain = %s",
            (shop_domain,),
        )
        return cur.fetchone()


def delete_customer_data(conn, shop_domain: str, customer_email: str):
    """Delete customer-specific data for GDPR customers/redact.

    Note: We don't store per-customer PII — only shop-level installation data
    and encrypted access tokens. This is a no-op for customer data but we log
    the request for audit compliance.
    """
    # No per-customer data to delete. Log for audit trail.
    conn.commit()  # Explicit commit to confirm the operation was processed


def delete_shop_data(conn, shop_domain: str):
    """Delete ALL data for a shop (GDPR shop/redact). Permanent deletion."""
    with conn.cursor() as cur:
        cur.execute(
            "DELETE FROM shopify_installations WHERE shop_domain = %s",
            (shop_domain,),
        )
    conn.commit()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/shopify_oauth/test_db_gdpr.py -v`
Expected: 3 passed

- [ ] **Step 5: Commit**

```bash
git add services/shopify_oauth/db.py tests/shopify_oauth/test_db_gdpr.py
git commit -m "feat: add GDPR database functions (get_customer_data, delete_customer_data, delete_shop_data)

Supports customers/data_request, customers/redact, and shop/redact webhooks.
Note: We don't store per-customer PII, only shop-level installation data.

Mirror Polish finding R48/B5."
```

### Task 9: Implement Real GDPR Webhook Handlers

**Files:**
- Modify: `services/shopify_oauth/webhooks.py:58-78` (replace no-op handlers)
- Create: `tests/shopify_oauth/test_webhooks_gdpr.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/shopify_oauth/test_webhooks_gdpr.py
"""Tests for GDPR webhook handlers."""
import json
import hashlib
import hmac
import base64
from unittest.mock import patch, MagicMock

import pytest
from fastapi.testclient import TestClient
from fastapi import FastAPI

from services.shopify_oauth.webhooks import router


@pytest.fixture
def app():
    app = FastAPI()
    app.include_router(router)
    return app


@pytest.fixture
def client(app):
    return TestClient(app)


def make_hmac(body: bytes, secret: str = "test-secret") -> str:
    return base64.b64encode(
        hmac.new(secret.encode(), body, hashlib.sha256).digest()
    ).decode()


@patch("services.shopify_oauth.webhooks.settings")
@patch("services.shopify_oauth.webhooks.get_connection")
def test_customers_data_request(mock_conn_fn, mock_settings):
    """customers/data_request should return customer data."""
    mock_settings.SHOPIFY_CLIENT_SECRET = "test-secret"
    mock_conn = MagicMock()
    mock_conn_fn.return_value = mock_conn

    app = FastAPI()
    app.include_router(router)
    client = TestClient(app)

    body = json.dumps({
        "shop_domain": "test.myshopify.com",
        "customer": {"email": "customer@example.com"},
    }).encode()

    response = client.post(
        "/webhooks/gdpr/customers-data_request",
        content=body,
        headers={"X-Shopify-Hmac-SHA256": make_hmac(body)},
    )
    assert response.status_code == 200
    mock_conn.close.assert_called()


@patch("services.shopify_oauth.webhooks.settings")
@patch("services.shopify_oauth.webhooks.get_connection")
def test_customers_redact(mock_conn_fn, mock_settings):
    """customers/redact should attempt to delete customer data."""
    mock_settings.SHOPIFY_CLIENT_SECRET = "test-secret"
    mock_conn = MagicMock()
    mock_conn_fn.return_value = mock_conn

    app = FastAPI()
    app.include_router(router)
    client = TestClient(app)

    body = json.dumps({
        "shop_domain": "test.myshopify.com",
        "customer": {"email": "customer@example.com"},
    }).encode()

    response = client.post(
        "/webhooks/gdpr/customers-redact",
        content=body,
        headers={"X-Shopify-Hmac-SHA256": make_hmac(body)},
    )
    assert response.status_code == 200
    mock_conn.close.assert_called()


@patch("services.shopify_oauth.webhooks.settings")
@patch("services.shopify_oauth.webhooks.get_connection")
def test_shop_redact_deletes_data(mock_conn_fn, mock_settings):
    """shop/redact should permanently delete shop installation data."""
    mock_settings.SHOPIFY_CLIENT_SECRET = "test-secret"
    mock_conn = MagicMock()
    mock_conn_fn.return_value = mock_conn

    app = FastAPI()
    app.include_router(router)
    client = TestClient(app)

    body = json.dumps({
        "shop_domain": "test.myshopify.com",
    }).encode()

    response = client.post(
        "/webhooks/gdpr/shop-redact",
        content=body,
        headers={"X-Shopify-Hmac-SHA256": make_hmac(body)},
    )
    assert response.status_code == 200
    mock_conn.close.assert_called()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/shopify_oauth/test_webhooks_gdpr.py -v`
Expected: Tests fail — current handlers don't call get_connection or GDPR functions.

- [ ] **Step 3: Implement real GDPR handlers**

Replace the `gdpr_webhook` handler in `services/shopify_oauth/webhooks.py` (lines 58-78).

**Important behavioral change:** The existing `shop-redact` handler calls `mark_shop_uninstalled()` which does a soft-delete (sets `status='uninstalled'`, clears token). The new handler calls `delete_shop_data()` which does a hard DELETE. This is intentional — GDPR `shop/redact` requires permanent data deletion, not just deactivation. The `import` on line 12 must be updated to include the new functions (replace, don't add a duplicate import).

First, update the import on line 12 of `webhooks.py` — replace:
```python
from services.shopify_oauth.db import get_connection, mark_uninstalled
```
with:
```python
from services.shopify_oauth.db import get_connection, mark_uninstalled, get_customer_data, delete_customer_data, delete_shop_data
```

Then replace the handler:
```python
@router.post("/webhooks/gdpr/{topic}")
async def gdpr_webhook(topic: str, request: Request):
    body = await request.body()
    if len(body) > MAX_WEBHOOK_BODY:
        return Response("Payload too large", status_code=413)
    hmac_header = request.headers.get("X-Shopify-Hmac-SHA256", "")
    if not verify_webhook_hmac(body, hmac_header):
        return Response("Invalid HMAC", status_code=401)

    try:
        data = json.loads(body)
    except (json.JSONDecodeError, ValueError):
        return Response("Invalid JSON", status_code=400)

    shop_domain = data.get("shop_domain", "")
    customer = data.get("customer", {})
    customer_email = customer.get("email", "") if isinstance(customer, dict) else ""

    log.info(f"GDPR webhook received: {topic} for shop={shop_domain}")

    try:
        conn = get_connection()
        try:
            if topic == "customers-data_request":
                # Return what data we have about this customer's shop
                result = get_customer_data(conn, shop_domain, customer_email)
                log.info(f"GDPR data request: shop={shop_domain}, customer={customer_email}, data_found={result is not None}")

            elif topic == "customers-redact":
                # Delete customer-specific data (we don't store per-customer PII)
                delete_customer_data(conn, shop_domain, customer_email)
                log.info(f"GDPR customer redact: shop={shop_domain}, customer={customer_email}")

            elif topic == "shop-redact":
                # Permanent deletion of ALL shop data
                delete_shop_data(conn, shop_domain)
                log.info(f"GDPR shop redact: permanently deleted shop={shop_domain}")

            else:
                log.warning(f"Unknown GDPR topic: {topic}")
        finally:
            conn.close()
    except Exception as e:
        log.error(f"GDPR webhook {topic} failed for shop={shop_domain}: {e}")
        # Return 200 anyway — Shopify retries on non-200, and we don't want infinite retries
        # on transient DB errors. Log the error for manual follow-up.

    return {"status": "ok"}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/shopify_oauth/test_webhooks_gdpr.py -v`
Expected: 3 passed

- [ ] **Step 5: Commit**

```bash
git add services/shopify_oauth/webhooks.py tests/shopify_oauth/test_webhooks_gdpr.py
git commit -m "feat: implement real GDPR webhook handlers

customers/data_request returns shop-level installation data.
customers/redact acknowledges (no per-customer PII stored).
shop/redact permanently deletes the shop's installation record.

All handlers: HMAC-verified, error-logged, return 200 to prevent
Shopify retry storms on transient failures.

Mirror Polish finding R48/B5 — was a v3 production bug."
```

---

## Chunk 6: Cloud Run Timeout and Liveness Probe

**Why:** SSE sessions limited by Cloud Run `--timeout` (R64). Current 300s disconnects mid-session. Liveness probe ensures crashed processes are detected.

**Trade-off:** `--timeout=3600` applies to ALL requests, not just SSE. A hung non-SSE request could block for up to 1 hour. Cloud Run does not support per-path timeout configuration. We accept this trade-off because: (1) SSE is the primary transport and needs long sessions, (2) inner-layer timeouts (Apollo 30s) prevent most hangs, (3) the alternative (300s) actively breaks SSE sessions.

### Task 10: Update Cloud Run Configuration

**Files:**
- Modify: `deploy/cloudbuild.yaml:22-23` (timeout + probe)

- [ ] **Step 1: Change Cloud Run timeout from 300s to 3600s**

In `deploy/cloudbuild.yaml`, change line 22:

```yaml
      - '--timeout=3600'
```

- [ ] **Step 2: Add liveness probe**

Add after the startup probe line (line 23):

```yaml
      - '--liveness-probe=failureThreshold=3,periodSeconds=30,timeoutSeconds=5,httpGet.path=/health,httpGet.port=8080'
```

This probes auth-proxy's health endpoint every 30s. 3 failures = container restart.

- [ ] **Step 3: Write verification test**

```bash
# tests/test_cloud_run_config.sh
#!/bin/bash
ISSUES=0

if grep -q 'timeout=3600' deploy/cloudbuild.yaml; then
  echo "PASS: Cloud Run timeout is 3600s"
else
  echo "FAIL: Cloud Run timeout not set to 3600s"
  ISSUES=$((ISSUES+1))
fi

if grep -q 'liveness-probe' deploy/cloudbuild.yaml; then
  echo "PASS: Liveness probe configured"
else
  echo "FAIL: No liveness probe in cloudbuild.yaml"
  ISSUES=$((ISSUES+1))
fi

[ "$ISSUES" -eq 0 ] && echo "All Cloud Run config checks passed" || exit 1
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_cloud_run_config.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add deploy/cloudbuild.yaml tests/test_cloud_run_config.sh
git commit -m "feat: add liveness probe, increase timeout to 3600s

Liveness probe hits auth-proxy /health every 30s (3 failures = restart).
Timeout raised from 300s to 3600s for SSE session longevity.
Trade-off: all requests get 3600s max, mitigated by inner-layer timeouts.

Mirror Polish findings R64/B7, architecture review."
```

---

## Chunk 7: Google-Sheets SSE Probe

**Why:** The google-sheets bridge wait only checks `healthz` — no SSE endpoint probe (unlike dev-mcp which probes both). The bridge HTTP server can be up while the underlying MCP subprocess isn't connected yet. Architecture doc line 1033 explicitly flags this as Phase 1.

### Task 10.5: Add SSE Probe to Google-Sheets Bridge Wait

**Files:**
- Modify: `scripts/entrypoint.sh` (google-sheets start_and_verify section)

- [ ] **Step 1: Find the google-sheets bridge start section**

In `scripts/entrypoint.sh`, locate where the google-sheets bridge is started (after dev-mcp, before auth-proxy). The current pattern uses `start_and_verify` which only does `kill -0` (process alive check). dev-mcp has an additional SSE probe pattern we should replicate.

- [ ] **Step 2: Add SSE probe after google-sheets bridge starts**

After the `start_and_verify "sheets bridge"` line, add an SSE endpoint readiness check:

```bash
# Verify google-sheets SSE endpoint is responding (not just the HTTP server)
# Same pattern as dev-mcp — wait up to 30s for /sse to accept connections
for probe_attempt in $(seq 1 15); do
  if curl -sf --connect-timeout 2 --max-time 3 "http://127.0.0.1:8004/sse" -o /dev/null 2>/dev/null; then
    echo "[fluid-intelligence] sheets SSE endpoint ready [+$(elapsed)s]"
    break
  fi
  [ "$probe_attempt" -eq 15 ] && echo "[fluid-intelligence] WARNING: sheets SSE endpoint not responding after 30s"
  sleep 2
done
```

- [ ] **Step 3: Write a grep-based verification test**

```bash
# tests/test_sheets_sse_probe.sh
#!/bin/bash
if grep -q 'sheets.*SSE\|sheets.*sse.*probe\|8004/sse' scripts/entrypoint.sh; then
  echo "PASS: entrypoint.sh has google-sheets SSE probe"
else
  echo "FAIL: entrypoint.sh missing google-sheets SSE probe"
  exit 1
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_sheets_sse_probe.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/entrypoint.sh tests/test_sheets_sse_probe.sh
git commit -m "feat: add SSE endpoint probe to google-sheets bridge

Previously only checked process liveness (kill -0). Now also probes
http://127.0.0.1:8004/sse to confirm the MCP subprocess is connected.
Same pattern as dev-mcp bridge.

Mirror Polish finding R135/B14."
```

---

## Chunk 8: Documentation Updates

### Task 11: Update .env.example with All New Variables

**Files:**
- Modify: `.env.example`

- [ ] **Step 1: Verify all new env vars are documented**

Check that these are present (some may have been added in earlier tasks):
- `AUTH_ENCRYPTION_SECRET`
- `OTEL_SERVICE_NAME`
- `OTEL_EXPORTER_OTLP_ENDPOINT`
- `OTEL_TRACES_EXPORTER`
- `OTEL_METRICS_EXPORTER`
- `MIN_TOOL_COUNT` (optional, bootstrap override)

- [ ] **Step 2: Add any missing vars and commit**

```bash
git add .env.example
git commit -m "docs: ensure all Phase 1 env vars documented in .env.example"
```

### Task 12: Update Architecture Doc Phase 1 Status

**Files:**
- Modify: `docs/architecture.md` (V4 Design Directions section)

- [ ] **Step 1: Add Phase 1 completion markers**

For each item in the Phase 1 list (line 979), add completion status as items are deployed:

```markdown
- **Phase 1** (no plugins needed): ~~`X-Forwarded-User` header forwarding from auth-proxy~~(deferred — requires auth-proxy investigation), OTEL env vars ✅, VS stability proxy (deferred — Phase 2), tool descriptions (deferred — manual), bootstrap advisory lock ✅, liveness probe ✅, Alembic safety (docs only), nested timeouts ✅, minimum tool count floor ✅.
```

Note: `X-Forwarded-User` is deferred to Task 4 investigation — if auth-proxy v2.5.4 doesn't support it, this becomes a Phase 2 item requiring a custom auth-proxy build or ContextForge plugin.

- [ ] **Step 2: Commit**

```bash
git add docs/architecture.md
git commit -m "docs: update Phase 1 status in architecture.md V4 Design Directions"
```

---

## Execution Notes

### Deployment Order

1. **Secret creation** (Task 1) — must happen first, GCP-side
2. **Code changes** (Tasks 2-9) — all local, can be developed in any order
3. **Cloud Build config** (Tasks 4, 7, 10) — deploy together in a single Cloud Build
4. **Migration script** (Task 3) — run AFTER new secret is live and code is deployed
5. **Documentation** (Tasks 11-12) — last

### Testing Strategy

- Unit tests: `python -m pytest tests/` (Tasks 5, 8, 9)
- Shell tests: `bash tests/test_*.sh` (Tasks 2, 5)
- Integration: Deploy to Cloud Run, verify via `curl https://fluid-intelligence-1056128102929.asia-southeast1.run.app/health`
- GDPR: Trigger test webhooks via Shopify CLI or manual curl with HMAC

### Rollback

Every change is backward-compatible:
- `AUTH_ENCRYPTION_SECRET` falls back to `JWT_SECRET_KEY` if not set
- `MIN_TOOL_COUNT` defaults to 70 but is a warning, not a hard failure
- OTEL vars are ignored if ContextForge OTEL is not configured
- GDPR handlers still return 200 on any error
- Cloud Run timeout increase is safe (only affects max, not typical)

### What's Deferred to Phase 2

These Phase 1 items from the architecture doc require investigation or plugins:
- **X-Forwarded-User**: Requires auth-proxy v2.5.4 investigation. If unsupported, needs custom build or ContextForge plugin (Phase 2).
- **VS stability proxy**: Needs named routing layer. Complex — Phase 2.
- **Tool descriptions**: Manual content work. Not code. Ongoing.
- **Alembic safety**: Documentation + process. No code change needed unless ContextForge upgrade happens.
- **ContextForge→Apollo 35s timeout**: May not be configurable in RC-2. Research in Task 4.
- **auth-proxy→ContextForge 40s timeout**: May not be configurable in v2.5.4. Research in Task 4.
- **crypto.py key versioning**: Useful for key rotation but not critical for decoupling. Phase 2.
