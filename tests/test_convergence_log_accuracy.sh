#!/bin/bash
# Test: bootstrap.sh convergence log must distinguish stabilized vs exhausted

ISSUES=0

# The "stabilized" message must only appear inside a conditional that checks $stable
# Verify: 1) the pattern exists, AND 2) it's guarded by a stable check
if ! grep -q 'echo.*stabilized after' scripts/bootstrap.sh; then
  echo "FAIL: bootstrap.sh missing 'stabilized after' log message"
  ISSUES=$((ISSUES+1))
elif ! grep -B2 'echo.*stabilized after' scripts/bootstrap.sh | grep -q 'stable'; then
  echo "FAIL: convergence log says 'stabilized' without checking \$stable counter"
  ISSUES=$((ISSUES+1))
else
  echo "PASS: convergence log checks stabilization before claiming it"
fi

# Must have a "did NOT stabilize" path for when the loop exhausts
if grep -q 'did NOT stabilize\|not stabilize\|unstable' scripts/bootstrap.sh; then
  echo "PASS: bootstrap.sh has non-stabilization log path"
else
  echo "FAIL: bootstrap.sh missing non-stabilization log message"
  ISSUES=$((ISSUES+1))
fi

[ "$ISSUES" -eq 0 ] && echo "All convergence log checks passed" || exit 1
