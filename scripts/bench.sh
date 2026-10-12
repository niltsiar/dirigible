#!/bin/bash
# Runs the slow tests that match a filter in an optimized build (-c release, no DEBUG).
# `swift test -c release` in this package runs the @main of an executable target, not the tests.
# So the script copies the package to .build/bench, makes each executable target a library,
# removes its @main, and runs the tests in that copy. Tests that start the `dirigible` binary
# do not work in the copy.
# The script holds the build lock (with-lock.sh) for the build and the timed run. Under the hold of
# a caller (bench-pairs.sh, or an outer with-lock.sh call), it runs at once.
# Usage: scripts/bench.sh <test filter>, for example scripts/bench.sh LaneRenderBenchmark
set -euo pipefail
filter="${1:?usage: scripts/bench.sh <test filter>}"
# with-lock.sh runs this script again with the marker, and the marker stops a second wrap.
[[ "${DIRIGIBLE_LOCKED_SCRIPT:-}" == "$0" ]] || DIRIGIBLE_LOCKED_SCRIPT="$0" exec "$(dirname "$0")/with-lock.sh" "$0" "$@"
root="$(cd "$(dirname "$0")/.." && pwd)"
# The cost review of reflect (cost.sh) counts a repeat by the commit and the filter of this line.
tree=clean
[[ -z "$(git -C "$root" status --porcelain)" ]] || tree=dirty
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
code=0
DIRIGIBLE_SLOW_TESTS=1 swift test -c release -Xswiftc -enable-testing --skip-build --no-parallel --filter "$filter" || code=$?
load
exit "$code"
