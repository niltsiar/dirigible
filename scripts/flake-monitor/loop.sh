#!/bin/bash
# Runs `make test` with the flake monitor (Tests/DirigibleAudioTests/FlakeMonitor.swift) for the
# runs <first> to <last>, and appends one line for each run to <out folder>/summary.txt. The log
# of run i is <out folder>/<tag>-<i>.log, and its monitor folder is <out folder>/<tag>-<i>/.
# Usage: scripts/with-lock.sh scripts/flake-monitor/loop.sh [--min-load <n>] <tag> <first> <last> <out folder> [repo]
#        scripts/flake-monitor/loop.sh --summary <tag> <run> <exit> <wall> <load> <begin> <log>
# The second form prints the summary line of one log. loop.test.sh calls it.
# The first form runs under with-lock.sh, so the loop takes the build lock once, outside the loop.
# It sets WITH_LOCK_MAX_WAIT=0: a lock wait in a run never ends in exit 75 and never counts as a
# failed run.
# With --min-load, the loop stops before a run whose 1-minute load average is below <n>. A loop
# under a load source uses it: a load source that makes no load gives the numbers of a quiet loop.
set -uo pipefail
export WITH_LOCK_MAX_WAIT=0

# The summary line: tag, run, exit code, wall seconds, the load average at the start, the start
# of the monitor after the start of `make test`, the durations of the two longest timed tests,
# the worst WAIT of each helper, the highest CLI-CHILDREN peak, the FLAKE-MONITOR numbers, and
# each failed test.
summary() {
    local log="$7" waits monitor start children failed
    duration() { grep -oE "Test $1\(\) (passed|failed) after [0-9.]+" "$log" | awk '{print $NF}'; }
    waits=$(grep -oE '^WAIT [A-Za-z.]+ [0-9.]+' "$log" | sort -k3,3nr | awk '!seen[$2]++ { printf "%s%s=%s", sep, $2, $3; sep = " " }')
    children=$(grep -oE '^CLI-CHILDREN peak [0-9]+' "$log" | awk '{print $3}' | sort -n | tail -1)
    monitor=$(grep -oE 'FLAKE-MONITOR .*' "$log" | head -1)
    start=$(grep -oE 'start [0-9]+' <<< "$monitor" | awk -v begin="$6" '{print $2 - begin}')
    # A test that records a known issue prints ✘ too, but it passes.
    failed=$(grep '✘ Test' "$log" | grep -v 'known issue' | grep -oE '✘ Test [A-Za-z0-9_]+\(' | sed -E 's/.*Test ([A-Za-z0-9_]+).*/\1/' | sort -u | paste -sd' ' -)
    echo "$1 $2 exit=$3 wall=${4}s load=$5 monitor-start=+${start}s" \
        "banner=$(duration theWindowSubtitleFollowsTheTracks)s settle=$(duration settleEndsATakeWhileAPassWaits)s" \
        "waits=[$waits] children=$children monitor=[$(sed -E 's/^FLAKE-MONITOR //; s/, start [0-9]+//' <<< "$monitor")] failed=[$failed]"
}

if [[ "${1:-}" == --summary ]]; then
    shift
    [[ $# -eq 7 ]] || { echo "usage: loop.sh --summary <tag> <run> <exit> <wall> <load> <begin> <log>" >&2; exit 2; }
    summary "$@"
    exit 0
fi

min_load=0
if [[ "${1:-}" == --min-load ]]; then
    min_load="${2:-}"
    shift 2 || true
fi
[[ $# -ge 4 ]] || { echo "usage: loop.sh [--min-load <n>] <tag> <first> <last> <out folder> [repo]" >&2; exit 2; }
tag="$1" first="$2" last="$3"
mkdir -p "$4"
out="$(cd "$4" && pwd -P)"
cd "${5:-$(dirname "$0")/../..}" || exit 2
for i in $(seq "$first" "$last"); do
    log="$out/$tag-$i.log"
    load=$(sysctl -n vm.loadavg | awk '{print $2}')
    uptime
    if awk -v l="$load" -v m="$min_load" 'BEGIN { exit !(l < m) }'; then
        echo "loop.sh: the load $load is below the minimum $min_load before run $i; the loop stops" >&2
        exit 3
    fi
    begin=$(date +%s)
    DIRIGIBLE_FLAKE_MONITOR="$out/$tag-$i" make test > "$log" 2>&1
    code=$?
    wall=$(($(date +%s) - begin))
    summary "$tag" "$i" "$code" "$wall" "$load" "$begin" "$log" | tee -a "$out/summary.txt"
done
uptime
