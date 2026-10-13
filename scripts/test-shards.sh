#!/bin/bash
# Run all tests except AppBundleTests and DiskImageTests (make test) in shards at the same time
# after one build. One process holds the main actor of its tests, so the main-actor suites of
# DirigibleTests wait in one queue; shards give each its own main thread (run 2026-10-13-test-speed:
# 600 s in two processes in sequence, 350 s in 5 shards on 4 cores).
# Steps: swift build --build-tests; --list-tests of the bundle; the tests split by their key (the
# ID up to the first slash: a suite, or a free function) over TEST_SHARDS shards (default 4), with
# the largest keys first into the shard with the least seconds (scripts/test-shards.weights: the
# seconds of each suite alone; after a big test change, run each module with test-helper.sh
# --no-parallel and add the "passed after <s> seconds" of each test into its suite line); the CLI
# tests in a shard of their own, because their fixture I/O slows the main actor of the other
# tests (in one process, the stall tripped the 60 s DeviceEventTests watchdog in 3 of 40 runs). Each
# shard runs the bundle through scripts/test-helper.sh with --filter '^(<keys>)(/|$)'.
# Each shard log is .build/test-shards/shard-<n>.log. The script prints each log whole, in shard
# order, after all shards end, so scripts/run-checks.sh reads each failed-test line. A shard that
# crashes, exits 0 with no report line, runs fewer tests than it listed, or matches no test prints
# "test-shards: shard <n>: the test process ended before its report": run-checks.sh then reruns
# nothing, because a lost test is never a flake. A shard with a failed test and a full report is a
# normal failure. The last line is "test-shards: <run> of <listed> tests in <s> s". The exit is 0
# only when each shard passed.
# The script holds the build lock (with-lock.sh) once for the build, the list, and the shards.
# INT, TERM, or an exit stops each shard process; on a stop, it prints the tail of each shard.
# Usage: [TEST_SHARDS=<n>] scripts/test-shards.sh
# scripts/test-shards.test.sh tests it.
set -uo pipefail
# with-lock.sh runs this script again with the marker, and the marker stops a second wrap.
[[ "${DIRIGIBLE_LOCKED_SCRIPT:-}" == "$0" ]] || DIRIGIBLE_LOCKED_SCRIPT="$0" exec "$(dirname "$0")/with-lock.sh" "$0" "$@"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 1
n="${TEST_SHARDS:-4}"
[[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "test-shards: TEST_SHARDS must be a count: $n" >&2; exit 2; }
helper="$root/scripts/test-helper.sh"
bundle="$root/.build/debug/DirigiblePackageTests.xctest/Contents/MacOS/DirigiblePackageTests"
logs="$root/.build/test-shards"
start=$SECONDS

swift build --build-tests || { echo "test-shards: the build failed" >&2; exit 1; }
mkdir -p "$logs"
rm -f "$logs"/shard-*.log
list="$logs/list.txt"
"$helper" --test-bundle-path "$bundle" --testing-library swift-testing --list-tests > "$list" ||
    { echo "test-shards: the test list failed" >&2; cat "$list" >&2; exit 1; }
grep -vE '^DirigibleTests\.(AppBundleTests|DiskImageTests)/' "$list" | grep -E '^[A-Za-z0-9_]+\.' > "$logs/ids.txt"
[[ -s "$logs/ids.txt" ]] || { echo "test-shards: the list has no test" >&2; exit 1; }

# The shards: "<shard> <test count> <key>" lines, with the CLI key alone in shard cli. The weight
# of a key is its seconds alone in scripts/test-shards.weights, else 0.5 s for each test.
weights="$root/scripts/test-shards.weights"
cut -d/ -f1 "$logs/ids.txt" | sort | uniq -c | awk -v file="$weights" '
    BEGIN { while ((getline line < file) > 0) { split(line, f, "\t"); w[f[1]] = f[2] } }
    { print ($2 in w) ? w[$2] : $1 * 0.5, $1, $2 }' | sort -k1,1nr -k3,3 | awk -v n="$n" '
    $3 ~ /^DirigibleCLITests\./ { cli += $2; next }
    { b = 1; for (i = 2; i <= n; i++) if (load[i] < load[b]) b = i; load[b] += $1; print b, $2, $3 }
    END { if (cli) print "cli", cli, "DirigibleCLITests\\." }' > "$logs/shards.txt"

pids=() names=()
stop() {
    local p
    for p in ${pids[@]+"${pids[@]}"}; do kill -TERM "$p" 2>/dev/null; done
    for p in ${pids[@]+"${pids[@]}"}; do wait "$p" 2>/dev/null; done
}
interrupted() {
    trap - INT TERM
    stop
    local s
    for s in ${names[@]+"${names[@]}"}; do
        echo "test-shards: shard $s stopped; the end of its log:"
        tail -n 20 "$logs/shard-$s.log"
    done
    exit 130
}
trap interrupted INT TERM
trap stop EXIT

for s in $(cut -d' ' -f1 "$logs/shards.txt" | awk '!seen[$0]++'); do
    # The key of a CLI shard is already a regex; each other key is escaped.
    keys="$(awk -v s="$s" '$1 == s { k = $3; if (s != "cli") gsub(/[][\\.*^$+?(){}|\/]/, "\\\\&", k); printf "%s%s", sep, k; sep = "|" }' "$logs/shards.txt")"
    filter="^($keys)(/|\$)"
    [[ "$s" != cli ]] || filter="^($keys)"
    "$helper" --test-bundle-path "$bundle" --testing-library swift-testing --filter "$filter" > "$logs/shard-$s.log" 2>&1 &
    pids+=($!) names+=("$s")
done

listed=0 total=0 failed=0 messages=()
for i in "${!pids[@]}"; do
    s="${names[$i]}" log="$logs/shard-${names[$i]}.log"
    wait "${pids[$i]}"
    code=$?
    want="$(awk -v s="$s" '$1 == s { t += $2 } END { print t + 0 }' "$logs/shards.txt")"
    got="$(sed -nE 's/.*Test run with ([0-9]+) tests? in .*/\1/p' "$log" | tail -n 1)"
    listed=$((listed + want)) total=$((total + ${got:-0}))
    lost=""
    if [[ -z "$got" ]]; then lost="no report line, exit $code"
    elif [[ "$got" -eq 0 ]]; then lost="no test matched, exit $code"
    elif [[ "$got" -ne "$want" ]]; then
        messages+=("test-shards: shard $s ran $got of $want tests")
        lost="$got of $want tests"
    elif [[ $code -ne 0 ]] && ! grep -qE '^✘ Test .* failed after' "$log"; then lost="exit $code with no failed test"
    fi
    if [[ -n "$lost" ]]; then
        messages+=("test-shards: shard $s: the test process ended before its report ($lost)")
        failed=1
    elif [[ $code -ne 0 ]]; then failed=1
    fi
done
pids=()
trap - INT TERM

for s in "${names[@]}"; do
    echo "test-shards: shard $s ($logs/shard-$s.log)"
    cat "$logs/shard-$s.log"
done
for m in ${messages[@]+"${messages[@]}"}; do echo "$m"; done
echo "test-shards: $total of $listed tests in $((SECONDS - start)) s"
exit "$failed"
