#!/bin/bash
# Shuts down (default) or deletes rules_idb's pooled simulators.
#
#   tools/clean_simulators.sh            # shut down pool simulators (free RAM,
#                                        # keep them for warm reuse)
#   tools/clean_simulators.sh --delete   # delete them entirely (next run
#                                        # recreates on demand)
set -euo pipefail

mode="shutdown"
if [[ "${1:-}" == "--delete" ]]; then
  mode="delete"
fi

udids=$(xcrun simctl list devices -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime_devices in devices.values():
    for device in runtime_devices:
        if device["name"].startswith("rules_idb."):
            print(device["udid"], device["name"], device["state"])
')

if [[ -z "$udids" ]]; then
  echo "no rules_idb simulators found"
  exit 0
fi

while read -r udid name state; do
  echo "$mode: $name ($udid, was $state)"
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  if [[ "$mode" == "delete" ]]; then
    xcrun simctl delete "$udid"
  fi
done <<< "$udids"
