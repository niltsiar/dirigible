#!/bin/bash
# Run only the tests of a slice: process 1 skips the app bundle, disk image, and CLI tests, with
# one --filter for each name. Process 2 runs the CLI tests of a name that a file under
# Tests/DirigibleCLITests/ has, in its own process, as the CLI shard of make test.
# Process 2 runs also when process 1 fails, as in make test. It fails closed: it exits with the
# first nonzero swift status, and with 1 when no process ran a test. swift test exits 0 when a
# filter matches no test, so the script reads the two no-test strings of mutate.py; one string
# alone means that tests ran. Each process runs through scripts/swift-test.sh, so a process
# that ends with exit 0 and no report line fails.
# A name can match no test while the other names run tests. When a name shows in no started line
# of the test output ("◇ Test <name>(" with --exact; else "◇ Test" or "◇ Suite" with the name in
# the text), the script makes one `swift test list --skip-build` call. It exits 1 with
# "test-filter: no test ID matches <names>" for each name that no listed ID matches: process 1
# takes the IDs that it does not skip, and process 2 the CLI IDs of a name that a CLI file has.
# A list exit 75 gives exit 75. Any other list failure gives exit 1 and "test list failed".
# With --exact, each name is the whole name of a Swift Testing test: the filter is '/<name>\(' with
# the regex characters escaped, so a name that is a prefix of another test name runs only its own
# test. The CLI process then takes a name that a CLI test file has as 'func <name>('. With
# --no-parallel, both swift calls get --no-parallel (a rerun of slow tests, scripts/run-checks.sh).
# With --skip-build, both swift calls get --skip-build --disable-xctest (a mutant that its build
# command built already), and the Swift Testing no-test string alone means that no test ran.
# Usage: scripts/test-filter.sh [--exact] [--no-parallel] [--skip-build] <name>...
#        make test-filter FILTER='<name> <name>'
# scripts/test-filter.test.sh tests it.
set -euo pipefail
exact=0 serial=0 built=0
while [[ "${1:-}" =~ ^--(exact|no-parallel|skip-build)$ ]]; do
    case "$1" in --exact) exact=1 ;; --no-parallel) serial=1 ;; *) built=1 ;; esac
    shift
done
[[ $# -gt 0 ]] || { echo "usage: scripts/test-filter.sh [--exact] [--no-parallel] [--skip-build] <test or suite name>..." >&2; exit 2; }
cd "$(dirname "$0")/.."
out="$(mktemp)" started="$(mktemp)"
trap 'rm -f "$out" "$started"' EXIT

ran=0 status=0
# run <swift test arguments>: keeps the first nonzero swift status; sets ran when tests ran, and
# adds the started lines of the test output to $started.
run() {
    local code=0
    scripts/swift-test.sh "$@" 2>&1 | tee "$out" || code=$?
    grep -E '^◇ (Test|Suite) .* started\.$' "$out" | grep -vxF '◇ Test run started.' >> "$started" || true
    [[ $status -ne 0 ]] || status=$code
    { [[ $built -eq 1 ]] || grep -qF 'No matching test cases were run' "$out"; } && grep -qF 'Test run with 0 tests' "$out" || ran=1
}

p1=(--skip AppBundleTests --skip DiskImageTests --skip DirigibleCLITests) p2=()
names=("$@") rx=() inCLI=()
for name in "$@"; do
    cli=0
    if [[ $exact -eq 1 ]]; then
        anchored="/$(sed 's/[][\.*^$+?(){}|/]/\\&/g' <<<"$name")\\("
        p1+=(--filter "$anchored")
        grep -rqF -- "func $name(" Tests/DirigibleCLITests 2>/dev/null && { p2+=(--filter "DirigibleCLITests.*$anchored"); cli=1; }
        rx+=("$anchored")
    else
        p1+=(--filter "$name")
        grep -rqF -- "$name" Tests/DirigibleCLITests 2>/dev/null && { p2+=(--filter "DirigibleCLITests.*$name"); cli=1; }
        rx+=("$name")
    fi
    inCLI+=("$cli")
done
[[ $serial -eq 0 ]] || { p1+=(--no-parallel); [[ ${#p2[@]} -eq 0 ]] || p2+=(--no-parallel); }
[[ $built -eq 0 ]] || { p1+=(--skip-build --disable-xctest); [[ ${#p2[@]} -eq 0 ]] || p2+=(--skip-build --disable-xctest); }
run "${p1[@]}"
[[ ${#p2[@]} -eq 0 ]] || run "${p2[@]}"
[[ $status -eq 0 ]] || exit $status
[[ $ran -eq 1 ]] || { echo "test-filter: no test matched $*" >&2; exit 1; }

# A name that shows in no started line gets the list check. The text of the started lines is kept
# in a variable and read with a here-string: grep -q on a pipe can end the writer early.
shown="$(sed -E 's/^◇ (Test|Suite) (.*) started\.$/\2/' "$started")"
unseen=()
for i in "${!names[@]}"; do
    if [[ $exact -eq 1 ]]; then
        grep -Eq -- "^◇ Test ${rx[$i]#/}" "$started" || unseen+=("$i")
    else
        grep -qF -- "${names[$i]}" <<<"$shown" || unseen+=("$i")
    fi
done
[[ ${#unseen[@]} -gt 0 ]] || exit 0
list_args=(test list --skip-build)
[[ $built -eq 0 ]] || list_args+=(--disable-xctest)
list_code=0
listing="$(scripts/with-lock.sh swift "${list_args[@]}")" || list_code=$?
[[ $list_code -ne 75 ]] || exit 75
[[ $list_code -eq 0 ]] || { echo "test-filter: test list failed (exit $list_code)" >&2; exit 1; }
ids="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*\.[^[:space:]]+$' <<<"$listing" || true)"
p1_ids="$(grep -vE 'AppBundleTests|DiskImageTests|DirigibleCLITests' <<<"$ids" || true)"
cli_ids="$(grep -E 'DirigibleCLITests' <<<"$ids" || true)"
missing=()
for i in "${unseen[@]}"; do
    grep -Eq -- "${rx[$i]}" <<<"$p1_ids" && continue
    [[ ${inCLI[$i]} -eq 1 ]] && grep -Eq -- "DirigibleCLITests.*${rx[$i]}" <<<"$cli_ids" && continue
    missing+=("${names[$i]}")
done
[[ ${#missing[@]} -eq 0 ]] || { echo "test-filter: no test ID matches ${missing[*]}" >&2; exit 1; }
