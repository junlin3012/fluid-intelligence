#!/bin/bash
# Test: bootstrap.sh JWT expiry comment must match actual wait loop timeouts

ISSUES=0

# dev-mcp wait loop is seq 1 120 = 120s. Comment must NOT say 90s.
if grep -q 'dev-mcp 90s' scripts/bootstrap.sh; then
  echo "FAIL: bootstrap.sh comment says dev-mcp 90s but wait loop is 120s"
  ISSUES=$((ISSUES+1))
else
  echo "PASS: bootstrap.sh JWT comment matches dev-mcp 120s timeout"
fi

[ "$ISSUES" -eq 0 ] && echo "All comment accuracy checks passed" || exit 1
