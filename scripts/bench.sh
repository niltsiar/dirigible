#!/bin/bash
# Runs the slow tests that match a filter in an optimized build (-c release, no DEBUG).
# `swift test -c release` in this package runs the @main of an executable target, not the tests.
# So the script copies the package to .build/bench, makes each executable target a library,
# removes its @main, and runs the tests in that copy. Tests that start the `dirigible` binary
# do not work in the copy.
# Usage: scripts/bench.sh <test filter>, for example scripts/bench.sh LaneRenderBenchmark
set -euo pipefail
filter="${1:?usage: scripts/bench.sh <test filter>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
# The cost review of reflect (cost.sh) counts a repeat by the commit and the filter of this line.
tree=clean
[[ -z "$(git -C "$root" status --porcelain)" ]] || tree=dirty
echo "bench: commit $(git -C "$root" rev-parse HEAD) tree $tree filter $filter"
copy="$root/.build/bench"
mkdir -p "$copy"
rsync -a --delete --exclude .build "$root/Package.swift" "$root/Package.resolved" "$root/Sources" "$root/Tests" "$copy/"
cd "$copy"
sed -i '' -e 's/\.executableTarget(/.target(/' -e '/\.executable(name:/d' Package.swift
grep -rl '^@main$' Sources | xargs sed -i '' 's/^@main$//'
swift build -c release -Xswiftc -enable-testing --build-tests
# Another tree that builds or tests slows the timed run (DLV-157): wait for a load under
# BENCH_LOAD_MAX (default 4) and no test of another tree. The load lines show what the run had.
CHECK_LOAD_MAX="${BENCH_LOAD_MAX:-4}" "$root/scripts/check-changed.sh" --wait-load bench
load() { echo "bench: load $(sysctl -n vm.loadavg | awk '{ print $2 }')"; }
load
code=0
DIRIGIBLE_SLOW_TESTS=1 swift test -c release -Xswiftc -enable-testing --skip-build --no-parallel --filter "$filter" || code=$?
load
exit "$code"
