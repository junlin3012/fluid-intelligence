-- services/contextforge/db/init.sql
-- Creates the contextforge database and a least-privilege user.
-- Executed by docker-compose postgres init (docker-entrypoint-initdb.d).
--
-- Required env var: CONTEXTFORGE_DB_PASS (passed via psql -v)

CREATE DATABASE contextforge;

CREATE USER contextforge_user WITH
    PASSWORD :'CONTEXTFORGE_DB_PASS'
    CONNECTION LIMIT 100
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE;

GRANT CONNECT ON DATABASE contextforge TO contextforge_user;

\connect contextforge
GRANT USAGE, CREATE ON SCHEMA public TO contextforge_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO contextforge_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO contextforge_user;
