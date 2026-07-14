# Releasing rules_idb

Every release pins three things, and the release notes must record all of
them:

1. **The facebook/idb commit** the companion artifact and the vendored
   python client were built from.
2. **The patch** (`patches/idb-build-fixes.patch`) applied on top of it.
3. **The Xcode/macOS version** the artifact was built with and the versions
   it was verified against.

## Cutting a release

1. If bumping the idb pin (or Xcode broke something):
   - Update the local checkout, re-apply/extend the patch, and rebuild per
     [docs/BUILDING_IDB.md](docs/BUILDING_IDB.md).
   - Re-vendor the python client if `idb/` or `proto/idb.proto` changed:
     copy `idb/` into `third_party/idb_client/`, regenerate
     `idb_pb2.py`/`idb_grpc.py`, keep the `python/migrations` shim.
   - Run the full example suite and the benchmark.
2. Tag and create the GitHub release:
   `git tag vX.Y.Z && git push --tags && gh release create vX.Y.Z --notes "..."`.
3. Build and attach the companion artifact: run the **Build idb companion
   distribution** workflow with the pinned commit and the release tag (or
   build locally and `gh release upload`).
4. Update `idb/extensions.bzl` (`COMPANION_RELEASE`, `COMPANION_SHA256`)
   to the new artifact and land that commit.

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
