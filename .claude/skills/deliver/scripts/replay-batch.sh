#!/bin/bash
# Replay the killed controls of a run once, in one Bash call of 10 min or less (mutation-controls.md,
# Replay once in Phase 7).
# Usage: replay-batch.sh [--timeout <seconds>] [--again] [--allow-side-effects] <tree> <controls folder> <budget seconds> [<log>...]
# - <tree> is the absolute root of the worktree to replay. The script runs there, because a replay
#   mutates, builds, and tests the tree that it runs in. It refuses the main checkout, a tree
#   with changes, and a tree whose mutate.py lock a live process holds (an earlier replay runs).
# - With no <log>, it takes each top-level log of the folder with `# result: killed` (a hang too).
#   Each replay log goes to <controls>/replay/<name>, the folder that cost.sh and replay-list.sh
#   read. A replay is done when its log has the result killed, killed (hang), or survived, and the
#   `# head:` line that the script appends names the HEAD of the tree now. A done replay is
#   skipped, also for a named log, unless --again is given; after a new commit each log replays.
# - Time: the budget is at most 480 s. Before each log, the time left is the budget minus the time
#   used minus the build allowance (mutate.py gives the build no limit): twice the build time of
#   the last replay log (its first `Build complete! (<n>s)` line: the build command; the test
#   command builds later), and 30 s or more. The first log of a call takes it from its source log. One incremental
#   build after a one-line Sources/ mutation took 13 s. A log whose header timeout plus the
#   allowance fits the budget runs only with its full header timeout; when that is over the
#   time left, the script prints BUDGET and stops, and a fresh call runs it. A log that cannot fit
#   (or has no `# timeout:` line) runs once, capped at the time left (60 s or more, else BUDGET).
#   A capped `killed (hang)` or `WRONG FAILURE` can come from the cap, so it is not done: its log
#   moves to <name>.capped and the script prints CAPPED HANG. Later the log gets only its full
#   limit; when that cannot fit, the script prints TOO LONG and the command that replays it alone
#   (run it with run_in_background): this script with --timeout and the same tree.
# - --timeout <seconds> gives each log that limit, with no budget, no cap, and no BUDGET stop.
# - A replay with BUILD FAILED, NO TESTS, or WRONG FAILURE on this HEAD needs a decision
#   (mutation-controls.md:21): it is not left, and only --again replays it.
# - A mutate.py refusal (side effects, a changed old text) prints its message, counts as refused,
#   and the next log runs. --allow-side-effects goes to mutate.py. A failed restore (exit 3) stops
#   the batch at once with RESTORE FAILED and exit 3: a mutant can be in the tree.
# - Each call ends with `replayed N of M; left K; too long J; refused R; needs a decision D`. With
#   K 0: TOO LONG PENDING when J is over 0, REFUSED when R is over 0, and ALL DONE when J, R, and
#   D are 0.
# replay-batch.test.sh tests it.
set -uo pipefail
usage="usage: replay-batch.sh [--timeout <seconds>] [--again] [--allow-side-effects] <tree> <controls folder> <budget seconds, 480 or less> [<log>...]"
limit="" again="" allow=""
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --timeout) [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "$usage" >&2; exit 2; }; limit="$2"; shift 2 ;;
        --again) again=1; shift ;;
        --allow-side-effects) allow=--allow-side-effects; shift ;;
        *) echo "$usage" >&2; exit 2 ;;
    esac
