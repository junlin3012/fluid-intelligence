#!/bin/bash
# services/db-init.sh
# Runs all service DB init scripts in sequence.
# Mounted into postgres container via docker-compose.
set -euo pipefail

for sql in /docker-entrypoint-initdb.d/sql/*.sql; do
    echo "Running $sql..."
    psql -v ON_ERROR_STOP=1 \
         --username "$POSTGRES_USER" \
         --dbname postgres \
         --variable=CONTEXTFORGE_DB_PASS="${CONTEXTFORGE_DB_PASS}" \
         --variable=KEYCLOAK_DB_PASS="${KEYCLOAK_DB_PASS}" \
         --variable=TOKEN_SERVICE_DB_PASS="${TOKEN_SERVICE_DB_PASS}" \
         --file "$sql"
done
