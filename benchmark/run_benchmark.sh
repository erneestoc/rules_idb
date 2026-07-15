#!/bin/bash
# Benchmarks the rules_idb runner against the stock rules_apple
# xcodebuild-based runner on identical hosted test suites.
#
# Scenarios (idb vs xcodebuild unless noted):
#   single           one hosted test target, warm simulator
#   coldboot_single  same, after `simctl shutdown all` (boot+install+run)
#   big_single       one target whose host app carries a 400 MB resource
#                    (staging/install wall time at a realistic app size)
#   concurrent4      four independent targets, --local_test_jobs=4
#   concurrent8      eight independent targets, --local_test_jobs=8
#   repeat12         --runs_per_test=3 on four targets, jobs=8 (12 actions)
#   sustained3x8     idb-only: three consecutive concurrent8 passes with
#                    RULES_IDB_WARM_POOL_SIZE=4 (default) vs 8, quantifying
#                    the warm-residue reboot cost on repeated wide runs
#
# For each scenario we record wall time, sample host-side harness memory and
# CPU (xcodebuild family vs idb family) every 0.5s, and print a per-target
# phase breakdown (simulator / install+session / in-simulator test time).
# Results land in benchmark/results/.

set -euo pipefail
cd "$(dirname "$0")/.."

RESULTS_DIR="${1:-benchmark/results}"
mkdir -p "$RESULTS_DIR"
: > "$RESULTS_DIR/summary.txt"

IDB_BIN="${RULES_IDB_IDB_PATH:-$PWD/.venv-src/bin/idb}"
COMPANION_BIN="${RULES_IDB_COMPANION_PATH:-$HOME/workspace/rules_idb/tools/idb-dist/idb_companion}"
TEST_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
TESTLOGS_DIR=$(bazel info bazel-testlogs)

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

# run_scenario <name> <warmup|nowarmup> <passes> [bazel args...]
run_scenario() {
  local name="$1" warmup="$2" passes="$3"
  shift 3
  echo
  echo "=== scenario: $name ==="
  # Leftover harness processes from earlier runs would pollute the samples.
  kill_stray_harness_processes
  if [[ "$warmup" == warmup ]]; then
    # Untimed warm-up pass: boots pool simulators / warms caches so the
    # measured pass reflects steady-state CI behavior for both runners.
    echo "--- warm-up pass (untimed)"
    bazel test "${BAZEL_TEST_FLAGS[@]}" "$@" >/dev/null 2>&1 || true
  fi
  local csv="$RESULTS_DIR/$name.csv"
  python3 benchmark/sampler.py "$csv" &
  local sampler_pid=$!
  local pass=1
  while [[ "$pass" -le "$passes" ]]; do
    local suffix=""
    [[ "$passes" -gt 1 ]] && suffix=".pass$pass"
    echo "--- measured pass $pass/$passes"
    local status=0
    local start end
    local marker
    marker="$(cd "$RESULTS_DIR" && pwd)/.marker"
    touch "$marker"
    sleep 1  # test.log mtimes have 1s resolution on some filesystems
    start=$(date +%s)
    bazel test "${BAZEL_TEST_FLAGS[@]}" "$@" 2>&1 \
      | tee "$RESULTS_DIR/$name$suffix.log" || status=$?
    end=$(date +%s)
    {
      echo "--- $name$suffix: wall=$((end - start))s bazel_exit=$status"
      python3 benchmark/phases.py "$RESULTS_DIR/$name$suffix.log" "$TESTLOGS_DIR" "$marker"
    } | tee -a "$RESULTS_DIR/summary.txt"
    # Preserve this pass's test.logs before a later pass/scenario overwrites
    # them -- failure diagnosis is impossible otherwise.
    local logdir
    mkdir -p "$RESULTS_DIR/$name$suffix-testlogs"
    logdir="$(cd "$RESULTS_DIR/$name$suffix-testlogs" && pwd)"
    (cd "$TESTLOGS_DIR" && find . -name "test.log" -newer "$marker" -exec rsync -R {} "$logdir/" \;) 2>/dev/null || true
    pass=$((pass + 1))
  done
  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
  python3 benchmark/summarize.py "$csv" | tee -a "$RESULTS_DIR/summary.txt"
}

