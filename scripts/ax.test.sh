#!/bin/bash
# Check the argument parsing of ax.swift. It reads no tree: each case fails before the
# Accessibility check. Run by `make test-hooks`.
set -uo pipefail
ax="$(cd "$(dirname "$0")" && pwd -P)/ax.swift"
failures=0

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# expect_usage <case> <args...>: exit 2 and the usage text on stderr.
expect_usage() {
    local name="$1"
    shift
    local err
    err="$(swift "$ax" "$@" 2>&1 >/dev/null)"
    local code=$?
    [[ $code -eq 2 ]] || fail "$name: exit $code, not 2"
    [[ "$err" == *"usage: ax.swift"* ]] || fail "$name: no usage text: $err"
}

expect_usage "no command"
expect_usage "unknown command" walk
expect_usage "dump with a word" dump deep
expect_usage "find with no text" find
expect_usage "press with two titles" press a b
expect_usage "step with no action" step AXSplitter
expect_usage "step with an unknown action" step AXSplitter wiggle

[[ $failures -eq 0 ]] && echo "ax tests: all passed" || { echo "ax tests: $failures failed"; exit 1; }
