#!/bin/bash
# Open a deliver run: .scratchpads/runs/<date>-<slug>/ with run.md, decisions.tsv, logs/, and the
# analysis.md and plan.md skeletons (headings only, so scripts/check-plan.sh refuses them until the
# run fills them), plus one open row in the run log of the wiki (scripts/wiki.py log). A subagent
# fills a skeleton with the Edit tool, which works where the Write tool refuses a new run file.
# Running it again for the slug of an open run, on any day, returns the same folder and changes
# nothing. It prints the later count, the upkeep items of status next, the size of the next list
# (a warning over 3000 words), a due architecture audit, a due consolidation (the workflow doc
# words over TOTAL x 1.03 of docs/workflow/budgets.tsv), and a due dependency check (the Last check:
# date of docs/workflow/dependency-check.md 30 or more days old) on stderr. It also prints one health line:
# the product and the workflow PRs of the runs with a done row and a run name dated in the last 7
# days (the log rows have no date), the seconds of the newest "test-shards: ... <s> s" line in the
# push-check.log of a done run, and the minutes of the hold lines of dirigible-build-holds.log
# (git common dir) that start in the last 7 days. A part with no source says none.
# A new run gets `- Branch: <type>/<slug>` in run.md. The script refuses a third non-feature run
# in a row (exit 2, no folder, no log row): the two runs with the highest PR numbers in their
# done log rows (each run once, by its last row) have a run.md branch type other than feat (the
# text between "- Branch: " and the first slash; no type is not a feature), and <type> is not feat.
# With --blocks-feature, it opens the run and logs the reason as a phase 0 row. The run folders
# are in .scratchpads/ of the main checkout (the git common dir). With no wiki, the script exits
# 1 before it makes a folder: wiki.py names the path, `scripts/wiki.py init`, and DIRIGIBLE_WIKI.
# Usage: new-run.sh <slug> <type> [--blocks-feature '<reason>']
set -euo pipefail

