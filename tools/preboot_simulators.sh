#!/bin/bash
# Pre-boots N rules_idb pool simulators so test runs start warm. Idempotent:
# already-booted simulators are skipped, missing ones are created.
#
#   bazel run @rules_idb//tools:preboot -- 4
#   bazel run @rules_idb//tools:preboot -- 4 --device "iPhone 17 Pro" --os 26.2
#   bazel run @rules_idb//tools:preboot -- 4 --max-concurrent-boots 3
#
# This is a desired-state command: it also shuts down any booted rules_idb.*
# simulator that is NOT one of the N requested pool slots, so you end up
# with exactly the requested set booted. Simulators not named rules_idb.*
# are never touched. Pass --no-reconcile to only boot, never shut down.
#
# device/os must match the runner's device_type/os_version attributes (both
# empty by default) so the pool keys line up.
set -euo pipefail

count=""
device_type=""
os_version=""
max_concurrent_boots=3
reconcile=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device_type="$2"; shift 2 ;;
    --os) os_version="$2"; shift 2 ;;
    --max-concurrent-boots) max_concurrent_boots="$2"; shift 2 ;;
    --no-reconcile) reconcile=false; shift ;;
    -*) echo "error: unknown flag '$1'" >&2; exit 1 ;;
    *) count="$1"; shift ;;
  esac
done
if [[ -z "$count" || ! "$count" =~ ^[0-9]+$ ]]; then
  echo "usage: preboot <count> [--device NAME] [--os VERSION] [--max-concurrent-boots N]" >&2
  exit 1
fi

pool_key=$(printf '%s' "${device_type:-default}_${os_version:-latest}" | tr -c 'A-Za-z0-9._-' '-')
echo "pre-booting $count simulators for pool '$pool_key' (max $max_concurrent_boots concurrent boots)"

to_boot=()
for ((slot=0; slot<count; slot++)); do
  name="rules_idb.$pool_key.$slot"
  # Same find-or-create logic as the test runner's simulator pool.
  result=$(python3 - "$name" "$device_type" "$os_version" <<'PYEOF'
import json, subprocess, sys

name, device_type, os_version = sys.argv[1], sys.argv[2], sys.argv[3]

def simctl(*args):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True)

devices = json.loads(simctl("list", "devices", "-j"))["devices"]
for runtime_devices in devices.values():
    for device in runtime_devices:
        if device["name"] == name and device.get("isAvailable", True):
            print(device["udid"] + ":" + device.get("state", "Shutdown"))
            sys.exit(0)

runtimes = [
    r
    for r in json.loads(simctl("list", "runtimes", "-j"))["runtimes"]
    if r["platform"] == "iOS" and r["isAvailable"]
]
if os_version:
    runtimes = [
        r
        for r in runtimes
        if r["version"] == os_version or r["version"].startswith(os_version + ".")
    ]
if not runtimes:
    sys.exit("error: no available iOS runtime matching version %r" % os_version)
runtimes.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
runtime = runtimes[-1]

if not device_type:
    supported = {d["identifier"] for d in runtime.get("supportedDeviceTypes", [])}
    device_types = json.loads(simctl("list", "devicetypes", "-j"))["devicetypes"]

    def model_key(d):
        model = d.get("modelIdentifier", "")
        digits = model[len("iPhone"):] if model.startswith("iPhone") else ""
        try:
            major, minor = digits.split(",")
            return (int(major), int(minor))
        except ValueError:
            return (0, 0)

    iphones = [
        d
        for d in device_types
        if d.get("productFamily") == "iPhone"
        and d.get("modelIdentifier", "").startswith("iPhone")
        and d["identifier"] in supported
    ]
    if not iphones:
        sys.exit("error: no iPhone device types supported by runtime %s" % runtime["identifier"])
    device_type = max(iphones, key=model_key)["name"]

print(simctl("create", name, device_type, runtime["identifier"]).strip() + ":Created")
PYEOF
)
  udid="${result%%:*}"
  state="${result##*:}"
  if [[ "$state" == "Booted" ]]; then
    echo "  $name ($udid): already booted"
  else
    echo "  $name ($udid): $state -> will boot"
    to_boot+=("$udid")
  fi
done

# Reconcile: shut down booted rules_idb.* simulators outside the target set.
if [[ "$reconcile" == true ]]; then
  expected=""
  for ((slot=0; slot<count; slot++)); do
    expected="$expected rules_idb.$pool_key.$slot"
  done
  while read -r udid name; do
    [[ -n "$udid" ]] || continue
    if [[ " $expected " != *" $name "* ]]; then
      echo "  reconcile: shutting down $name ($udid)"
      xcrun simctl shutdown "$udid" 2>/dev/null || true
    fi
  done < <(xcrun simctl list devices -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime_devices in devices.values():
    for device in runtime_devices:
        if device["name"].startswith("rules_idb.") and device.get("state") == "Booted":
            print(device["udid"], device["name"])
')
fi

if [[ ${#to_boot[@]} -eq 0 ]]; then
  echo "nothing to boot"
  exit 0
fi

printf '%s\n' "${to_boot[@]}" | xargs -P "$max_concurrent_boots" -I{} xcrun simctl bootstatus {} -b
echo "done: ${#to_boot[@]} simulators booted"
