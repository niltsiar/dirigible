#!/bin/bash
# Run all tests except AppBundleTests and DiskImageTests (make test) in shards at the same time
# after one build. One process holds the main actor of its tests, so the main-actor suites of
# DirigibleTests wait in one queue; shards give each its own main thread. On 4 cores: 600 s in two
# processes in sequence; shards of 330 s in 4 processes, and 385 s with 3 failed waits in 3.
# Steps: swift build --build-tests; --list-tests of the bundle; the tests split by their key (the
# ID up to the first slash: a suite, or a free function) over TEST_SHARDS - 1 shards, with
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
# normal failure. Each shard writes journals to the empty folder .build/test-shards/default-logs
# (DIRIGIBLE_LOG_FOLDER): a test that starts a front end passes its own folder, so a file there
# fails the run with "test-shards: a test wrote a journal to the default log folder: <names>"
# (decision 0059). The last line is "test-shards: <run> of <listed> tests in <s> s". The exit is 0
# only when each shard passed.
# The script holds the build lock (with-lock.sh) once for the build, the list, and the shards.
# INT, TERM, or an exit stops each shard process; on INT (exit 130) or TERM (exit 143), it
# prints the tail of each shard that still ran.
# The list step and each shard have a limit of L seconds: TEST_SHARD_LIMIT (whole seconds, 0 for
# none), else max(2400, 1.5 x the newest push-check hold of dirigible-build-holds.log in the git
# common dir: the last line whose command has check-changed and BASE=, with no fifth column
# limit). The script prints "test-shards: each shard has a limit of
# <L> s" before the build. A step past L gets TERM, then KILL 10 s later, only while its pid is a
# live child of this script. A shard past L prints "test-shards: shard <n>: the test process
# ended before its report (over its limit of <L> s)", and the run fails after the other shards
# end. A list past L prints "test-shards: the test list: the test process ended before its report
# (over its limit of <L> s)", starts no shard, and exits 1. run-checks.sh reruns nothing after
# either line. A limit also creates <lock>/shard-limit, so with-lock.sh writes the column limit
# on the hold line: a push check that a limit ended is no base of L. .build/test-shards/steps.log
# gets one line for each step event: "<ISO time> list start", "list end", "list limit", "shard
# <n> start", "shard <n> end", "shard <n> limit". After a hang, the last step that started names it.
# The full suite runs only in the push check. A call without DIRIGIBLE_PUSH_CHECK=1 (run-checks.sh
# sets it for a run with BASE) or DIRIGIBLE_FULL_SUITE=1 (a person sets it) prints the reason and
# exits 1, before the build. make test and make check reach this script. An outer
# with-lock.sh call still waits for the lock first.
# Usage: [TEST_SHARDS=<processes, the CLI shard in the count; default: the physical cores>]
#        [TEST_SHARD_LIMIT=<seconds>] scripts/test-shards.sh
# scripts/test-shards.test.sh tests it.
set -uo pipefail
if [[ "${DIRIGIBLE_PUSH_CHECK:-}" != 1 && "${DIRIGIBLE_FULL_SUITE:-}" != 1 ]]; then
    echo "test-shards: the full suite runs only in the push check: make check-changed BASE=origin/main. A slice runs make check-changed FILTER='<name> <name>'. A person who needs the full suite sets DIRIGIBLE_FULL_SUITE=1." >&2
    exit 1
fi
# with-lock.sh runs this script again with the marker, and the marker stops a second wrap.
[[ "${DIRIGIBLE_LOCKED_SCRIPT:-}" == "$0" ]] || DIRIGIBLE_LOCKED_SCRIPT="$0" exec "$(dirname "$0")/with-lock.sh" "$0" "$@"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 1
# The count of test processes, the CLI shard in it: one for each physical core. More processes
# than cores starve the main actor of each one.
total="${TEST_SHARDS:-$(sysctl -n hw.physicalcpu 2>/dev/null || echo 4)}"
[[ "$total" =~ ^[1-9][0-9]*$ ]] || { echo "test-shards: TEST_SHARDS must be a count: $total" >&2; exit 2; }
n=$((total > 1 ? total - 1 : 1))
helper="$root/scripts/test-helper.sh"
bundle="$root/.build/debug/DirigiblePackageTests.xctest/Contents/MacOS/DirigiblePackageTests"
logs="$root/.build/test-shards"
steps="$logs/steps.log"
common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)" || { echo "test-shards: no git folder" >&2; exit 2; }
lock="$common/dirigible-build.lock"
start=$SECONDS

