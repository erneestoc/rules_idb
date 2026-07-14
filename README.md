# rules_idb

An [idb](https://github.com/facebook/idb)-based test runner for
[rules_apple](https://github.com/bazelbuild/rules_apple) iOS tests.

The stock rules_apple runner drives hosted (app-hosted) XCTest bundles with
`xcodebuild test-without-building`. `xcodebuild` is memory hungry and grows
quickly during a run, which limits how many simulators a CI host can drive
concurrently. On top of that, the stock runner reuses a single simulator per
(device, OS) pair, so running tests concurrently with `--local_test_jobs=N`
requires every team to hand-roll a `simulator_creator` that file-locks
simulators and cleans the lock up in shell traps.

`rules_idb` replaces only the *run* phase: bundling, code signing, and
providers all still come from rules_apple. It is a drop-in `runner` for
`ios_unit_test`:

```bzl
# MODULE.bazel
bazel_dep(name = "rules_idb", version = "0.1.0")
```

```bzl
# BUILD.bazel
load("@rules_idb//idb:idb_test_runner.bzl", "ios_idb_test_runner")

ios_idb_test_runner(
    name = "idb_runner",
    device_type = "iPhone 17 Pro",  # optional; defaults to newest iPhone
    os_version = "",                # optional; defaults to newest iOS runtime
)

ios_unit_test(
    name = "HostedTests",
    minimum_os_version = "16.0",
    runner = ":idb_runner",
    test_host = ":HostApp",
    deps = [":HostedTestsLib"],
)
```

Or use the predefined `@rules_idb//idb:default_runner`.

## What you get

* **Much lower harness memory than xcodebuild.** Tests are installed and run
  through `idb`/`idb_companion` (built on FBSimulatorControl) instead of
  `xcodebuild test-without-building`. Each test action runs its own
  `idb_companion` on a private unix socket, so harness memory is bounded,
  isolated, and fully reclaimed when the action ends. See
  [benchmark/RESULTS.md](benchmark/RESULTS.md) for measurements on this
  repository's example suite.
* **`--local_test_jobs=N` out of the box.** Every concurrently running test
  action acquires its own simulator from a per-(device, OS) pool. Slots are
  guarded by kernel `flock()` locks held on a file descriptor owned by the
  test process, so the kernel releases them automatically when the test
  exits — even on `SIGKILL`. No lock files to clean up, no traps, no custom
  `simulator_creator`.
* **Warm simulator reuse.** Pool simulators stay booted between runs (named
  `rules_idb.<pool>.<slot>`), so repeat runs skip simulator boot entirely.
  Set `shutdown_simulator_after_test = True` (or
  `RULES_IDB_SHUTDOWN_SIMULATOR=1`) to trade speed for idle memory.
* **Bazel-native reporting.** The runner parses idb's structured output,
  fails the action on test failures (idb itself exits 0), writes a JUnit
  `XML_OUTPUT_FILE` for Bazel, honors `--test_filter`
  (`Class/testMethod,-Class/testToSkip`), forwards `--test_env` variables
  into the hosted process, and fails when zero tests ran.
* **UI tests.** `ios_ui_test` targets work: the runner assembles an
  XCTRunner host app from Xcode's agent template and drives it through
  `idb xctest run ui`.
* **Coverage.** `bazel coverage` produces standard lcov output (idb pulls
  the raw `.profraw` files; the runner merges and exports them with
  `llvm-cov`, same as the stock runner). Requires
  `coverage --experimental_use_llvm_covmap` in your `.bazelrc`.
* **Random test ordering** via `random = True`
  (XCTestConfiguration.testExecutionOrdering, like `-test-iterations`' era
  xctestrun key; requires a test host).
* **Sanitizers.** `--features=asan` (and friends) work: sanitizer runtimes
  found in the test bundle are appended to the test host's
  `DYLD_INSERT_LIBRARIES` alongside idb's test shim.
* **`pre_action` / `post_action` hooks** with the same environment contract
  as the stock runner (`SIMULATOR_UDID`, `TEST_EXIT_CODE`, `TEST_LOG_FILE`,
  and `post_action_determines_exit_code`).
* **Pluggable simulator provisioning.** Teams with an existing
  `simulator_creator` can plug it in unchanged via
  `create_simulator_action` / `clean_up_simulator_action` (same env
  contract as rules_apple); the built-in pool remains the default.

## Requirements

Both idb halves must currently be built from `facebook/idb` **main** — the
2022-era releases (`brew install facebook/fb/idb-companion`, `pip3 install
fb-idb`) are unusable on modern machines:

* the bottled `idb_companion 1.1.8` misdetects Apple Silicon simulators as
  x86_64 and refuses arm64 test bundles, and
* the PyPI `fb-idb 1.1.7` client crashes a current companion's `install`
  RPC (its streaming pattern trips a `NIOThrowingAsyncSequenceProducer`
  fatal error).

See [docs/BUILDING_IDB.md](docs/BUILDING_IDB.md) for the exact build steps
(including the upstream build fixes this repo carries as patches in
[patches/](patches/)).

The test action must be able to find both binaries. Either put them on the
test action's `PATH`, set the `idb_path` attribute, or pass
`--test_env=RULES_IDB_IDB_PATH=/path/to/idb` and
`--test_env=PATH=/opt/homebrew/bin:/usr/bin:/bin`.

## Runner attributes

| Attribute | Default | Description |
| --- | --- | --- |
| `device_type` | newest iPhone | `xcrun simctl list devicetypes` name |
| `os_version` | newest iOS | `xcrun simctl list runtimes` version |
| `pool_size` | `0` (on demand) | max simulators per (device, OS) pool |
| `random` | `False` | run tests in random order (requires test host) |
| `shutdown_simulator_after_test` | `False` | shut simulator down after each test |
| `idb_path` | `idb` | path to the idb client |
| `pre_action` / `post_action` | none | hook binaries around test execution |
| `post_action_determines_exit_code` | `False` | post_action exit code wins |
| `create_simulator_action` / `clean_up_simulator_action` | built-in pool | custom simulator provisioning binaries |

Runtime environment overrides: `RULES_IDB_IDB_PATH`,
`RULES_IDB_COMPANION_PATH`, `RULES_IDB_POOL_DIR`, `RULES_IDB_POOL_SIZE`,
`RULES_IDB_SHUTDOWN_SIMULATOR`, `RULES_IDB_COLLECT_LOGS`,
`DEBUG_IDB_TEST_RUNNER`.

## How the simulator pool works

```
$(getconf DARWIN_USER_TEMP_DIR)rules_idb_pool/<device>_<os>/slot-N.lock
```

(The Darwin per-user temp dir is used instead of `$HOME` because Bazel gives
every test action a private `$HOME`; the pool must be shared across actions.)

1. A test action opens `slot-0.lock` and tries a non-blocking exclusive
   `flock()`. If the lock is held (another test is using slot 0), it moves
   on to `slot-1`, and so on. With `pool_size > 0` it wraps around and
   retries instead of growing past the cap.
2. The slot maps to a simulator named `rules_idb.<pool>.<slot>`, created on
   first use and booted with `simctl bootstatus -b`.
3. The `flock()` is held by the test runner's shell process for the entire
   run. When the process exits — success, failure, timeout, or `SIGKILL` —
   the kernel drops the lock and the slot (and its warm simulator) is
   immediately reusable.
4. A dedicated `idb_companion` for the acquired simulator is started on a
   private unix socket and torn down when the action finishes. Long-lived
   shared companions are deliberately avoided: they cache installed test
   bundle descriptors by bundle id (stale across Bazel's ephemeral staging
   dirs, and colliding when targets share a bundle id), and concurrent
   client-managed spawns race on idb's shared companion registry.

Because Bazel caps concurrent test actions at `--local_test_jobs`, the pool
never grows beyond that number of simulators.

## Benchmarks

```sh
./benchmark/run_benchmark.sh
```

Runs the identical hosted test suite through both runners, single and with
`--local_test_jobs=4`, sampling host-side harness RSS (xcodebuild /
XCBBuildService vs idb / idb_companion) every 0.5s. See
[benchmark/RESULTS.md](benchmark/RESULTS.md).

## Limitations

* Device (non-simulator) testing is out of scope.
* xcresult bundles are not produced; the runner emits JUnit XML and idb log
  output instead.
* x86_64 test bundles on arm64 hosts (Rosetta) are untested.
