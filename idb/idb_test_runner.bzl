"""An iOS test runner rule that runs XCTest bundles on simulators via
Facebook's idb (https://github.com/facebook/idb) instead of xcodebuild.

Compared to the default rules_apple runners this runner:

* Uses `idb` + `idb_companion` to install and run hosted, logic, and UI
  tests, which uses far less memory than `xcodebuild
  test-without-building`.
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
load("@rules_python//python:py_info.bzl", "PyInfo")

def _py312_transition_impl(_settings, _attr):
    return {"@rules_python//python/config_settings:python_version": "3.12"}

# The vendored client and its locked pip wheels target python 3.12; pin the
# configuration on the dependency edge so the consumer's default python
# version doesn't break wheel selection.
_py312_transition = transition(
    implementation = _py312_transition_impl,
    inputs = [],
    outputs = ["@rules_python//python/config_settings:python_version"],
)

def _get_template_substitutions(ctx, *, create_simulator_action_binary, clean_up_simulator_action_binary, pre_action_binary, post_action_binary, post_action_determines_exit_code):
    substitutions = {
        "device_type": ctx.attr.device_type,
        "os_version": ctx.attr.os_version,
        "pool_size": str(ctx.attr.pool_size),
        "max_concurrent_boots": str(ctx.attr.max_concurrent_boots),
        "shutdown_after_test": "true" if ctx.attr.shutdown_simulator_after_test else "false",
        "idb_path": ctx.attr.idb_path,
        "idb_python_path": ctx.file._python.short_path,
        "idb_client_imports": ":".join(ctx.attr._idb_client_lib[0][PyInfo].imports.to_list()),
        "companion_path": _companion_binary(ctx).short_path,
        "random": "true" if ctx.attr.random else "false",
        "create_simulator_action_binary": create_simulator_action_binary,
        "clean_up_simulator_action_binary": clean_up_simulator_action_binary,
        "pre_action_binary": pre_action_binary,
        "post_action_binary": post_action_binary,
        "post_action_determines_exit_code": "true" if post_action_determines_exit_code else "false",
    }
    return {"%({})s".format(key): value for key, value in substitutions.items()}

def _companion_binary(ctx):
    for f in ctx.attr._companion.files.to_list():
        if f.basename == "idb_companion":
            return f
    fail("idb_companion binary not found in @idb_companion_dist//:dist")

def _ios_idb_test_runner_impl(ctx):
    runfiles = ctx.runfiles(transitive_files = ctx.attr._companion.files)

    # The client is launched directly with the hermetic interpreter from
    # runfiles rather than as a py_binary: py_binary resolves its interpreter
    # through toolchain resolution, which the consumer's root module can
    # (and in practice does) redirect to a system python that is too old for
    # the client.
    runfiles = runfiles.merge(ctx.attr._idb_client_lib[0][DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.runfiles(
        files = [ctx.file._python],
        transitive_files = ctx.attr._idb_client_lib[0][PyInfo].transitive_sources,
    ))

    default_action_binary = "/usr/bin/true"

    pre_action_binary = default_action_binary
    if ctx.executable.pre_action:
        pre_action_binary = ctx.executable.pre_action.short_path
        runfiles = runfiles.merge(ctx.attr.pre_action[DefaultInfo].default_runfiles)
        runfiles = runfiles.merge(ctx.runfiles(files = [ctx.executable.pre_action]))

    post_action_binary = default_action_binary
    post_action_determines_exit_code = False
    if ctx.executable.post_action:
        post_action_binary = ctx.executable.post_action.short_path
        post_action_determines_exit_code = ctx.attr.post_action_determines_exit_code
        runfiles = runfiles.merge(ctx.attr.post_action[DefaultInfo].default_runfiles)
        runfiles = runfiles.merge(ctx.runfiles(files = [ctx.executable.post_action]))

    # Empty string selects the built-in flock-based simulator pool.
    create_simulator_action_binary = ""
    if ctx.executable.create_simulator_action:
        create_simulator_action_binary = ctx.executable.create_simulator_action.short_path
        runfiles = runfiles.merge(ctx.attr.create_simulator_action[DefaultInfo].default_runfiles)
        runfiles = runfiles.merge(ctx.runfiles(files = [ctx.executable.create_simulator_action]))

    clean_up_simulator_action_binary = ""
    if ctx.executable.clean_up_simulator_action:
        clean_up_simulator_action_binary = ctx.executable.clean_up_simulator_action.short_path
        runfiles = runfiles.merge(ctx.attr.clean_up_simulator_action[DefaultInfo].default_runfiles)
        runfiles = runfiles.merge(ctx.runfiles(files = [ctx.executable.clean_up_simulator_action]))

    ctx.actions.expand_template(
        template = ctx.file._test_template,
        output = ctx.outputs.test_runner_template,
        substitutions = _get_template_substitutions(
            ctx,
            create_simulator_action_binary = create_simulator_action_binary,
            clean_up_simulator_action_binary = clean_up_simulator_action_binary,
            pre_action_binary = pre_action_binary,
            post_action_binary = post_action_binary,
            post_action_determines_exit_code = post_action_determines_exit_code,
        ),
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
        DefaultInfo(runfiles = runfiles),
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
        "max_concurrent_boots": attr.int(
            default = 0,
            doc = """
