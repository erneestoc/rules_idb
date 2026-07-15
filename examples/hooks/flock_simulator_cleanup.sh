#!/bin/bash
# Releases the pool-slot lockfile claimed by flock_simulator_creator.sh.
# The simulator is intentionally left booted for warm reuse.
set -euo pipefail
exec python3 - <<'PYEOF'
import os
import subprocess

udid = os.environ.get("SIMULATOR_UDID", "")
tmp = subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip()
pool = os.path.join(tmp, "bench_xcb_pool")
if udid and os.path.isdir(pool):
    for entry in os.listdir(pool):
        if not entry.endswith(".pid"):
            continue
        path = os.path.join(pool, entry)
        try:
            parts = open(path).read().split()
        except OSError:
            continue
        if len(parts) == 2 and parts[1] == udid:
            os.unlink(path)
            break
PYEOF
