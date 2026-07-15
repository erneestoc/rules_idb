#!/usr/bin/env python3
"""Summarizes a sampler.py CSV: peak/mean RSS, CPU seconds per family."""

import csv
import sys


def main():
    path = sys.argv[1]
    with open(path) as f:
        rows = list(csv.DictReader(f))
    if not rows:
        print("no samples in %s" % path)
        return
    for family in ("xcodebuild", "idb"):
        rss = [float(r["%s_rss_mib" % family]) for r in rows]
        procs = [int(r["%s_procs" % family]) for r in rows]
        cpu = [float(r.get("%s_cpu_s" % family, 0.0) or 0.0) for r in rows]
        active = [v for v in rss if v > 1.0]
        print(
            "%-11s peak=%8.1f MiB  mean-active=%8.1f MiB  max-procs=%d  cpu=%6.1f s"
            % (
                family,
                max(rss),
                (sum(active) / len(active)) if active else 0.0,
                max(procs),
                cpu[-1],
            )
        )


if __name__ == "__main__":
    main()
