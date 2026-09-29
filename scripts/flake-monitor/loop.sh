#!/bin/bash
# Runs `make test` with the flake monitor (Tests/DirigibleAudioTests/FlakeMonitor.swift) for the
# runs <first> to <last>, and appends one line for each run to <out folder>/summary.txt. The log
# of run i is <out folder>/<tag>-<i>.log, and its monitor folder is <out folder>/<tag>-<i>/.
# Usage: scripts/flake-monitor/loop.sh <tag> <first> <last> <out folder> [repo]
#        scripts/flake-monitor/loop.sh --summary <tag> <run> <exit> <wall> <load> <begin> <log>
# The second form prints the summary line of one log. loop.test.sh calls it.
set -uo pipefail

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
    failed=$(grep -oE '✘ Test [A-Za-z0-9_]+\(' "$log" | sed -E 's/.*Test ([A-Za-z0-9_]+).*/\1/' | sort -u | paste -sd' ' -)
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

[[ $# -ge 4 ]] || { echo "usage: loop.sh <tag> <first> <last> <out folder> [repo]" >&2; exit 2; }
tag="$1" first="$2" last="$3"
mkdir -p "$4"
out="$(cd "$4" && pwd -P)"
cd "${5:-$(dirname "$0")/../..}" || exit 2
for i in $(seq "$first" "$last"); do
    log="$out/$tag-$i.log"
    load=$(sysctl -n vm.loadavg | awk '{print $2}')
    uptime
    begin=$(date +%s)
    DIRIGIBLE_FLAKE_MONITOR="$out/$tag-$i" make test > "$log" 2>&1
    code=$?
    wall=$(($(date +%s) - begin))
    summary "$tag" "$i" "$code" "$wall" "$load" "$begin" "$log" | tee -a "$out/summary.txt"
done
uptime
