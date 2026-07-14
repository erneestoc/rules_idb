#!/bin/bash
# Benchmarks the rules_idb runner against the stock rules_apple
# xcodebuild-based runner on identical hosted test suites.
#
# Scenarios:
#   *_single       one hosted test target
#   *_concurrent4  four independent hosted test targets, --local_test_jobs=4
#
# For each scenario we record wall time and sample host-side harness memory
# (xcodebuild family vs idb family) every 0.5s. Results land in
# benchmark/results/.

set -euo pipefail
cd "$(dirname "$0")/.."

RESULTS_DIR="${1:-benchmark/results}"
mkdir -p "$RESULTS_DIR"
: > "$RESULTS_DIR/summary.txt"

IDB_BIN="${RULES_IDB_IDB_PATH:-$PWD/.venv-src/bin/idb}"
COMPANION_BIN="${RULES_IDB_COMPANION_PATH:-$HOME/workspace/rules_idb/tools/idb-dist/idb_companion}"
TEST_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

BAZEL_TEST_FLAGS=(
  --nocache_test_results
  --test_output=summary
  "--test_env=RULES_IDB_IDB_PATH=$IDB_BIN"
  "--test_env=RULES_IDB_COMPANION_PATH=$COMPANION_BIN"
  "--test_env=PATH=$TEST_PATH"
)

kill_stray_harness_processes() {
  pkill -9 -f "idb-dist/idb_companion" 2>/dev/null || true
  pkill -9 -f "bin/idb " 2>/dev/null || true
  pkill -x xcodebuild 2>/dev/null || true
  sleep 1
}

run_scenario() {
  local name="$1"
  shift
  echo
  echo "=== scenario: $name ==="
  # Leftover harness processes from earlier runs would pollute the samples.
  kill_stray_harness_processes
  # Untimed warm-up pass: boots pool simulators / warms caches so the
  # measured pass reflects steady-state CI behavior for both runners.
  echo "--- warm-up pass (untimed)"
  bazel test "${BAZEL_TEST_FLAGS[@]}" "$@" >/dev/null 2>&1 || true
  echo "--- measured pass"
  local csv="$RESULTS_DIR/$name.csv"
  python3 benchmark/sampler.py "$csv" &
  local sampler_pid=$!
  local status=0
  local start end
  start=$(date +%s)
  bazel test "${BAZEL_TEST_FLAGS[@]}" "$@" 2>&1 | tee "$RESULTS_DIR/$name.log" || status=$?
  end=$(date +%s)
  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
  {
    echo "--- $name: wall=$((end - start))s bazel_exit=$status"
    python3 benchmark/summarize.py "$csv"
  } | tee -a "$RESULTS_DIR/summary.txt"
}

echo "Building all test targets once so measured runs are pure test execution..."
bazel build \
  //examples:HostedTests \
  //examples:HostedTests_xcodebuild \
  //examples:HostedTestsShard1 //examples:HostedTestsShard2 \
  //examples:HostedTestsShard3 //examples:HostedTestsShard4 \
  //examples:HostedTestsShard1_xcodebuild //examples:HostedTestsShard2_xcodebuild \
  //examples:HostedTestsShard3_xcodebuild //examples:HostedTestsShard4_xcodebuild

run_scenario idb_single //examples:HostedTests
run_scenario xcodebuild_single //examples:HostedTests_xcodebuild

run_scenario idb_concurrent4 --local_test_jobs=4 \
  //examples:HostedTestsShard1 //examples:HostedTestsShard2 \
  //examples:HostedTestsShard3 //examples:HostedTestsShard4

run_scenario xcodebuild_concurrent4 --local_test_jobs=4 \
  //examples:HostedTestsShard1_xcodebuild //examples:HostedTestsShard2_xcodebuild \
  //examples:HostedTestsShard3_xcodebuild //examples:HostedTestsShard4_xcodebuild

echo
echo "=== overall summary ==="
cat "$RESULTS_DIR/summary.txt"
