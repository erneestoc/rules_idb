# Releasing rules_idb

Every release pins three things, and the release notes must record all of
them:

1. **The facebook/idb commit** the companion artifact and the vendored
   python client were built from.
2. **The patch** (`patches/idb-build-fixes.patch`) applied on top of it.
3. **The Xcode/macOS version** the artifact was built with and the versions
   it was verified against.

## Cutting a release (BCR-enabled flow)

Pushing a `v*` tag now runs the Release workflow: it creates a DRAFT
release with a deterministic source archive (`rules_idb-<version>.tar.gz`,
what BCR pins). You then attach the companion artifact, write the notes
(template below), and **publish** the release — publishing triggers the
publish-to-BCR workflow, which opens the version PR against
bazel-central-registry from the erneestoc fork.

One-time setup still required: add a classic PAT with repo+workflow scope
as the `BCR_PUBLISH_TOKEN` repository secret (the fork
erneestoc/bazel-central-registry already exists). The first BCR submission
adds the module directory itself; expect BCR maintainer review.

## Cutting a release (manual details)

1. If bumping the idb pin (or Xcode broke something):
   - Update the local checkout, re-apply/extend the patch, and rebuild per
     [docs/BUILDING_IDB.md](docs/BUILDING_IDB.md).
   - Re-vendor the python client if `idb/` or `proto/idb.proto` changed:
     copy `idb/` into `third_party/idb_client/`, regenerate
     `idb_pb2.py`/`idb_grpc.py`, keep the `python/migrations` shim.
   - Run the full example suite and the benchmark.
2. Tag and create the GitHub release **with the companion artifact
   attached** before landing any commit that references it — CI fetches the
   artifact URL, so a commit pointing `extensions.bzl` at a release that
   doesn't exist yet breaks every build in the gap:
   `git tag vX.Y.Z && git push --tags && gh release create vX.Y.Z <artifact> --notes "..."`
   (or run the **Build idb companion distribution** workflow with the
   pinned commit and the release tag).
3. Only then update `idb/extensions.bzl` (`COMPANION_RELEASE`,
   `COMPANION_SHA256`) and land that commit.

## Release notes template

```
## Companion artifact
- Built from facebook/idb commit `<sha>` with patches/idb-build-fixes.patch (`<patch sha256 or git blob>`)
- Built with: Xcode <version> (<build>) on macOS <version>
- Verified against: Xcode <versions> / iOS <versions> simulators
- idb-companion-dist.tar.gz SHA256: `<sha256>`

## Changes
- ...
```

## Compatibility policy

- The companion loads CoreSimulator from the machine's active Xcode at
  runtime, so one artifact generally spans several Xcode versions. Cut a
  new artifact when Apple changes the testmanagerd protocol or
  CoreSimulator APIs (typically major Xcode releases).
- `RULES_IDB_COMPANION_PATH` / `RULES_IDB_IDB_PATH` remain supported so
  users can run a locally built toolchain while waiting for a release.
