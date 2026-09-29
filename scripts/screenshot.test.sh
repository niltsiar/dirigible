#!/bin/bash
# Check the arguments of screenshot.sh. No case finds a window, so no case captures the
# screen. Run by `make test-hooks`.
set -uo pipefail
shot="$(cd "$(dirname "$0")" && pwd -P)/screenshot.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

err="$("$shot" 2>&1 >/dev/null)" && fail "no argument: exit 0"
[[ "$err" == *"usage: screenshot.sh"* ]] || fail "no argument: no usage text: $err"

err="$("$shot" --owner 2>&1 >/dev/null)" && fail "--owner with no name: exit 0"
[[ "$err" == *"usage: screenshot.sh"* ]] || fail "--owner with no name: no usage text: $err"

err="$("$shot" --owner NoSuchApp "$tmp/x.png" 2>&1 >/dev/null)"
code=$?
[[ $code -eq 1 ]] || fail "unknown owner: exit $code, not 1"
[[ "$err" == *"No NoSuchApp window on screen"* ]] || fail "unknown owner: wrong message: $err"
[[ ! -e "$tmp/x.png" ]] || fail "unknown owner: a file was written"

[[ $failures -eq 0 ]] && echo "screenshot tests: all passed" || { echo "screenshot tests: $failures failed"; exit 1; }
