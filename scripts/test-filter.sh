#!/bin/bash
# Run only the tests of a slice, as `make test` runs all tests: process 1 skips the app bundle,
# disk image, and CLI tests, with one --filter for each name. Process 2 runs the CLI tests of a
# name that a file under Tests/DirigibleCLITests/ has, in its own process (Makefile, target test).
# It fails closed: it exits 1 when no process ran a test, and with the status of swift when a
# test fails. swift test exits 0 when a filter matches no test, so the script reads the two
# no-test strings of mutate.py; one string alone means that tests ran.
# Usage: scripts/test-filter.sh <name>..., or make test-filter FILTER='<name> <name>'.
# scripts/test-filter.test.sh tests it.
set -euo pipefail
[[ $# -gt 0 ]] || { echo "usage: scripts/test-filter.sh <test or suite name>..." >&2; exit 2; }
cd "$(dirname "$0")/.."
out="$(mktemp)"
trap 'rm -f "$out"' EXIT

ran=0
# run <swift test arguments>: stops with the swift status on a failure; sets ran when tests ran.
run() {
    swift test "$@" 2>&1 | tee "$out" || exit $?
    grep -qF 'No matching test cases were run' "$out" && grep -qF 'Test run with 0 tests' "$out" || ran=1
}

p1=(--skip AppBundleTests --skip DiskImageTests --skip DirigibleCLITests) p2=()
for name in "$@"; do
    p1+=(--filter "$name")
    grep -rqF -- "$name" Tests/DirigibleCLITests 2>/dev/null && p2+=(--filter "DirigibleCLITests.*$name")
done
run "${p1[@]}"
[[ ${#p2[@]} -eq 0 ]] || run "${p2[@]}"
[[ $ran -eq 1 ]] || { echo "test-filter: no test matched $*" >&2; exit 1; }
