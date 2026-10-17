#!/bin/bash
# Runs `make test` with the flake monitor (Tests/DirigibleAudioTests/FlakeMonitor.swift) for the
# runs <first> to <last>, and appends one line for each run to <out folder>/summary.txt. The log
# of run i is <out folder>/<tag>-<i>.log, and its monitor folder is <out folder>/<tag>-<i>/.
# Usage: scripts/flake-monitor/loop.sh [--min-load <n>] <tag> <first> <last> <out folder> [repo]
#        scripts/flake-monitor/loop.sh --summary <tag> <run> <exit> <wall> <load> <begin> <log>
# The second form prints the summary line of one log. loop.test.sh calls it.
# The first form runs itself under with-lock.sh (with the DIRIGIBLE_LOCKED_SCRIPT marker, as
# test-shards.sh does), so the loop takes the build lock once, outside the loop. A caller that holds
# the lock already (a nested call) keeps its own hold limit. For its own take, the loop sets
# WITH_LOCK_MAX_HOLD to the run count times 2 times the newest push-check hold in the hold log,
# at least 3600 s, unless the caller sets it.
# It sets WITH_LOCK_MAX_WAIT=0: a lock wait in a run never ends in exit 75 and never counts as a
# failed run. It sets DIRIGIBLE_FULL_SUITE=1: the loop runs the full suite on purpose, and a bare
# make test refuses (test-shards.sh).
# With --min-load, the loop stops before a run whose 1-minute load average is below <n>. A loop
# under a load source uses it: a load source that makes no load gives the numbers of a quiet loop.
set -uo pipefail
export WITH_LOCK_MAX_WAIT=0 DIRIGIBLE_FULL_SUITE=1

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

args=("$@")
min_load=0
if [[ "${1:-}" == --min-load ]]; then
    min_load="${2:-}"
    shift 2 || true
fi
[[ $# -ge 4 && "$2" =~ ^[0-9]+$ && "$3" =~ ^[0-9]+$ ]] || { echo "usage: loop.sh [--min-load <n>] <tag> <first> <last> <out folder> [repo]" >&2; exit 2; }
tag="$1" first="$2" last="$3"
# with-lock.sh runs this script again with the marker, and the marker stops a second wrap. The awk
# line is the one of with-lock.sh for a call with no wait limit, with the run count as a factor.
if [[ "${DIRIGIBLE_LOCKED_SCRIPT:-}" != "$0" ]]; then
    wrapper="$(dirname "$0")/../with-lock.sh"
    holds="$(git -C "$(dirname "$wrapper")" rev-parse --path-format=absolute --git-common-dir)/dirigible-build-holds.log" || exit 2
    export WITH_LOCK_MAX_HOLD="${WITH_LOCK_MAX_HOLD:-$(awk -F'\t' -v first="$first" -v last="$last" \
        '$3 ~ /check-changed/ && $3 ~ /BASE=/ && $5 != "limit" { s = $2 }
        END { s *= 2 * ((last > first ? last - first : first - last) + 1); print (s < 3600) ? 3600 : s }' "$holds" 2>/dev/null)}"
    DIRIGIBLE_LOCKED_SCRIPT="$0" exec "$wrapper" "$0" "${args[@]}"
fi
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
