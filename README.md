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
bazel_dep(name = "rules_idb", version = "0.1.3")
git_override(  # until rules_idb is published to the Bazel Central Registry
    module_name = "rules_idb",
    remote = "https://github.com/erneestoc/rules_idb.git",
    tag = "v0.1.3",
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
| `pool_size` | `0` (on demand) | max simulators per (device, OS) pool |
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
simulators that are missing, skips ones already booted, and shuts down any
booted `rules_idb.*` simulator outside the requested set, so you end with
exactly N booted. It never touches simulators it didn't name. Use
`--no-reconcile` to only boot.

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
* x86_64 test bundles on arm64 hosts (Rosetta) are untested.
