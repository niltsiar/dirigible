#!/bin/bash
# Print the cost summary of a run folder for the reflect cost review.
# Usage: cost.sh <run folder> [<transcript.jsonl>]
# - open: the birth time of the folder. phase: one line for each block of rows of the same phase
#   in decisions.tsv, in file order. A block ends at its last row and starts at the end of the
#   block before it (the first block starts at open). A first row over 30 min after the start of
#   its block (a wait before the work) adds `, first row after <N> min`.
# - checks: the logs/ files with a `check-changed: commit`, `targets:`, or `stamp: delta` line (not
#   the load wait lines of a bench log). Filtered: the targets have test-filter. Push: a base
#   that is not empty, none, or -, or the targets have test-slow or test-dmg. Repeated: a
#   `check-changed:` line on a clean tree with the commit and the targets of an earlier line. With
#   no logs/ folder, the checks and benches lines say so, not zero.
# - benches: the logs/ files with a `bench:` or `scripts/bench.sh` line; the pairs sets (folders
#   with a load.txt); repeated: a `bench:` line on a clean tree with an earlier commit and filter.
# - controls: the logs at the top of controls/.
# - late on-screen: the phase 7 rows whose result starts with NOT VERIFIED (after an optional
#   criterion ID, as for friction) and that say "on screen" or "on-screen".
# - missed unknowns: the rows whose result starts with "missed unknown", in any case.
# - critical findings: the lines of a review-*.md at the top of the run folder whose tag has
#   critical, in any case. The tag is the parenthesis after the item number or ID (`1. (`, `G1 (`);
#   a tag with `critical: no` does not count, and a later parenthesis does not change the count.
#   Not an Intent, Panel, Source, or Sources line, not an indented line
#   (a Fix sub-bullet that quotes the format), and not a line under a ## or ### heading other than
#   Act on or Act-on, in any case. A deeper heading (### G1 under ## Act on) does not change the
#   section. A line under no section heading counts (a flat list).
# - friction: the critical findings plus the rows whose result starts with a token, in any case:
#   NOT VERIFIED, survived, flake, failed, fail, or missed unknown. One criterion ID can come first
#   (DC4 FAIL, C6 (c) failed). The token ends at a character that is not a letter. The deliver
#   Autonomy rules tell the writer to start a result with its token; check-docs.sh checks that
#   they name each token.
# - window: the time of the first decisions.tsv row (the open time when no row has a time) to the
#   end of the minute of the latest row (the clock time when no row has a time).
# - agents, workflows, idle, and wait: the Agent and mcp__t3-code__delegate_task calls and the
#   Workflow calls of the transcript in the window (a Workflow call starts many agents that the
#   transcript does not show), and the gaps over 5 min between its records in the window, sorted by
#   time. A gap is a wait when a task is open at its start, else idle. A task opens at its start
#   result: a delegate_task result (its taskId), or the ID of a background Bash, a background Agent,
#   or a Workflow. It ends at the first end text of its ID in any record: a user message line
#   "Delegated task <taskId> (<title>) [completed]:" or "[failed]:", a task_cancel result
#   "cancel_requested", a <task-notification> line, or a TaskStop result. A t3_background_wait result
#   ends no task, and a task with no end text stays open. Run windows that overlap share these counts.
# - subagents: each agent-*.jsonl at any depth under <transcript without .jsonl>/subagents (a
#   Workflow puts its agents in subagents/workflows/wf_*/) whose first user message names the run
#   folder (no letter, digit, or hyphen after the name) and whose time span overlaps the subagent
#   window (the earlier of the open time and the window start, to the window end; the agent that
#   opens a run starts before its first row):
#   one line with its tool calls, wall minutes, error results (at most 5 commands, 80 characters
#   each), the commands that ran more than once (the 3 most), and its gaps over 5 min. Each tool_use
#   id counts once, and an error counts once for each tool_use_id. A command is the Bash command,
#   or else the tool name and its file_path. The other files are unattributed.
# - lock: the minutes of wait and of hold in the lock logs (dirigible-build-waits.log and
#   dirigible-build-holds.log of the git common dir of each tree) for the lines that start in the
#   window. The trees are the worktree of each `- Branch:` line of run.md (the first word of the
#   line, backticks removed) and each `- Worktree:` line (a relative path starts at the checkout
#   that holds the run folder). A tree that two lines name counts once, and the seconds of all trees
#   add up before the division by 60. A line of another tree, and a wait line of 4 columns (no
#   tree), do not count. With no tree the line says so.
# - tokens: one line for each model, `tokens: <model> in <i> out <o> cache-read <r>
#   cache-write-5m <w5> cache-write-1h <w1>`, for the replies of the transcript in the window and
#   of the attributed subagents. Each reply counts once by message.id and requestId, and each
#   usage.iterations entry counts under its own model (an advisor_message names the advisor). The
#   lines also add each other .jsonl next to the transcript (the session of a T3 delegated agent;
#   the transcript is compared by its resolved path) whose first user message names the run folder
#   and whose time span overlaps the subagent window, as for the subagents.
# - pace: open to merge, when run.md names a pull request that gh lists as merged; the merges
#   on each of the last 10 days with a merge (local dates).
# cost.test.sh tests it.
set -euo pipefail
[[ $# -eq 1 || $# -eq 2 ]] || { echo "usage: cost.sh <run folder> [<transcript.jsonl>]" >&2; exit 2; }
run="${1%/}" transcript="${2:-}"
[[ -f "$run/decisions.tsv" ]] || { echo "cost.sh: no decisions.tsv in $run" >&2; exit 2; }
name="$(basename "$run")"
open="$(stat -f %SB -t %FT%R "$run")"
# date -j takes the fields that the format does not name from the clock, so the format names the seconds.
epoch() { date -j -f %Y-%m-%dT%H:%M:%S "$1:00" +%s; }

echo "run: $name"
echo "open: $open"
start="$open"
# The awk compares the phase as text: as a number, phase 0 equals the unset p, and no block starts.
while read -r phase first end; do
    gap=$((($(epoch "$first") - $(epoch "$start")) / 60)) late=""
    if ((gap > 30)); then late=", first row after $gap min"; fi
    echo "phase $phase: $start to $end, $((($(epoch "$end") - $(epoch "$start")) / 60)) min$late"
    start="$end"
done < <(awk -F'\t' '$1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$/ {
        if (NR > 1 && $2 "" != p "" && p != "") print p, f, e
        if ($2 "" != p "") f = $1
        p = $2; e = $1
    } END { if (p != "") print p, f, e }' "$run/decisions.tsv")

checks=0 filtered=0 push=0 benches=0
for f in "$run"/logs/*; do
    [[ -f "$f" ]] || continue
    if grep -qE '^(check-changed: commit |targets: |stamp: delta )' "$f"; then
        checks=$((checks + 1))
        grep -qE '^targets: .*test-filter|^check-changed: .* targets .*test-filter' "$f" && filtered=$((filtered + 1))
        base="$(sed -n -E 's/^check-changed: .* base ([^ ]*) targets .*/\1/p' "$f" | head -n 1)"
        if [[ -n "$base" && "$base" != none && "$base" != - ]] || grep -qE '^targets: .*(test-slow|test-dmg)' "$f"; then
            push=$((push + 1))
        fi
    fi
    grep -qE '^(bench: |scripts/bench\.sh )' "$f" && benches=$((benches + 1))
done
# The repeats: the lines on a clean tree whose commit and targets (or filter) came before.
repeats() { awk -v kind="$1" '$1 == kind ":" && $5 == "clean" { $5 = ""; if (seen[$0]++) n++ } END { print n + 0 }'; }
check_repeats="$(cat "$run"/logs/* 2>/dev/null | repeats check-changed || true)"
bench_repeats="$(cat "$run"/logs/* 2>/dev/null | repeats bench || true)"
pairs="$(find "$run" -maxdepth 3 -name load.txt -type f | wc -l | tr -d ' ')"
if [[ -d "$run/logs" ]]; then
    echo "checks: $checks logs, $filtered filtered, $push push checks, $check_repeats repeated (same commit and targets)"
    echo "benches: $benches bench logs, $pairs pairs sets, $bench_repeats repeated (same commit and filter)"
else
    echo "checks: no logs folder"
    echo "benches: no logs folder, $pairs pairs sets"
fi

written=0
[[ ! -d "$run/controls" ]] || written="$(find "$run/controls" -maxdepth 1 -name '*.log' -type f | wc -l | tr -d ' ')"
echo "controls: $written written"

critical="$(find "$run" -maxdepth 1 -name 'review-*.md' -type f -exec awk '
    FNR == 1 { keep = 1; section = 0 }
    FNR > 1 && /^#+ / {
        level = index($0, " ") - 1
        if (!section || level <= section) { keep = (tolower($0) ~ /^#+ act[- ]on/); section = level; next }
    }
    keep && !/^[ \t]/ && !/^(- )?(\*\*)?(Intent|Panel|Sources?):/ {
        s = tolower($0)
        if (match(s, /^(#+ +)?(- +|\| +)?(\*\*)?([0-9]+\. +)?(\*\*)?([a-z]+[0-9]+[a-z]? +)?\(/)) {
            tag = substr(s, RLENGTH + 1)
            sub(/\).*/, "", tag)
            if (tag ~ /critical/ && tag !~ /critical: no/) n++
        }
    }
    END { print n + 0 }' {} \; | awk '{ n += $1 } END { print n + 0 }')"
awk -F'\t' -v critical="$critical" '
    function token(s) { return tolower(s) ~ /^([a-z]+[0-9]+[a-z]? (\([a-z]\) )?)?(not verified|survived|flake|failed|fail|missed unknown)([^a-z]|$)/ }
    function not_verified(s) { return tolower(s) ~ /^([a-z]+[0-9]+[a-z]? (\([a-z]\) )?)?not verified([^a-z]|$)/ }
    NR == 1 { next }
    $2 == "7" && not_verified($6) && tolower($0) ~ /on screen|on-screen/ { late++ }
    tolower($6) ~ /^missed unknown/ { missed++ }
    token($6) { friction++ }
    END { printf "late on-screen: %d\nmissed unknowns: %d\ncritical findings: %d\nfriction: %d\n", late, missed, critical, friction + critical }' "$run/decisions.tsv"

# The window in epoch seconds: the transcript is in UTC, the run times are local.
times="$(awk -F'\t' '$1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$/ { print $1 }' "$run/decisions.tsv" | sort)"
first="$(head -n 1 <<<"$times")" last="$(tail -n 1 <<<"$times")"
if [[ -n "$first" ]]; then
    from="$(epoch "$first")" to="$(($(epoch "$last") + 59))"
else
    from="$(stat -f %B "$run")" to="$(date +%s)"
fi
echo "window: ${first:-$open} to ${last:-now}"
since="$(stat -f %B "$run")"
((since < from)) || since="$from"
# The lock minutes of the trees of the run: the worktree of each `- Branch:` line and each
# `- Worktree:` line. The logs hold local ISO times and the tree of each call.
checkout="$(git -C "$run" rev-parse --show-toplevel 2>/dev/null || echo "$run")"
worktrees="$(git -C "$run" worktree list --porcelain 2>/dev/null || true)"
candidates="$(sed -n 's/^- Worktree: *\([^ ]*\).*/\1/p' "$run/run.md" 2>/dev/null || true)"
while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    candidates+=$'\n'"$(awk -v ref="refs/heads/$b" '/^worktree /{ p = substr($0, 10) } $1 == "branch" && $2 == ref { print p; exit }' <<<"$worktrees")"
done < <(sed -n 's/^- Branch: *//p' "$run/run.md" 2>/dev/null | sed -E 's/[ ,].*$//; s/`//g')
# lock_sec <log> <tree column>: the seconds of the lines of $tree that start in the window.
lock_sec() {
    awk -F'\t' -v tree="$tree" -v col="$2" -v from="$(date -r "$from" +%FT%T)" -v to="$(date -r "$to" +%FT%T)" \
        '$1 >= from && $1 <= to && $col == tree { sum += $2 } END { printf "%d", sum }' "$1" 2>/dev/null || printf 0
}
lock_wait=0 lock_hold=0 counted=""
while IFS= read -r w; do
    [[ -n "$w" ]] || continue
    [[ "$w" == /* ]] || w="$checkout/$w"
    tree="$(git -C "$w" rev-parse --show-toplevel 2>/dev/null)" || continue
    common="$(git -C "$w" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || continue
    ! grep -qxF -- "$tree" <<<"$counted" || continue
    counted+="$tree"$'\n'
    lock_wait=$((lock_wait + $(lock_sec "$common/dirigible-build-waits.log" 5)))
    lock_hold=$((lock_hold + $(lock_sec "$common/dirigible-build-holds.log" 4)))
done <<<"$candidates"
if [[ -z "$counted" ]]; then
    echo "lock: no tree for the Branch or Worktree line of run.md"
else
    echo "lock: $((lock_wait / 60)) min wait, $((lock_hold / 60)) min hold"
fi
if [[ -n "$transcript" && -f "$transcript" ]]; then
    # One R row for each record (in the window or not, its agent and Workflow calls), then the task
    # rows of the record: U a delegate_task call, D its result with the task ID, S the start of a
    # background Bash, Agent, or Workflow task, E an end. The awk keeps the open tasks of all records.
    jq -r --argjson from "$from" --argjson to "$to" '
        def text: if type == "string" then . else ([.[]? | objects | select(.type == "text") | .text] | join(" ")) end;
        select(.timestamp) |
        (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $t |
        [.message.content[]? | objects | select(.type == "tool_use")] as $u |
        ([$t, "R", (if $t >= $from and $t <= $to then 1 else 0 end),
          ($u | map(select(.name == "Agent" or .name == "Task" or .name == "mcp__t3-code__delegate_task")) | length),
          ($u | map(select(.name == "Workflow")) | length)] | @tsv),
        ($u[] | select(.name == "mcp__t3-code__delegate_task") | [$t, "U", .id] | @tsv),
        (.message.content[]? | objects | select(.type == "tool_result") | .tool_use_id as $id | (.content | text) as $c |
            (($c | capture("^\\{\"taskId\":\"(?<k>[^\"]+)\"") | .k) as $k |
                if ($c | test("\"status\":\"cancel_requested\"")) then [$t, "E", $k] else [$t, "D", $id, $k] end | @tsv),
            ($c | capture("^(Command running in background with ID: |Workflow launched in background\\. Task ID: |Async agent launched successfully\\..*?\\nagentId: )(?<k>[A-Za-z0-9_-]+)"; "s")
                | [$t, "S", .k] | @tsv),
            ($c | capture("^\\{\"message\":\"Successfully stopped task: (?<k>[A-Za-z0-9_-]+)") | [$t, "E", .k] | @tsv)),
        (select(.type == "user") | .message.content | text
            | scan("(?:^|\\n)Delegated task (\\S+) \\([^\\n]*\\) \\[(?:completed|failed)\\]:") | [$t, "E", .[0]] | @tsv),
        ([.content, (select(.type == "user") | .message.content | text)][] | strings
            | scan("(?:^|\\n)<task-notification>\\n<task-id>([^<]+)</task-id>") | [$t, "E", .[0]] | @tsv)' "$transcript" |
        sort -s -n -k1,1 |
        awk -F'\t' '$2 == "U" { use[$3] = 1 } $2 == "D" && use[$3] { open[$4] = 1 } $2 == "S" { open[$3] = 1 }
            $2 == "E" { delete open[$3] }
            $2 == "R" && $3 {
                if (seen && $1 - last > 300) {
                    n = 0
                    for (task in open) n++
                    if (n) { wait += $1 - last; w++ } else { gap += $1 - last; k++ }
                }
                seen = 1; last = $1; agents += $4; workflows += $5
            }
            END { printf "agents: %d\nworkflows: %d\nidle: %d min in %d gaps over 5 min\nwait: %d min in %d gaps\n", agents, workflows, gap / 60, k, wait / 60, w }'
else
    echo "agents: no transcript"
    echo "workflows: no transcript"
    echo "idle: no transcript"
    echo "wait: no transcript"
fi

attributed=()
if [[ -z "$transcript" || ! -f "$transcript" ]]; then
    echo "subagents: no transcript"
elif [[ ! -d "${transcript%.jsonl}/subagents" ]]; then
    echo "subagents: none"
else
    other=0
    while IFS= read -r f; do
        start="$(jq -r -s 'def text: if type == "string" then . else ([.[]? | objects | select(.type == "text") | .text] | join(" ")) end;
            def t: .timestamp | sub("\\.[0-9]+Z$"; "Z") | (fromdateiso8601? // 0) | tostring;
            [.[] | select(.timestamp)] as $r | ($r[0] | t? // "x") + " " + ($r[-1] | t? // "x") + " " +
            ([.[] | select(.type == "user")][0].message.content | text | gsub("\n"; " "))' "$f" 2>/dev/null || true)"
        t0="${start%% *}" rest="${start#* }"
        t1="${rest%% *}"
        if [[ "$t0" =~ ^[0-9]+$ && "$t1" =~ ^[0-9]+$ ]] && ((t0 <= to && t1 >= since)) && grep -qE -- "${name}([^A-Za-z0-9-]|$)" <<<"${rest#* }"; then
            attributed+=("$f")
            jq -r -s --arg file "$(basename "$f" .jsonl)" '
                ([.[] | select(.timestamp) | .timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601] | sort) as $t
                | ([.[] | .message.content[]? | objects | select(.type == "tool_use")
                    | {id, c: ((.input.command // ([.name, .input.file_path // empty] | join(" "))) | tostring | gsub("\n"; " ") | .[0:80])}] | unique_by(.id)) as $uses
                | ($uses | map({(.id): .c}) | add // {}) as $by
                | ([.[] | .message.content[]? | objects | select(.type == "tool_result" and .is_error == true)] | unique_by(.tool_use_id) | map($by[.tool_use_id] // "?")) as $errs
                | ([$uses | group_by(.c)[] | select(length > 1) | {c: .[0].c, n: length}] | sort_by(-.n) | .[0:3]) as $rep
                | [range(1; $t | length) as $i | $t[$i] - $t[$i - 1] | select(. > 300)] as $gaps
                | "subagent: \($file): \($uses | length) tool calls, \((($t[-1] // 0) - ($t[0] // 0)) / 60 | floor) min, \($errs | length) errors"
                  + (if ($errs | length) > 0 then " (\($errs[0:5] | join("; ")))" else "" end)
                  + ", repeated: \(if ($rep | length) > 0 then ($rep | map("\(.c) x\(.n)") | join(", ")) else "none" end)"
                  + ", gaps: \($gaps | length) over 5 min (\(($gaps | add // 0) / 60 | floor) min)"' "$f"
        else
            other=$((other + 1))
        fi
    done < <(find "${transcript%.jsonl}/subagents" -name 'agent-*.jsonl' -type f | sort)
    echo "unattributed: $other files"
fi

# One row for each usage entry of a reply: the awk keeps the first row of each reply and entry.
if [[ -z "$transcript" || ! -f "$transcript" ]]; then
    echo "tokens: no transcript"
else
    rows='select(.type == "assistant" and (.message.usage | type) == "object")
        | (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $t
        | select($all or ($t >= $from and $t <= $to))
        | .message as $m | .requestId as $r
        | (if ($m.usage.iterations | length) > 0 then $m.usage.iterations else [$m.usage] end) | to_entries[]
        | .key as $i | .value as $u | ($u.cache_creation.ephemeral_1h_input_tokens // 0) as $w1
        | [$m.id, $r, ($u.model // $m.model // "unknown"), ($u.input_tokens // 0), ($u.output_tokens // 0),
           ($u.cache_read_input_tokens // 0), (($u.cache_creation_input_tokens // 0) - $w1), $w1, $i] | @tsv'
    # The sessions of the project (a T3 delegated agent): first() stops jq at the first user message.
    sessions=() lead="$(cd "$(dirname "$transcript")" && pwd -P)/$(basename "$transcript")"
    for f in "$(dirname "$lead")"/*.jsonl; do
        [[ -f "$f" && "$f" != "$lead" ]] || continue
        first="$(jq -r -n 'first(inputs | select(.type == "user")) | .message.content
            | if type == "string" then . else ([.[]? | objects | select(.type == "text") | .text] | join(" ")) end' "$f" 2>/dev/null || true)"
        grep -qE -- "${name}([^A-Za-z0-9-]|$)" <<<"$first" || continue
        span="$(jq -r 'select(.timestamp) | .timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // empty' "$f" 2>/dev/null | sed -n '1p;$p' | xargs || true)"
        t0="${span%% *}" t1="${span##* }"
        if [[ "$t0" =~ ^[0-9]+$ && "$t1" =~ ^[0-9]+$ ]] && ((t0 <= to && t1 >= since)); then sessions+=("$f"); fi
    done
    {
        jq -r --argjson from "$from" --argjson to "$to" --argjson all false "$rows" "$transcript"
        for f in ${attributed[@]+"${attributed[@]}"} ${sessions[@]+"${sessions[@]}"}; do
            jq -r --argjson from 0 --argjson to 0 --argjson all true "$rows" "$f"
        done
    } | awk -F'\t' '
        !seen[$1, $2, $9]++ { m[$3] = 1; i[$3] += $4; o[$3] += $5; r[$3] += $6; w5[$3] += $7; w1[$3] += $8 }
        END {
            for (k in m) printf "tokens: %s in %.0f out %.0f cache-read %.0f cache-write-5m %.0f cache-write-1h %.0f\n", k, i[k], o[k], r[k], w5[k], w1[k]
            if (length(m) == 0) print "tokens: none"
        }' | sort
fi

if prs="$(gh pr list --state merged --limit 100 --json number,createdAt,mergedAt,title 2>/dev/null)" && [[ -n "$prs" ]]; then
    number="$(grep -oE 'github\.com/[^ ]+/pull/[0-9]+' "$run/run.md" 2>/dev/null | head -n 1 | sed 's|.*/||' || true)"
    if [[ -n "$number" ]]; then
        jq -r --argjson n "$number" --argjson open "$(stat -f %B "$run")" --arg name "$name" \
            '.[] | select(.number == $n and .mergedAt != null) | "pace: \($name) open to merge \(((.mergedAt | fromdateiso8601) - $open) / 360 | round / 10 | tostring | if test("\\.") then . else . + ".0" end) h"' <<<"$prs"
    fi
    jq -r '[.[] | select(.mergedAt != null) | .mergedAt | fromdateiso8601 | strflocaltime("%Y-%m-%d")] | group_by(.) | map("\(.[0]) \(length)") | .[-10:] | "pace: merges per day " + join(" ")' <<<"$prs"
else
    echo "pace: no gh data"
fi
