#!/bin/bash
# rules_idb test runner template.
#
# Runs an XCTest bundle (hosted, logic, or UI) on an iOS simulator using
# Facebook's idb instead of xcodebuild. Simulators are acquired from a pool
# guarded by kernel flock() locks so that concurrently running Bazel test
# actions (--local_test_jobs=N) each get their own simulator, out of the box.
#
# Runtime environment variable overrides:
#   RULES_IDB_IDB_PATH        path to the idb client binary
#   RULES_IDB_COMPANION_PATH  path to the idb_companion binary
#   RULES_IDB_POOL_DIR        directory holding pool lock files
#   RULES_IDB_POOL_SIZE       max simulators per (device, os) pool
#   RULES_IDB_SHUTDOWN_SIMULATOR  shut the simulator down after the run
#   RULES_IDB_COLLECT_LOGS    collect idb run logs into undeclared outputs
#   DEBUG_IDB_TEST_RUNNER     set -x tracing

set -euo pipefail

if [[ -n "${TEST_PREMATURE_EXIT_FILE:-}" ]]; then
  touch "$TEST_PREMATURE_EXIT_FILE"
fi

if [[ -n "${DEBUG_IDB_TEST_RUNNER:-}" ]]; then
  set -x
fi

# ---------------------------------------------------------------------------
# Configuration expanded by the ios_idb_test_runner rule.
# ---------------------------------------------------------------------------
device_type="%(device_type)s"
os_version="%(os_version)s"
pool_size="${RULES_IDB_POOL_SIZE:-%(pool_size)s}"
# Concurrency is naturally bounded by --local_test_jobs (one slot per
# running action); what must be bounded separately is the idle residue:
# each simulator left booted keeps ~60-100 CoreSimulator processes alive.
# After a test, only the first N slots stay warm; higher slots shut their
# simulator down. Auto default: half the CPU cores (floor 4), matching the
# boot gate -- benchmarked: sustained 8-wide runs with a cap of 4 spend
# 15-60s per action re-booting trimmed simulators (and flake under the
# churn), while a cap matching the concurrency stays flat.
warm_pool_size="${RULES_IDB_WARM_POOL_SIZE:-}"
if [[ -z "$warm_pool_size" ]]; then
  warm_pool_size=$(( $(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 8) / 2 ))
  [[ "$warm_pool_size" -ge 4 ]] || warm_pool_size=4
fi
max_concurrent_boots="${RULES_IDB_MAX_CONCURRENT_BOOTS:-%(max_concurrent_boots)s}"
if [[ "$max_concurrent_boots" -le 0 ]]; then
  # Auto: half the CPU cores. Parallel boots win on strong hardware
  # (measured), while constrained machines need a lower explicit cap.
  max_concurrent_boots=$(( $(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 8) / 2 ))
  [[ "$max_concurrent_boots" -ge 1 ]] || max_concurrent_boots=1
fi
shutdown_after_test="%(shutdown_after_test)s"
python_bin="${RULES_IDB_PYTHON:-python3}"

# Millisecond wall clock for the phase timing summary printed after the run.
now_ms() {
  /usr/bin/perl -MTime::HiRes=time -e 'printf("%d", time * 1000)' 2>/dev/null \
    || echo $(( $(date +%s) * 1000 ))
}
fmt_ms() {
  printf '%d.%03ds' $(($1 / 1000)) $(($1 % 1000))
}
runner_start_ms=$(now_ms)