done
[[ $# -ge 3 && "$3" =~ ^[0-9]+$ && "$3" -ge 1 && "$3" -le 480 ]] || { echo "$usage" >&2; exit 2; }
tree="$1" budget="$3"
controls="$(cd "$2" 2>/dev/null && pwd)" || { echo "replay-batch: no folder $2" >&2; exit 2; }
shift 3
here="$(cd "$(dirname "$0")" && pwd)"
mutate="$here/mutate.py"
top="$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null)" && [[ "$top" == "$(cd "$tree" && pwd -P)" ]] ||
    { echo "replay-batch: $tree is not the root of a worktree" >&2; exit 2; }
common="$(git -C "$tree" rev-parse --path-format=absolute --git-common-dir)"
[[ "$(dirname "$common")" != "$top" ]] || { echo "replay-batch: $tree is the main checkout; replay in the worktree of the run" >&2; exit 2; }
[[ -z "$(git -C "$top" status --porcelain)" ]] ||
    { echo "replay-batch: $top has changes; commit them, or wait for the replay that runs there" >&2; exit 2; }
lock="$(git -C "$top" rev-parse --absolute-git-dir)/dirigible-mutate.lock"
[[ -d "$lock" ]] && kill -0 "$(cat "$lock/pid" 2>/dev/null)" 2>/dev/null &&
    { echo "replay-batch: a mutate.py run holds $lock; wait for it to end" >&2; exit 2; }
cd "$top" || exit 2
allowance=30
# build_allowance <log>: set the allowance from the first build line of the log, if it has one.
build_allowance() {
    local b
    b="$(grep -m1 'Build complete! (' "$1" 2>/dev/null | sed 's/.*Build complete! (\([0-9]*\).*/\1/')"
    [[ -n "$b" ]] && allowance=$(( 2 * b > 30 ? 2 * b : 30 ))
}
mkdir -p "$controls/replay"

logs=("$@")
if [[ ${#logs[@]} -eq 0 ]]; then
    for log in "$controls"/*.log; do
        grep -q '^# result: killed' "$log" 2>/dev/null && logs+=("$log")
    done
fi
head="$(git rev-parse HEAD)"
# result_on_head <replay log> <result pattern>: the log has that result on the HEAD of the tree.
result_on_head() { [[ -f "$1" ]] && grep -qE "^# result: ($2)" "$1" && grep -qx "# head: $head" "$1"; }
done_log() { result_on_head "$1" 'killed|survived'; }
decision_log() { result_on_head "$1" 'BUILD FAILED|NO TESTS|WRONG FAILURE'; }
# The names of the logs that this call refused or found too long, between spaces.
too_long_names=" " refused_names=" "
# count: print the count line and the end line.
count() {
    local n=0 d=0 j=0 r=0 left=0 log name
    for log in ${logs[@]+"${logs[@]}"}; do
        name="$(basename "$log")"
        if [[ "$refused_names" == *" $name "* ]]; then r=$((r + 1))
        elif [[ "$too_long_names" == *" $name "* ]]; then j=$((j + 1))
        elif done_log "$controls/replay/$name"; then n=$((n + 1))
        elif decision_log "$controls/replay/$name"; then d=$((d + 1))
        else left=$((left + 1)); fi
    done
    echo "replayed $n of ${#logs[@]}; left $left; too long $j; refused $r; needs a decision $d"
    [[ $d -gt 0 ]] && echo "needs a decision: BUILD FAILED, NO TESTS, or WRONG FAILURE; see .claude/skills/deliver/references/mutation-controls.md:21"
    [[ $left -gt 0 ]] && return
    [[ $j -gt 0 ]] && echo "TOO LONG PENDING: do not build or commit until it ends"
    [[ $r -gt 0 ]] && echo "REFUSED: replay each refused log, or log why not"
    [[ $j -gt 0 || $r -gt 0 || $d -gt 0 ]] || echo "ALL DONE"
}

start="$(date +%s)"
seeded=""
for log in ${logs[@]+"${logs[@]}"}; do
    name="$(basename "$log")"
    out="$controls/replay/$name"
    [[ -z "$again" ]] && { done_log "$out" || decision_log "$out"; } && continue
    [[ -n "$seeded" ]] || { build_allowance "$log"; seeded=1; }
    full="$(sed -n 's/^# timeout: //p' "$log" | head -1)"
    full="${full%.*}"
    left=$(( budget - ($(date +%s) - start) - allowance ))
    capped=0
    if [[ -n "$limit" ]]; then
        t=$limit
    elif [[ -n "$full" ]] && (( full + allowance <= budget )); then
        (( full <= left )) || { echo BUDGET; count; exit 0; }
        t=$full
    elif [[ -e "$out.capped" ]]; then
        echo "$name: TOO LONG; run it with run_in_background: $here/replay-batch.sh --timeout ${full:-<seconds>} $top $controls $budget $log"
        too_long_names+="$name "
        continue
    else
        (( left >= 60 )) || { echo BUDGET; count; exit 0; }
        t=$left capped=1
    fi
    result="$(python3 -I "$mutate" --timeout "$t" $allow --replay "$log" "$out" 2>&1)"
    if [[ $? -eq 3 ]]; then
        echo "$name: $result"
        echo "RESTORE FAILED: check git status; a mutant can be in the tree"
        count
        exit 3
    fi
    grep -q '^# result: ' "$out" 2>/dev/null && echo "# head: $head" >> "$out"
    build_allowance "$out"
    line="$(grep -m1 -E '^(killed|survived|BUILD FAILED|WRONG FAILURE|NO TESTS|stopped|mutate:)' <<<"$result" || tail -1 <<<"$result")"
    [[ "$line" == mutate:* ]] && refused_names+="$name "
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
