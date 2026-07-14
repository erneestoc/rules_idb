# Session handoff — 2026-07-14

Working notes for the next session. Repo: github.com/erneestoc/rules_idb.
Long-term state also lives in the Claude project memory
(`rules-idb-project.md`); this doc captures the tail end of the
performance-investigation session.

## Uncommitted working-tree state (deliberately NOT pushed)

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
