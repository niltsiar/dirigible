#!/bin/bash
# Print the cost summary of a run folder for the reflect cost review.
# Usage: cost.sh <run folder> [<transcript.jsonl>]
# - open: the birth time of the folder. phase: one line for each block of rows of the same phase
#   in decisions.tsv, in file order. A block ends at its last row and starts at the end of the
#   block before it (the first block starts at open).
# - checks: the logs/ files with a `check-changed:` or `targets:` line. Filtered: the targets have
#   test-filter. Push: a base that is not empty, none, or -, or the targets have test-slow or
#   test-dmg. Repeated: a `check-changed:` line on a clean tree with the commit and the targets of
#   an earlier line. With no logs/ folder, the checks and benches lines say so, not zero.
# - benches: the logs/ files with a `bench:` or `scripts/bench.sh` line; the pairs sets (folders
#   with a load.txt); repeated: a `bench:` line on a clean tree with an earlier commit and filter.
# - controls: the logs at the top of controls/ and the different replay logs under controls/replay*.
# - late on-screen: the phase 7 rows with NOT VERIFIED and "on screen" or "on-screen".
# - missed unknowns: the rows whose result starts with "missed unknown", in any case.
# - critical findings: the lines of a review-*.md at the top of the run folder with critical in a
#   parenthesis, in any case. Not an Intent, Panel, Source, or Sources line, and not a line under a
#   ## or ### heading other than Act on or Act-on, in any case. A deeper heading (### G1 under
#   ## Act on) does not change the section. A line under no section heading counts (a flat list).
# - friction: the critical findings plus the rows whose result starts with a token, in any case:
#   NOT VERIFIED, survived, flake, failed, fail, or missed unknown. One criterion ID can come first
#   (DC4 FAIL, C6 (c) failed). The token ends at a character that is not a letter. The deliver
#   Autonomy rules tell the writer to start a result with its token; check-docs.sh checks that
#   they name each token.
# - window: the time of the first decisions.tsv row (the open time when no row has a time) to the
#   end of the minute of the latest row (the clock time when no row has a time).
# - agents and idle: the Agent calls of the transcript in the window, and the gaps over 5 min
#   between its records in the window. Run windows that overlap share these counts.
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
while read -r phase end; do
    echo "phase $phase: $start to $end, $((($(epoch "$end") - $(epoch "$start")) / 60)) min"
    start="$end"
done < <(awk -F'\t' '$1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$/ {
        if (NR > 1 && $2 != p && p != "") print p, e
        p = $2; e = $1
    } END { if (p != "") print p, e }' "$run/decisions.tsv")

checks=0 filtered=0 push=0 benches=0
for f in "$run"/logs/*; do
    [[ -f "$f" ]] || continue
    if grep -qE '^(check-changed: |targets: )' "$f"; then
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

written=0 replayed=0
if [[ -d "$run/controls" ]]; then
    written="$(find "$run/controls" -maxdepth 1 -name '*.log' -type f | wc -l | tr -d ' ')"
    replayed="$(find "$run/controls" -path "$run/controls/replay*" -name '*.log' -type f -exec shasum {} + | awk '{ print $1 }' | sort -u | wc -l | tr -d ' ')"
fi
echo "controls: $written written, $replayed replayed"

critical="$(find "$run" -maxdepth 1 -name 'review-*.md' -type f -exec awk '
    FNR == 1 { keep = 1; section = 0 }
    FNR > 1 && /^#+ / {
        level = index($0, " ") - 1
        if (!section || level <= section) { keep = (tolower($0) ~ /^#+ act[- ]on/); section = level; next }
    }
    keep && tolower($0) ~ /\([^)]*critical/ && !/^(- )?(\*\*)?(Intent|Panel|Sources?):/ { n++ }
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
        "\($t) \([.message.content[]? | objects | select(.type == "tool_use" and (.name == "Agent" or .name == "Task"))] | length)"' "$transcript" |
        awk 'NR > 1 && $1 - last > 300 { gap += $1 - last; k++ } { last = $1; agents += $2 }
            END { printf "agents: %d\nidle: %d min in %d gaps over 5 min\n", agents, gap / 60, k }'
else
    echo "agents: no transcript"
    echo "idle: no transcript"
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