usage="usage: new-run.sh <slug> <type> [--blocks-feature '<reason>']"
slug="${1:?$usage}"
type="${2:?$usage}"
reason=""
if [[ $# -gt 2 ]]; then
    [[ $# -eq 4 && "$3" == --blocks-feature && -n "$4" ]] || { echo "$usage" >&2; exit 2; }
    reason="$4"
fi
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "slug must be kebab-case: $slug" >&2; exit 2; }
[[ "$type" =~ ^(feat|fix|test|refactor|perf|docs|build|chore|style)$ ]] ||
    { echo "type must be a Conventional Commits type: $type" >&2; exit 2; }

root="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.scratchpads"
wiki="$(cd "$(dirname "$0")/../../../.." && pwd)/scripts/wiki.py"
# The run log of the wiki, as one row for each run: the last row of its name, in the order of those
# rows. With no wiki, wiki.py fails here and the script stops before it makes a folder.
log_lines="$("$wiki" runs)"
rows="$(awk -F'|' '/^\|/ { n = $2; gsub(/ /, "", n)
    if (n ~ /^[0-9]{4}-/) { last[n] = NR; text[NR] = $0; who[NR] = n } }
    END { for (i = 1; i <= NR; i++) if ((i in text) && last[who[i]] == i) print text[i] }' <<<"$log_lines")"
# Reuse the open run of this exact slug, so a run that spans days keeps one folder.
# A done run is history: never reopen it.
run=""
for d in "$root"/runs/*; do
    name="$(basename "$d")"
    [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-(.+)$ && "${BASH_REMATCH[1]}" == "$slug" ]] || continue
    if grep -q "^| $name | .* | open |" <<<"$rows"; then run="$name"; fi
done
if [[ -z "$run" ]]; then
    run="$(date +%Y-%m-%d)-$slug"
    [[ ! -d "$root/runs/$run" ]] || { echo "run $run is closed; choose a new slug" >&2; exit 2; }
fi
dir="$root/runs/$run"
# The feature guard, for a new run only.
if [[ ! -d "$dir" && "$type" != feat ]]; then
    # The land order is the PR number of the done row (a row with no PR is older).
    # A done row says `done`, `done: ...`, or `done, ...`. The PR number is the pull/<n> URL of the
    # Result cell, else `PR <n>` or `PR #<n>` of the Status cell.
    last="$(awk -F'|' '{ n = $2; gsub(/ /, "", n); st = $4; gsub(/ /, "", st) }
        n ~ /^[0-9]{4}-/ && st ~ /^done([,:]|$)/ {
            pr = 0
            if (match($5, /pull\/[0-9]+/)) pr = substr($5, RSTART + 5, RLENGTH - 5)
            else if (match($4, /PR #?[0-9]+/)) { pr = substr($4, RSTART, RLENGTH); gsub(/[^0-9]/, "", pr) }
            print pr + 0, NR, n
        }' \
        <<<"$rows" | sort -k1,1n -k2,2n | awk '{ print $3 }' | tail -r | awk '!seen[$0]++' | head -n 2)"
    features=0
    for r in $last; do
        t="$(sed -n 's/^- Branch: \([^/]*\)\/.*/\1/p' "$root/runs/$r/run.md" 2>/dev/null | head -n 1)"
        [[ "$t" != feat ]] || features=1
    done
    if [[ "$(wc -w <<<"$last")" -eq 2 && $features -eq 0 && -z "$reason" ]]; then
        echo "new-run: a third non-feature run in a row; give --blocks-feature '<reason>'" >&2
        exit 2
    fi
fi
# logs/ holds the check and bench logs that cost.sh of reflect counts.
mkdir -p "$dir/logs"
# The wiki tool reads the row from a file and removes the file after its commit.
if ! grep -q "^| $run |" <<<"$rows"; then
    printf '| %s | %s | open | |\n' "$run" "$slug" > "$dir/logs/wiki-log.txt"
    "$wiki" log --from "$dir/logs/wiki-log.txt"
fi

# Report the wiki on stderr; stdout stays the run folder. Phase 0 reads the next list at each run
# start, so a long list costs each run. A wiki item has no date, so the later count of the last
# run.md is the record of the change.
next="$("$wiki" list next)"
next_words="$(wc -w <<<"$next" | tr -d ' ')"
(( next_words <= 3000 )) || echo "warning: wiki.py list next has $next_words words, over 3000; move items to later" >&2
later="$("$wiki" count later)"
last=""
for d in "$root"/runs/*/; do [[ "${d%/}" == "$dir" ]] || last="${d%/}"; done
prev=""
[[ -f "$last/run.md" ]] && prev="$(sed -n 's/^- Later items: \([0-9][0-9]*\)$/\1/p' "$last/run.md" | head -n 1)"
if [[ -n "$prev" ]]; then
    printf 'backlog: later has %d items (%+d since %s)\n' "$later" $((later - prev)) "$(basename "$last")" >&2
else
    echo "backlog: later has $later items" >&2
fi
# Reflect rule 6: with 8 or more upkeep items with status next, this run is a workflow upkeep run.
upkeep="$(grep -c '^[0-9][0-9]* upkeep ' <<<"$next" || true)"
echo "upkeep items: $upkeep" >&2
(( upkeep < 8 )) || echo "warning: $upkeep upkeep items wait; make this run a workflow upkeep run (reflect rule 6)" >&2
# The distinct product runs after the done row of the last run whose name has architecture: an
# open audit has not audited yet. A run has an open and a done row, and its last row counts. A
# product run has a run.md branch of type feat, fix, or perf, and a slug with no hardening. The
# current run does not count.
is_product_run() {
    [[ "$1" != *hardening* ]] || return 1
    local t
    t="$(sed -n 's/^- Branch: \([^/]*\)\/.*/\1/p' "$root/runs/$1/run.md" 2>/dev/null | head -n 1)" || true
    [[ "$t" == feat || "$t" == fix || "$t" == perf ]]
}
product=0
while IFS= read -r r; do
    if is_product_run "$r"; then product=$((product + 1)); fi
done < <(awk -F'|' -v cur="$run" '
    { name = $2; gsub(/ /, "", name); state = $4; gsub(/ /, "", state) }
    name !~ /^[0-9]{4}-/ { next }
    name ~ /architecture/ { if (state ~ /^done([,:]|$)/) { split("", seen); split("", list); n = 0 }; next }
    name != cur && !(name in seen) { seen[name] = 1; list[++n] = name }
    END { for (i = 1; i <= n; i++) print list[i] }' <<<"$rows")
(( product < 5 )) || echo "architecture audit due: $product product runs since the last architecture run;" \
    "audit the module boundaries, the files near 400 lines, the copies, and the red flags of" \
    ".claude/skills/architect/references/design-red-flags.md, and the tooling (scripts/, .claude/hooks," \
    ".claude/skills/*/scripts, .githooks, the Makefile): see docs/workflow/release-cycle.md" >&2
# The health line. rows holds the last row of each run, so a run counts once.
week_ago=$(( $(date +%s) - 7 * 86400 ))
since_day="$(date -r "$week_ago" +%F)"
done_runs="$(awk -F'|' '{ n = $2; gsub(/ /, "", n); st = $4; gsub(/ /, "", st) }
    n ~ /^[0-9]{4}-/ && st ~ /^done([,:]|$)/ { print n }' <<<"$rows")"
product_prs=0 workflow_prs=0
while IFS= read -r r; do
    [[ -n "$r" ]] && ! [[ "${r:0:10}" < "$since_day" ]] || continue
    if is_product_run "$r"; then product_prs=$((product_prs + 1)); else workflow_prs=$((workflow_prs + 1)); fi
done <<<"$done_runs"
shards=none
while IFS= read -r r; do
    secs="$(awk '/^test-shards: / && $NF == "s" && $(NF - 1) ~ /^[0-9]+$/ { v = $(NF - 1) } END { print v }' \
        "$root/runs/$r/logs/push-check.log" 2>/dev/null)" || true
    [[ -z "$secs" ]] || { shards="$secs s"; break; }
done < <(tail -r <<<"$done_runs")
holds="$(git rev-parse --path-format=absolute --git-common-dir)/dirigible-build-holds.log"
held=none
if [[ -f "$holds" ]]; then
    held="$(awk -F'\t' -v from="$(date -r "$week_ago" +%FT%T)" '$1 >= from { s += $2 } END { printf "%d", s / 60 + 0.5 }' "$holds") min"
fi
echo "health: 7 days: $product_prs product PRs, $workflow_prs workflow PRs; test-shards $shards; lock held $held" >&2
# Decision 0028, Word budgets: a consolidation is due when the workflow doc words pass TOTAL x 1.03.
top="$(git rev-parse --show-toplevel)"
total="$(awk -F'\t' '$1 == "TOTAL" { print $2 }' "$top/docs/workflow/budgets.tsv" 2>/dev/null || true)"
if [[ "$total" =~ ^[0-9]+$ ]]; then
    sum="$("$(cd "$(dirname "$0")/../../../.." && pwd)/scripts/workflow-words.sh" sum --root "$top")"
    (( sum * 100 <= total * 103 )) || echo "consolidation due: the workflow docs have $sum words, over TOTAL x 1.03 ($total in docs/workflow/budgets.tsv);" \
        "add one consolidation item with status next unless it has one (reflect rule 6)" >&2
fi
# BSD date turns 2026-11-31 into 2026-12-01 with exit 0, so a valid date gives back its own text.
# With no doc, no check is due. Noon anchors keep the day count whole across a DST change.
dep_doc="$top/docs/workflow/dependency-check.md"
if [[ -f "$dep_doc" ]]; then
    dep_run="add one dependency check item with status next unless the next list has one (docs/workflow/dependency-check.md)"
    last="$(sed -n 's/^Last check: //p' "$dep_doc" | head -n 1)"
    if [[ "$last" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$(date -j -f %F "$last" +%F 2>/dev/null)" == "$last" ]]; then
        noon() { date -j -f '%F %T' "$1 12:00:00" +%s; }
        days=$(( ($(noon "$(date +%F)") - $(noon "$last") + 43200) / 86400 ))
        (( days < 30 )) || echo "dependency check due: last check $last, $days days ago; $dep_run" >&2
    else
        echo "dependency check due: no valid Last check: line in docs/workflow/dependency-check.md; $dep_run" >&2
    fi
fi

[[ -f "$dir/analysis.md" ]] || printf '# Analysis: %s\n\n## Acceptance criteria\n\n## Unknowns\n\n| id | parent | question | resolver | answer | row |\n|---|---|---|---|---|---|\n\n## Out of scope\n' "$slug" > "$dir/analysis.md"
[[ -f "$dir/plan.md" ]] || printf '# Plan: %s\n\n## Slices\n' "$slug" > "$dir/plan.md"
[[ -f "$dir/decisions.tsv" ]] || printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n' > "$dir/decisions.tsv"
[[ -f "$dir/run.md" ]] || cat > "$dir/run.md" <<MD
# Run $run

- Status: open
- Goal: $slug
- Requirements:
- Branch: $type/$slug
- Later items: $later

## Phases

- [ ] 0 Open the run
- [ ] 1 Analyze (analysis.md)
- [ ] 2 Plan (plan.md)
- [ ] 3 Plan gate (review-plan-*.md)
- [ ] 4 Implement
- [ ] 5 Clean up
- [ ] 6 Code gate (review-diff-*.md)
- [ ] 7 Verify
- [ ] 8 Reflect
- [ ] 9 Land and close

## Slices

## Manual checks

## Summary
MD

if [[ -n "$reason" ]] && ! grep -qF 'third non-feature run' "$dir/decisions.tsv"; then
    "$(dirname "$0")/log-decision.sh" "$dir" 0 "third non-feature run in a row: $type/$slug" "$reason" \
        "new-run.sh --blocks-feature" "accepted" > /dev/null
fi
echo "$dir"
