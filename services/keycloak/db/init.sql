-- services/keycloak/db/init.sql
-- Creates the keycloak database and a least-privilege user.
-- Executed by docker-compose postgres init (docker-entrypoint-initdb.d).
--
-- Required env var: KEYCLOAK_DB_PASS (passed via psql -v)

CREATE DATABASE keycloak;

CREATE USER keycloak_user WITH
    PASSWORD :'KEYCLOAK_DB_PASS'
    CONNECTION LIMIT 10
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE;

GRANT CONNECT ON DATABASE keycloak TO keycloak_user;

\connect keycloak
GRANT USAGE, CREATE ON SCHEMA public TO keycloak_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO keycloak_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO keycloak_user;
