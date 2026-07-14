#!/bin/bash
# Example post_action: runs after the tests, before result handling.
set -euo pipefail

if [[ -z "${TEST_EXIT_CODE:-}" || -z "${TEST_LOG_FILE:-}" || -z "${SIMULATOR_UDID:-}" ]]; then
  echo "POST_ACTION_ERROR: expected TEST_EXIT_CODE, TEST_LOG_FILE and SIMULATOR_UDID" >&2
  exit 1
fi
if [[ ! -f "$TEST_LOG_FILE" ]]; then
  echo "POST_ACTION_ERROR: TEST_LOG_FILE does not exist" >&2
  exit 1
fi
echo "POST_ACTION_RAN exit=$TEST_EXIT_CODE udid=$SIMULATOR_UDID log_lines=$(wc -l < "$TEST_LOG_FILE" | tr -d ' ')"
