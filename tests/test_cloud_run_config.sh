#!/bin/bash
ISSUES=0

if grep -q 'timeout=3600' deploy/cloudbuild.yaml; then
  echo "PASS: Cloud Run timeout is 3600s"
else
  echo "FAIL: Cloud Run timeout not set to 3600s"
  ISSUES=$((ISSUES+1))
fi

if grep -q 'liveness-probe' deploy/cloudbuild.yaml; then
  echo "PASS: Liveness probe configured"
else
  echo "FAIL: No liveness probe in cloudbuild.yaml"
  ISSUES=$((ISSUES+1))
fi

[ "$ISSUES" -eq 0 ] && echo "All Cloud Run config checks passed" || exit 1
