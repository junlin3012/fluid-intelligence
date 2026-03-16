#!/bin/bash
if grep -q '8004/sse' scripts/entrypoint.sh; then
  echo "PASS: entrypoint.sh has google-sheets SSE probe"
else
  echo "FAIL: entrypoint.sh missing google-sheets SSE probe"
  exit 1
fi
