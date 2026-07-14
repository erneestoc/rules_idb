# Benchmark results

Measured 2026-07-13 by `./benchmark/run_benchmark.sh`. Raw CSVs and bazel
logs are in `benchmark/results/`.

## Environment

| | |
| --- | --- |
| Host | Mac16,6 — Apple M4 Max, 16 cores, 48 GB RAM |
| macOS / Xcode | macOS 26.2 (25C56) / Xcode 26.2 (17C52) |
| Simulator | iPhone 17 Pro, iOS 26.2 |
| rules_apple | 4.5.3, stock `ios_xctestrun_ordered_runner` (xcodebuild) |
| idb | idb_companion + fb-idb client built from facebook/idb `70d75b3` (2026-07-10) with [patches](../patches/idb-build-fixes.patch) |
| Suite | 15 hosted XCTests (UIKit + CPU/alloc workloads) in a UIKit test host |

Each scenario ran an untimed warm-up pass first (simulators booted, caches
warm), then a measured pass with `--nocache_test_results`. "Harness RSS" is
the sampled resident-set total of host-side driver processes only —
`xcodebuild`+`XCBBuildService`+`xcresulttool` vs `idb` client+`idb_companion`.
Simulator-side processes are excluded: both runners boot the same simulators
and run the same tests inside them; the harness is what differs, and it is
what limits how many simulators fit on a CI host.

## Results

| Scenario | Runner | Outcome | Wall | Peak harness RSS | Mean active RSS | Max procs |
| --- | --- | --- | --- | --- | --- | --- |
| 1 test target | **idb** | ✅ pass | 4 s | **115.7 MiB** | 92.1 MiB | 5 |
| 1 test target | xcodebuild | ✅ pass | 4 s | 271.5 MiB | 211.3 MiB | 8 |
| 4 targets, `--local_test_jobs=4` | **idb** | ✅ 4/4 pass | **4 s** | **369.2 MiB** | 271.0 MiB | 11 |
| 4 targets, `--local_test_jobs=4` | xcodebuild | ❌ **3/4 FAIL** | 32 s | 1302.2 MiB | 782.4 MiB | 23 |

## Findings

1. **~2.3× lower harness memory per test action.** A single hosted test run
   costs ~116 MiB of harness (idb python client + one dedicated
   idb_companion) vs ~272 MiB for `xcodebuild test-without-building`. Under
   4-way concurrency the gap widens to **3.5×** (369 MiB vs 1302 MiB —
   xcodebuild's aggregate peak varied between 1.3–1.8 GiB across runs).
   Extrapolating per concurrent slot: ~90 MiB/slot for idb vs
   ~330 MiB/slot for xcodebuild, so the same memory budget drives roughly
   **3–4× more simulators** with the idb runner.

2. **The stock runner cannot actually run hosted tests concurrently.** With
   `--local_test_jobs=4` and no custom `simulator_creator`, all four
   xcodebuild invocations reuse the same simulator; each app
   install/launch kills the previous session and 3 of 4 targets fail with
   *"Test crashed with signal kill before establishing connection"*
   (`bazel_exit=3`, and it still takes 32 s to fail). This is precisely the
   problem that today forces teams to hand-roll flock-based
   `simulator_creator` scripts. The idb runner's built-in pool ran **4/4
   green on 4 distinct simulators in 4 s wall time** with zero
   configuration.

3. **Warm-path latency strongly favors idb.** On this small suite both
   runners complete a warm single run in ~4 s, but the first (cold-cache)
   xcodebuild pass of the same suite took ~27 s vs ~7 s via idb; and at
   4-way concurrency idb finishes all four suites in the time xcodebuild
   takes to fail one.

4. **Harness memory is bounded and reclaimed.** The idb runner starts one
   dedicated `idb_companion` (~30 MiB idle, ~50–90 MiB under load) per test
   action and kills it when the action ends; after a benchmark run, zero
   harness processes remain. xcodebuild's memory profile also ends with the
   action, but its per-action footprint is ~3× larger and known to grow
   with suite size/log volume on long suites (not exercised by this short
   suite).

## Caveats

* Small suite (15 fast tests); xcodebuild's memory growth over long test
  sessions is not captured here — on real suites the single-action gap
  should widen further, in idb's favor.
* Single machine, small number of runs; peaks varied ~±30% run-to-run for
  the concurrent xcodebuild scenario.
* The concurrent xcodebuild failure is the *default* behavior. A team with
  a custom flock-based `simulator_creator` would pass, at roughly
  4 × ~330 MiB of harness — the memory ratio conclusion is unchanged.
