#!/bin/bash
# Test: bootstrap.sh must contain advisory lock logic

if grep -q 'pg_try_advisory_lock' scripts/bootstrap.sh; then
  echo "PASS: bootstrap.sh has advisory lock"
else
  echo "FAIL: bootstrap.sh missing advisory lock"
  exit 1
fi

# Check it uses env vars, not hardcoded paths only
if grep -q 'DATABASE_URL\|DB_HOST' scripts/bootstrap.sh; then
  echo "PASS: advisory lock uses env vars for DB connection"
else
  echo "FAIL: advisory lock may have hardcoded DB path"
  exit 1
fi
echo "All advisory lock checks passed"
