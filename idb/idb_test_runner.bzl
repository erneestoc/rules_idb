"""An iOS test runner rule that runs XCTest bundles on simulators via
Facebook's idb (https://github.com/facebook/idb) instead of xcodebuild.

Compared to the default rules_apple runners this runner:

* Uses `idb` + `idb_companion` to install and run hosted tests, which uses
  far less memory than `xcodebuild test-without-building`.
* Supports `--local_test_jobs=N` out of the box: each concurrently running
  test acquires its own simulator from a pool guarded by kernel `flock`
  locks. Locks are tied to the runner process lifetime, so they are released
  automatically even when a test is killed (no stale lock files, no traps).
"""

load(
    "@rules_apple//apple:providers.bzl",
    "AppleDeviceTestRunnerInfo",
    "apple_provider",
)

def _get_template_substitutions(ctx):
    substitutions = {
        "device_type": ctx.attr.device_type,
        "os_version": ctx.attr.os_version,
        "pool_size": str(ctx.attr.pool_size),
        "shutdown_after_test": "true" if ctx.attr.shutdown_simulator_after_test else "false",
        "idb_path": ctx.attr.idb_path,
    }
    return {"%({})s".format(key): value for key, value in substitutions.items()}

def _ios_idb_test_runner_impl(ctx):
    ctx.actions.expand_template(
        template = ctx.file._test_template,
        output = ctx.outputs.test_runner_template,
        substitutions = _get_template_substitutions(ctx),
    )

    return [
        apple_provider.make_apple_test_runner_info(
            execution_requirements = {"requires-darwin": ""},
            test_runner_template = ctx.outputs.test_runner_template,
        ),
        AppleDeviceTestRunnerInfo(
            device_type = ctx.attr.device_type,
            os_version = ctx.attr.os_version,
        ),
        DefaultInfo(),
    ]

ios_idb_test_runner = rule(
    _ios_idb_test_runner_impl,
    attrs = {
        "device_type": attr.string(
            default = "",
            doc = """
The simulator device type to run tests on, e.g. `iPhone 17 Pro`. Values
correspond to `xcrun simctl list devicetypes`. If empty, the newest available
iPhone device type is used.
""",
        ),
        "os_version": attr.string(
            default = "",
            doc = """
The iOS version to run tests on, e.g. `26.2`. Values correspond to
`xcrun simctl list runtimes`. If empty, the newest available iOS runtime is
used.
""",
        ),
        "pool_size": attr.int(
            default = 0,
            doc = """
Maximum number of pooled simulators per (device_type, os_version)
combination. `0` (the default) lets the pool grow on demand; effective
concurrency is then bounded by Bazel's `--local_test_jobs`. Can be
overridden at test time with the `RULES_IDB_POOL_SIZE` environment variable.
""",
        ),
        "shutdown_simulator_after_test": attr.bool(
            default = False,
            doc = """
Shut the pooled simulator down after the test finishes. The default keeps
simulators booted so subsequent test runs reuse a warm simulator, which is
substantially faster. Enable this to trade speed for a lower idle memory
footprint.
""",
        ),
        "idb_path": attr.string(
            default = "idb",
            doc = """
Path to the `idb` client binary (from the `fb-idb` pip package). Defaults to
finding `idb` on `PATH`. `idb_companion` must also be discoverable on `PATH`
(`brew install facebook/fb/idb-companion`). Can be overridden at test time
with the `RULES_IDB_IDB_PATH` environment variable.
""",
        ),
        "_test_template": attr.label(
            default = Label("//idb:idb_test_runner.template.sh"),
            allow_single_file = True,
        ),
    },
    outputs = {
        "test_runner_template": "%{name}.sh",
    },
    doc = """
Creates a test runner for `ios_unit_test` targets that executes tests with
Facebook's idb instead of xcodebuild.

Example:

```bzl
load("@rules_idb//idb:idb_test_runner.bzl", "ios_idb_test_runner")

ios_idb_test_runner(
    name = "idb_runner",
    device_type = "iPhone 17 Pro",
)

ios_unit_test(
    name = "HostedTests",
    minimum_os_version = "16.0",
    runner = ":idb_runner",
    test_host = ":HostApp",
    deps = [":HostedTestsLib"],
)
```

Or use the predefined runner `@rules_idb//idb:default_runner`.
""",
)