# True once SpringBoard has a PID in the simulator's launchd -- the earliest
# point at which app installs/launches reliably succeed. `simctl bootstatus`
# is not enough: it can report a terminal failure status yet exit 0, and
# even a successful boot finishes slightly before SpringBoard is up; running
# tests in that window fails with zero test results (seen at 8-way
# concurrency).
wait_for_springboard() {
  local udid="$1"
  for _ in $(seq 1 40); do
    if xcrun simctl spawn "$udid" launchctl list 2>/dev/null \
        | grep com.apple.SpringBoard | grep -qv '^-'; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# Resolve a runfiles short_path against the test's runfiles tree.
runfile() {
  local p="$1"
  if [[ "$p" == ../* ]]; then
    echo "${TEST_SRCDIR}/${p#../}"
  else
    echo "${TEST_SRCDIR}/${TEST_WORKSPACE}/$p"
  fi
}

# Tool resolution precedence: test-time env override, then the runner rule's
# idb_path attribute, then the py_binary client bundled with rules_idb.
idb_bin="${RULES_IDB_IDB_PATH:-%(idb_path)s}"
random_order="%(random)s"
create_simulator_action_binary="%(create_simulator_action_binary)s"
clean_up_simulator_action_binary="%(clean_up_simulator_action_binary)s"
pre_action_binary="%(pre_action_binary)s"
post_action_binary="%(post_action_binary)s"
post_action_determines_exit_code="%(post_action_determines_exit_code)s"

if [[ -z "$idb_bin" ]]; then
  idb_bin="$(runfile "%(idb_client_path)s")"
fi

if ! command -v "$idb_bin" >/dev/null 2>&1; then
  echo "error: 'idb' client not found at '$idb_bin'." >&2
  exit 1
fi

companion_bin="${RULES_IDB_COMPANION_PATH:-}"
if [[ -z "$companion_bin" ]]; then
  companion_bin="$(runfile "%(companion_path)s")"
fi
if ! command -v "$companion_bin" >/dev/null 2>&1; then
  echo "error: 'idb_companion' not found at '$companion_bin'." >&2
  exit 1
fi
# The prebuilt companion ships arm64-only; fail with a real message instead
# of a "Bad CPU type" from deep inside the run.
if [[ "$(uname -m)" == "x86_64" ]] && ! file "$companion_bin" 2>/dev/null | grep -q x86_64; then
  echo "error: the bundled idb_companion is arm64-only and this is an x86_64 host." >&2
  echo "error: build the companion locally (docs/BUILDING_IDB.md) and set RULES_IDB_COMPANION_PATH." >&2
  exit 1
fi

command_line_args=()
while [[ $# -gt 0 ]]; do
  arg="$1"
  case $arg in
    --command_line_args=*)
      IFS="," read -r -a extra_args <<< "${arg#*=}"
      command_line_args+=("${extra_args[@]}")
      ;;
    *)
      echo "error: Unsupported argument '${arg}' for the idb test runner" >&2
      exit 1
      ;;
  esac
  shift
done

basename_without_extension() {
  local filename
  filename=$(basename "$1")
  echo "${filename%.*}"
}

test_type="%(test_type)s"
is_ui_test=false
if [[ "$test_type" == "XCUITEST" ]]; then
  is_ui_test=true
fi

if [[ "$random_order" == true && "$test_type" != "XCUITEST" && -z "%(test_host_path)s" ]]; then
  echo "error: random test ordering requires a test host" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Stage the test bundle (and test host app, if any) into a writable tmp dir.
# ---------------------------------------------------------------------------
test_tmp_dir="$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/idb_test_runner.XXXXXX")"
companion_pid=""
companion_sock_dir=""
cleanup() {
  if [[ -n "$companion_pid" ]]; then
    kill "$companion_pid" 2>/dev/null || true
    # The companion's gRPC server can ignore SIGTERM; make sure it dies.
    for _ in 1 2 3 4 5; do
      kill -0 "$companion_pid" 2>/dev/null || break
      sleep 0.2
    done
    kill -9 "$companion_pid" 2>/dev/null || true
  fi
  if [[ -n "$companion_sock_dir" ]]; then
    rm -rf "$companion_sock_dir"
  fi
  if [[ -z "${NO_CLEAN:-}" ]]; then
    rm -rf "${test_tmp_dir}"
  fi
}
# EXIT alone does not cover fatal signals: bash skips the EXIT trap when
# killed by an unhandled SIGTERM/SIGINT (Bazel's timeout path sends TERM
# first), which would orphan the companion. Convert them into exits.
trap 'exit 143' TERM
trap 'exit 130' INT
if [[ -z "${NO_CLEAN:-}" ]]; then
  trap cleanup EXIT
else
  test_tmp_dir="${TMPDIR:-/tmp}/idb_test_runner_dir.$$"
  rm -rf "$test_tmp_dir"
  mkdir -p "$test_tmp_dir"
  echo "note: keeping test dir around at: $test_tmp_dir"
  trap cleanup EXIT
fi

stage_start_ms=$(now_ms)
test_bundle_path="%(test_bundle_path)s"
test_bundle_name=$(basename_without_extension "$test_bundle_path")
test_bundle_dir="$test_tmp_dir/$test_bundle_name.xctest"

if [[ "$test_bundle_path" == *.xctest ]]; then
  cp -cRL "$test_bundle_path" "$test_tmp_dir"
  chmod -R u+rwX "$test_bundle_dir"
else
  echo "note: staging test bundle from archive; building with" >&2
  echo "note:   --@rules_apple//apple/build_settings:use_tree_artifacts_outputs" >&2
  echo "note: stages with copy-on-write instead (see rules_idb README, Performance)" >&2
  unzip -qq -d "${test_tmp_dir}" "${test_bundle_path}"
fi

test_host_path="%(test_host_path)s"
test_host_dir=""
if [[ -n "$test_host_path" ]]; then
  test_host_name=$(basename_without_extension "$test_host_path")

  if [[ "$test_host_path" == *.app ]]; then
    cp -cRL "$test_host_path" "$test_tmp_dir"
    test_host_dir="$test_tmp_dir/$test_host_name.app"
    chmod -R u+rwX "$test_host_dir"
  else
    unzip -qq -d "${test_tmp_dir}" "${test_host_path}"
    mv "$test_tmp_dir"/Payload/*.app "$test_tmp_dir"
    test_host_dir=$(find "$test_tmp_dir" -name "*.app" -type d -maxdepth 1 -mindepth 1 -print -quit)
  fi
fi

test_bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$test_bundle_dir/Info.plist")
test_host_bundle_id=""
if [[ -n "$test_host_dir" ]]; then
  test_host_bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$test_host_dir/Info.plist")
fi

# ---------------------------------------------------------------------------
# UI tests: assemble an XCTRunner.app host from Xcode's agent template. For
# UI tests idb launches this runner app (which loads the test bundle), while
# the staged test host is the app under test.
# ---------------------------------------------------------------------------
runner_app_dir=""
if [[ "$is_ui_test" == true ]]; then
  developer_dir=$(xcode-select -p)
  agents_dir="$developer_dir/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents"
  runner_app_name="$test_bundle_name-Runner"
  runner_app_dir="$test_tmp_dir/$runner_app_name.app"
  runner_bundle_id="com.apple.test.$runner_app_name"

  cp -cR "$agents_dir/XCTRunner.app" "$runner_app_dir"
  chmod -R 777 "$runner_app_dir"

  declare -r sed_delim=$'\001'
  runner_app_infoplist="$runner_app_dir/Info.plist"
  /usr/bin/plutil -convert xml1 "$runner_app_infoplist"
  /usr/bin/sed \
    -e "s${sed_delim}\$(WRAPPEDPRODUCTNAME)${sed_delim}XCTRunner${sed_delim}g" \
    -e "s${sed_delim}WRAPPEDPRODUCTNAME${sed_delim}XCTRunner${sed_delim}g" \
    -e "s${sed_delim}\$(WRAPPEDPRODUCTBUNDLEIDENTIFIER)${sed_delim}$runner_bundle_id${sed_delim}g" \
    -e "s${sed_delim}WRAPPEDPRODUCTBUNDLEIDENTIFIER${sed_delim}$runner_bundle_id${sed_delim}g" \
    -i "" \
    "$runner_app_infoplist"
  /usr/bin/plutil -convert binary1 "$runner_app_infoplist"

  # Embed the XCTest frameworks the runner links against. The companion adds
  # the developer framework directories to DYLD_FALLBACK_FRAMEWORK_PATH, but
  # embedding matches Xcode's own layout and keeps the runner self-contained.
  libraries_path="$developer_dir/Platforms/iPhoneSimulator.platform/Developer/Library"
  runner_frameworks="$runner_app_dir/Frameworks"
  mkdir -p "$runner_frameworks"
  cp -cR "$libraries_path/Frameworks/XCTest.framework" "$runner_frameworks/"
  for private_framework in XCTestCore XCTAutomationSupport XCUnit XCTestSupport; do
    if [[ -d "$libraries_path/PrivateFrameworks/$private_framework.framework" ]]; then
      cp -cR "$libraries_path/PrivateFrameworks/$private_framework.framework" "$runner_frameworks/"
    fi
  done
  if [[ -d "$libraries_path/Frameworks/Testing.framework" ]]; then
    cp -cR "$libraries_path/Frameworks/Testing.framework" "$runner_frameworks/"
  fi
  # XCUIAutomation moved out of PrivateFrameworks in Xcode 16.3.
  if [[ -d "$libraries_path/Frameworks/XCUIAutomation.framework" ]]; then
    cp -cR "$libraries_path/Frameworks/XCUIAutomation.framework" "$runner_frameworks/"
  else
    cp -cR "$libraries_path/PrivateFrameworks/XCUIAutomation.framework" "$runner_frameworks/"
  fi
  developer_usr_lib="$developer_dir/Platforms/iPhoneSimulator.platform/Developer/usr/lib"
  cp "$developer_usr_lib/libXCTestSwiftSupport.dylib" "$runner_frameworks/" 2>/dev/null || true
  cp "$developer_usr_lib/libXCTestBundleInject.dylib" "$runner_frameworks/" 2>/dev/null || true
fi

stage_ms=$(( $(now_ms) - stage_start_ms ))

# ---------------------------------------------------------------------------
# Acquire a simulator: either through a custom create_simulator_action (the
# same contract as rules_apple's ios_xctestrun_runner) or the built-in pool.
#
# Pool: each (device_type, os_version) pool is a directory of slot lock
# files. A runner claims a slot by taking a non-blocking exclusive flock()
# on it. The lock lives on the file descriptor held by this shell process,
# so the kernel releases it when this process exits for any reason
# (including SIGKILL) -- no stale lock files, no traps required.
# ---------------------------------------------------------------------------
if [[ "$shutdown_after_test" == true || -n "${RULES_IDB_SHUTDOWN_SIMULATOR:-}" ]]; then
  reuse_simulator=
else
  reuse_simulator=1
fi

simulator_was_created=false
if [[ -n "$create_simulator_action_binary" ]]; then
  simulator_id="$(SIMULATOR_DEVICE_TYPE="$device_type" SIMULATOR_OS_VERSION="$os_version" SIMULATOR_REUSE_SIMULATOR="${reuse_simulator:-}" "$create_simulator_action_binary")"
  echo "note: using simulator $simulator_id from custom create_simulator_action" >&2
else
  # The pool root must be identical for every concurrently running test
  # action. $HOME is NOT suitable: Bazel points HOME at a per-action tmp
  # dir, which would give every action its own private "pool" and hand them
  # all the same simulator. The Darwin per-user temp dir is stable.
  pool_root="${RULES_IDB_POOL_DIR:-$(getconf DARWIN_USER_TEMP_DIR)rules_idb_pool}"
  pool_key=$(printf '%s' "${device_type:-default}_${os_version:-latest}" | tr -c 'A-Za-z0-9._-' '-')
  # A custom pool root gets its own simulator namespace: otherwise two
  # invocations with different roots would hold "slot 0" under different
  # locks yet drive the same simulator. Tools must be run with the same
  # RULES_IDB_POOL_DIR to see these pools.
  if [[ -n "${RULES_IDB_POOL_DIR:-}" ]]; then
    pool_key="$pool_key.r$(printf '%s' "$pool_root" | /usr/bin/cksum | cut -d' ' -f1)"
  fi
  pool_dir="$pool_root/$pool_key"
  mkdir -p "$pool_dir"

  # Locks the given fd (inherited from this shell) without blocking; exits
  # 1 if the lock is held by another test action.
  try_flock() {
    "$python_bin" -c 'import fcntl, sys
try:
    fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)' "$1"
  }

  acquired_slot=""
  slot=0
  while true; do
    exec 200>>"$pool_dir/slot-$slot.lock"
    if try_flock 200; then
      acquired_slot=$slot
      break
    fi
    exec 200>&-
    slot=$((slot + 1))
    if [[ "$pool_size" -gt 0 && "$slot" -ge "$pool_size" ]]; then
      slot=0
      sleep 1
    fi
  done
  echo "note: acquired simulator pool slot $acquired_slot (pool: $pool_key)" >&2

  # Find or create the simulator bound to this pool slot. The lookup runs
  # ungated; creation happens under the boot gate below.
  simulator_name="rules_idb.$pool_key.$acquired_slot"
  simulator_pool_py() {
  "$python_bin" - "$1" "$simulator_name" "$device_type" "$os_version" <<'PYEOF'
import json, subprocess, sys

mode, name, device_type, os_version = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def simctl(*args):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True)

runtimes = [
    r
    for r in json.loads(simctl("list", "runtimes", "-j"))["runtimes"]
    if r["platform"] == "iOS" and r["isAvailable"]
]
if os_version:
    runtimes = [
        r
        for r in runtimes
        if r["version"] == os_version or r["version"].startswith(os_version + ".")
    ]
if not runtimes:
    sys.exit("error: no available iOS runtime matching version %r" % os_version)
runtimes.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
runtime = runtimes[-1]

device_types = json.loads(simctl("list", "devicetypes", "-j"))["devicetypes"]
if not device_type:
    # Pick the newest iPhone the chosen runtime actually supports, using the
    # hardware model identifier (e.g. "iPhone18,1") as the recency key --
    # neither simctl list is ordered chronologically. The iPod touch reports
    # the iPhone product family but is incompatible with modern runtimes.
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
        sys.exit("error: no iPhone device types supported by runtime %s" % runtime["identifier"])
    device_type = max(iphones, key=model_key)["name"]

expected_dt = next(
    (
        d["identifier"]
        for d in device_types
        if d["name"] == device_type or d["identifier"] == device_type
    ),
    None,
)

# Reuse an existing simulator only if its SUBSTANCE matches the resolved
# intent (runtime + device type), not just its name: with default
# device/os, "latest" drifts across Xcode upgrades and a stale simulator
# would otherwise be reused forever. We hold this slot's flock, so stale
# and duplicate-name devices are safe to delete here.
devices = json.loads(simctl("list", "devices", "-j"))["devices"]
matches = [
    (runtime_id, device)
    for runtime_id, runtime_devices in devices.items()
    for device in runtime_devices
    if device["name"] == name
]
good = [
    device
    for runtime_id, device in matches
    if device.get("isAvailable", True)
    and runtime_id == runtime["identifier"]
    and (expected_dt is None or device.get("deviceTypeIdentifier") == expected_dt)
]
for _, device in matches:
    if good and device is good[0]:
        continue
    subprocess.run(["xcrun", "simctl", "shutdown", device["udid"]], capture_output=True)
    subprocess.run(["xcrun", "simctl", "delete", device["udid"]], capture_output=True)
    print(
        "note: removed simulator %s (%s): device/runtime did not match the request"
        % (name, device["udid"]),
        file=sys.stderr,
    )

if good:
    if mode == "find":
        print(good[0]["udid"] + ":" + good[0].get("state", "Shutdown"))
    else:
        print("CREATED:" + good[0]["udid"])
    sys.exit(0)

if mode == "find":
    print("NOTFOUND")
    sys.exit(0)

print("CREATED:" + simctl("create", name, device_type, runtime["identifier"]).strip())
PYEOF
  }

  result=$(simulator_pool_py find)
  simulator_id=""
  simulator_state="Shutdown"
  needs_create=false
  if [[ "$result" == "NOTFOUND" ]]; then
    needs_create=true
  else
    simulator_state="${result##*:}"
    simulator_id="${result%%:*}"
    echo "note: using simulator '$simulator_name' ($simulator_id, $simulator_state)" >&2
  fi

  if [[ "$needs_create" == true || "$simulator_state" != "Booted" ]]; then
    # Gate concurrent simulator creation and boots machine-wide: doing many
    # at once is slower than staggering them. Same auto-releasing flock
    # mechanism as the pool, on fd 201; released once the boot finishes.
    boot_gate_dir="$pool_root/boot-gate"
    mkdir -p "$boot_gate_dir"
    boot_slot=""
    while true; do
      bslot=0
      while [[ "$bslot" -lt "$max_concurrent_boots" ]]; do
        exec 201>>"$boot_gate_dir/slot-$bslot.lock"
        if try_flock 201; then
          boot_slot=$bslot
          break
        fi
        exec 201>&-
        bslot=$((bslot + 1))
      done
      [[ -n "$boot_slot" ]] && break
      echo "note: waiting for a boot slot ($max_concurrent_boots concurrent creates/boots max)" >&2
      sleep 2
    done

    if [[ "$needs_create" == true ]]; then
      simulator_id=$(simulator_pool_py create)
      simulator_was_created=true
      simulator_id="${simulator_id#CREATED:}"
      echo "note: created simulator '$simulator_name' ($simulator_id)" >&2
    fi

    # Boot the simulator and wait until it is usable, with a deadline: a
    # wedged boot would otherwise hold this machine-wide boot-gate slot
    # forever ('bootstatus -b' has no timeout of its own). Non-zero exits
    # are tolerated the same way rules_apple's simulator_creator does (149
    # means "already booted"); the readiness check below is authoritative.
    boot_wait_secs="${RULES_IDB_BOOT_TIMEOUT:-240}"
    xcrun simctl bootstatus "$simulator_id" -b >&2 200>&- 201>&- &
    bootstatus_pid=$!
    for (( i = 0; i < boot_wait_secs * 2; i++ )); do
      kill -0 "$bootstatus_pid" 2>/dev/null || break
      sleep 0.5
    done
    if kill -0 "$bootstatus_pid" 2>/dev/null; then
      echo "note: boot still pending after ${boot_wait_secs}s; abandoning the wait" >&2
      kill -9 "$bootstatus_pid" 2>/dev/null || true
    fi
    wait "$bootstatus_pid" 2>/dev/null \
      || echo "note: ignoring non-zero 'simctl bootstatus' exit code" >&2

    # Release the boot slot; the pool slot lock (fd 200) stays held. The
    # readiness wait below intentionally happens after the release: it is
    # not boot work and must not throttle other actions' boots.
    exec 201>&-

    # Wait until the simulator can actually run apps, re-booting once if it
    # never gets there (bootstatus tolerates failed boots; see helper).
    if ! wait_for_springboard "$simulator_id"; then
      echo "note: simulator not ready after boot; re-booting it once" >&2
      xcrun simctl shutdown "$simulator_id" >&2 || true
      xcrun simctl bootstatus "$simulator_id" -b >&2 || true
      wait_for_springboard "$simulator_id" \
        || echo "note: simulator still not ready; proceeding, idb will surface errors" >&2
    fi
    # Short settle: SpringBoard being up still slightly precedes launch
    # readiness on a loaded machine.
    sleep 2
  fi
fi

simulator_ms=$(( $(now_ms) - stage_start_ms - stage_ms ))

# Run a pre-action binary, if provided. The pool/boot-gate lock fds are
# closed for it (and every other spawned process): a child that outlives
# this shell would otherwise keep the slot lock alive.
SIMULATOR_UDID="$simulator_id" \
  "$pre_action_binary" 200>&- 201>&-

# Run a dedicated idb_companion for this test action, on a private unix
# socket. A shared, long-lived companion is not safe here: it installs local
# .xctest bundles as symlinks into per-bundle-id storage and caches their
# descriptors in memory, so ephemeral Bazel staging dirs and bundle-id reuse
# across targets (rules_apple derives the id from the test host) make it
# resolve stale or wrong bundles. A per-action companion also avoids races
# on the idb client's shared companion registry when Bazel runs tests
# concurrently.
real_home=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')
idb_bundle_root="${real_home:-$HOME}/Library/Developer/CoreSimulator/Devices/$simulator_id/data/fbsimulatorcontrol/idb-test-bundles"
rm -rf "$idb_bundle_root/$test_bundle_id"
# The companion installs bundles as symlinks to staging dirs that die with
# their test action; the dangling leftovers make its bundle enumeration
# (used by test listing / sharding) fail. Sweep them.
for stale_bundle in "$idb_bundle_root"/*/*.xctest; do
  if [[ -L "$stale_bundle" && ! -e "$stale_bundle" ]]; then
    rm -rf "$(dirname "$stale_bundle")"
  fi
done

# The socket must live at a short path: unix domain socket paths are limited
# to ~104 bytes on macOS and Bazel's TEST_TMPDIR is far longer than that.
companion_sock_dir="$(mktemp -d "/tmp/rules_idb.XXXXXX")"
companion_sock="$companion_sock_dir/c.sock"
companion_log="$test_tmp_dir/companion.log"

kill_companion() {
  [[ -n "$companion_pid" ]] || return 0
  kill "$companion_pid" 2>/dev/null || true
  # The companion's gRPC server can ignore SIGTERM; make sure it dies.
  for _ in 1 2 3 4 5; do
    kill -0 "$companion_pid" 2>/dev/null || break
    sleep 0.2
  done
  kill -9 "$companion_pid" 2>/dev/null || true
  companion_pid=""
}

spawn_companion() {
  companion_start_ms=$(now_ms)
  rm -f "$companion_sock"
  "$companion_bin" --udid "$simulator_id" --grpc-domain-sock "$companion_sock" >> "$companion_log" 2>&1 200>&- 201>&- &
  companion_pid=$!

  companion_ready=false
  for _ in $(seq 1 600); do
    if [[ -S "$companion_sock" ]]; then
      companion_ready=true
      break
    fi
    if ! kill -0 "$companion_pid" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done
  if [[ "$companion_ready" != true ]]; then
    echo "error: idb_companion failed to start; log follows" >&2
    cat "$companion_log" >&2
    exit 1
  fi
  companion_ms=$(( $(now_ms) - companion_start_ms ))
}

spawn_companion

# ---------------------------------------------------------------------------
# Forward the Bazel test environment into the hosted test process. The idb
# client passes any IDB_-prefixed environment variable through to the test
# process with the prefix stripped.
# ---------------------------------------------------------------------------
sanitize_and_export() {
  local key="$1" value="$2"
  if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    export "IDB_$key=$value"
  else
    echo "warning: skipping test env var with unsupported name '$key'" >&2
  fi
}

test_env="%(test_env)s"
default_test_env="TEST_SRCDIR=${TEST_SRCDIR:-},TEST_UNDECLARED_OUTPUTS_DIR=${TEST_UNDECLARED_OUTPUTS_DIR:-},TEST_PREMATURE_EXIT_FILE=${TEST_PREMATURE_EXIT_FILE:-}"
if [[ -n "$test_env" ]]; then
  test_env="$test_env,$default_test_env"
else
  test_env="$default_test_env"
fi

env_inherit=%(test_env_inherit)s
for env_var in "${env_inherit[@]:-}"; do
  if [[ -n "$env_var" ]] && declare -p "$env_var" &>/dev/null; then
    test_env="$test_env,$env_var=${!env_var}"
  fi
done

saved_IFS=$IFS
IFS=","
set -f  # values may contain glob characters; splitting must not expand them
for test_env_key_value in ${test_env}; do
  IFS="=" read -r key value <<< "$test_env_key_value"
  [[ -n "$key" ]] && sanitize_and_export "$key" "$value"
done
set +f
IFS=$saved_IFS

# Random test ordering: the (patched) companion reads this key out of the
# launch environment and sets XCTestConfiguration.testExecutionOrdering.
if [[ "$random_order" == true ]]; then
  export IDB_FB_XCTEST_EXECUTION_ORDERING=random
fi

# Sanitizer runtimes and the Main Thread Checker ship inside the test
# bundle's Frameworks directory when enabled; they must be present in
# DYLD_INSERT_LIBRARIES of the host process. The (patched) companion appends
# request-provided DYLD_* variables to its own (which carry the test shim)
# instead of replacing them.
insert_libraries=""
for dylib in "$test_bundle_dir"/Frameworks/libclang_rt.*.dylib "$test_bundle_dir"/Frameworks/libMainThreadChecker.dylib; do
  [[ -e "$dylib" ]] || continue
  if [[ -n "$insert_libraries" ]]; then
    insert_libraries="$insert_libraries:$dylib"
  else
    insert_libraries="$dylib"
  fi
done
if [[ -n "$insert_libraries" ]]; then
  echo "note: inserting libraries into test host: $insert_libraries" >&2
  export IDB_DYLD_INSERT_LIBRARIES="$insert_libraries"
fi

# ---------------------------------------------------------------------------
# Map Bazel's --test_filter / the rule's test_filter attribute onto idb's
# --tests-to-run / --tests-to-skip. Filters are comma separated
# `Class/testMethod` entries; a leading '-' marks a test to skip.
# ---------------------------------------------------------------------------
test_filter="%(test_filter)s"
all_filters=""
if [[ -n "${TESTBRIDGE_TEST_ONLY:-}" && -n "$test_filter" ]]; then
  all_filters="$TESTBRIDGE_TEST_ONLY,$test_filter"
elif [[ -n "${TESTBRIDGE_TEST_ONLY:-}" ]]; then
  all_filters="$TESTBRIDGE_TEST_ONLY"
else
  all_filters="$test_filter"
fi

only_tests=()
skip_tests=()
if [[ -n "$all_filters" ]]; then
  saved_IFS=$IFS
  IFS=","
  set -f
  for filter in $all_filters; do
    if [[ "$filter" == -* ]]; then
      skip_tests+=("${filter:1}")
    else
      only_tests+=("$filter")
    fi
  done
  set +f
  IFS=$saved_IFS
fi

# ---------------------------------------------------------------------------
# Bazel test sharding: list the bundle's tests through the companion and run
# this shard's deterministic slice (interleaved over the sorted list). A
# user --test_filter is applied to the list first so filters and shards
# compose the way Bazel expects.
# ---------------------------------------------------------------------------
if [[ "${TEST_TOTAL_SHARDS:-1}" -gt 1 ]]; then
  if [[ "$is_ui_test" == true ]]; then
    echo "error: shard_count > 1 is not supported for UI tests" >&2
    exit 1
  fi
  # Swift Testing (@Test) functions are invisible to XCTest enumeration and
  # suppressed entirely by --tests-to-run filters (verified empirically):
  # sharding a bundle that links Testing.framework would silently run them
  # in no shard at all. Refuse loudly instead.
  if otool -L "$test_bundle_dir/$test_bundle_name" 2>/dev/null \
      | grep -q "Testing.framework/Testing"; then
    echo "error: shard_count > 1 is not supported for bundles containing" >&2
    echo "error: Swift Testing (@Test) tests: they cannot be enumerated for" >&2
    echo "error: partitioning and every shard would silently skip them." >&2
    exit 1
  fi
  # Tell Bazel this runner implements sharding.
  if [[ -n "${TEST_SHARD_STATUS_FILE:-}" ]]; then
    touch "$TEST_SHARD_STATUS_FILE"
  fi
  "$idb_bin" --companion "$companion_sock" xctest install "$test_bundle_dir" >&2
  "$idb_bin" --companion "$companion_sock" xctest list-bundle "$test_bundle_id" --json \
    > "$test_tmp_dir/all_tests.json"
  printf '%s\n' "${only_tests[@]:-}" > "$test_tmp_dir/user_filters.txt"
  "$python_bin" - "$test_tmp_dir/all_tests.json" "${TEST_TOTAL_SHARDS}" \
    "${TEST_SHARD_INDEX:-0}" "$test_tmp_dir/user_filters.txt" \
    > "$test_tmp_dir/shard_tests.txt" <<'PYEOF'
import json, sys

names = sorted(json.load(open(sys.argv[1])))
total, index = int(sys.argv[2]), int(sys.argv[3])
only = [f for f in open(sys.argv[4]).read().splitlines() if f]

def matches(name):
    if not only:
        return True
    # Listed names are "Module.Class/method"; user filters usually omit
    # the module.
    return name in only or name.split(".", 1)[-1] in only

picked = [n for n in names if matches(n)]
for i, n in enumerate(picked):
    if i % total == index:
        print(n)
PYEOF
  only_tests=()
  # `|| [[ -n ... ]]` keeps a final line that lacks a trailing newline.
  while IFS= read -r shard_test || [[ -n "$shard_test" ]]; do
    [[ -n "$shard_test" ]] && only_tests+=("$shard_test")
  done < "$test_tmp_dir/shard_tests.txt"
  echo "note: shard $(( ${TEST_SHARD_INDEX:-0} + 1 ))/${TEST_TOTAL_SHARDS} runs ${#only_tests[@]} tests" >&2
  if [[ ! -s "$test_tmp_dir/all_tests.json" || "$(cat "$test_tmp_dir/all_tests.json")" == "[]" ]]; then
    # Nothing enumerable at all: every shard would "pass" while running
    # nothing. Fail the way an unsharded empty bundle does.
    echo "error: no tests could be enumerated for sharding, is the test bundle empty?" >&2
    exit 1
  fi
  if [[ ${#only_tests[@]} -eq 0 ]]; then
    # More shards than (filtered) tests: an empty shard passes with 0 tests.
    if [[ -n "${XML_OUTPUT_FILE:-}" ]]; then
      printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n  <testsuite name="%s" tests="0" failures="0"/>\n</testsuites>\n' \
        "$test_bundle_name" > "$XML_OUTPUT_FILE"
    fi
    if [[ -f "${TEST_PREMATURE_EXIT_FILE:-}" ]]; then
      rm -f "$TEST_PREMATURE_EXIT_FILE"
    fi
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Run the tests through idb.
# ---------------------------------------------------------------------------
readonly testlog="$test_tmp_dir/test.log"
test_exit_code=0

# Global options must precede the subcommand, and option flags must precede
# the positional bundle paths: the run subcommands end in a greedy
# `test_arguments` positional (nargs=REMAINDER) that captures every token
# after the positionals verbatim.
idb_cmd=("$idb_bin" "--companion" "$companion_sock")

idb_cmd+=("xctest" "run")
if [[ "$is_ui_test" == true ]]; then
  idb_cmd+=("ui")
elif [[ -n "$test_host_dir" ]]; then
  idb_cmd+=("app")
else
  idb_cmd+=("logic")
fi
idb_cmd+=("--json")

if [[ ${#only_tests[@]} -gt 0 ]]; then
  idb_cmd+=("--tests-to-run" "${only_tests[@]}")
fi
if [[ ${#skip_tests[@]} -gt 0 ]]; then
  idb_cmd+=("--tests-to-skip" "${skip_tests[@]}")
fi

# Let idb time out slightly before Bazel would kill us, for better hang
# diagnostics (idb samples the hung process).
if [[ -n "${TEST_TIMEOUT:-}" && "${TEST_TIMEOUT}" -gt 60 ]]; then
  idb_cmd+=("--timeout" "$((TEST_TIMEOUT - 15))")
fi

if [[ -n "${RULES_IDB_COLLECT_LOGS:-}" && -n "${TEST_UNDECLARED_OUTPUTS_DIR:-}" ]]; then
  mkdir -p "$TEST_UNDECLARED_OUTPUTS_DIR/idb_logs"
  idb_cmd+=("--log-directory-path" "$TEST_UNDECLARED_OUTPUTS_DIR/idb_logs")
fi

# Coverage: have idb pull the raw .profraw files the instrumented processes
# write; they are merged and exported below.
readonly coverage_dir="$test_tmp_dir/coverage"
collect_coverage=false
if [[ "${COVERAGE:-}" -eq 1 && "${APPLE_COVERAGE:-}" -eq 1 ]]; then
  collect_coverage=true
  mkdir -p "$coverage_dir"
  idb_cmd+=("--coverage-output-path" "$coverage_dir" "--coverage-format" "RAW")
fi

# Positionals last: bundle paths (via --install), then any extra arguments
# for the test process, which are intentionally captured by REMAINDER.
idb_cmd+=("--install" "$test_bundle_dir")
if [[ "$is_ui_test" == true ]]; then
  # For UI tests: app under test, then the XCTRunner host app.
  idb_cmd+=("$test_host_dir" "$runner_app_dir")
elif [[ -n "$test_host_dir" ]]; then
  idb_cmd+=("$test_host_dir")
fi

if [[ ${#command_line_args[@]} -gt 0 ]]; then
  idb_cmd+=("${command_line_args[@]}")
fi

# Run idb and interpret its structured (json-lines) output: compute the
# verdict, print a summary, and emit a JUnit XML report for Bazel.
#
# The idb client exits 0 even when test cases fail (it only exits non-zero
# for infrastructure errors or crashes outside of test cases), so the log is
# the source of truth for pass/fail.
run_idb_once() {
  test_exit_code=0
  idb_start_ms=$(now_ms)
  "${idb_cmd[@]}" 2>&1 200>&- | tee -i "$testlog" || test_exit_code=$?
  idb_ms=$(( $(now_ms) - idb_start_ms ))
  idb_exit_code=$test_exit_code

  parse_exit_code=0
  "$python_bin" - "$testlog" "${XML_OUTPUT_FILE:-}" "$test_bundle_name" <<'PYEOF' || parse_exit_code=$?
import json, sys
from xml.sax.saxutils import escape

testlog, xml_output_file, bundle_name = sys.argv[1], sys.argv[2], sys.argv[3]

records = []
with open(testlog, "r", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict) and "className" in record and "methodName" in record:
            records.append(record)

executed = len(records)
failures = [r for r in records if not r.get("passed", False)]

if xml_output_file:
    cases = []
    for r in records:
        name = escape(r.get("methodName", "unknown"), {'"': "&quot;"})
        classname = escape(r.get("className", bundle_name), {'"': "&quot;"})
        duration = float(r.get("duration") or 0.0)
        body = ""
        if not r.get("passed", False):
            info = r.get("failureInfo") or {}
            message = info.get("message", "test failed")
            location = ""
            if info.get("file"):
                location = "%s:%s: " % (info.get("file"), info.get("line", 0))
            kind = "error" if r.get("crashed", False) else "failure"
            body = '\n      <%s message="%s">%s</%s>' % (
                kind, escape(location + message, {'"': "&quot;"}),
                escape("\n".join(r.get("logs") or [])), kind,
            )
        cases.append(
            '    <testcase name="%s" classname="%s" time="%.3f">%s</testcase>'
            % (name, classname, duration, body + ("\n    " if body else ""))
        )
    xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<testsuites>\n'
        '  <testsuite name="%s" tests="%d" failures="%d">\n%s\n  </testsuite>\n'
        '</testsuites>\n'
    ) % (escape(bundle_name), executed, len(failures), "\n".join(cases))
    with open(xml_output_file, "w") as f:
        f.write(xml)

print("")
reported_s = sum(r.get("duration", 0.0) for r in records)
print(
    "note: executed %d tests, %d failed (%.1fs in-simulator)"
    % (executed, len(failures), reported_s),
    file=sys.stderr,
)
for r in failures:
    info = r.get("failureInfo") or {}
    print(
        "  FAILED: %s/%s: %s"
        % (r.get("className"), r.get("methodName"), info.get("message", "(crashed)")),
        file=sys.stderr,
    )

if failures:
    sys.exit(70)
if executed == 0:
    sys.exit(71)
PYEOF
}

run_idb_once

# One retry on the infrastructure-failure signature -- idb itself failed and
# not a single test record came back (a mid-boot or wedged simulator, not a
# test failure). Give the simulator a clean boot and a fresh companion.
# Only for pool simulators; custom-provisioned ones are not ours to re-boot.
if [[ "$idb_exit_code" -ne 0 && "$parse_exit_code" -eq 71 && -n "${acquired_slot:-}" ]]; then
  echo "note: infrastructure failure (idb exited $idb_exit_code with no test results); re-booting the simulator and retrying once" >&2
  kill_companion
  xcrun simctl shutdown "$simulator_id" >&2 || true
  xcrun simctl bootstatus "$simulator_id" -b >&2 || true
  wait_for_springboard "$simulator_id" || true
  sleep 2
  spawn_companion
  run_idb_once
fi

# Phase timing summary. "idb" covers bundle install plus test execution;
# subtract the in-simulator test time reported above to estimate install
# and session-setup overhead.
echo "note: timing stage=$(fmt_ms "$stage_ms") simulator=$(fmt_ms "$simulator_ms") companion=$(fmt_ms "$companion_ms") idb=$(fmt_ms "$idb_ms") total=$(fmt_ms $(( $(now_ms) - runner_start_ms )))" >&2

if [[ "$parse_exit_code" -eq 70 ]]; then
  echo "error: some tests failed" >&2
  test_exit_code=1
elif [[ "$parse_exit_code" -eq 71 && "${ERROR_ON_NO_TESTS_RAN:-1}" == "1" && "$test_exit_code" -eq 0 ]]; then
  echo "error: no tests were executed, is the test bundle empty?" >&2
  test_exit_code=1
elif [[ "$parse_exit_code" -ne 0 && "$parse_exit_code" -ne 71 && "$test_exit_code" -eq 0 ]]; then
  echo "error: failed to parse idb output (exit $parse_exit_code)" >&2
  test_exit_code=1
fi

# Catch crashes that XCTest reports as successes (Swift fatalError, uncaught
# C++ exceptions). Mirrors the rules_apple runner's false-negative check.
if [[ "$test_exit_code" -eq 0 ]] && grep -q \
  -e "^Fatal error:" \
  -e "^.*:[0-9]\{1,\}:\sFatal error:" \
  -e "^libc++abi.dylib: terminating with uncaught exception" \
  "$testlog"; then
  echo "error: log contained test false negative" >&2
  test_exit_code=1
fi

# Infrastructure-failure recovery: idb itself failed and not a single test
# record came back. A wedged simulator that still reports "Booted" produces
# exactly this signature on every subsequent run; shut it down so the next
# action on this slot gets a fresh boot instead of inheriting the wedge.
if [[ "$idb_exit_code" -ne 0 && "$parse_exit_code" -eq 71 && -n "${acquired_slot:-}" ]]; then
  echo "note: infrastructure failure (idb exited $idb_exit_code with no test results);" >&2
  echo "note: shutting simulator $simulator_id down for a clean boot on the next run" >&2
  xcrun simctl shutdown "$simulator_id" >&2 || true
fi

# ---------------------------------------------------------------------------
# Coverage: merge the pulled .profraw files and export an lcov report to
# where Bazel expects it. Ported from rules_apple's xctestrun runner.
# ---------------------------------------------------------------------------
llvm_cov_status=0
llvm_cov_json_export_status=0
if [[ "$collect_coverage" == true ]]; then
  profraw_count=$(find "$coverage_dir" -name "*.profraw" | wc -l | tr -d ' ')
  if [[ "$profraw_count" -eq 0 ]]; then
    echo "error: coverage was requested but no .profraw files were produced" >&2
    test_exit_code=1
  else
    readonly profdata="$test_tmp_dir/coverage.profdata"
    # A file list instead of xargs: batch splitting near ARG_MAX would run
    # multiple merges that silently overwrite each other's output.
    find "$coverage_dir" -name "*.profraw" > "$test_tmp_dir/profraw.list"
    xcrun llvm-profdata merge -f "$test_tmp_dir/profraw.list" --output "$profdata"

    if [[ "${COLLECT_PROFDATA:-0}" == "1" && -n "${TEST_UNDECLARED_OUTPUTS_DIR:-}" ]]; then
      cp "$profdata" "$TEST_UNDECLARED_OUTPUTS_DIR"
    fi

    lcov_args=(
      -instr-profile "$profdata"
      -ignore-filename-regex='.*external/.+'
      -path-equivalence=".,$PWD"
    )
    has_binary=false
    saved_IFS=$IFS
    IFS=";"
    arch=$(uname -m)
    for binary in ${TEST_BINARIES_FOR_LLVM_COV:-}; do
      if [[ "$has_binary" == false ]]; then
        lcov_args+=("${binary}")
        has_binary=true
        if ! file "$binary" | grep -q "$arch"; then
          arch=x86_64
        fi
      else
        lcov_args+=(-object "${binary}")
      fi

      lcov_args+=("-arch=$arch")
    done
    IFS=$saved_IFS

    llvm_coverage_manifest="${COVERAGE_MANIFEST:-}"
    readonly provided_coverage_manifest="%(test_coverage_manifest)s"
    if [[ -s "${provided_coverage_manifest:-}" ]]; then
      llvm_coverage_manifest="$provided_coverage_manifest"
    fi

    readonly error_file="$test_tmp_dir/llvm-cov-error.txt"
    xcrun llvm-cov \
      export \
      -format lcov \
      "${lcov_args[@]}" \
      @"$llvm_coverage_manifest" \
      > "$COVERAGE_OUTPUT_FILE" \
      2> "$error_file" \
      || llvm_cov_status=$?

    # Error ourselves if lcov outputs warnings, such as if we misconfigure
    # something and the file path of one of the covered files doesn't exist.
    if [[ -s "$error_file" || "$llvm_cov_status" -ne 0 ]]; then
      echo "error: while exporting coverage report" >&2
      cat "$error_file" >&2
      [[ "$llvm_cov_status" -ne 0 ]] || llvm_cov_status=1
    fi

    if [[ -n "${COVERAGE_PRODUCE_JSON:-}" ]]; then
      xcrun llvm-cov \
        export \
        -format text \
        "${lcov_args[@]}" \
        @"$llvm_coverage_manifest" \
        > "$TEST_UNDECLARED_OUTPUTS_DIR/coverage.json" \
        2> "$error_file" \
        || llvm_cov_json_export_status=$?
      if [[ -s "$error_file" || "$llvm_cov_json_export_status" -ne 0 ]]; then
        echo "error: while exporting json coverage report" >&2
        cat "$error_file" >&2
        [[ "$llvm_cov_json_export_status" -ne 0 ]] || llvm_cov_json_export_status=1
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Post action, simulator cleanup, and final verdict. The pool slot lock is
# released automatically when this process exits; by default the simulator
# stays booted so the next run is warm.
# ---------------------------------------------------------------------------
post_action_exit_code=0
TEST_EXIT_CODE=$test_exit_code \
  TEST_LOG_FILE="$testlog" \
  SIMULATOR_UDID="$simulator_id" \
  LLVM_COV_EXIT_CODE="$llvm_cov_status" \
  LLVM_COV_JSON_EXPORT_EXIT_CODE="$llvm_cov_json_export_status" \
  "$post_action_binary" 200>&- 201>&- || post_action_exit_code=$?

# The companion dies before any simulator shutdown below so it never
# observes (and logs errors about) its device disappearing under it.
kill_companion

if [[ -n "$clean_up_simulator_action_binary" ]]; then
  SIMULATOR_UDID="$simulator_id" SIMULATOR_REUSE_SIMULATOR="${reuse_simulator:-}" \
    "$clean_up_simulator_action_binary" 200>&- 201>&- || true
elif [[ "$shutdown_after_test" == true || -n "${RULES_IDB_SHUTDOWN_SIMULATOR:-}" ]]; then
  xcrun simctl shutdown "$simulator_id" >&2 || true
elif [[ -n "${acquired_slot:-}" && "$acquired_slot" -ge "$warm_pool_size" ]]; then
  echo "note: slot $acquired_slot >= warm pool size $warm_pool_size; shutting simulator down" >&2
  xcrun simctl shutdown "$simulator_id" >&2 || true
fi

if [[ "$post_action_determines_exit_code" == true ]]; then
  if [[ "$post_action_exit_code" -ne 0 ]]; then
    echo "error: post_action exited with '$post_action_exit_code'" >&2
    exit "$post_action_exit_code"
  fi
elif [[ "$test_exit_code" -ne 0 ]]; then
  echo "error: tests exited with '$test_exit_code'" >&2
  exit "$test_exit_code"
fi

if [[ "$llvm_cov_status" -ne 0 ]]; then
  echo "error: exporting coverage report failed" >&2
  exit "$llvm_cov_status"
fi

if [[ "$llvm_cov_json_export_status" -ne 0 ]]; then
  echo "error: exporting json coverage report failed" >&2
  exit "$llvm_cov_json_export_status"
fi

if [[ -f "${TEST_PREMATURE_EXIT_FILE:-}" ]]; then
  rm -f "$TEST_PREMATURE_EXIT_FILE"
fi
