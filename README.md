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
`ios_unit_test` and `ios_ui_test`, and it is fully self-contained: the idb
client ships vendored (on a hermetic python toolchain) and the prebuilt
`idb_companion` is fetched from this repository's releases. **The only host
requirement is Xcode.**

```bzl
# MODULE.bazel
bazel_dep(name = "rules_idb", version = "0.2.1")
git_override(  # until rules_idb is published to the Bazel Central Registry
    module_name = "rules_idb",
    remote = "https://github.com/erneestoc/rules_idb.git",
    tag = "v0.2.1",
)
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

Or use the predefined `@rules_idb//idb:default_runner`. For coverage, add
`coverage --experimental_use_llvm_covmap` to your `.bazelrc`.

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

Just Xcode. Nothing to `brew install`, no python setup, no PATH plumbing:

* the **idb python client** is vendored in this repository
  (`third_party/idb_client`, pinned facebook/idb commit) and runs on a
  hermetic python 3.12 toolchain via rules_python;
* the **`idb_companion` binary** (plus simulator shims) is prebuilt by this
  repository's [release pipeline](.github/workflows/build-idb-dist.yml)
  from the same pinned commit + [patches/](patches/), and downloaded
  sha256-verified by a module extension. Each release's notes record the
  idb commit, patch, and Xcode version it was built and verified with (see
  [RELEASING.md](RELEASING.md)).

