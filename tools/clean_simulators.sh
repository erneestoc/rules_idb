#!/bin/bash
# Shuts down (default) or deletes rules_idb's pooled simulators.
#
#   tools/clean_simulators.sh            # shut down pool simulators (free RAM,
#                                        # keep them for warm reuse)
#   tools/clean_simulators.sh --delete   # delete them entirely (next run
#                                        # recreates on demand)
#
# Simulators whose pool slot flock is held by a running test action are
# skipped with a warning instead of being yanked out from under the test.
set -euo pipefail

mode="shutdown"
case "${1:-}" in
  "") ;;
  --delete) mode="delete" ;;
  *) echo "usage: clean_simulators.sh [--delete]" >&2; exit 1 ;;
esac

exec python3 - "$mode" <<'PYEOF'
import fcntl
import json
import os
import re
import subprocess
import sys

mode = sys.argv[1]
slot_re = re.compile(r"^rules_idb\.(.+)\.(\d+)$")

root = os.environ.get("RULES_IDB_POOL_DIR")
if not root:
    tmp = subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip()
    root = tmp + "rules_idb_pool"


def try_lock(name):
    """Take the runner's slot flock for this simulator; None if held."""
    m = slot_re.match(name)
    if not m:
        return True  # not a pool-slot name; nothing to coordinate with
    d = os.path.join(root, m.group(1))
    os.makedirs(d, exist_ok=True)
    f = open(os.path.join(d, "slot-%s.lock" % m.group(2)), "a")
    try:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        return f
    except OSError:
        f.close()
        return None


devices = json.loads(
    subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"], text=True)
)["devices"]
found = skipped = 0
for runtime_devices in devices.values():
    for device in runtime_devices:
        name = device["name"]
        if not name.startswith("rules_idb."):
            continue
        found += 1
        lock = try_lock(name)
        if lock is None:
            print("skip: %s (%s) is in use by a running test" % (name, device["udid"]))
            skipped += 1
            continue
        print("%s: %s (%s, was %s)" % (mode, name, device["udid"], device["state"]))
        subprocess.run(["xcrun", "simctl", "shutdown", device["udid"]], capture_output=True)
        if mode == "delete":
            subprocess.run(["xcrun", "simctl", "delete", device["udid"]], check=True)
        if lock is not True:
            lock.close()

if not found:
    print("no rules_idb simulators found")
if skipped:
    print("note: %d simulator(s) skipped; re-run once their tests finish" % skipped)
PYEOF
