#!/bin/bash
# Test: bootstrap.sh must enforce a minimum tool count floor

if ! grep -q 'MIN_TOOL_COUNT\|min_tool_count\|TOOL_FLOOR' scripts/bootstrap.sh; then
  echo "FAIL: bootstrap.sh has no minimum tool count floor"
  exit 1
fi

# Check the floor value is >= 50 (conservative — actual is ~74)
# Matches both MIN_TOOL_COUNT=70 and MIN_TOOL_COUNT:-70 (bash default syntax)
FLOOR=$(grep -oE '(MIN_TOOL_COUNT|TOOL_FLOOR)[=:-]+[0-9]+' scripts/bootstrap.sh | grep -oE '[0-9]+$' | head -1)
if [ -z "$FLOOR" ] || [ "$FLOOR" -lt 50 ]; then
  echo "FAIL: Tool count floor is too low (got: ${FLOOR:-none}, need >= 50)"
  exit 1
fi
echo "PASS: Bootstrap has tool count floor of $FLOOR"