Why not upstream binaries? The 2022-era releases are unusable on modern
machines (the bottled companion misdetects Apple Silicon simulators as
x86_64; the PyPI client crashes a current companion's install RPC), and
Meta's open-source build of `main` needed the fixes carried in
[patches/](patches/). [docs/BUILDING_IDB.md](docs/BUILDING_IDB.md)
documents building the toolchain yourself; point
`RULES_IDB_IDB_PATH`/`RULES_IDB_COMPANION_PATH` at the result to override
the bundled binaries.

## Runner attributes

| Attribute | Default | Description |
| --- | --- | --- |
| `device_type` | newest iPhone | `xcrun simctl list devicetypes` name |
| `os_version` | newest iOS | `xcrun simctl list runtimes` version |
| `pool_size` | `0` (on demand) | max simulators per pool; concurrency already bounded by `--local_test_jobs`. Idle residue bounded by `RULES_IDB_WARM_POOL_SIZE` (default: half the CPU cores, floor 4, stay booted; each ≈ 60-100 processes). Keep it ≥ your `--local_test_jobs`: a lower cap makes sustained wide runs re-boot trimmed simulators every pass (measured: 2-4× slower and flaky) |
| `max_concurrent_boots` | `0` = auto (ncpu/2) | machine-wide cap on simultaneous simulator creates/boots |
| `random` | `False` | run tests in random order (requires test host) |
| `shutdown_simulator_after_test` | `False` | shut simulator down after each test |
| `idb_path` | `idb` | path to the idb client |
| `pre_action` / `post_action` | none | hook binaries around test execution |
| `post_action_determines_exit_code` | `False` | post_action exit code wins |
| `create_simulator_action` / `clean_up_simulator_action` | built-in pool | custom simulator provisioning binaries |

Runtime environment overrides: `RULES_IDB_IDB_PATH`,
`RULES_IDB_COMPANION_PATH`, `RULES_IDB_POOL_DIR`, `RULES_IDB_POOL_SIZE`,
`RULES_IDB_SHUTDOWN_SIMULATOR`, `RULES_IDB_COLLECT_LOGS`,
`RULES_IDB_REPORT_ACTIVITIES`, `RULES_IDB_COLLECT_RESULT_BUNDLE`,
`RULES_IDB_RECORD_VIDEO`, `RULES_IDB_CRASH_WAIT_SECS`,
`RULES_IDB_CRASH_GRACE_SECS`, `RULES_IDB_STARTUP_GRACE_SECS`,
`RULES_IDB_STALL_SECS`, `DEBUG_IDB_TEST_RUNNER`.

### Diagnosing a hung or disconnected test run

When the test process disconnects, idb waits for a crash report matching the
test host's pid before reporting `Lost connection to test process, but could
not find a crash log`. That wait defaults to **120 seconds**
(`crashCheckWaitLimit`, `XCTestBootstrap/TestManager/FBTestBundleConnection.swift`)
and the event stream is silent throughout, so it looks like a hang. It also
cannot succeed at all when crash reports are unreadable from the test action
(a sandbox, or a per-action `$HOME`) or when the host was killed for memory,
since that writes a `JetsamEvent-*.ips` report rather than a pid-matching
crash log.

`RULES_IDB_CRASH_WAIT_SECS` bounds it. The value is exported to the companion
as `FBXCTEST_CRASH_WAIT_TIMEOUT`; XCTestBootstrap runs inside the companion,
so `--test_env` alone does not reach it.

On any non-zero exit the runner writes to
`$TEST_UNDECLARED_OUTPUTS_DIR/idb_diagnostics/`:

| File | Contents |
|---|---|
| `companion.log` | the per-action `idb_companion` stderr |
| `idb_client.log` | raw idb client output, including transport errors |
| `phase_markers.json` | timestamps for stream phases and the last test event |
| `diagnosis.txt` | timings, simulator UDID, pool slot, pids, the idb command, every crash-report path checked and whether it was readable, and any recent `JetsamEvent` reports |

Unlike `RULES_IDB_COLLECT_LOGS` (which asks the idb *client* to write its logs
at the end of a completed run, and so produces nothing when a run is cut
short), these are captured however the run ended, including the
timeout/SIGTERM path.

Each run also reports `timing last_test_event_at=… trailing=…`: the gap
between the final test result and the end of the idb phase. A large trailing
value is the signature of a post-disconnect wait rather than slow tests.

### Three ways a run can appear to hang, and what bounds each

These are distinct mechanisms with distinct fixes. `examples:CrashingTests`
and `examples:LaunchCrashTests` reproduce the first two; measured on an M4 Max
with Xcode 26.2.

| | What happens | Baseline | With defaults | Tuned |
|---|---|---|---|---|
| **Crash mid-run** | a test reports `crashed`; idb never returns a terminal result | timeout | **8.6s** | — |
| **Crash during startup** | the bundle never connects; client stream stays empty | timeout | **35.8s** | — |
| **Silence, cause unknown** | no output, no crash reported anywhere | timeout | timeout | bounded by `RULES_IDB_STALL_SECS` |

**Crash mid-run.** When a test reports `crashed` the host process is gone:
XCTest cannot continue in a dead process and idb does not relaunch it, so that
record is the last result the stream can carry. (Verified: a bundle whose
middle test crashes reports nothing at all for the test after it.) The runner
waits only `RULES_IDB_CRASH_GRACE_SECS` afterwards — 5s by default, 60s when
result bundles, coverage or logs were requested and idb legitimately still has
artifacts to assemble.

**Crash during startup** — a framework that fails to load, or a crash in
`didFinishLaunching`. This one is *not* idb hanging: it is idb serving out two
internal timeouts, `bundleReadyTimeout` (60s) then `crashCheckWaitLimit` (120s),
and the companion logs nothing until both expire. Two independent knobs bound
it:

Both are now bounded by default, so neither needs configuring:

* `RULES_IDB_CRASH_WAIT_SECS` (default 5s, idb's own default is 120s) bounds
  the crash-report wait. This path is only reached once the host has already
  died, so shortening it cannot affect a passing run.
* `RULES_IDB_BUNDLE_READY_SECS` (default 25s, upstream hardcodes 60s) bounds
  how long idb waits for the test bundle to connect. Upstream provides no way
  to change this; the vendored patch adds one, following the precedent
  `FBXCTEST_CRASH_WAIT_TIMEOUT` already sets in the same subsystem. A healthy
  launch reaches its first result in a couple of seconds; raise this if yours
  legitimately takes longer.

Both are exported to the companion, because XCTestBootstrap runs inside it and
`--test_env` alone cannot reach it.
* `RULES_IDB_STARTUP_GRACE_SECS` (default 120s) bounds it without any
  configuration. The clock starts when the companion logs the app launch, and
  only runs while *no test has reported yet* — so it cannot mistake a slow test
  for a stall, because no test has started. idb's own `bundleReadyTimeout` is
  60s, so the default sits well clear of any legitimate startup.

**Silence with no crash reported** is the residual case, covered by
`RULES_IDB_STALL_SECS` (off by default, since a long gap between results can be
a legitimately slow test).

For remote execution, where a hung action can trigger retries rather than
returning the real failure, `RULES_IDB_STALL_SECS` is worth setting as a
backstop for the residual case:

```
--test_env=RULES_IDB_STALL_SECS=45
```

A test-process disconnect that prevents results from being reported is
represented as a failing test case in the JUnit XML, not only as a non-zero
runner exit: tests that never ran are named individually when the expected set
is known (sharding or `--test_filter`), and otherwise a single
`idb_test_process_disconnected` case is emitted.

### Test attachments

By default idb runs XCTest with activities disabled, so a test that calls
`add(XCTAttachment(...))` **hard-fails** with "Attachments cannot be added to
the test because activities are disabled". This keeps the common case light:
recording activities makes the companion buffer attachment payloads, which
forfeits most of idb's memory advantage.

Set `RULES_IDB_REPORT_ACTIVITIES=1` (e.g. via the test's `env` or
`--test_env`) to enable activities so attachment-using suites run instead of
crashing. The attachments appear in idb's JSON activity log; their payloads
are not extracted as files.

`RULES_IDB_COLLECT_RESULT_BUNDLE=1` additionally requests an `.xcresult`
(with attachment payloads) into the test's undeclared outputs. Note: the
`.xcresult` is fundamentally an `xcodebuild`-session artifact, and idb's
native test path does not emit one with the vendored companion — the runner
warns when the requested bundle does not materialize. Use this only if a
companion build that emits result bundles in the native path is in use.

### Screen recording

Set `RULES_IDB_RECORD_VIDEO` (via the test's `env` or `--test_env`) to capture
the simulator screen to `screen.mp4` in the test's undeclared outputs:

* `on-failure` (any value other than `always`) keeps the recording only when
  the test fails — the common case for debugging a flaky UI test.
* `always` keeps it on every run.

Recording runs headless: the companion streams the simulator's IOSurface
framebuffer directly, so no `Simulator.app` window is needed. It is a separate
`idb` invocation on the same companion socket, started around the test and
stopped (and flushed) when the run finishes.

> Requires a companion built from the current `patches/idb-build-fixes.patch`.
> The `RecordMethodHandler` fix that makes recording work is newer than the
> `v0.1.2` released artifact; build one locally (see
> [docs/BUILDING_IDB.md](docs/BUILDING_IDB.md)) and point
> `RULES_IDB_COMPANION_PATH` at it, or use a release that post-dates the fix.

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

### Boot concurrency and pre-booting

Simulator creation and boots (and only those — warm simulators are
unaffected) are gated
machine-wide to **4 concurrent** by default; tune with the
`max_concurrent_boots` attribute or `RULES_IDB_MAX_CONCURRENT_BOOTS`. The
optimum is machine-dependent — on an M4 Max, booting 4 simulators took 13s
at cap 4 vs 31s serialized, so cap boots only as hard as your hardware
requires (low-memory CI agents may want 2).

To start warm — e.g. at CI-agent startup or before a big local run:

```sh
bazel run @rules_idb//tools:preboot -- 4                          # default pool
bazel run @rules_idb//tools:preboot -- 4 --device "iPhone 17 Pro" # named pool
```

`preboot` is a desired-state command: it creates/boots the N pool
simulators that are missing (verifying that an existing simulator's
runtime and device type actually match the request, recreating it if not),
skips ones already booted, and shuts down any booted `rules_idb.*`
simulator outside the requested set, so you end with exactly N booted. It
never touches simulators it didn't name, and it is safe to run next to
live tests: any simulator whose pool slot is claimed by a running test
action is skipped, never yanked. Use `--no-reconcile` to only boot.

### Simulator lifecycle and cleanup

Pool simulators are created on demand (one per concurrency slot actually
used, per device/OS pool) and then **reused indefinitely** — repeat runs
never create more. They are intentionally left **booted** so warm runs skip
the ~30s boot; that idle RAM is the trade. Your options:

* `tools/clean_simulators.sh` — shut all `rules_idb.*` simulators down
  (keeps them for warm reuse); `--delete` removes them entirely.
* `shutdown_simulator_after_test = True` on the runner (or
  `RULES_IDB_SHUTDOWN_SIMULATOR=1` at test time) — every run shuts its
  simulator down afterwards; right choice for RAM-constrained laptops,
  costs a boot per cold run.
* `pool_size = N` — hard-cap how many simulators a pool may create.

## Benchmarks

```sh
./benchmark/run_benchmark.sh
```

Runs the identical hosted test suite through both runners, single and with
`--local_test_jobs=4`, sampling host-side harness RSS (xcodebuild /
XCBBuildService vs idb / idb_companion) every 0.5s. See
[benchmark/RESULTS.md](benchmark/RESULTS.md).

## Performance

Add to your `.bazelrc`:

```
build --@rules_apple//apple/build_settings:use_tree_artifacts_outputs
```

This makes rules_apple output bundles as directories instead of archives,
so the runner stages them with APFS clonefile (copy-on-write) instead of
unzipping — measured ~1.2s faster per test action with 800 MB of bundles
on NVMe, and the gap grows with compressible many-file bundles and slower
CI disks. The runner prints a hint when it detects archive staging. Also
see the boot-concurrency and `preboot` sections above; simulator installs
are already copy-on-write, so bundle size otherwise barely affects the
run phase.

## Limitations

* Device (non-simulator) testing is out of scope.
* xcresult bundles are not produced; the runner emits JUnit XML and idb log
  output instead.
* x86_64 test bundles on arm64 hosts (Rosetta) are untested, and the
  bundled companion is arm64-only (the runner fails fast with instructions
  on x86_64 hosts).
* `XCTSkip`-ped tests do not fail the run, but are reported as passed
  rather than skipped (the idb protocol has no skipped status yet).
* `shard_count` is supported for hosted and logic XCTest bundles (the
  runner lists the bundle's tests through the companion and runs each
  shard's deterministic slice; `--test_filter` composes). UI tests cannot
  be sharded, and bundles containing Swift Testing (`@Test`) tests are
  rejected with an error: those tests cannot be enumerated for
  partitioning, so every shard would silently skip them. The same applies
  to `--test_filter` on a bundle that mixes XCTest and Swift Testing:
  filters only match the XCTest tests.

Swift Testing (`@Test`) is supported: swift-testing tests execute, report
per-test results, and their failures fail the target (validated
continuously by `tests/validate.sh`).
