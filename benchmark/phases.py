#!/usr/bin/env python3
"""Per-target wall-clock phase breakdown for a benchmark scenario.

Reads the bazel output of a scenario (for per-target wall time) and each
target's test.log (for the phase breakdown), and prints one line per test
action:

  idb targets      the runner's `note: timing` line gives stage / simulator /
                   companion / idb phases; the JSON parse note gives the
                   in-simulator test time, so overhead = idb - in-simulator
                   covers bundle install + session setup.
  xcodebuild       XCTest's own "Executed N tests ... in X (Y) seconds"
                   summary gives the in-simulator time; everything else the
                   action spent (wall - in-simulator) is harness overhead:
                   simulator provisioning, app install, session setup.

Usage: phases.py <scenario.log> <bazel-testlogs-dir> [<marker-file>]

With a marker file, test.logs older than it (stale artifacts of earlier
scenarios, e.g. run_N_of_M dirs from a --runs_per_test scenario) are skipped.
"""

import glob
import os
import re
import sys

TARGET_RE = re.compile(r"^(//\S+)\s+(PASSED|FAILED|FLAKY|TIMEOUT)", re.M)
TIMING_RE = re.compile(
    r"note: timing stage=([\d.]+)s simulator=([\d.]+)s "
    r"companion=([\d.]+)s idb=([\d.]+)s total=([\d.]+)s"
)
INSIM_IDB_RE = re.compile(r"executed (\d+) tests, (\d+) failed \(([\d.]+)s in-simulator\)")
INSIM_XC_RE = re.compile(
    r"Executed (\d+) tests?, with (?:\d+ tests? skipped and )?(\d+) failures? "
    r"\(\d+ unexpected\) in ([\d.]+) \(([\d.]+)\) seconds"
)


def target_walls(scenario_log):
    """label -> (status, wall_s or None) from bazel's result lines."""
    walls = {}
    with open(scenario_log, errors="replace") as f:
        for line in f:
            m = TARGET_RE.match(line.strip())
            if not m:
                continue
            label, status = m.group(1), m.group(2)
            times = [float(t) for t in re.findall(r"([\d.]+)s", line)]
            walls[label] = (status, max(times) if times else None)
    return walls


def analyze_log(path):
    with open(path, errors="replace") as f:
        text = f.read()
    timing = TIMING_RE.search(text)
    if timing:
        stage, simulator, companion, idb, total = (float(x) for x in timing.groups())
        insim = INSIM_IDB_RE.search(text)
        insim_s = float(insim.group(3)) if insim else None
        return {
            "kind": "idb",
            "stage": stage,
            "simulator": simulator,
            "companion": companion,
            "idb": idb,
            "total": total,
            "insim": insim_s,
        }
    matches = INSIM_XC_RE.findall(text)
    if matches:
        # The last "All tests" style summary is cumulative for the bundle.
        insim_s = max(float(m[3]) for m in matches)
        return {"kind": "xcodebuild", "insim": insim_s}
    return None


def main():
    scenario_log, testlogs = sys.argv[1], sys.argv[2]
    min_mtime = os.path.getmtime(sys.argv[3]) if len(sys.argv) > 3 else 0
    walls = target_walls(scenario_log)
    for label in sorted(walls):
        status, wall = walls[label]
        rel = label.lstrip("/").replace(":", "/")
        logs = sorted(
            log
            for log in glob.glob(os.path.join(testlogs, rel, "test.log"))
            + glob.glob(os.path.join(testlogs, rel, "run_*", "test.log"))
            if os.path.getmtime(log) >= min_mtime
        )
        if not logs:
            print("  %-55s %-7s wall=%ss (no test.log)" % (label, status, wall))
            continue
        for log in logs:
            run = os.path.basename(os.path.dirname(log))
            suffix = "" if run == os.path.basename(rel) else " [%s]" % run
            info = analyze_log(log)
            wall_s = "%.1f" % wall if wall is not None else "?"
            if info is None:
                print("  %-55s %-7s wall=%ss (unparseable)" % (label + suffix, status, wall_s))
            elif info["kind"] == "idb":
                overhead = (
                    "%.1f" % (info["idb"] - info["insim"]) if info["insim"] is not None else "?"
                )
                print(
                    "  %-55s %-7s wall=%ss stage=%.1fs sim=%.1fs companion=%.1fs "
                    "install+session=%ss run(insim)=%.1fs"
                    % (
                        label + suffix,
                        status,
                        wall_s,
                        info["stage"],
                        info["simulator"],
                        info["companion"],
                        overhead,
                        info["insim"] or 0.0,
                    )
                )
            else:
                overhead = "%.1f" % (wall - info["insim"]) if wall is not None else "?"
                print(
                    "  %-55s %-7s wall=%ss provision+install+session=%ss run(insim)=%.1fs"
                    % (label + suffix, status, wall_s, overhead, info["insim"])
                )


if __name__ == "__main__":
    main()
