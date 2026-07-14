#!/bin/bash
# Example custom clean_up_simulator_action.
set -euo pipefail

if [[ -z "${SIMULATOR_UDID:-}" ]]; then
  echo "CUSTOM_CLEANUP_ERROR: SIMULATOR_UDID not set" >&2
  exit 1
fi
echo "CUSTOM_CLEANUP_RAN udid=$SIMULATOR_UDID reuse='${SIMULATOR_REUSE_SIMULATOR:-}'" >&2
