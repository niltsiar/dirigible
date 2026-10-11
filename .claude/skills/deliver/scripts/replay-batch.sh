#!/bin/bash
# Replay the killed controls of a run once, in one Bash call of 10 min or less (mutation-controls.md,
# Replay once in Phase 7).
# Usage: replay-batch.sh <tree> <controls folder> <budget seconds> [<log>...]
# - <tree> is the absolute root of the worktree to replay. The script runs there, because a replay
#   mutates, builds, and tests the tree that it runs in; it refuses the main checkout.
# - With no <log>, it takes each top-level log of the folder with `# result: killed` (a hang too).
#   A named log always replays. Each replay log goes to <controls>/replay/<name>, the folder that
#   cost.sh and replay-list.sh read. A replay is done when its log has a `# result:` line other
#   than `stopped`; a done replay is skipped.
# - Time: the budget is at most 480 s. Before each log, the time left is the budget minus the time
#   used minus 120 s for the build (mutate.py gives the build no limit). A log whose header
#   timeout plus 120 fits the budget runs only with its full header timeout; when that is over the
#   time left, the script prints BUDGET and stops, and a fresh call runs it. A log that cannot fit
#   (or has no `# timeout:` line) runs once, capped at the time left (60 s or more, else BUDGET).
#   A capped `killed (hang)` or `WRONG FAILURE` can come from the cap, so it is not done: its log
#   moves to <name>.capped and the script prints CAPPED HANG. Later the log gets only its full
#   limit; when that cannot fit, the script prints TOO LONG and the command that replays it alone
#   (run it with run_in_background).
# - A mutate.py exit 2 (side effects, a changed old text) prints its message, and the next log runs.
# - Each call ends with `replayed N of M; left K; too long J`, and ALL DONE when K is 0.
# replay-batch.test.sh tests it.
set -uo pipefail
usage="usage: replay-batch.sh <tree> <controls folder> <budget seconds, 480 or less> [<log>...]"
[[ $# -ge 3 && "$3" =~ ^[0-9]+$ && "$3" -ge 1 && "$3" -le 480 ]] || { echo "$usage" >&2; exit 2; }
tree="$1" budget="$3"
controls="$(cd "$2" 2>/dev/null && pwd)" || { echo "replay-batch: no folder $2" >&2; exit 2; }
shift 3
mutate="$(cd "$(dirname "$0")" && pwd)/mutate.py"
top="$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null)" && [[ "$top" == "$(cd "$tree" && pwd -P)" ]] ||
    { echo "replay-batch: $tree is not the root of a worktree" >&2; exit 2; }
common="$(git -C "$tree" rev-parse --path-format=absolute --git-common-dir)"
[[ "$(dirname "$common")" != "$top" ]] || { echo "replay-batch: $tree is the main checkout; replay in the worktree of the run" >&2; exit 2; }
cd "$top" || exit 2
allowance=120
mkdir -p "$controls/replay"

logs=("$@")
if [[ ${#logs[@]} -eq 0 ]]; then
    for log in "$controls"/*.log; do
        grep -q '^# result: killed' "$log" 2>/dev/null && logs+=("$log")
    done
fi
done_log() { [[ -f "$1" ]] && grep '^# result: ' "$1" | grep -qv '^# result: stopped$'; }
# count: print the count line, and ALL DONE when no log is left.
too_long=0
count() {
    local n=0 log
    for log in ${logs[@]+"${logs[@]}"}; do done_log "$controls/replay/$(basename "$log")" && n=$((n + 1)); done
    local left=$(( ${#logs[@]} - n - too_long ))
    echo "replayed $n of ${#logs[@]}; left $left; too long $too_long"
    [[ $left -gt 0 ]] || echo "ALL DONE"
}

start="$(date +%s)"
for log in ${logs[@]+"${logs[@]}"}; do
    name="$(basename "$log")"
    out="$controls/replay/$name"
    [[ $# -eq 0 ]] && done_log "$out" && continue
    full="$(sed -n 's/^# timeout: //p' "$log" | head -1)"
    full="${full%.*}"
    left=$(( budget - ($(date +%s) - start) - allowance ))
    capped=0
    if [[ -n "$full" ]] && (( full + allowance <= budget )); then
        (( full <= left )) || { echo BUDGET; count; exit 0; }
        t=$full
    elif [[ -e "$out.capped" ]]; then
        echo "$name: TOO LONG; replay it alone: python3 -I $mutate --timeout ${full:-<seconds>} --replay $log $out"
        too_long=$((too_long + 1))
        continue
    else
        (( left >= 60 )) || { echo BUDGET; count; exit 0; }
        t=$left capped=1
    fi
    result="$(python3 -I "$mutate" --timeout "$t" --replay "$log" "$out" 2>&1)"
    line="$(grep -m1 -E '^(killed|survived|BUILD FAILED|WRONG FAILURE|NO TESTS|stopped|mutate:)' <<<"$result" || tail -1 <<<"$result")"
    if [[ $capped -eq 1 && "$line" =~ ^(killed\ \(hang\)|WRONG\ FAILURE) ]]; then
        mv "$out" "$out.capped"
        echo "$name: CAPPED HANG (capped $t s)"
    elif [[ $capped -eq 1 ]]; then
        echo "$name: $line (capped $t s)"
    else
        echo "$name: $line"
    fi
done
count
