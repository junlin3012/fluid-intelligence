#!/bin/bash
# Test: SSE probes must accept curl exit code 28 (timeout = streaming = alive)
# Bug: "if curl -sf ..." only checks exit code 0, but SSE returns 28

ISSUES=0

# entrypoint.sh sheets SSE probe must handle exit code 28
# Correct pattern: capture rc and check for 0 or 28
# Incorrect: if curl -sf ... (only accepts 0)
if grep -A2 '8004/sse' scripts/entrypoint.sh | grep -q 'if curl -sf'; then
  echo "FAIL: entrypoint.sh SSE probe uses 'if curl -sf' which ignores exit code 28"
  ISSUES=$((ISSUES+1))
else
  echo "PASS: entrypoint.sh SSE probe handles exit code 28"
fi

[ "$ISSUES" -eq 0 ] && echo "All SSE probe checks passed" || exit 1