shutdown_all_simulators() {
  echo "--- shutting down all simulators for a cold-boot scenario"
  xcrun simctl shutdown all >/dev/null 2>&1 || true
  # Give CoreSimulator time to fully tear the devices down.
  sleep 10
}

IDB_SHARDS_4=(//examples:HostedTestsShard1 //examples:HostedTestsShard2
  //examples:HostedTestsShard3 //examples:HostedTestsShard4)
XC_SHARDS_4=(//examples:HostedTestsShard1_xcodebuild //examples:HostedTestsShard2_xcodebuild
  //examples:HostedTestsShard3_xcodebuild //examples:HostedTestsShard4_xcodebuild)
IDB_SHARDS_8=("${IDB_SHARDS_4[@]}" //examples:HostedTestsShard5 //examples:HostedTestsShard6
  //examples:HostedTestsShard7 //examples:HostedTestsShard8)
XC_SHARDS_8=("${XC_SHARDS_4[@]}" //examples:HostedTestsShard5_xcodebuild
  //examples:HostedTestsShard6_xcodebuild //examples:HostedTestsShard7_xcodebuild
  //examples:HostedTestsShard8_xcodebuild)

echo "Building all test targets once so measured runs are pure test execution..."
bazel build \
  //examples:HostedTests //examples:HostedTests_xcodebuild \
  //examples:HostedTestsBig //examples:HostedTestsBig_xcodebuild \
  "${IDB_SHARDS_8[@]}" "${XC_SHARDS_8[@]}"

# --- warm single-target latency --------------------------------------------
run_scenario single_idb warmup 1 //examples:HostedTests
run_scenario single_xcodebuild warmup 1 //examples:HostedTests_xcodebuild

# --- cold-boot single-target latency (simulators shut down, not deleted) ---
shutdown_all_simulators
run_scenario coldboot_single_idb nowarmup 1 //examples:HostedTests
shutdown_all_simulators
run_scenario coldboot_single_xcodebuild nowarmup 1 //examples:HostedTests_xcodebuild

# --- staging/install wall time at a realistic (400 MB) app size ------------
# In-repo default is tree artifacts (clonefile staging); the _zip variants
# measure the archive path most consumers are on.
run_scenario big_single_idb warmup 1 //examples:HostedTestsBig
run_scenario big_single_xcodebuild warmup 1 //examples:HostedTestsBig_xcodebuild
run_scenario big_single_zip_idb warmup 1 \
  --@rules_apple//apple/build_settings:use_tree_artifacts_outputs=false \
  //examples:HostedTestsBig
run_scenario big_single_zip_xcodebuild warmup 1 \
  --@rules_apple//apple/build_settings:use_tree_artifacts_outputs=false \
  //examples:HostedTestsBig_xcodebuild

# --- concurrency ------------------------------------------------------------
run_scenario concurrent4_idb warmup 1 --local_test_jobs=4 "${IDB_SHARDS_4[@]}"
run_scenario concurrent4_xcodebuild warmup 1 --local_test_jobs=4 "${XC_SHARDS_4[@]}"

run_scenario concurrent8_idb warmup 1 --local_test_jobs=8 \
  --test_env=RULES_IDB_WARM_POOL_SIZE=8 "${IDB_SHARDS_8[@]}"
run_scenario concurrent8_xcodebuild warmup 1 --local_test_jobs=8 "${XC_SHARDS_8[@]}"

# --- --runs_per_test stress (12 actions over 8 slots) -----------------------
run_scenario repeat12_idb warmup 1 --local_test_jobs=8 --runs_per_test=3 \
  --test_env=RULES_IDB_WARM_POOL_SIZE=8 "${IDB_SHARDS_4[@]}"
run_scenario repeat12_xcodebuild warmup 1 --local_test_jobs=8 --runs_per_test=3 \
  "${XC_SHARDS_4[@]}"

# --- warm-residue thrash: repeated wide runs, default cap vs full cap -------
run_scenario sustained3x8_idb_warm4 warmup 3 --local_test_jobs=8 \
  --test_env=RULES_IDB_WARM_POOL_SIZE=4 "${IDB_SHARDS_8[@]}"
run_scenario sustained3x8_idb_warm8 warmup 3 --local_test_jobs=8 \
  --test_env=RULES_IDB_WARM_POOL_SIZE=8 "${IDB_SHARDS_8[@]}"

echo
echo "=== overall summary ==="
cat "$RESULTS_DIR/summary.txt"
