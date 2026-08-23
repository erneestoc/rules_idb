# Building idb from source

rules_idb drives tests through Facebook's [idb](https://github.com/facebook/idb):
a per-simulator gRPC daemon (`idb_companion`, built on FBSimulatorControl)
plus a thin python CLI client (`idb`). The 2022 binary releases are broken on
current machines (see the README), so both are built from `main`. Verified
against commit `3f1bb6eb3ae7041ba4902605c6a5a4d686ccc3f8` (2026-08-22) with
Xcode 26.2 on macOS 26. (Previously verified against `70d75b3`,
2026-07-10.)

## Prerequisites

```sh
brew install xcodegen protobuf swift-protobuf uv
```

## 1. Clone and patch

```sh
git clone https://github.com/facebook/idb.git ~/workspace/idb-src
cd ~/workspace/idb-src
git apply /path/to/rules_idb/patches/idb-build-fixes.patch
```

The patch carries fixes for upstream issues in the open-source build (Meta
builds internally with Buck; none of these paths are covered by their CI).
Two fixes that were needed at `70d75b3` are gone as of `3f1bb6e` — upstream
now ships `Companion/project.yml`'s `ReplProtocol`/`CompanionDiscovery`
targets and `protoc_compiler_template.py`'s `grpclib.plugin.main` import
directly — so the patch no longer touches those two files.

Behavioral fixes (carried since `70d75b3`):

* **`FBiOSTarget.h` / `FBiOSTarget.swift`**: two C functions are
  reimplemented in Swift with `@_cdecl` while their `_Nonnull` C prototypes
  stay in the header. Swift serializes the `@_cdecl` thunk's SIL with an
  `Optional` object return; a Swift consumer importing the C prototype types
  it non-optional, and swift-frontend aborts with a `SILFunction type
  mismatch` deserialization failure when compiling `idb_companion` in
  Release. The patch marks the prototypes `NS_SWIFT_UNAVAILABLE` and exposes
  renamed `public` Swift functions instead.
* **`InstallMethodHandler.swift`**: the handler created a new AsyncIterator
  per read on the gRPC request stream, which grpc-swift's
  `NIOThrowingAsyncSequenceProducer` forbids (fatal error on every install).
  As of `3f1bb6e` upstream added a second, parallel zip-archive install path
  (`installZipArchive`) with the same bug; the patch's single-iterator
  wrapper now threads through that path too.
* **`FBTestRunnerConfiguration.swift`**: adds the platform's
  `Developer/usr/lib` to the test host's `DYLD_FALLBACK_LIBRARY_PATH` so
  Swift test bundles can load `libXCTestSwiftSupport.dylib`; also plumbs a
  `FB_XCTEST_EXECUTION_ORDERING=random` launch-env key into
  `XCTestConfiguration.testExecutionOrdering`.
* **`FBManagedTestRunStrategy.swift`**: request-provided `DYLD_*` variables
  are appended to (not replacing) the composed launch values, so sanitizer
  runtimes can ride along with the test shim.
* **`FBTestManagerAPIMediator.swift`**: failing to terminate the app under
  test during UI-test teardown (it usually already exited) no longer fails
  the run.

Toolchain-compatibility fixes (new at `3f1bb6e`, Swift 6.2.3 /
swiftlang-6.2.3.3.21 on Xcode 26.2 — none of these are behavioral, they only
work around the current Swift compiler rejecting patterns upstream's own
code already uses elsewhere):

* **`FBRemoteInvoking.swift`**: upstream already has a `nonisolated(unsafe)`
  workaround here for a `sending Result<Any?, Error>` false positive (see
  their own commit `3a78617`), but it doesn't fully satisfy this compiler.
  Applying `nonisolated(unsafe)` to the constructed `Result` itself (not
  just the payload inside it) does.
* **`FBAXBridgeTransport.swift`**: two `[String]`-returning functions built
  their argument list as one long `+`-chained expression; the type checker
  times out on it under this compiler. Rewritten as a `var` built up
  statement-by-statement.
