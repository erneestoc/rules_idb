# Session handoff — 2026-07-14

Working notes for the next session. Repo: github.com/erneestoc/rules_idb.
Long-term state also lives in the Claude project memory
(`rules-idb-project.md`); this doc captures the tail end of the
performance-investigation session.

## Update (later same session): SHIPPED
The chmod slimming, tree-artifact default (.bazelrc + README Performance
section + runner hint on archive staging), and tests/validate.sh (11
behavioral checks: failure detection, JUnit counts, filter exactness,
no-tests guard, post_action gating) were committed and pushed; validate.sh
runs on the 26.2 CI leg. CI result pending at handoff time — check
gh run list. The section below is retained for history.

## Uncommitted working-tree state (historical; since shipped)

`idb/idb_test_runner.template.sh`: staging chmod slimmed —
`chmod -R u+rwX` on the `cp -cRL` (tree-artifact) paths, **no chmod** after
the unzip paths (extracted files are already writable; matches the stock
runner). Verified 3/3 tree-mode + 1/1 zip-mode green. Benchmarked at 500 MB
app: **no measurable saving** (6.6/5.3s vs 6.2/5.9s old — noise). Keep it
for stock-parity/cleanliness, but do not advertise as a speedup. Commit or
discard next session.

`MODULE.bazel.lock`: incidental churn from experiments; safe to checkout.

## Performance findings (all measured on M4 Max/48GB, NVMe)

| Question | Result |
| --- | --- |
| Skip host-app reinstall when unchanged? | **Not worth it.** APFS clonefile makes local sim installs size-independent; skipping saves only LaunchServices registration ≈ 0.25s fixed (verified at 300 MB). Mechanism validated anyway: `idb xctest install <bundle>` + `xctest run app <ids>` without `--install` runs identically; `simctl get_app_container` works as presence probe. |
| Tree artifacts vs zipped staging | `--define=apple.experimental.tree_artifact_outputs=1` verified working end-to-end with the runner. At 500 MB app + 300 MB bundle (incompressible, 2 files): zip 7.4/6.7s vs tree 6.3/5.4s → **~1.2s/action (~18%)**. Lower bound: real bundles (compressible, many files) and slower CI disks decompress slower. **TODO: document in README as the recommended option** — user asked for it as an option; it is consumer-side (.bazelrc), nothing to change in the rules. |
| chmod -R over staged trees | Noise at 2-file/800 MB scale (see above). Might matter at 100k files — unproven. |
| Boot concurrency | Parallelism wins at every tested level on strong hardware (8 create+boots: 87s uncapped vs 115s cap-4; re-boots ×4: 14s cap-4 vs 31s serial). Default is auto = ncpu/2 (`/usr/sbin/sysctl`, absolute path required — not on bazel test PATH). |
| Per-action fixed overhead (warm) | companion spawn→socket ~0.3s, client start+RPC ~0.1–0.2s, remainder = install registration + app launch + test time. Small app warm action ≈ 2.5s. |
| **Unexplained residue** | Even in tree mode, warm action grew ~2.5s (4 MB) → ~5.4s (800 MB). Something size-dependent remains (candidates: codesign verification during install, dyld/launch, clonefile of many extents, chmod). **Profile this before believing any further size-independence claims.** |

## User's workload context (drives priorities)

~600 MB app, 200–500 MB xctest bundles, **thousands of test targets**.
Asked: does dynamic linking help? Answer given: with CoW staging the run
phase barely cares; dynamic linking pays on the build side (dedup of
TB-scale outputs/cache traffic) at the cost of dyld launch time × thousands
of actions — needs measurement on their app.

## Future work, prioritized

1. **README**: add "Performance" section — tree-artifact flag (+ measured
   numbers), and the boot/preboot guidance. (User-requested option.)
2. **Bazel test sharding** (`shard_count` / `TEST_SHARD_INDEX`): enumerate
   tests, slice into `--tests-to-run`. Biggest lever at thousands of
   targets, amortizes fixed overhead.
3. **Profile the size-dependent residue** (see table) — next real
   optimization target.
