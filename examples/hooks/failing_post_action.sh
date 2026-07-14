#!/bin/bash
# Post action that fails on purpose to validate post_action_determines_exit_code.
echo "FAILING_POST_ACTION_RAN exit_was=$TEST_EXIT_CODE"
exit 7
