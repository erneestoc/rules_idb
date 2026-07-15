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
# Safe to run next to live tests: every mutation (create, delete, shutdown)
# happens only while holding the same per-slot flock the test runner uses to
# claim a simulator, so a slot with a test on it is skipped, never yanked.
#
# device/os must match the runner's device_type/os_version attributes (both
# empty by default) so the pool keys line up.
set -euo pipefail

exec python3 - "$@" <<'PYEOF'
import argparse
import concurrent.futures
import fcntl
import json
import os
import re
import subprocess
import sys

parser = argparse.ArgumentParser(prog="preboot")
parser.add_argument("count", type=int)
parser.add_argument("--device", default="", dest="device_type")
parser.add_argument("--os", default="", dest="os_version")
parser.add_argument(
    "--max-concurrent-boots", type=int, default=3,
    help="0 = auto (half the CPU cores), matching the runner's convention",
)
parser.add_argument("--boot-timeout", type=int, default=240)
parser.add_argument("--no-reconcile", action="store_false", dest="reconcile")
args = parser.parse_args()
if args.count < 0:
    sys.exit("error: count must be >= 0")
max_boots = args.max_concurrent_boots
if max_boots <= 0:
    max_boots = max(1, os.cpu_count() // 2)


def simctl(*a, **kw):
    return subprocess.check_output(["xcrun", "simctl", *a], text=True, **kw)


def pool_key(device_type, os_version):
    raw = "%s_%s" % (device_type or "default", os_version or "latest")
    key = re.sub(r"[^A-Za-z0-9._-]", "-", raw)
    # Mirrors the runner: a custom pool root namespaces its simulators.
    root = os.environ.get("RULES_IDB_POOL_DIR")
    if root:
        crc = subprocess.run(
            ["/usr/bin/cksum"], input=root, capture_output=True, text=True
        ).stdout.split()[0]
        key = "%s.r%s" % (key, crc)
    return key


def pool_dir(key):
    root = os.environ.get("RULES_IDB_POOL_DIR")
    if not root:
        tmp = subprocess.check_output(
            ["getconf", "DARWIN_USER_TEMP_DIR"], text=True
        ).strip()
        root = tmp + "rules_idb_pool"
    return os.path.join(root, key)


def try_lock_slot(key, slot):
    """Take the test runner's slot flock; None if a test action holds it.

    The returned file object keeps the lock until closed (or process exit).
    """
    d = pool_dir(key)
    os.makedirs(d, exist_ok=True)
    f = open(os.path.join(d, "slot-%d.lock" % slot), "a")
    try:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        return f
    except OSError:
        f.close()
        return None


# --- Resolve the requested runtime and device type once. --------------------
runtimes = [
    r
    for r in json.loads(simctl("list", "runtimes", "-j"))["runtimes"]
    if r["platform"] == "iOS" and r["isAvailable"]
]
if args.os_version:
    runtimes = [
        r
        for r in runtimes
        if r["version"] == args.os_version
        or r["version"].startswith(args.os_version + ".")
    ]
if not runtimes:
    sys.exit("error: no available iOS runtime matching version %r" % args.os_version)
runtimes.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
runtime = runtimes[-1]

device_types = json.loads(simctl("list", "devicetypes", "-j"))["devicetypes"]
device_type = args.device_type
if not device_type:
    # Pick the newest iPhone the chosen runtime actually supports, using the
    # hardware model identifier as the recency key (same logic as the
    # runner's pool).
    supported = {d["identifier"] for d in runtime.get("supportedDeviceTypes", [])}

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
        sys.exit(
            "error: no iPhone device types supported by runtime %s"
            % runtime["identifier"]
        )
    device_type = max(iphones, key=model_key)["name"]

expected_dt = next(
    (
        d["identifier"]
        for d in device_types
        if d["name"] == device_type or d["identifier"] == device_type
    ),
    None,
)

key = pool_key(args.device_type, args.os_version)
print(
    "pre-booting %d simulators for pool '%s' (%s, iOS %s; max %d concurrent boots)"
    % (args.count, key, device_type, runtime["version"], max_boots)
)

# Mirrors the runner's default: half the CPU cores, floor 4.
warm = int(os.environ.get("RULES_IDB_WARM_POOL_SIZE", "0")) or max(4, os.cpu_count() // 2)
if args.count > warm:
    print(
        "warning: count %d exceeds RULES_IDB_WARM_POOL_SIZE (%d); after each "
        "test, slots >= %d shut their simulator down again. Export "
        "RULES_IDB_WARM_POOL_SIZE=%d to keep all of them warm."
        % (args.count, warm, warm, args.count),
        file=sys.stderr,
    )


def list_devices():
    return json.loads(simctl("list", "devices", "-j"))["devices"]


# --- Find-or-create each slot, mutating only under the slot's flock. --------
devices = list_devices()
to_boot = []  # (name, udid)
held_locks = []
for slot in range(args.count):
    name = "rules_idb.%s.%d" % (key, slot)
    matches = [
        (runtime_id, device)
        for runtime_id, runtime_devices in devices.items()
        for device in runtime_devices
        if device["name"] == name
    ]
    # Reuse an existing simulator only if its SUBSTANCE matches the resolved
    # intent (runtime + device type), not just its name: with default
    # device/os, "latest" drifts across Xcode upgrades and a stale simulator
    # would otherwise be reused forever.
    good = [
        (rid, d)
        for rid, d in matches
        if d.get("isAvailable", True)
        and rid == runtime["identifier"]
        and (expected_dt is None or d.get("deviceTypeIdentifier") == expected_dt)
    ]
    stale = [d for rid, d in matches if not any(d is g[1] for g in good)]

    lock = try_lock_slot(key, slot)
    if lock is None:
        state = good[0][1].get("state", "?") if good else "missing"
        print(
            "  %s: slot in use by a running test (%s); leaving it alone"
            % (name, state)
        )
        continue

    if good:
        udid = good[0][1]["udid"]
        state = good[0][1].get("state", "Shutdown")
        # Duplicate-name devices (created by races before locking existed)
        # make every name-based lookup nondeterministic; delete the extras.
        stale += [d for _, d in good[1:]]
    else:
        udid = None
    for d in stale:
        subprocess.run(["xcrun", "simctl", "shutdown", d["udid"]], capture_output=True)
        subprocess.run(["xcrun", "simctl", "delete", d["udid"]], capture_output=True)
        print("  %s: removed stale/duplicate device %s" % (name, d["udid"]))
    if udid is None:
        udid = simctl("create", name, device_type, runtime["identifier"]).strip()
        state = "Created"
        print("  %s (%s): created" % (name, udid))
    if state == "Booted":
        print("  %s (%s): already booted" % (name, udid))
        lock.close()
    else:
        print("  %s (%s): %s -> will boot" % (name, udid, state))
        to_boot.append((name, udid))
        # Hold the lock through the boot so reconcile/tests can't race it.
        held_locks.append(lock)

# --- Reconcile: shut down booted rules_idb.* sims outside the target set. ---
if args.reconcile:
    expected = {"rules_idb.%s.%d" % (key, slot) for slot in range(args.count)}
    slot_re = re.compile(r"^rules_idb\.(.+)\.(\d+)$")
    for runtime_devices in list_devices().values():
        for device in runtime_devices:
            name = device["name"]
            if not name.startswith("rules_idb.") or device.get("state") != "Booted":
                continue
            if name in expected:
                continue
            m = slot_re.match(name)
            lock = try_lock_slot(m.group(1), int(m.group(2))) if m else None
            if m and lock is None:
                print(
                    "  reconcile: %s (%s) is in use by a running test; skipping"
                    % (name, device["udid"])
                )
                continue
            print("  reconcile: shutting down %s (%s)" % (name, device["udid"]))
            subprocess.run(
                ["xcrun", "simctl", "shutdown", device["udid"]], capture_output=True
            )
            if lock:
                lock.close()

# --- Boot, bounded and fault-tolerant. ---------------------------------------
if not to_boot:
    print("nothing to boot")
    sys.exit(0)


def boot(entry):
    name, udid = entry
    try:
        subprocess.run(
            ["xcrun", "simctl", "bootstatus", udid, "-b"],
            capture_output=True,
            timeout=args.boot_timeout,
        )
    except subprocess.TimeoutExpired:
        pass
    # bootstatus exits non-zero for benign reasons (e.g. 149 when a test
    # action booted it first); the device's state is the source of truth.
    out = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "-j", udid],
        capture_output=True,
        text=True,
    ).stdout
    try:
        for runtime_devices in json.loads(out)["devices"].values():
            for device in runtime_devices:
                if device["udid"] == udid and device.get("state") == "Booted":
                    return None
    except ValueError:
        pass
    return name


with concurrent.futures.ThreadPoolExecutor(max_workers=max_boots) as pool:
    failed = [name for name in pool.map(boot, to_boot) if name]

for lock in held_locks:
    lock.close()

if failed:
    sys.exit("error: failed to boot: %s" % ", ".join(failed))
print("done: %d simulators booted" % len(to_boot))
PYEOF
