#!/bin/bash
# Example custom create_simulator_action, using the same environment
# contract as rules_apple's ios_xctestrun_runner. Prints only the UDID.
set -euo pipefail

echo "CUSTOM_CREATOR_RAN device='${SIMULATOR_DEVICE_TYPE:-}' os='${SIMULATOR_OS_VERSION:-}' reuse='${SIMULATOR_REUSE_SIMULATOR:-}'" >&2

name="rules_idb.custom-example"
udid=$(xcrun simctl list devices -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime_devices in devices.values():
    for device in runtime_devices:
        if device["name"] == "rules_idb.custom-example" and device.get("isAvailable", True):
            print(device["udid"])
            raise SystemExit
')

if [[ -z "$udid" ]]; then
  udid=$(xcrun simctl create "$name" "${SIMULATOR_DEVICE_TYPE:-iPhone 17 Pro}")
fi

xcrun simctl bootstatus "$udid" -b >&2 || true
echo "$udid"
