#!/bin/bash
# Hand-rolled pooled simulator creator for rules_apple's ios_xctestrun_runner,
# representative of what teams write today to make --local_test_jobs work
# with the stock runner (the exact problem rules_idb's built-in pool solves).
#
# Claims a pool slot with a PID lockfile (locks from killed actions are
# detected via liveness of XCTESTRUN_RUNNER_PID and stolen), find-or-creates
# "bench_xcb_pool.<slot>", boots it, and prints the UDID. The paired
# flock_simulator_cleanup.sh releases the lockfile after the test.
set -euo pipefail
exec python3 - <<'PYEOF'
import errno
import json
import os
import subprocess
import sys


def simctl(*a):
    return subprocess.check_output(["xcrun", "simctl", *a], text=True)


def note(msg):
    print("creator: " + msg, file=sys.stderr)


owner_pid = int(os.environ.get("XCTESTRUN_RUNNER_PID") or os.getppid())
device_type = os.environ.get("SIMULATOR_DEVICE_TYPE") or "iPhone 17 Pro"
os_version = os.environ.get("SIMULATOR_OS_VERSION") or ""

tmp = subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip()
pool = os.path.join(tmp, "bench_xcb_pool")
os.makedirs(pool, exist_ok=True)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError as e:
        return e.errno != errno.ESRCH


slot = None
i = 0
while slot is None:
    path = os.path.join(pool, "slot-%d.pid" % i)
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.write(fd, ("%d\n" % owner_pid).encode())
        os.close(fd)
        slot = i
    except FileExistsError:
        try:
            holder = int(open(path).read().split()[0])
        except (ValueError, IndexError):
            holder = 0
        if not holder or not alive(holder):
            note("stealing stale slot %d (pid %d dead)" % (i, holder))
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
            continue
        i += 1

name = "bench_xcb_pool.%d" % slot
note("claimed slot %d for pid %d" % (slot, owner_pid))

udid = None
state = "Shutdown"
devices = json.loads(simctl("list", "devices", "-j"))["devices"]
for runtime_devices in devices.values():
    for device in runtime_devices:
        if device["name"] == name and device.get("isAvailable", True):
            udid = device["udid"]
            state = device.get("state", "Shutdown")
            break

if udid is None:
    runtimes = [
        r
        for r in json.loads(simctl("list", "runtimes", "-j"))["runtimes"]
        if r["platform"] == "iOS" and r["isAvailable"]
        and (not os_version or r["version"] == os_version
             or r["version"].startswith(os_version + "."))
    ]
    if not runtimes:
        sys.exit("error: no available iOS runtime matching %r" % os_version)
    runtimes.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
    udid = simctl("create", name, device_type, runtimes[-1]["identifier"]).strip()
    note("created %s (%s)" % (name, udid))

if state != "Booted":
    subprocess.run(
        ["xcrun", "simctl", "bootstatus", udid, "-b"],
        stdout=sys.stderr, stderr=sys.stderr,
    )

# Record the udid so the cleanup can find this slot's lockfile.
with open(os.path.join(pool, "slot-%d.pid" % slot), "w") as f:
    f.write("%d %s\n" % (owner_pid, udid))

print(udid)
PYEOF
