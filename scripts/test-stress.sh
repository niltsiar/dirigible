#!/bin/bash
# Run the test suite (or the tests of a filter) under load: 2 x hw.ncpu busy processes, so a test
# that waits on the wall clock fails the way it does in a busy push check. The lane is the baseline
# of red tests under load for the plan that makes tests independent of CPU load.
# Usage: scripts/test-stress.sh [--runs <n>] [--filter '<names>'] <out folder>
# The script takes the build lock itself, as scripts/flake-monitor/loop.sh does (the
# DIRIGIBLE_LOCKED_SCRIPT marker), with WITH_LOCK_MAX_WAIT=0 and, unless the caller sets it,
# WITH_LOCK_MAX_HOLD=6600: one call holds the lock for at most 6600 s, under the 7200 s limit of a
# Bash background call. A full-suite call (no --filter) runs shards with TEST_SHARD_LIMIT = the hold
# / <runs> / 2 s, and test-shards.sh refuses a limit under 2400 s. So a full-suite call whose hold
# gives a shard under 2400 s exits 2 before the lock, with a message that names the largest --runs
# that fits. The default hold fits --runs 1. A --filter call has no run limit and no floor:
# test-filter.sh reads no TEST_SHARD_LIMIT, so the hold bounds the whole call, and a hung run keeps
# the lock until the hold ends it with exit 124. A hold of 0 is no limit. A call that holds the lock
# already (DIRIGIBLE_BUILD_LOCK set, no marker of this script) exits 2: an outer hold limit would
# end the lane in exit 124. An out folder that holds a summary.txt exits 2.
# Inside the lock: it starts 2 x hw.ncpu busy processes (pids in <out folder>/busy.pids) and waits
# until the 1-minute load average is at or over hw.ncpu (a check each 5 s, 36 checks, else exit 3
# with "test-stress: the load source made no load"). Then it runs scripts/flake-monitor/loop.sh
# --min-load <hw.ncpu> with the tag stress, the runs 1 to <n>, and --filter when given. A
# full-suite call exports TEST_SHARD_LIMIT (test-shards.sh then stops a shard past it).
# Each lane process stays in the process group of this script, which with-lock.sh starts as a group
# leader. INT or TERM is ignored by the trap, which sends TERM to the group, waits for loop.sh, and
# exits 130 or 143, so the lock goes after the last lane process. A KILL of the outer with-lock.sh
# leaves the group alive with the lock held, as for any with-lock.sh command. The EXIT trap stops
# the busy processes.
# After the runs it prints "test-stress: <name> red in <k> of <n> runs" for each failed test (most
# reds first), "test-stress: run <i> ended with exit <code> and no failed test" for a run with a
# nonzero exit and no failed test, "test-stress: the loop ended with exit <code> after <k> of <n>
# runs" for a loop that stopped early, and last "test-stress: <t> red tests in <n> runs at a 1-minute
# load of <l>" (<l> is the lowest load at the start of a run). The exit is 0 only with no such line.
# scripts/test-stress.test.sh tests it.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
args=("$@")
runs=1 filter=""
while [[ "${1:-}" == --runs || "${1:-}" == --filter ]]; do
    [[ $# -ge 2 ]] || break
    if [[ "$1" == --runs ]]; then runs="$2"; else filter="$2"; fi
    shift 2
done
usage="usage: scripts/test-stress.sh [--runs <n>] [--filter '<names>'] <out folder>"
[[ $# -eq 1 && "$runs" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "$usage" >&2; exit 2; }
out="$1"

if [[ "${DIRIGIBLE_LOCKED_SCRIPT:-}" != "$0" ]]; then
    if [[ -n "${DIRIGIBLE_BUILD_LOCK:-}" ]]; then
        echo "test-stress: run it with no with-lock.sh word; it takes the lock with its own hold limit" >&2
        exit 2
    fi
    if [[ -e "$out/summary.txt" ]]; then
        echo "test-stress: $out holds a summary.txt; use a new out folder" >&2
        exit 2
    fi
    export WITH_LOCK_MAX_WAIT=0
    export WITH_LOCK_MAX_HOLD="${WITH_LOCK_MAX_HOLD:-6600}"
    hold="$WITH_LOCK_MAX_HOLD"
    if [[ "$hold" =~ ^[1-9][0-9]{0,14}$ ]]; then
        if [[ -z "$filter" && $hold -lt $((4800 * runs)) ]]; then
            fit="the largest --runs that fits is $((hold / 4800)), or"
            [[ $hold -ge 4800 ]] || fit="no --runs fits, so"
            echo "test-stress: --runs $runs with a hold of $hold s gives each shard $((hold / runs / 2)) s, under the floor of 2400 s; $fit set WITH_LOCK_MAX_HOLD to $((4800 * runs)) or more" >&2
            exit 2
        fi
    fi
    DIRIGIBLE_LOCKED_SCRIPT="$0" exec "$here/with-lock.sh" "$0" "${args[@]}"
fi

mkdir -p "$out"
out="$(cd "$out" && pwd -P)"
ncpu="$(sysctl -n hw.ncpu)"
load() { sysctl -n vm.loadavg | awk '{print $2}'; }
hold="${WITH_LOCK_MAX_HOLD:-0}"
[[ -n "$filter" ]] || export TEST_SHARD_LIMIT=$((hold / runs / 2))

busy=()
looppid=""
stop_busy() {
    local p
    for p in ${busy[@]+"${busy[@]}"}; do kill "$p" 2>/dev/null; done
    for p in ${busy[@]+"${busy[@]}"}; do wait "$p" 2>/dev/null; done
}
terminated() {
    trap '' INT TERM
    kill -TERM -- "-$$" 2>/dev/null
    [[ -z "$looppid" ]] || { kill -TERM "$looppid" 2>/dev/null; wait "$looppid" 2>/dev/null; }
    exit "$1"
}
trap 'terminated 130' INT
trap 'terminated 143' TERM
trap stop_busy EXIT

: > "$out/busy.pids"
for _ in $(seq $((2 * ncpu))); do
    yes > /dev/null &
    busy+=($!)
    echo $! >> "$out/busy.pids"
done
made=""
for _ in $(seq 36); do
    if awk -v l="$(load)" -v m="$ncpu" 'BEGIN { exit !(l >= m) }'; then made=1; break; fi
    sleep 5
done
[[ -n "$made" ]] || { echo "test-stress: the load source made no load" >&2; exit 3; }

loop=("$here/flake-monitor/loop.sh" --min-load "$ncpu")
[[ -z "$filter" ]] || loop+=(--filter "$filter")
"${loop[@]}" stress 1 "$runs" "$out" &
looppid=$!
wait "$looppid"
code=$?
looppid=""

summary="$out/summary.txt"
[[ -f "$summary" ]] || : > "$summary"
status=0
# Each failed test with its count of runs (most first), the runs with an exit and no failed test,
# and the lowest start load.
awk -v runs="$runs" '
    { code = $3; sub(/^exit=/, "", code); l = $5; sub(/^load=/, "", l)
      if (!n++ || l + 0 < low + 0) low = l
      list = ""; if (match($0, /failed=\[[^]]*\]/)) list = substr($0, RSTART + 8, RLENGTH - 9)
      k = split(list, names, " ")
      for (i = 1; i <= k; i++) red[names[i]]++
      if (code != 0 && k == 0) print "NOTEST\t" $2 "\t" code }
    END { for (t in red) { total++; print "RED\t" red[t] "\t" t }; print "TOTAL\t" total + 0 "\t" (n ? low : 0) }' "$summary" |
    sort -t$'\t' -k1,1 -k2,2nr -k3,3 > "$out/table.tsv"
while IFS=$'\t' read -r kind a b; do
    case "$kind" in
        NOTEST) echo "test-stress: run $a ended with exit $b and no failed test"; status=1 ;;
        RED) echo "test-stress: $b red in $a of $runs runs"; status=1 ;;
    esac
done < "$out/table.tsv"
lines="$(wc -l < "$summary" | tr -d ' ')"
if [[ $code -ne 0 && $lines -lt $runs ]]; then
    echo "test-stress: the loop ended with exit $code after $lines of $runs runs"
    status=1
fi
IFS=$'\t' read -r _ total low < <(grep '^TOTAL' "$out/table.tsv")
echo "test-stress: $total red tests in $runs runs at a 1-minute load of $low"
exit "$status"
