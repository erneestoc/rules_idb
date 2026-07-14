#!/usr/bin/env python3
"""Samples host-side test harness memory while a benchmark scenario runs.

Every 0.5s this records the RSS of processes belonging to each harness
family:

  xcodebuild: xcodebuild, XCBBuildService, xcresulttool
  idb:        idb_companion, the fb-idb python client

Simulator-side processes (CoreSimulator, backboardd, the test host app,
testmanagerd, ...) are intentionally excluded: both runners boot the same
simulators and run the same tests inside them, so that cost is identical.
What differs -- and what limits how many simulators fit on a CI host -- is
the harness process that drives the run.

Usage: sampler.py <output.csv>   (runs until SIGTERM/SIGINT)
"""

import csv
import signal
import subprocess
import sys
import time

FAMILIES = {
    "xcodebuild": ("xcodebuild", "XCBBuildService", "xcresulttool"),
    "idb": ("idb_companion", "bin/idb ", "bin/idb\n"),
}

running = True


def stop(_sig, _frame):
    global running
    running = False


def sample():
    out = subprocess.check_output(
        ["ps", "-axo", "pid=,rss=,args="], text=True, errors="replace"
    )
    totals = {name: 0 for name in FAMILIES}
    counts = {name: 0 for name in FAMILIES}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        _pid, rss, args = parts
        if "sampler.py" in args:
            continue
        for name, needles in FAMILIES.items():
            if any(needle in args or args.endswith(needle.strip()) for needle in needles):
                totals[name] += int(rss)  # KiB
                counts[name] += 1
                break
    return totals, counts


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    output = sys.argv[1]
    with open(output, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            ["elapsed_s"]
            + ["%s_rss_mib" % n for n in FAMILIES]
            + ["%s_procs" % n for n in FAMILIES]
        )
        start = time.time()
        while running:
            totals, counts = sample()
            writer.writerow(
                ["%.1f" % (time.time() - start)]
                + ["%.1f" % (totals[n] / 1024.0) for n in FAMILIES]
                + [counts[n] for n in FAMILIES]
            )
            f.flush()
            time.sleep(0.5)


if __name__ == "__main__":
    main()
