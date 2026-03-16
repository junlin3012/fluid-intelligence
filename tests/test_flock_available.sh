#!/bin/bash
# Test: Dockerfile.base must install util-linux (provides flock for bootstrap advisory lock)

if grep -q 'util-linux' deploy/Dockerfile.base; then
  echo "PASS: Dockerfile.base installs util-linux (provides flock)"
else
  echo "FAIL: Dockerfile.base missing util-linux — bootstrap flock will fail at runtime"
  exit 1
fi
