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
shutdown_after_test="%(shutdown_after_test)s"
python_bin="${RULES_IDB_PYTHON:-python3}"

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
# idb_path attribute, then the client/companion bundled with rules_idb.
idb_bin="${RULES_IDB_IDB_PATH:-%(idb_path)s}"
if [[ -z "$idb_bin" ]]; then
  idb_bin="$(runfile "%(idb_client_path)s")"
fi
random_order="%(random)s"
create_simulator_action_binary="%(create_simulator_action_binary)s"
clean_up_simulator_action_binary="%(clean_up_simulator_action_binary)s"
pre_action_binary="%(pre_action_binary)s"
post_action_binary="%(post_action_binary)s"
post_action_determines_exit_code="%(post_action_determines_exit_code)s"

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

command_line_args=()
while [[ $# -gt 0 ]]; do
  arg="$1"
  case $arg in
    --command_line_args=*)
      IFS="," read -r -a extra_args <<< "${arg##*=}"
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
  fi
  if [[ -n "$companion_sock_dir" ]]; then
    rm -rf "$companion_sock_dir"
  fi
  if [[ -z "${NO_CLEAN:-}" ]]; then
    rm -rf "${test_tmp_dir}"
  fi
}
if [[ -z "${NO_CLEAN:-}" ]]; then
  trap cleanup EXIT
else
  test_tmp_dir="${TMPDIR:-/tmp}/idb_test_runner_dir"
  rm -rf "$test_tmp_dir"
  mkdir -p "$test_tmp_dir"
  echo "note: keeping test dir around at: $test_tmp_dir"
  trap cleanup EXIT
fi

test_bundle_path="%(test_bundle_path)s"
test_bundle_name=$(basename_without_extension "$test_bundle_path")
test_bundle_dir="$test_tmp_dir/$test_bundle_name.xctest"

if [[ "$test_bundle_path" == *.xctest ]]; then
  cp -cRL "$test_bundle_path" "$test_tmp_dir"
  chmod -R 777 "$test_bundle_dir"
else
  unzip -qq -d "${test_tmp_dir}" "${test_bundle_path}"
fi

