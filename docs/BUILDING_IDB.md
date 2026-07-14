# Building idb from source

rules_idb drives tests through Facebook's [idb](https://github.com/facebook/idb):
a per-simulator gRPC daemon (`idb_companion`, built on FBSimulatorControl)
plus a thin python CLI client (`idb`). The 2022 binary releases are broken on
current machines (see the README), so both are built from `main`. Verified
against commit `70d75b3` (2026-07-10) with Xcode 26.2 on macOS 26.

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
builds internally with Buck; none of these paths are covered by their CI):

* **`Companion/project.yml`**: adds the missing `ReplProtocol` framework
  target (companion sources import it, but no OSS target builds it).
* **`FBiOSTarget.h` / `FBiOSTarget.swift`**: two C functions are
  reimplemented in Swift with `@_cdecl` while their `_Nonnull` C prototypes
  stay in the header. Swift serializes the `@_cdecl` thunk's SIL with an
  `Optional` object return; a Swift consumer importing the C prototype types
  it non-optional, and swift-frontend aborts with a `SILFunction type
  mismatch` deserialization failure when compiling `idb_companion` in
  Release. The patch marks the prototypes `NS_SWIFT_UNAVAILABLE` and exposes
  renamed `public` Swift functions instead.
* **`protoc_compiler_template.py`**: the python client's generated protoc
  plugin used `pkg_resources`, which no longer exists in modern setuptools.

## 2. Build the companion

```sh
cd ~/workspace/idb-src
./build.sh build shims
./build.sh build SimulatorFrameworkBridge
./build.sh build idb_companion
```

Then assemble the runtime layout (skipping `idb-repl`, which needs a
`CompanionDiscovery` target that doesn't exist in the OSS project either):

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
