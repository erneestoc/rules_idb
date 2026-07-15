#!/bin/bash
# Behavioral validation of the idb test runner: asserts the outcomes that
# make the runner trustworthy, not just that green targets stay green.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fails=$((fails+1)); fi; }

TL=$(bazel info bazel-testlogs 2>/dev/null)

# 1. A failing test bundle must fail the target (idb itself exits 0).
bazel test //examples:FailingTests --nocache_test_results --test_output=summary >/dev/null 2>&1
check "failing tests fail the target" "[[ $? -ne 0 ]]"
check "failure message names the assertion" "grep -q 'testThatFails: XCTAssertEqual failed' '$TL/examples/FailingTests/test.log'"
check "junit xml records 2 tests 1 failure" "grep -q 'tests=\"2\" failures=\"1\"' '$TL/examples/FailingTests/test.xml'"

# 2. --test_filter runs exactly the selected test and passes.
bazel test //examples:FailingTests --test_filter="FailingTests/testThatPasses" --nocache_test_results --test_output=summary >/dev/null 2>&1
check "filtered run passes" "[[ $? -eq 0 ]]"
check "filter ran exactly 1 test" "grep -q 'executed 1 tests, 0 failed' '$TL/examples/FailingTests/test.log'"

# 3. A filter matching nothing must fail (no-tests-ran guard).
bazel test //examples:FailingTests --test_filter="NoSuch/testNothing" --nocache_test_results --test_output=summary >/dev/null 2>&1
check "zero-test run fails" "[[ $? -ne 0 ]]"
check "zero-test run says why" "grep -q 'no tests were executed' '$TL/examples/FailingTests/test.log'"

# 4. post_action_determines_exit_code gates a passing suite.
bazel test //examples:HostedTestsPostGate --nocache_test_results --test_output=summary >/dev/null 2>&1
check "failing post_action fails the target" "[[ $? -ne 0 ]]"
check "post_action exit code surfaced" "grep -q \"post_action exited with '7'\" '$TL/examples/HostedTestsPostGate/test.log'"

# 5. Passing suite emits complete JUnit XML.
bazel test //examples:HostedTests --nocache_test_results --test_output=summary >/dev/null 2>&1
check "hosted suite passes" "[[ $? -eq 0 ]]"
check "junit xml has all 15 tests" "grep -q 'tests=\"15\" failures=\"0\"' '$TL/examples/HostedTests/test.xml'"

# 6. XCTSkip must not fail the run.
bazel test //examples:SkippingTests --nocache_test_results --test_output=summary >/dev/null 2>&1
check "skipped test does not fail the target" "[[ $? -eq 0 ]]"
check "skip suite reports both tests" "grep -q 'executed 2 tests, 0 failed' '$TL/examples/SkippingTests/test.log'"

# 7. Swift Testing (@Test) executes, and its failures fail the target.
bazel test //examples:SwiftTestingTests --nocache_test_results --test_output=summary >/dev/null 2>&1
check "swift-testing suite passes" "[[ $? -eq 0 ]]"
check "swift-testing ran both tests" "grep -q 'executed 2 tests, 0 failed' '$TL/examples/SwiftTestingTests/test.log'"
bazel test //examples:FailingSwiftTestingTests --nocache_test_results --test_output=summary >/dev/null 2>&1
check "failing swift-testing test fails the target" "[[ $? -ne 0 ]]"
check "swift-testing failure names the expectation" "grep -q 'intentional failure for runner validation' '$TL/examples/FailingSwiftTestingTests/test.log'"

# 8. Sharding: every test runs exactly once across shards. Serialized:
# three parallel shard actions would need three simulators, which starves
# the small hosted CI runners (they preboot exactly one).
bazel test //examples:HostedTestsSharded --local_test_jobs=1 --nocache_test_results --test_output=summary >/dev/null 2>&1
check "sharded suite passes" "[[ $? -eq 0 ]]"
shard_union=$(cat "$TL/examples/HostedTestsSharded/shard_"*"_of_3/test.log" 2>/dev/null | grep -o '"methodName": "[A-Za-z0-9()]*"' | sort | uniq | wc -l | tr -d ' ')
shard_total=$(cat "$TL/examples/HostedTestsSharded/shard_"*"_of_3/test.log" 2>/dev/null | grep -c '"methodName"')
check "shards cover all 15 tests exactly once" "[[ '$shard_union' == '15' && '$shard_total' == '15' ]]"

echo
if [[ $fails -eq 0 ]]; then echo "ALL BEHAVIORAL CHECKS PASSED"; else echo "$fails CHECK(S) FAILED"; exit 1; fi
