#!/bin/bash
# Runs the slow tests that match a filter in an optimized build (-c release, no DEBUG).
# `swift test -c release` in this package runs the @main of an executable target, not the tests.
# So the script copies the package to .build/bench, makes each executable target a library,
# removes its @main, and runs the tests in that copy. Tests that start the `dirigible` binary
# do not work in the copy.
# The script holds the build lock (with-lock.sh) for the build and the timed run. Under the hold of
# a caller (bench-pairs.sh, or an outer with-lock.sh call), it runs at once.
# Usage: scripts/bench.sh [--trace <file> [--under <frame>]] <name> [<name>...], for example
#        scripts/bench.sh LaneRenderBenchmark
# The names, also with spaces in one argument (make bench FILTER='<name> <name>'), join into one
# --filter '<name>|<name>'. A test run whose output has both no-test strings of test-filter.sh
# ran no test: the script exits 1.
# With --trace <file>, xctrace records a Time Profiler trace of the test run into <file> (a new
# path), through scripts/test-helper.sh, and stops it after BENCH_TRACE_LIMIT (default 10m), so a
# held dialog cannot hold the lock with no end. The trace adds sampling cost: it is not a timing
# verdict, so a failed test (a bench miss) still gives the trace, and the xctrace status does not
# count. The run fails when the output has no "Test run with" line of 1 test or more (a dyld
# failure, a crash, or the time limit), or when the trace has no time-profile table. Else the
# script exports the table to <file>.xml and writes the top leaf frames (scripts/trace-top.py)
# to <file>.top.txt. With --under <frame>, the list counts only the samples under that frame: the
# @inline(never) function of the timed span (NavigationKeyBenchmark.timedSpan), so the fixture
# build and the untimed steps do not count. xctrace finds no Time Profiler template inside
# scripts/probe.sh.
set -euo pipefail
: "${1:?usage: scripts/bench.sh [--trace <file> [--under <frame>]] <name> [<name>...]}"
# with-lock.sh runs this script again with the marker, and the marker stops a second wrap.
[[ "${DIRIGIBLE_LOCKED_SCRIPT:-}" == "$0" ]] || DIRIGIBLE_LOCKED_SCRIPT="$0" exec "$(dirname "$0")/with-lock.sh" "$0" "$@"
trace="" under=()
if [[ "$1" == --trace ]]; then
    : "${3:?usage: scripts/bench.sh --trace <file> [--under <frame>] <name> [<name>...]}"
    # The test step runs in the copy, so a relative path becomes absolute here.
    trace="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
    [[ ! -e "$trace" ]] || { echo "bench: the trace exists: $trace" >&2; exit 2; }
    shift 2
    if [[ "$1" == --under ]]; then
        : "${3:?usage: scripts/bench.sh --trace <file> [--under <frame>] <name> [<name>...]}"
        under=(--under "$2")
        shift 2
    fi
fi
read -ra names <<< "$*"
filter="$(IFS='|'; echo "${names[*]}")"
root="$(cd "$(dirname "$0")/.." && pwd)"
# The cost review of reflect (cost.sh) counts a repeat by the commit and the filter of this line.
# Only a change in a bench input makes the tree dirty (bench-pairs.sh checks the same paths).
tree=clean
[[ -z "$(git -C "$root" status --porcelain -- Sources Tests Package.swift Package.resolved scripts/bench.sh)" ]] || tree=dirty
echo "bench: commit $(git -C "$root" rev-parse HEAD) tree $tree filter $filter"
copy="$root/.build/bench"
mkdir -p "$copy/.build"
# A .build cloned from another checkout holds PCH files with the module cache path of that
# checkout, and the build fails. The stamp holds the copy path of the last build.
stamp="$copy/.build/dirigible-bench-root"
if [[ "$(cat "$stamp" 2>/dev/null)" != "$copy" ]]; then
    find "$copy/.build" -name '*.pch' -delete
    find "$copy/.build" -type d -name ModuleCache -prune -exec rm -rf {} +
    echo "$copy" > "$stamp"
fi
rsync -a --delete --exclude .build "$root/Package.swift" "$root/Package.resolved" "$root/Sources" "$root/Tests" "$copy/"
cd "$copy"
sed -i '' -e 's/\.executableTarget(/.target(/' -e '/\.executable(name:/d' Package.swift
grep -rl '^@main$' Sources | xargs sed -i '' 's/^@main$//'
swift build -c release -Xswiftc -enable-testing --build-tests
# Another tree that builds or tests slows the timed run (DLV-157): wait for no test of another
# tree and a load under the core count (the build above just raised the load, so a lower maximum
# waits the full cap). The load lines show what the run had.
"$root/scripts/check-changed.sh" --wait-load bench
load() { echo "bench: load $(sysctl -n vm.loadavg | awk '{ print $2 }')"; }
load
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
code=0
if [[ -z "$trace" ]]; then
    DIRIGIBLE_SLOW_TESTS=1 swift test -c release -Xswiftc -enable-testing --skip-build --no-parallel --filter "$filter" 2>&1 |
        tee "$out" || code=$?
else
    bundle="$copy/.build/$(uname -m)-apple-macosx/release/DirigiblePackageTests.xctest/Contents/MacOS/DirigiblePackageTests"
    xcrun xctrace record --template 'Time Profiler' --no-prompt --time-limit "${BENCH_TRACE_LIMIT:-10m}" \
        --output "$trace" --env DIRIGIBLE_SLOW_TESTS=1 --target-stdout - --launch -- "$root/scripts/test-helper.sh" \
        --test-bundle-path "$bundle" --testing-library swift-testing --no-parallel --filter "$filter" 2>&1 |
        tee "$out" || true
fi
load
if grep -qF 'No matching test cases were run' "$out" && grep -qF 'Test run with 0 tests' "$out"; then
    echo "bench: no test matched the filter $filter" >&2
    exit 1
fi
[[ -n "$trace" ]] || exit "$code"
grep -qE 'Test run with [1-9]' "$out" ||
    { echo "bench: the traced run printed no Test run with line of 1 test or more (a dyld failure, a crash, or the time limit)" >&2; exit 1; }
# A grep -q on a pipe can stop xcrun with SIGPIPE, so the table list is read first.
toc="$(xcrun xctrace export --input "$trace" --toc)"
grep -qF 'schema="time-profile"' <<<"$toc" || { echo "bench: the trace $trace has no time-profile table" >&2; exit 1; }
xcrun xctrace export --input "$trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' --output "$trace.xml"
"$root/scripts/trace-top.py" ${under[@]+"${under[@]}"} "$trace.xml" | tee "$trace.top.txt"
echo "bench: the trace is $trace, its top leaf frames are in $trace.top.txt"
