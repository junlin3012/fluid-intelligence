#!/bin/bash
# Test: verify timeout configuration exists

ISSUES=0

# Check 1: Apollo timeout configured
if grep -q 'timeout:' config/mcp-config.yaml; then
  echo "PASS: Apollo timeout configured in mcp-config.yaml"
else
  echo "FAIL: No timeout in mcp-config.yaml"
  ISSUES=$((ISSUES+1))
fi

[ "$ISSUES" -eq 0 ] && echo "All timeout checks passed" || exit 1
