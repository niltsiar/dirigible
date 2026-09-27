#!/bin/bash
# Check the argument parsing of hid.swift. It posts no event: each case fails before the
# Accessibility check. Run by `make test-hooks`.
set -uo pipefail
hid="$(cd "$(dirname "$0")" && pwd -P)/hid.swift"
failures=0

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# expect_usage <case> <args...>: exit 2 and the usage text on stderr.
expect_usage() {
    local name="$1"
    shift
    local err
    err="$(swift "$hid" "$@" 2>&1 >/dev/null)"
    local code=$?
    [[ $code -eq 2 ]] || fail "$name: exit $code, not 2"
    [[ "$err" == *"usage: hid.swift"* ]] || fail "$name: no usage text: $err"
}

expect_usage "no command"
expect_usage "unknown command" wiggle 1 2
expect_usage "drag with two numbers" drag 10 20
expect_usage "up with a word" up 10 left
expect_usage "key with no code" key
expect_usage "scroll with one number" scroll 5

[[ $failures -eq 0 ]] && echo "hid tests: all passed" || { echo "hid tests: $failures failed"; exit 1; }