4. **Pool self-healing**: boot failure → delete+recreate simulator once.
5. **Staging cache** (hash-keyed persistent unzip dir) — only relevant for
   consumers who can't adopt tree artifacts.
6. **Upstream the idb patches** (six real bugs; see
   docs/BUILDING_IDB.md) + weekly canary CI vs facebook/idb main.
7. shellcheck + buildifier CI (two real bugs this session were
   shellcheck-catchable: zsh no-word-split `$VAR` command, literal-IFS
   for-loop), `tools:doctor`, BCR publication, companion log tail on any
   failure, UI-test failure screenshots.

## Operational gotchas (hard-won, do not rediscover)

- Release procedure: `gh release create` WITHOUT asset → `gh release
  upload` (retries) → `edit --draft=false` → only then land the
  extensions.bzl bump. Attaching assets during create times out and leaves
  hidden drafts.
- CI companion build: `./build.sh build idb_companion` must run twice on a
  clean tree (IDBGRPCSwift module quirk); Repl shims don't build on newer
  toolchains (skipped in CI).
- Hosted CI runners: preboot 1 sim + `--local_test_jobs=1` or parallel cold
  boots starve into bazel timeouts. Xcode 27 beta leg is commented out in
  ci.yml pending actions/runner-images#14196.
- Everything through v0.1.2 + CI matrix (26.2/26.4.1/26.5) is green and
  pushed; the only unpushed delta is the chmod slimming above.

## Adversarial review + stress benchmark session (2026-07-14, later)

Two review agents swept the runner/tools/bzl/workflows; every claim was
verified against the code before acting. Fixed in this session:

* **fd leak**: pool slot lock (fd 200) leaked into the companion and hooks;
  a SIGKILLed runner left the slot locked for the companion's lifetime.
  All spawns now get `200>&- 201>&-`. Verified with lsof during a live run.
* **Signal traps**: cleanup only ran on EXIT; TERM/INT now `exit` so the
  trap fires (Bazel timeouts send TERM first).
* **Runner substance verification** (parity with preboot): pool find now
  verifies runtime+deviceType under the slot flock, deleting stale or
  duplicate-name simulators. Verified by planting an iPhone 17 sim under an
  iPhone 17 Pro pool name.
