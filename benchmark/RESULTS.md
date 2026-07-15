# Benchmark results

Measured 2026-07-14 by `./benchmark/run_benchmark.sh`. Raw CSVs, bazel logs,
and per-pass test logs are in `benchmark/results/` (post-hardening runner)
and `benchmark/results-baseline/` (pre-hardening), both gitignored.

## Environment

| | |
| --- | --- |
| Host | Mac16,6 — Apple M4 Max, 16 cores, 48 GB RAM |
| macOS / Xcode | macOS 26.2 (25C56) / Xcode 26.2 (17C52) |
| Simulator | iPhone 17 Pro, iOS 26.2 |
| rules_apple | 4.5.3, stock `ios_xctestrun_ordered_runner` (xcodebuild) |
| idb | idb_companion + fb-idb client built from facebook/idb `70d75b3` (2026-07-10) with [patches](../patches/idb-build-fixes.patch) |
| Suite | 15 hosted XCTests (UIKit + CPU/alloc workloads) in a UIKit test host |

Each scenario ran an untimed warm-up pass first, then a measured pass with
`--nocache_test_results`. "Harness" numbers cover host-side driver processes
only — `xcodebuild`+`XCBBuildService`+`xcresulttool` vs `idb`
client+`idb_companion`; simulator-side processes are identical for both
runners and excluded. CPU is cumulative harness CPU-seconds for the scenario
(per-PID max cputime, summed). The idb runner prints a per-phase timing line
(`note: timing stage/simulator/companion/idb`); the xcodebuild breakdown is
inferred from XCTest's own suite summary (wall − in-simulator = provisioning
+ install + session setup).

## Wall-clock (installing + running), per scenario

| Scenario | idb | xcodebuild |
| --- | --- | --- |
| 1 target, warm simulator | 4.8s (0.9s install+session, 1.9s tests) | **4.0s** (2.1s overhead, 1.9s tests) |
| 1 target, cold boot (`shutdown all` first) | **10.6s** (3.9s boot) | 12.0s (10.1s overhead) |
| 1 target, 400 MB app, tree artifacts | 4.8s (0.0s staging, 0.9s install) | **4.0s** |
| 1 target, 400 MB app, zip bundles | **5.9s** (1.2s unzip, 0.8s install) | 7.3s (5.4s overhead) |
| 4 targets, `--local_test_jobs=4` | **6s, 4/4 pass** | 32s, **1/4 pass** |
| 8 targets, `--local_test_jobs=8` | **6s, 8/8 pass** | 47s, **1/8 pass** |
| 4 targets × `--runs_per_test=3`, jobs=8 | **11s, 12/12 pass** | 43s, **0/12 pass** |
| 8 targets × 3 consecutive passes (warm cap ≥ jobs) | **9s / 9s / 9s, all pass** | n/a (fails at jobs=8) |
| same, warm cap 4 < jobs 8 (misconfigured) | 52s / 48s / 54s, all pass | n/a |

## Harness memory and CPU

| Scenario | Runner | Peak RSS | Mean active RSS | Max procs | CPU |
| --- | --- | --- | --- | --- | --- |
| 1 target | **idb** | **111 MiB** | 85 MiB | 4 | **0.3 s** |
| 1 target | xcodebuild | 272 MiB | 227 MiB | 8 | 1.2 s |
| 4 targets, jobs=4 | **idb** | **367 MiB** | 235 MiB | 10 | **1.2 s** |
| 4 targets, jobs=4 | xcodebuild | 2944 MiB | 832 MiB | 23 | 11.1 s |
| 8 targets, jobs=8 | **idb** | **711 MiB** | 430 MiB | 18 | **2.5 s** |
| 8 targets, jobs=8 | xcodebuild | 3494 MiB | 1701 MiB | 43 | 35.4 s |
| 12 actions (`--runs_per_test`) | **idb** | **711 MiB** | 355 MiB | 18 | **3.7 s** |
| 12 actions (`--runs_per_test`) | xcodebuild | 7256 MiB | 1902 MiB | 44 | 32.8 s |

## Findings

1. **Concurrency is the headline, and it holds at 8-way.** The stock runner
   still cannot run hosted tests concurrently without a hand-rolled
   `simulator_creator`: 1/4 pass at jobs=4, 1/8 at jobs=8, 0/12 with
   `--runs_per_test` — each failing action burns ~30–47s and gigabytes of
   RSS before dying. The idb pool runs the same matrices green in 6–11s
   total. Per concurrent slot the harness costs ~90 MiB (idb) vs
   ~330–430 MiB (xcodebuild), so the same memory budget drives roughly
   **4× more simulators**; the `--runs_per_test` stress peaked at 7.3 GB of
   xcodebuild harness vs 0.7 GB for idb.

2. **Harness CPU is 4–14× lower.** 0.3 vs 1.2 CPU-s on a single warm target,
   2.5 vs 35.4 CPU-s at 8-way. On CI hosts running many simulators, the
   xcodebuild harness itself becomes a meaningful competitor for the cores
   the tests need.

3. **Warm single-target wall is a wash (xcodebuild ~0.8s faster).** idb's
   per-action fixed costs (pool acquire ~0.3s, dedicated companion spawn
   ~0.3–0.4s, JSON parse) roughly offset xcodebuild's larger session
   overhead on this small suite. idb wins the cold path (10.6s vs 12.0s)
   and everything concurrent.

4. **Installs are effectively free at any app size with tree artifacts.** A
   400 MB test host staged in ~0s (APFS clonefile) and installed in ~0.9s —
   identical to the 4 MB host. On the default zip path the same app costs
   idb 1.2s of unzip vs ~3.3s extra overhead for xcodebuild (5.9s vs 7.3s
   total). `build --@rules_apple//apple/build_settings:use_tree_artifacts_outputs`
   is set in this repo's `.bazelrc` and recommended.

5. **Sustained wide runs need `RULES_IDB_WARM_POOL_SIZE ≥ --local_test_jobs`**
   (now the default: half the CPU cores, floor 4). With the cap below the
   job count, every pass re-boots the trimmed simulators: 52s/pass vs 9s/pass
   at 8-way. The old fixed default of 4 also *flaked* under that churn —
   see finding 6.

6. **Boot-adjacent flakes are root-caused and self-healing.** Under
   parallel boot storms, `simctl bootstatus` can report a failed boot yet
   exit 0, and launch readiness lags "booted"; the session then dies with
   zero test results. The runner now verifies SpringBoard is actually
   running after every boot (re-booting once if not) and retries the idb
   session once on the infrastructure-failure signature. A
   shutdown-all + 8-way boot-storm loop that previously failed ~2 actions
   per round now passes 8/8 repeatedly, with occasional visible
   self-healing retries in the logs.

## Caveats

* Small suite (15 fast tests); xcodebuild's memory growth over long test
  sessions is not captured — on real suites the single-action gap should
  widen further in idb's favor.
* Single machine; concurrent-scenario peaks vary ±30% run-to-run
  (xcodebuild's 4-way peak measured 1.5–2.9 GB across runs).
* The concurrent xcodebuild failures are the *default* behavior. A team
  with a custom flock-based `simulator_creator` would pass, at
  ~330–430 MiB of harness per slot — the memory/CPU conclusions stand.
* In-simulator test time inflates under load for both runners (1.9s solo →
  ~2.8–4.5s at 8-way): the simulators compete for the same cores. That cost
  is identical for both harnesses.
