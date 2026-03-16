#!/bin/bash
# Test: bootstrap.sh must contain concurrency lock logic

if grep -q 'flock' scripts/bootstrap.sh; then
  echo "PASS: bootstrap.sh has flock-based concurrency lock"
else
  echo "FAIL: bootstrap.sh missing concurrency lock"
  exit 1
fi

# Verify non-blocking mode (-n flag)
if grep -q 'flock -n' scripts/bootstrap.sh; then
  echo "PASS: flock uses non-blocking mode"
else
  echo "FAIL: flock should use -n (non-blocking)"
  exit 1
fi
echo "All concurrency lock checks passed"