test_host_path="%(test_host_path)s"
test_host_dir=""
if [[ -n "$test_host_path" ]]; then
  test_host_name=$(basename_without_extension "$test_host_path")

  if [[ "$test_host_path" == *.app ]]; then
    cp -cRL "$test_host_path" "$test_tmp_dir"
    chmod -R 777 "$test_tmp_dir/$test_host_name.app"
    test_host_dir="$test_tmp_dir/$test_host_name.app"
  else
    unzip -qq -d "${test_tmp_dir}" "${test_host_path}"
    mv "$test_tmp_dir"/Payload/*.app "$test_tmp_dir"
    test_host_dir=$(find "$test_tmp_dir" -name "*.app" -type d -maxdepth 1 -mindepth 1 -print -quit)
    chmod -R 777 "$test_host_dir"
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

  cp -R "$agents_dir/XCTRunner.app" "$runner_app_dir"
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
  cp -R "$libraries_path/Frameworks/XCTest.framework" "$runner_frameworks/"
  for private_framework in XCTestCore XCTAutomationSupport XCUnit XCTestSupport; do
    if [[ -d "$libraries_path/PrivateFrameworks/$private_framework.framework" ]]; then
      cp -R "$libraries_path/PrivateFrameworks/$private_framework.framework" "$runner_frameworks/"
    fi
  done
  if [[ -d "$libraries_path/Frameworks/Testing.framework" ]]; then
    cp -R "$libraries_path/Frameworks/Testing.framework" "$runner_frameworks/"
  fi
  # XCUIAutomation moved out of PrivateFrameworks in Xcode 16.3.
  if [[ -d "$libraries_path/Frameworks/XCUIAutomation.framework" ]]; then
    cp -R "$libraries_path/Frameworks/XCUIAutomation.framework" "$runner_frameworks/"
  else
    cp -R "$libraries_path/PrivateFrameworks/XCUIAutomation.framework" "$runner_frameworks/"
  fi
  developer_usr_lib="$developer_dir/Platforms/iPhoneSimulator.platform/Developer/usr/lib"
  cp "$developer_usr_lib/libXCTestSwiftSupport.dylib" "$runner_frameworks/" 2>/dev/null || true
  cp "$developer_usr_lib/libXCTestBundleInject.dylib" "$runner_frameworks/" 2>/dev/null || true
fi

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
  pool_dir="$pool_root/$pool_key"
  mkdir -p "$pool_dir"

  # Locks fd 200 (inherited from this shell) without blocking; exits 1 if
  # the lock is held by another test action.
  try_flock_200() {
    "$python_bin" -c 'import fcntl, sys
try:
    fcntl.flock(200, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)'
  }

  acquired_slot=""
  slot=0
  while true; do
    exec 200>>"$pool_dir/slot-$slot.lock"
    if try_flock_200; then
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

  # Find or create the simulator bound to this pool slot.
  simulator_name="rules_idb.$pool_key.$acquired_slot"
  simulator_id=$("$python_bin" - "$simulator_name" "$device_type" "$os_version" <<'PYEOF'
import json, subprocess, sys

name, device_type, os_version = sys.argv[1], sys.argv[2], sys.argv[3]

def simctl(*args):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True)

devices = json.loads(simctl("list", "devices", "-j"))["devices"]
for runtime_devices in devices.values():
    for device in runtime_devices:
        if device["name"] == name and device.get("isAvailable", True):
            print(device["udid"])
            sys.exit(0)

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

if not device_type:
    # Pick the newest iPhone the chosen runtime actually supports, using the
    # hardware model identifier (e.g. "iPhone18,1") as the recency key --
    # neither simctl list is ordered chronologically. The iPod touch reports
    # the iPhone product family but is incompatible with modern runtimes.
    supported = {d["identifier"] for d in runtime.get("supportedDeviceTypes", [])}
    device_types = json.loads(simctl("list", "devicetypes", "-j"))["devicetypes"]

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

print("CREATED:" + simctl("create", name, device_type, runtime["identifier"]).strip())
PYEOF
)
  if [[ "$simulator_id" == CREATED:* ]]; then
    simulator_was_created=true
    simulator_id="${simulator_id#CREATED:}"
  fi
  echo "note: using simulator '$simulator_name' ($simulator_id)" >&2

  # Boot the simulator (no-op if already booted) and wait until it is usable.
  if ! xcrun simctl bootstatus "$simulator_id" -b >&2; then
    # Exit code 149 means "already booted"; other states are tolerated the
    # same way rules_apple's simulator_creator does -- idb will surface real
    # errors.
    echo "note: ignoring non-zero 'simctl bootstatus' exit code" >&2
  fi

  # A simulator's very first boot finishes data migration slightly before
  # SpringBoard can actually launch apps; give a freshly created device a
  # few seconds to settle to avoid a first-run launch race.
  if [[ "$simulator_was_created" == true ]]; then
    echo "note: freshly created simulator; waiting for SpringBoard to settle" >&2
    sleep 10
  fi
fi

# Run a pre-action binary, if provided.
SIMULATOR_UDID="$simulator_id" \
  "$pre_action_binary"

# Run a dedicated idb_companion for this test action, on a private unix
# socket. A shared, long-lived companion is not safe here: it installs local
# .xctest bundles as symlinks into per-bundle-id storage and caches their
# descriptors in memory, so ephemeral Bazel staging dirs and bundle-id reuse
# across targets (rules_apple derives the id from the test host) make it
# resolve stale or wrong bundles. A per-action companion also avoids races
# on the idb client's shared companion registry when Bazel runs tests
# concurrently.
real_home=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
idb_bundle_storage="${real_home:-$HOME}/Library/Developer/CoreSimulator/Devices/$simulator_id/data/fbsimulatorcontrol/idb-test-bundles/$test_bundle_id"
rm -rf "$idb_bundle_storage"

# The socket must live at a short path: unix domain socket paths are limited
# to ~104 bytes on macOS and Bazel's TEST_TMPDIR is far longer than that.
companion_sock_dir="$(mktemp -d "/tmp/rules_idb.XXXXXX")"
companion_sock="$companion_sock_dir/c.sock"
companion_log="$test_tmp_dir/companion.log"
"$companion_bin" --udid "$simulator_id" --grpc-domain-sock "$companion_sock" > "$companion_log" 2>&1 &
companion_pid=$!

companion_ready=false
for _ in $(seq 1 150); do
  if [[ -S "$companion_sock" ]]; then
    companion_ready=true
    break
  fi
  if ! kill -0 "$companion_pid" 2>/dev/null; then
    break
  fi
  sleep 0.2
done
if [[ "$companion_ready" != true ]]; then
  echo "error: idb_companion failed to start; log follows" >&2
  cat "$companion_log" >&2
  exit 1
fi

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
for test_env_key_value in ${test_env}; do
  IFS="=" read -r key value <<< "$test_env_key_value"
  [[ -n "$key" ]] && sanitize_and_export "$key" "$value"
done
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
  for filter in $all_filters; do
    if [[ "$filter" == -* ]]; then
      skip_tests+=("${filter:1}")
    else
      only_tests+=("$filter")
    fi
  done
  IFS=$saved_IFS
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

"${idb_cmd[@]}" 2>&1 | tee -i "$testlog" || test_exit_code=$?

# ---------------------------------------------------------------------------
# Interpret the structured (json-lines) idb output: compute the verdict,
# print a summary, and emit a JUnit XML report for Bazel.
#
# The idb client exits 0 even when test cases fail (it only exits non-zero
# for infrastructure errors or crashes outside of test cases), so the log is
# the source of truth for pass/fail.
# ---------------------------------------------------------------------------
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
        name = escape(r.get("methodName", "unknown"))
        classname = escape(r.get("className", bundle_name))
        duration = r.get("duration", 0.0)
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
print("note: executed %d tests, %d failed" % (executed, len(failures)), file=sys.stderr)
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
    find "$coverage_dir" -name "*.profraw" -print0 \
      | xargs -0 xcrun llvm-profdata merge --output "$profdata"

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
  "$post_action_binary" || post_action_exit_code=$?

if [[ -n "$clean_up_simulator_action_binary" ]]; then
  SIMULATOR_UDID="$simulator_id" SIMULATOR_REUSE_SIMULATOR="${reuse_simulator:-}" \
    "$clean_up_simulator_action_binary" || true
elif [[ "$shutdown_after_test" == true || -n "${RULES_IDB_SHUTDOWN_SIMULATOR:-}" ]]; then
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
