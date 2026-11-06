"""Module extension fetching idb: the companion distribution and the client.

Both come from one pinned facebook/idb release plus
patches/idb-build-fixes.patch:

* idb_companion_dist: the prebuilt idb_companion, built by rules_idb's
  release pipeline from IDB_COMMIT and the patch; each release's notes
  record the commit, patch, and the Xcode version it was built and verified
  with. To use a locally built companion instead, set the
  RULES_IDB_COMPANION_PATH environment variable at test time (see
  docs/BUILDING_IDB.md).
* idb_client_src: the python client, built from source: the release's
  source tree with the patch applied, and its gRPC modules generated from
  proto/idb.proto at build time.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

# facebook/idb v1.7.8. CI and the companion release workflow build from this
# commit too, so the client and the companion always come from the same tree.
IDB_COMMIT = "c793afad2a31092628f7013cf1aa96f266c85024"

# GitHub's archive of IDB_COMMIT. GitHub does not guarantee these checksums
# never change; if a fetch fails on a checksum mismatch, recompute it.
IDB_SOURCE_SHA256 = "c440cd8b4fa2b0adaf675990e5a7ec7b5d43b4a3fb574fd86d419c57aa295f41"

COMPANION_RELEASE = "v0.3.0"
COMPANION_SHA256 = "1edd25393d4922ba08946b9f7dd3c84cd905004e0e775216713d8c9b75d3396a"

_COMPANION_BUILD = """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "dist",
    srcs = glob(["**"]),
)

exports_files(["idb_companion"])
"""

# The client's sources, with the gRPC modules generated next to them so that
# `idb.grpc.idb_pb2` resolves inside the one `idb` package.
_CLIENT_BUILD = """
load("@rules_python//python:py_library.bzl", "py_library")

genrule(
    name = "grpc_modules",
    srcs = ["proto/idb.proto"],
    outs = [
        "idb/grpc/idb_pb2.py",
        "idb/grpc/idb_grpc.py",
    ],
    cmd = "$(execpath {gen_grpc}) $(location proto/idb.proto) $(RULEDIR)/idb/grpc",
    tools = ["{gen_grpc}"],
)

py_library(
    name = "idb_client_lib",
    srcs = glob(
        ["idb/**/*.py"],
        exclude = [
            "idb/**/tests/**",
            "idb/**/*_tests.py",
        ],
    ) + [":grpc_modules"],
    imports = ["."],
    visibility = ["//visibility:public"],
    deps = [
        "{aiofiles}",
        "{grpclib}",
        "{protobuf}",
    ],
)
"""

def _idb_impl(module_ctx):
    # CI (and local development) can bypass the released artifact and use a
    # companion distribution built from the current commit's pinned idb
    # revision + patches, e.g. RULES_IDB_COMPANION_DIST_URL=file:///path/to/dist.tar.gz
    override_url = module_ctx.getenv("RULES_IDB_COMPANION_DIST_URL")
    override_sha = module_ctx.getenv("RULES_IDB_COMPANION_DIST_SHA256")
    if override_url and not override_sha and not override_url.startswith("file://"):
        fail(
            "RULES_IDB_COMPANION_DIST_URL points at a remote URL but " +
            "RULES_IDB_COMPANION_DIST_SHA256 is not set; refusing to fetch " +
            "an unverified companion binary. file:// URLs are exempt.",
        )
    http_archive(
        name = "idb_companion_dist",
        urls = [
            override_url or "https://github.com/erneestoc/rules_idb/releases/download/{}/idb-companion-dist.tar.gz".format(COMPANION_RELEASE),
        ],
        sha256 = override_sha or ("" if override_url else COMPANION_SHA256),
        build_file_content = _COMPANION_BUILD,
    )

    http_archive(
        name = "idb_client_src",
        urls = ["https://github.com/facebook/idb/archive/{}.tar.gz".format(IDB_COMMIT)],
        sha256 = IDB_SOURCE_SHA256,
        strip_prefix = "idb-{}".format(IDB_COMMIT),
        patches = [Label("//patches:idb-build-fixes.patch")],
        patch_args = ["-p1"],
        build_file_content = _CLIENT_BUILD.format(
            gen_grpc = str(Label("//third_party/idb_client:gen_grpc")),
            aiofiles = str(Label("@rules_idb_pip//aiofiles")),
            grpclib = str(Label("@rules_idb_pip//grpclib")),
            protobuf = str(Label("@rules_idb_pip//protobuf")),
        ),
    )

idb = module_extension(
    implementation = _idb_impl,
    doc = "Fetches idb for rules_idb: the prebuilt companion and the client's patched source.",
)
