#!/bin/bash
# Check the argument parsing of hid.swift and the order of its key events (--dry-run). It posts
# no event: each case ends before the Accessibility check. Run by `make test-hooks`.
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

expect_usage "click with one number" click 10
expect_usage "an unknown flag" key 53 --control

# The modifier keys go down before the key and up after it (55 Command, 58 Option; flags 1048576
# and 524288): a flag on the key event alone left the system modifier held.
events="$(swift "$hid" key 17 --command --option --dry-run 2>&1)"
want="down 55 flags 1048576
down 58 flags 1572864
down 17 flags 1572864
up 17 flags 1572864
up 58 flags 1048576
up 55 flags 0"
[[ "$events" == "$want" ]] || fail "the modifier keys around a key: $events"
[[ "$(swift "$hid" key 53 --dry-run 2>&1)" == $'down 53 flags 0\nup 53 flags 0' ]] || fail "a key with no modifier"

[[ $failures -eq 0 ]] && echo "hid tests: all passed" || { echo "hid tests: $failures failed"; exit 1; }
