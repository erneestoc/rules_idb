# Building idb from source

rules_idb drives tests through Facebook's [idb](https://github.com/facebook/idb):
a per-simulator gRPC daemon (`idb_companion`, built on FBSimulatorControl)
plus a thin python CLI client (`idb`). Both are built from the **v1.7.8**
release (commit `c793afad2a31092628f7013cf1aa96f266c85024`, 2026-11-01) with
`patches/idb-build-fixes.patch` applied. arm64 only: upstream builds arm64
only, and so does rules_idb.

Upstream now publishes its own companion (`idb-companion.macos-arm64.tar.gz`)
and client (`fb_idb` wheel) with every release. rules_idb still builds its
own because the fixes below are not in a release yet; once they are, the
patch can be dropped and the official artifacts used directly.

## The patch

Each fix is also proposed upstream; drop it from the patch once a release
includes it.

* **Swift test bundles can load their dylibs** (`FBXCTestCore/Configuration/TestRunnerConfiguration.swift`):
  adds the platform's `Developer/usr/lib` (holding
  `libXCTestSwiftSupport.dylib`) to the test host's
  `DYLD_FALLBACK_LIBRARY_PATH`, as Xcode's runners do. facebook/idb#TBD-A
* **Request `DYLD_*` variables extend the runner's** (`FBXCTestCore/Runners/ManagedTestRunner.swift`):
  so sanitizer runtimes and the Main Thread Checker can ride along with the
  test shim in `DYLD_INSERT_LIBRARIES`. facebook/idb#TBD-B
* **Configurable test bundle connection timeouts** (`FBXCTestCore/TestManager/TestBundleConnection.swift`,
  new `TestBundleConnectionTimeouts.swift`): `FBXCTEST_BUNDLE_READY_TIMEOUT`,
  `FBXCTEST_IDE_INTERFACE_TIMEOUT` and `FBXCTEST_DAEMON_SESSION_TIMEOUT`
  (seconds; default 60). The runner shortens them so a host that dies at
  startup fails fast. facebook/idb#TBD-C
* **A failed last xctest response ends the RPC** (`IDBXCTestReporter.swift`):
  instead of hanging until the client's timeout. facebook/idb#TBD-D
* **A UI-test target app that already exited does not fail the run**
  (`FBXCTestCore/TestManager/TestManagerAPIMediator.swift`). facebook/idb#TBD-F
* **`--randomize-execution-order`** (`proto/idb.proto` field
  `XctestRunRequest.randomize_execution_order`, plumbed through the
  companion, FBXCTestCore and the python client): sets
  `XCTestConfiguration.testExecutionOrdering` to random. Used by
  `random = True`. facebook/idb#TBD-E
* **Filtered runs no longer crash the companion** (`FBXCTestCore/Configuration/TestConfiguration.swift`):
  new in v1.7.8's Swift port of the test configuration. `XCTTestIdentifier`'s
  `+alloc` returns a shared placeholder that its initializer over-releases,
  so app-hosted runs with `--tests-to-run`/`--tests-to-skip` segfaulted the
  companion. That breaks `shard_count` and `--test_filter`. The patch
  retains the placeholder before each initializer. facebook/idb#TBD-G

What the patch no longer carries, compared with the `3f1bb6e` pin: the
toolchain workarounds (upstream code was rewritten), the single
`AsyncIterator` crash fix (upstream's `RequestStreamReader` fixes it the
same way), and the `FBiOSTarget` `@_cdecl` workaround.

## Prerequisites

```sh
brew install xcodegen protobuf uv
```

Xcode 26 or newer. Upstream builds with the newest Xcode on GitHub's
`macos-26` image, and so does rules_idb's CI; older Xcode 26.x compilers
reject some of upstream's Swift 6 concurrency code. If yours does, build
with `SWIFT_VERSION=5` locally (only to try a change; release artifacts come
from CI).

## 1. Clone and patch

```sh
git clone https://github.com/facebook/idb.git ~/workspace/idb-src
cd ~/workspace/idb-src
git checkout v1.7.8
git apply /path/to/rules_idb/patches/idb-build-fixes.patch
```

## 2. Build the companion

Only what the test runner needs (upstream's `./build.sh build all` also
builds the REPL, sim-video and the tvOS simulator bridge, which needs the
tvOS simulator SDK):

```sh
./build.sh build Shimulator-iOS
./build.sh build Shimulator-macOS
./build.sh build SimulatorFrameworkBridge-iOS
./build.sh build idb_companion
```

Then assemble the runtime layout:

```sh
R=Build/Products/Release; S=Build/Products/Release-iphonesimulator
D=/path/to/rules_idb/tools/idb-dist
mkdir -p "$D/Resources"
cp $R/idb_companion "$D/"
for b in $R/*.bundle; do ditto "$b" "$D/$(basename "$b")"; done
cp $S/libShimulator-iOS.dylib $R/libShimulator-macOS.dylib \
   $S/SimulatorFrameworkBridge-iOS "$D/Resources/"
```

## 3. Build the python client

Bazel builds the client itself: `idb/extensions.bzl` fetches the source at
`IDB_COMMIT`, applies the patch, and generates `idb_pb2.py` / `idb_grpc.py`
with `//third_party/idb_client:gen_grpc` (what upstream's `setup.py` does).
Nothing needs to be copied into the repository. To run a client outside
Bazel, install it from the patched tree:

```sh
uv venv --python 3.12 /path/to/rules_idb/.venv-src
mkdir /tmp/idb-py && git archive HEAD | tar -x -C /tmp/idb-py
git diff | (cd /tmp/idb-py && git apply)   # the patch, if not committed
FB_IDB_VERSION=1.7.8 uv pip install --python /path/to/rules_idb/.venv-src/bin/python /tmp/idb-py
```

Install from a copy outside the source tree: the python build writes to
`build/`, which collides with Xcode's `Build/` on case-insensitive APFS.

## 4. Point rules_idb at the toolchain

```sh
bazel test //examples:HostedTests \
  --test_env=RULES_IDB_IDB_PATH=/path/to/rules_idb/.venv-src/bin/idb \
  --test_env=RULES_IDB_COMPANION_PATH=/path/to/rules_idb/tools/idb-dist/idb_companion
```

or package the layout (`tar -czf dist.tar.gz -C tools/idb-dist .`) and set
`RULES_IDB_COMPANION_DIST_URL=file:///path/to/dist.tar.gz`.

Notes:

* The companion cannot bind TCP ports on macOS 26 when unsigned (EPERM from
  local-network privacy); the client's default unix-domain-socket transport
  is unaffected.
* Companions persist per simulator UDID (registered under `/tmp/idb`) and
  are reused across runs. Stale registry entries after killing companions
  can be cleared with `rm -rf /tmp/idb ~/.idb`.
