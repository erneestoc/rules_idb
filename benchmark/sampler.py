#!/usr/bin/env python3
"""Samples host-side test harness memory and CPU while a scenario runs.

Every 0.5s this records, for each harness family, the summed RSS of its
live processes and a cumulative CPU-seconds estimate (per-PID max cputime,
summed over every PID ever seen, so CPU spent by short-lived processes that
die between samples is retained up to their last observation):

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


def parse_cputime(value):
    """ps cputime: [DD-]HH:MM:SS.ss or MM:SS.ss -> seconds."""
    days = 0
    if "-" in value:
        day_part, value = value.split("-", 1)
        days = int(day_part)
    parts = [float(p) for p in value.split(":")]
    seconds = 0.0
    for p in parts:
        seconds = seconds * 60 + p
    return days * 86400 + seconds


def sample(cpu_seen):
    out = subprocess.check_output(
        ["ps", "-axo", "pid=,rss=,cputime=,args="], text=True, errors="replace"
    )
    totals = {name: 0 for name in FAMILIES}
    counts = {name: 0 for name in FAMILIES}
    for line in out.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 4:
            continue
        pid, rss, cputime, args = parts
        if "sampler.py" in args:
            continue
        for name, needles in FAMILIES.items():
            if any(needle in args or args.endswith(needle.strip()) for needle in needles):
                totals[name] += int(rss)  # KiB
                counts[name] += 1
                try:
                    cpu = parse_cputime(cputime)
                except ValueError:
                    cpu = 0.0
                key = (name, pid)
                cpu_seen[key] = max(cpu_seen.get(key, 0.0), cpu)
                break
    cpu_totals = {name: 0.0 for name in FAMILIES}
    for (name, _pid), cpu in cpu_seen.items():
        cpu_totals[name] += cpu
    return totals, counts, cpu_totals


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    output = sys.argv[1]
    cpu_seen = {}
    with open(output, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            ["elapsed_s"]
            + ["%s_rss_mib" % n for n in FAMILIES]
            + ["%s_procs" % n for n in FAMILIES]
            + ["%s_cpu_s" % n for n in FAMILIES]
        )
        start = time.time()
        while running:
            totals, counts, cpu_totals = sample(cpu_seen)
            writer.writerow(
                ["%.1f" % (time.time() - start)]
                + ["%.1f" % (totals[n] / 1024.0) for n in FAMILIES]
                + [counts[n] for n in FAMILIES]
                + ["%.1f" % cpu_totals[n] for n in FAMILIES]
            )
            f.flush()
            time.sleep(0.5)


if __name__ == "__main__":
    main()