* **`Companion/main.swift`, `LaunchMethodHandler.swift`,
  `ReplSocketClient.swift`**: `Task { ... }` / `group.addTask { ... }`
  closures capturing already-`nonisolated(unsafe)`-rebound values still hit
  "passing closure as a 'sending' parameter risks causing data races" here.
  Giving the closure itself an explicit `@Sendable` type annotation (in
  addition to the existing `nonisolated(unsafe)` rebind of its captures)
  resolves it; `nonisolated(unsafe)` alone does not, even though the
  otherwise-identical pattern in `LogMethodHandler.swift` compiles as only a
  warning without it. This diagnostic is flaky in exactly the way upstream's
  own `FBRemoteInvoking.swift` comment predicts ("newer Swift compilers no
  longer treat the [...] parameter as region-disconnected"); re-verify these
  four spots against whatever Swift toolchain is current when next bumping
  the pin.

## 2. Build the companion

```sh
cd ~/workspace/idb-src
./build.sh build shims
./build.sh build SimulatorFrameworkBridge
./build.sh build idb_companion || ./build.sh build idb_companion
# (a clean first invocation can fail with "no such module IDBGRPCSwift";
# the retry succeeds — upstream project-generation quirk)
```

Then assemble the runtime layout (skipping `idb-repl`; as of `3f1bb6e`
upstream's `Companion/project.yml` does define the `CompanionDiscovery`
target it needs, but building `idb-repl` itself is untested here and not
required for the companion/client this repo uses):

```sh
R=Build/Products/Release; S=Build/Products/Release-iphonesimulator
D=/path/to/rules_idb/tools/idb-dist
mkdir -p "$D/Resources"
cp $R/idb_companion "$D/"
for b in $R/*.bundle; do ditto "$b" "$D/$(basename "$b")"; done
cp $S/libShimulator-iOS.dylib $R/libShimulator-macOS.dylib \
   $S/libRepl-iOS.dylib $R/libRepl-macOS.dylib \
   $S/SimulatorFrameworkBridge "$D/Resources/"
```

Copy the layout **out of the source tree**: python wheel builds write to
`build/`, which collides with Xcode's `Build/` on case-insensitive APFS and
deletes your compiled products.

## 3. Build the python client

```sh
uv venv --python 3.12 /path/to/rules_idb/.venv-src
uv pip install --python /path/to/rules_idb/.venv-src/bin/python3 \
  pip setuptools wheel grpcio-tools grpclib pyre-extensions
cd ~/workspace/idb-src
PATH="/path/to/rules_idb/.venv-src/bin:$PATH" FB_IDB_VERSION=1.2.0.dev1 \
  /path/to/rules_idb/.venv-src/bin/pip install --no-build-isolation .
```

The client imports one Meta-internal module that isn't published; shim it:

```sh
SP=/path/to/rules_idb/.venv-src/lib/python3.12/site-packages
mkdir -p $SP/python/migrations
touch $SP/python/__init__.py $SP/python/migrations/__init__.py
cat > $SP/python/migrations/py310.py <<'EOF'
import enum
import sys

if sys.version_info >= (3, 11):
    StrEnum310 = enum.StrEnum
else:
    class StrEnum310(str, enum.Enum):
        def __str__(self):
            return str(self.value)
EOF
```

## 4. Point rules_idb at the toolchain

```sh
bazel test //examples:HostedTests \
  --test_env=RULES_IDB_IDB_PATH=/path/to/rules_idb/.venv-src/bin/idb \
  --test_env=RULES_IDB_COMPANION_PATH=/path/to/rules_idb/tools/idb-dist/idb_companion
```

Notes:

* The companion cannot bind TCP ports on macOS 26 when unsigned (EPERM from
  local-network privacy); the client's default unix-domain-socket transport
  is unaffected.
* Companions persist per simulator UDID (registered under `/tmp/idb`) and
  are reused across runs. Stale registry entries after killing companions
  can be cleared with `rm -rf /tmp/idb ~/.idb`.
* When bumping the pinned commit, delete any stale generated
  `IDBGRPCSwift/idb.grpc.swift` / `idb.pb.swift` from a previous build
  before running `build.sh build idb_companion` again — it only regenerates
  them when they're *absent*, and stale ones from the old commit's
  `proto/idb.proto` compile against the new Swift/companion sources with
  wrong field names, producing confusing "cannot find type" / "has no
  member" errors that look unrelated to protos.
* Re-vendoring `third_party/idb_client`'s generated `idb_pb2.py` /
  `idb_grpc.py` (e.g. via `python -m grpc_tools.protoc` plus a
  `grpclib.plugin.main`-based `protoc-gen-python_grpc` plugin) produces an
  `import idb_pb2` in `idb_grpc.py`; hand-fix it to
  `import idb.grpc.idb_pb2 as idb_pb2` to match the package layout the rest
  of the vendored client expects.
