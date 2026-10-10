#!/bin/bash
# Run `swift test` with the given arguments, print its output, and exit with its status. When
# swift exits 0 and the output has no Swift Testing summary line ("Test run with", on stderr),
# exit 1: an AppKit call in a test (a terminate reply, a posted mouse-up in a tracking loop) can
# end the test process with exit 0, and the later tests then do not run.
# Usage: scripts/swift-test.sh <swift test arguments>
# The Makefile test recipes, scripts/test-filter.sh, and scripts/test-dmg.sh call it.
# scripts/test-filter.test.sh tests it.
set -uo pipefail
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
swift test "$@" 2>&1 | tee "$out"
code=$?
if [[ $code -eq 0 ]] && ! grep -qF 'Test run with' "$out"; then
    echo "swift-test: the test process ended before its report (swift test $*)" >&2
    exit 1
fi
exit "$code"