* **preboot/clean_simulators rewritten**: every shutdown/delete now happens
  under the runner's own per-slot flock (busy slots are skipped with a
  note) — previously they could yank simulators from under live tests.
  Preboot also: resolves runtime/device once (was 3-4 simctl list calls per
  slot), dedupes duplicate-name sims, boots via ThreadPool with per-boot
  timeout+state recheck (a wedged boot no longer hangs it; "already booted
  by a racing test" no longer aborts it), `--max-concurrent-boots 0` = auto.
* **Warm-pool default** 4 → max(4, ncpu/2): sustained3x8 benchmark showed
  cap-4 spends 15-60s/action re-booting trimmed sims and flakes (71/41/83s
  passes vs 20/24/17s with cap 8).
* **Infra-failure recovery**: idb exit != 0 with zero parsed test records now
  shuts the simulator down so the next run boots clean (wedged-"Booted" sims
  previously poisoned their slot forever).
* **Perf**: boot gate released before the settle wait; fixed 10s settle
  sleep → SpringBoard poll + 2s grace; companion socket poll 0.2s → 0.05s;
  UI-test XCTRunner/framework copies use clonefile (`cp -c`).
* **Hardening**: `--command_line_args` split at first `=` (was last);
  `real_home` breaks on spaces fixed; llvm-cov warnings now fail as the
  comment promised; profraw merge via `-f` list (xargs batch overwrite);
  JUnit XML quote/null-duration hardening; `set -f` around IFS splits;
  `NO_CLEAN` dir gets `$$` suffix.
* **Supply chain**: publish-to-bcr pinned to commit SHA; remote companion
  URL override without sha256 now fails; bazel_compatibility >=7.1.0
  (module_ctx.getenv); CI companion cache key includes Xcode version;
  build-idb-dist.yml reconverged with ci.yml (was building Repl shims on
  macos-15 — would have failed or shipped divergent contents).
* **Benchmark harness**: CPU sampling (per-pid max cputime per family),
  per-phase wall breakdown (runner now always prints `note: timing
  stage/simulator/companion/idb`), scenarios for cold boot, 400MB installs
  (tree + zip), 8-way, --runs_per_test, sustained thrash; per-pass test.log
  archival (failures were getting overwritten before they could be read).

Known, deliberately deferred:

* XCTSkip: vendored client proto has no SKIPPED status; skipped tests are
  likely miscounted. Needs companion-side investigation.
* Test sharding (shard_count) unsupported — parity with the stock runner,
  but a `TEST_SHARD_STATUS_FILE` implementation would beat it.
* Overlapping staging with simulator acquisition (est. 0.5-1.5s/action for
  zip consumers); tree artifacts already mostly obviate it.
* Pool root hash in simulator names (divergent RULES_IDB_POOL_DIR roots can
  drive one sim from two actions) — edge case, name parity with preboot
  must move in lockstep.
* Hermetic python runfiles are only the interpreter binary — likely breaks
  under RBE with mac workers (stdlib not a declared input). Wait for John's
  EngFlow verdict before restructuring.
* The 8-way "0 tests executed" flake: ROOT CAUSE FOUND — `simctl
  bootstatus -b` can report terminal status -1 yet exit 0, and even good
  boots precede launch readiness; the companion then hits "failed to
  terminate com.apple.Spotlight" during launch and idb exits 1 with zero
  records. FIXED with three layers: (1) wait_for_springboard() (launchctl
  list PID probe — note: SpringBoard is NOT in `launchctl print system`)
  after every boot, with one re-boot; (2) 2s post-boot settle; (3) one
  in-action retry (clean re-boot + fresh companion via
  kill_companion/spawn_companion/run_idb_once) on the infra signature.
  Boot-storm test (shutdown all + 8-way, 3 rounds): was ~2 failures/round,
  now 0 with occasional self-healing retries. Residual: an extreme
  parallel-cold-boot round can still beat the single retry — CI can add
  --flaky_test_attempts; the real fix is an upstream companion patch
  treating "found nothing to terminate" (NSPOSIXErrorDomain code 3) as
  benign during launch.

## Follow-up session (2026-07-14, later still): apples-to-apples + parity

* **Apples-to-apples benchmark**: built the hand-rolled pooled
  simulator_creator for the stock runner (examples/hooks/flock_simulator_*,
  PID lockfiles + stale stealing, XCTESTRUN_RUNNER_PID liveness). Stock
  runner then passes all concurrency scenarios; idb keeps 1.6-2.6x memory,
  4-7x CPU, and 3x wall at 8-way (13-15s xcodebuild session overhead per
  action under load). Scenarios are permanent in run_benchmark.sh
  (*_xcb_pooled); RESULTS.md has the fair tables.
* **Test sharding implemented** (shard_count, hosted+logic): touch
  TEST_SHARD_STATUS_FILE, `xctest install` + `xctest list-bundle --json`
  through the per-action companion, deterministic interleaved slice,
  --test_filter composes, empty shards pass with 0-test XML. UI tests
  error. Gotcha found while testing: `while read` drops a final
  unterminated line — every shard silently lost its last test until the
  loop got `|| [[ -n "$line" ]]`. validate.sh asserts 15/15 exactly-once.
* **Swift Testing verified**: @Test suites execute under idb (hosted),
  per-test records, failures fail the target with the #expect message.
  Stock runner also runs them (its own ◇/✔ reporter; XCTest counter says 0).
  validate.sh covers pass+fail cases.
* **XCTSkip verified**: skip does not fail the run; reported as passed
  (protocol has no SKIPPED status) — documented in README.
* Remaining review items closed: RBE stdlib runfiles (//idb:client_python_files
  select over the darwin repos' :files), attr injection validation +
  negative-int checks in the rule, arm64-only fail-fast, bootstatus
  watchdog under the boot gate, companion killed before warm-residue
  shutdown, dangling idb-test-bundles sweep (dangling symlinks broke the
  companion's bundle enumeration), pool-root cksum namespacing when
  RULES_IDB_POOL_DIR is set (mirrored in preboot), CI leg exercising the
  released companion artifact (continue-on-error), new coverage targets in
  the CI matrix.
