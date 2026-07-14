#!/bin/bash
# Example pre_action: runs after simulator acquisition, before the tests.
set -euo pipefail

if [[ -z "${SIMULATOR_UDID:-}" ]]; then
  echo "PRE_ACTION_ERROR: SIMULATOR_UDID not set" >&2
  exit 1
fi
echo "PRE_ACTION_RAN udid=$SIMULATOR_UDID"