# The limit L of each step (header).
limit="${TEST_SHARD_LIMIT:-}"
if [[ -z "$limit" ]]; then
    limit="$(awk -F'\t' '$3 ~ /check-changed/ && $3 ~ /BASE=/ && $5 != "limit" { s = $2 } END { s *= 1.5; s = (s > int(s)) ? int(s) + 1 : s; print (s < 2400) ? 2400 : s }' "$common/dirigible-build-holds.log" 2>/dev/null)"
    limit="${limit:-2400}"
fi
[[ "$limit" =~ ^[0-9]+$ ]] || { echo "test-shards: TEST_SHARD_LIMIT must be whole seconds, or 0 for no limit: $limit" >&2; exit 2; }
limit=$((10#$limit))
if [[ $limit -gt 0 ]]; then echo "test-shards: each shard has a limit of $limit s"; else echo "test-shards: no shard limit (TEST_SHARD_LIMIT=0)"; fi

swift build --build-tests || { echo "test-shards: the build failed" >&2; exit 1; }
mkdir -p "$logs"
rm -f "$logs"/shard-*.log "$logs"/limit-*
: > "$steps"
guard="$logs/default-logs"
rm -rf "$guard" && mkdir "$guard" || { echo "test-shards: no folder $guard" >&2; exit 1; }
export DIRIGIBLE_LOG_FOLDER="$guard"
list="$logs/list.txt"
step_log() { echo "$(date +%FT%T) $*" >> "$steps"; }
# live_child <pid>: succeeds while the pid is a child of this script and no zombie (a shard that
# ended waits for its turn in the wait loop below).
live_child() {
    local out
    out="$(ps -o ppid=,stat= -p "$1" 2>/dev/null)" || return 1
    set -- $out
    [[ "${1:-}" == "$$" && "${2:-Z}" != Z* ]]
}
watchers=()
# watch <pid> <step>: a poll watcher, in the form of the one in with-lock.sh. It ends with its step
# or with this script. At L it acts only on a live child: it writes the marker, the line of
# steps.log, and the lock file, sends TERM, and sends KILL 10 s later.
watch() {
    [[ $limit -gt 0 ]] || return 0
    (
        end=$(($(date +%s) + limit))
        while kill -0 "$1" 2>/dev/null && kill -0 $$ 2>/dev/null && [[ $(date +%s) -lt $end ]]; do /bin/sleep 1; done
        kill -0 $$ 2>/dev/null && live_child "$1" || exit 0
        : > "$logs/limit-${2// /-}"
        echo "$(date +%FT%T) $2 limit" >> "$steps"
        [[ "$(cat "$lock/pid" 2>/dev/null)" != "${DIRIGIBLE_BUILD_LOCK:-none}" ]] || : > "$lock/shard-limit"
        kill -TERM "$1"
        /bin/sleep 10
        ! live_child "$1" || kill -KILL "$1"
    ) > /dev/null 2>&1 &
    watchers+=($!)
}
pids=() names=()
stop() {
    local p
    # A shard that ended gave its number back: signal a pid only while it is still a child of this shell.
    for p in ${pids[@]+"${pids[@]}"}; do
        [[ "$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" != "$$" ]] || kill -TERM "$p" 2>/dev/null
    done
    for p in ${pids[@]+"${pids[@]}"}; do wait "$p" 2>/dev/null; done
    for p in ${watchers[@]+"${watchers[@]}"}; do ! kill -0 "$p" 2>/dev/null || kill "$p" 2>/dev/null; done
}
interrupted() {
    trap - INT TERM
    local i running=()
    for i in ${pids[@]+"${!pids[@]}"}; do kill -0 "${pids[$i]}" 2>/dev/null && running+=("${names[$i]}"); done
    stop
    local s
    for s in ${running[@]+"${running[@]}"}; do
        echo "test-shards: shard $s stopped; the end of its log:"
        if [[ $s == list ]]; then tail -n 20 "$list"; else tail -n 20 "$logs/shard-$s.log"; fi
    done
    exit "$1"
}
trap 'interrupted 130' INT
trap 'interrupted 143' TERM
trap stop EXIT

step_log list start
"$helper" --test-bundle-path "$bundle" --testing-library swift-testing --list-tests > "$list" &
listpid=$!
pids+=($listpid) names+=(list)
watch $listpid list
wait $listpid
code=$?
step_log list end
pids=() names=()
if [[ -e "$logs/limit-list" ]]; then
    echo "test-shards: the test list: the test process ended before its report (over its limit of $limit s)" >&2
    exit 1
fi
[[ $code -eq 0 ]] || { echo "test-shards: the test list failed" >&2; cat "$list" >&2; exit 1; }
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

# A stale weights file: the keys with no weight (no CLI key: its shard has no split) and the weight
# keys with no test, on one line.
stale=""
if [[ -f "$weights" ]]; then
    keys="$(cut -d/ -f1 "$logs/ids.txt" | grep -v '^DirigibleCLITests\.' | sort -u)"
    known="$(cut -f1 "$weights" | sort -u)"
    missing="$(comm -23 <(echo "$keys") <(echo "$known") | paste -sd' ' -)"
    gone="$(comm -13 <(echo "$keys") <(echo "$known") | paste -sd' ' -)"
    [[ -z "$missing$gone" ]] || stale="test-shards: stale weights: no weight: ${missing:-none}; no test: ${gone:-none}"
fi

for s in $(cut -d' ' -f1 "$logs/shards.txt" | awk '!seen[$0]++'); do
    # The key of a CLI shard is already a regex; each other key is escaped.
    keys="$(awk -v s="$s" '$1 == s { k = $3; if (s != "cli") gsub(/[][\\.*^$+?(){}|\/]/, "\\\\&", k); printf "%s%s", sep, k; sep = "|" }' "$logs/shards.txt")"
    filter="^($keys)(/|\$)"
    [[ "$s" != cli ]] || filter="^($keys)"
    step_log "shard $s start"
    "$helper" --test-bundle-path "$bundle" --testing-library swift-testing --filter "$filter" > "$logs/shard-$s.log" 2>&1 &
    pids+=($!) names+=("$s")
    watch $! "shard $s"
done

listed=0 total=0 failed=0 messages=()
for i in "${!pids[@]}"; do
    s="${names[$i]}" log="$logs/shard-${names[$i]}.log"
    wait "${pids[$i]}"
    code=$?
    step_log "shard $s end"
    want="$(awk -v s="$s" '$1 == s { t += $2 } END { print t + 0 }' "$logs/shards.txt")"
    # Swift Testing writes " in <n> suites" (also "in 0 suites" for free functions); the part is optional.
    got="$(sed -nE 's/.*Test run with ([0-9]+) tests?( in [0-9]+ suites?)? (passed|failed) .*/\1/p' "$log" | tail -n 1)"
    listed=$((listed + want)) total=$((total + ${got:-0}))
    lost=""
    if [[ -e "$logs/limit-shard-$s" ]]; then lost="over its limit of $limit s"
    elif [[ -z "$got" ]]; then lost="no report line, exit $code"
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
written="$(ls -A "$guard" | paste -sd' ' -)"
if [[ -n "$written" ]]; then
    messages+=("test-shards: a test wrote a journal to the default log folder: $written")
    failed=1
fi

for s in "${names[@]}"; do
    echo "test-shards: shard $s ($logs/shard-$s.log)"
    cat "$logs/shard-$s.log"
done
for m in ${messages[@]+"${messages[@]}"}; do echo "$m"; done
[[ -z "$stale" ]] || echo "$stale"
echo "test-shards: $total of $listed tests in $((SECONDS - start)) s"
exit "$failed"
