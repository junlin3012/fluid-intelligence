-- Token Service database objects
-- Runs as postgres superuser during docker-entrypoint-initdb

-- Create token_service user (reuses contextforge database)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'token_service_user') THEN
        EXECUTE format('CREATE ROLE token_service_user LOGIN PASSWORD %L', :'TOKEN_SERVICE_DB_PASS');
    END IF;
END
$$;

-- Create table in contextforge database
\connect contextforge

CREATE TABLE IF NOT EXISTS oauth_credentials (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    provider                 TEXT NOT NULL,
    account_id               TEXT NOT NULL,
    encrypted_access_token   TEXT NOT NULL,
    encrypted_refresh_token  TEXT,
    token_expires_at         TIMESTAMPTZ NOT NULL,
    refresh_token_expires_at TIMESTAMPTZ,
    scopes                   TEXT,
    status                   TEXT NOT NULL DEFAULT 'active',
    failure_count            INT NOT NULL DEFAULT 0,
    last_refreshed_at        TIMESTAMPTZ,
    last_error               TEXT,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(provider, account_id)
);

CREATE INDEX IF NOT EXISTS idx_credentials_expiry
    ON oauth_credentials(token_expires_at)
    WHERE status = 'active';

-- Grant permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth_credentials TO token_service_user;
GRANT USAGE ON SCHEMA public TO token_service_user;
