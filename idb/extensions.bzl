"""Module extension fetching the prebuilt idb_companion distribution.

The artifact is built by rules_idb's release pipeline from a pinned
facebook/idb commit plus patches/idb-build-fixes.patch; each release's notes
record the commit, patch, and the Xcode version it was built and verified
with. To use a locally built companion instead, set the
RULES_IDB_COMPANION_PATH environment variable at test time (see
docs/BUILDING_IDB.md).
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

COMPANION_RELEASE = "v0.1.2"
COMPANION_SHA256 = "b647e14d79f51cb0bffdf433599536a84c1155f48d4deb92525320e713a5fa09"

_COMPANION_BUILD = """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "dist",
    srcs = glob(["**"]),
)

exports_files(["idb_companion"])
"""

def _idb_impl(module_ctx):
    # CI (and local development) can bypass the released artifact and use a
    # companion distribution built from the current commit's pinned idb
    # revision + patches, e.g. RULES_IDB_COMPANION_DIST_URL=file:///path/to/dist.tar.gz
    override_url = module_ctx.getenv("RULES_IDB_COMPANION_DIST_URL")
    override_sha = module_ctx.getenv("RULES_IDB_COMPANION_DIST_SHA256")
    http_archive(
        name = "idb_companion_dist",
        urls = [
            override_url or "https://github.com/erneestoc/rules_idb/releases/download/{}/idb-companion-dist.tar.gz".format(COMPANION_RELEASE),
        ],
        sha256 = override_sha or ("" if override_url else COMPANION_SHA256),
        build_file_content = _COMPANION_BUILD,
    )

idb = module_extension(
    implementation = _idb_impl,
    doc = "Fetches the prebuilt idb_companion distribution for rules_idb.",
)
