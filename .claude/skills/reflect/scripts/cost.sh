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
# - late on-screen: the phase 7 rows with NOT VERIFIED and "on screen" or "on-screen".
# - missed unknowns: the rows whose result starts with "missed unknown", in any case.
# - critical findings: the lines of a review-*.md at the top of the run folder with critical in a
#   parenthesis, in any case. Not an Intent, Panel, Source, or Sources line, not an indented line
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
# - agents, workflows, and idle: the Agent calls and the Workflow calls of the transcript in the
#   window (a Workflow call starts many agents that the transcript does not show), and the gaps
#   over 5 min between its records in the window. Run windows that overlap share these counts.
# - subagents: each agent-*.jsonl at any depth under <transcript without .jsonl>/subagents (a
#   Workflow puts its agents in subagents/workflows/wf_*/) whose first user message names the run
#   folder (no letter, digit, or hyphen after the name) and whose time span overlaps the subagent
#   window (the earlier of the open time and the window start, to the window end; the agent that
#   opens a run starts before its first row):
#   one line with its tool calls, wall minutes, error results (at most 5 commands, 80 characters
#   each), the commands that ran more than once (the 3 most), and its gaps over 5 min. The other
#   files are unattributed.
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
    keep && !/^[ \t]/ && tolower($0) ~ /\([^)]*critical/ && !/^(- )?(\*\*)?(Intent|Panel|Sources?):/ { n++ }
    END { print n + 0 }' {} \; | awk '{ n += $1 } END { print n + 0 }')"
awk -F'\t' -v critical="$critical" '
    function token(s) { return tolower(s) ~ /^([a-z]+[0-9]+[a-z]? (\([a-z]\) )?)?(not verified|survived|flake|failed|fail|missed unknown)([^a-z]|$)/ }
    NR == 1 { next }
    $2 == "7" && /NOT VERIFIED/ && tolower($0) ~ /on screen|on-screen/ { late++ }
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
if [[ -n "$transcript" && -f "$transcript" ]]; then
    jq -r --argjson from "$from" --argjson to "$to" 'select(.timestamp) |
        (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $t | select($t >= $from and $t <= $to) |
        [.message.content[]? | objects | select(.type == "tool_use") | .name] as $n |
        "\($t) \($n | map(select(. == "Agent" or . == "Task")) | length) \($n | map(select(. == "Workflow")) | length)"' "$transcript" |
        awk 'NR > 1 && $1 - last > 300 { gap += $1 - last; k++ } { last = $1; agents += $2; workflows += $3 }
            END { printf "agents: %d\nworkflows: %d\nidle: %d min in %d gaps over 5 min\n", agents, workflows, gap / 60, k }'
else
    echo "agents: no transcript"
    echo "workflows: no transcript"
    echo "idle: no transcript"
fi

if [[ -z "$transcript" || ! -f "$transcript" ]]; then
    echo "subagents: no transcript"
elif [[ ! -d "${transcript%.jsonl}/subagents" ]]; then
    echo "subagents: none"
else
    other=0 since="$(stat -f %B "$run")"
    ((since < from)) || since="$from"
    while IFS= read -r f; do
        start="$(jq -r -s 'def text: if type == "string" then . else ([.[]? | objects | select(.type == "text") | .text] | join(" ")) end;
            def t: .timestamp | sub("\\.[0-9]+Z$"; "Z") | (fromdateiso8601? // 0) | tostring;
            [.[] | select(.timestamp)] as $r | ($r[0] | t? // "x") + " " + ($r[-1] | t? // "x") + " " +
            ([.[] | select(.type == "user")][0].message.content | text | gsub("\n"; " "))' "$f" 2>/dev/null || true)"
        t0="${start%% *}" rest="${start#* }"
        t1="${rest%% *}"
        if [[ "$t0" =~ ^[0-9]+$ && "$t1" =~ ^[0-9]+$ ]] && ((t0 <= to && t1 >= since)) && grep -qE -- "${name}([^A-Za-z0-9-]|$)" <<<"${rest#* }"; then
            jq -r -s --arg file "$(basename "$f" .jsonl)" '
                ([.[] | select(.timestamp) | .timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601] | sort) as $t
                | [.[] | .message.content[]? | objects | select(.type == "tool_use")
                    | {id, c: ((.input.command // .name) | tostring | gsub("\n"; " ") | .[0:80])}] as $uses
                | ($uses | map({(.id): .c}) | add // {}) as $by
                | [.[] | .message.content[]? | objects | select(.type == "tool_result" and .is_error == true) | $by[.tool_use_id] // "?"] as $errs
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
