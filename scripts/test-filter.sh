#!/bin/bash
# Run only the tests of a slice, as `make test` runs all tests: process 1 skips the app bundle,
# disk image, and CLI tests, with one --filter for each name. Process 2 runs the CLI tests of a
# name that a file under Tests/DirigibleCLITests/ has, in its own process (Makefile, target test).
# Process 2 runs also when process 1 fails, as in make test. It fails closed: it exits with the
# first nonzero swift status, and with 1 when no process ran a test. swift test exits 0 when a
# filter matches no test, so the script reads the two no-test strings of mutate.py; one string
# alone means that tests ran.
# With --exact, each name is the whole name of a Swift Testing test: the filter is '/<name>\(' with
# the regex characters escaped, so a name that is a prefix of another test name runs only its own
# test. The CLI process then takes a name that a CLI test file has as 'func <name>('. With
# --no-parallel, both swift calls get --no-parallel (a rerun of slow tests, scripts/run-checks.sh).
# Usage: scripts/test-filter.sh [--exact] [--no-parallel] <name>...
#        make test-filter FILTER='<name> <name>'
# scripts/test-filter.test.sh tests it.
set -euo pipefail
exact=0 serial=0
while [[ "${1:-}" == --exact || "${1:-}" == --no-parallel ]]; do
    [[ "$1" == --exact ]] && exact=1 || serial=1
    shift
done
[[ $# -gt 0 ]] || { echo "usage: scripts/test-filter.sh [--exact] [--no-parallel] <test or suite name>..." >&2; exit 2; }
cd "$(dirname "$0")/.."
out="$(mktemp)"
trap 'rm -f "$out"' EXIT

ran=0 status=0
# run <swift test arguments>: keeps the first nonzero swift status; sets ran when tests ran.
run() {
    local code=0
    swift test "$@" 2>&1 | tee "$out" || code=$?
    [[ $status -ne 0 ]] || status=$code
    grep -qF 'No matching test cases were run' "$out" && grep -qF 'Test run with 0 tests' "$out" || ran=1
}

p1=(--skip AppBundleTests --skip DiskImageTests --skip DirigibleCLITests) p2=()
for name in "$@"; do
    if [[ $exact -eq 1 ]]; then
        anchored="/$(sed 's/[][\.*^$+?(){}|/]/\\&/g' <<<"$name")\\("
        p1+=(--filter "$anchored")
        grep -rqF -- "func $name(" Tests/DirigibleCLITests 2>/dev/null && p2+=(--filter "DirigibleCLITests.*$anchored")
    else
        p1+=(--filter "$name")
        grep -rqF -- "$name" Tests/DirigibleCLITests 2>/dev/null && p2+=(--filter "DirigibleCLITests.*$name")
    fi
done
[[ $serial -eq 0 ]] || { p1+=(--no-parallel); [[ ${#p2[@]} -eq 0 ]] || p2+=(--no-parallel); }
run "${p1[@]}"
[[ ${#p2[@]} -eq 0 ]] || run "${p2[@]}"
[[ $status -eq 0 ]] || exit $status
[[ $ran -eq 1 ]] || { echo "test-filter: no test matched $*" >&2; exit 1; }