Maximum number of simulators created/booted concurrently, machine-wide
across all pools and test actions; already-booted simulators are
unaffected. `0` (the default) means auto: half the machine's CPU cores.
Measured on an M4 Max (16 cores, so auto = 8): parallelism won at every
tested level — 8 create+first-boots took 87s uncapped vs 115s at cap 4 vs
much longer serialized — while low-memory or busy CI machines benefit from
a low explicit cap. Can be overridden at test time with the
`RULES_IDB_MAX_CONCURRENT_BOOTS` environment variable.
""",
        ),
        "pool_size": attr.int(
            default = 0,
            doc = """
Maximum number of pooled simulators per (device_type, os_version)
combination. `0` (the default) caps the pool at 4: each booted simulator
keeps roughly 60-100 CoreSimulator processes alive, so an unbounded pool
on a many-core machine (or with --runs_per_test) can exhaust the process
table. Actions beyond the cap wait for a free slot; raise this (and use
--local_test_jobs) on machines meant to run wider. Can be
overridden at test time with the `RULES_IDB_POOL_SIZE` environment variable.
Ignored when a custom `create_simulator_action` is provided.
""",
        ),
        "random": attr.bool(
            default = False,
            doc = """
Whether to run the tests in random order to identify unintended state
dependencies. Requires a test host (hosted or UI tests).
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
            default = "",
            doc = """
Path to an `idb` client binary. When empty (the default) the client bundled
with rules_idb is used; nothing needs to be installed. Can be overridden at
test time with the `RULES_IDB_IDB_PATH` environment variable (and
`RULES_IDB_COMPANION_PATH` for the companion).
""",
        ),
        "create_simulator_action": attr.label(
            cfg = "exec",
            executable = True,
            doc = """
Optional binary that produces the UDID of a simulator to run the tests on,
replacing the built-in flock-based simulator pool. The binary must print
only the UDID to stdout. It receives the same environment contract as
rules_apple's `ios_xctestrun_runner`: `SIMULATOR_DEVICE_TYPE`,
`SIMULATOR_OS_VERSION`, and `SIMULATOR_REUSE_SIMULATOR` (always "1" unless
`shutdown_simulator_after_test` is set). Teams with an existing custom
`simulator_creator` can plug it in here unchanged; most users should prefer
the built-in pool, which already provides concurrency-safe simulator
acquisition.
""",
        ),
        "clean_up_simulator_action": attr.label(
            cfg = "exec",
            executable = True,
            doc = """
Optional binary that cleans up the simulator produced by
`create_simulator_action`. Runs after the `post_action`, regardless of test
outcome, with `SIMULATOR_UDID` and `SIMULATOR_REUSE_SIMULATOR` set. Only
used when `create_simulator_action` is also set.
""",
        ),
        "pre_action": attr.label(
            cfg = "exec",
            executable = True,
            doc = """
A binary to run prior to test execution, after simulator acquisition. Sets
the `$SIMULATOR_UDID` environment variable, in addition to any other
variables available to the test runner.
""",
        ),
        "post_action": attr.label(
            cfg = "exec",
            executable = True,
            doc = """
A binary to run following test execution, before test result handling. Sets
`$TEST_EXIT_CODE`, `$TEST_LOG_FILE`, and `$SIMULATOR_UDID`, in addition to
any other variables available to the test runner.
""",
        ),
        "post_action_determines_exit_code": attr.bool(
            default = False,
            doc = """
When true, the exit code of the test run is the exit code of the
`post_action`. Useful for tests that need to fail based on their own
criteria.
""",
        ),
        "_companion": attr.label(
            default = Label("@idb_companion_dist//:dist"),
            doc = "Prebuilt idb_companion distribution (binary + simulator shims).",
        ),
        "_idb_client_lib": attr.label(
            cfg = _py312_transition,
            default = Label("//third_party/idb_client:idb_client_lib"),
            doc = "Bundled fb-idb python client library.",
        ),
        "_python": attr.label(
            allow_single_file = True,
            cfg = "exec",
            default = Label("//idb:client_python"),
            doc = """
Hermetic python interpreter used to run the bundled client, resolved
directly (not through python toolchain resolution, which consumers can
override with interpreters too old for the client).
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
Creates a test runner for `ios_unit_test` and `ios_ui_test` targets that
executes tests with Facebook's idb instead of xcodebuild.

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
