#!/bin/bash
# Open a deliver run: .scratchpads/runs/<date>-<slug>/ with run.md, decisions.tsv, logs/, and the
# analysis.md and plan.md skeletons (headings only, so scripts/check-plan.sh refuses them until the
# run fills them), plus one line in .scratchpads/ledger.md. A subagent fills a skeleton with the
# Edit tool, which works where the Write tool refuses a new run file. Running it again for the
# slug of an open run, on any day, returns the same folder and changes nothing. It prints the
# backlog section sizes, the upkeep items of ## Next, a due architecture audit, and a due
# consolidation (the workflow doc words over TOTAL x 1.03 of docs/workflow/budgets.tsv) on stderr.
# A new run gets `- Branch: <type>/<slug>` in run.md. The script refuses a third non-feature run
# in a row (exit 2, no folder, no ledger line): the two runs with the highest PR numbers in their
# done ledger rows (each run once) have a run.md branch type other than feat (the text between
# "- Branch: " and the first slash; no type is not a feature), and <type> is not feat. With --blocks-feature, it opens the run and logs the
# reason as a phase 0 row. The ledger is in .scratchpads/ of the main checkout (the git common dir).
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
# Reuse the open run of this exact slug, so a run that spans days keeps one folder.
# A done run is history: never reopen it.
run=""
for d in "$root"/runs/*; do
    name="$(basename "$d")"
    [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-(.+)$ && "${BASH_REMATCH[1]}" == "$slug" ]] || continue
    grep -q "^| $name | .* | open |" "$root/ledger.md" 2>/dev/null && run="$name"
done
if [[ -z "$run" ]]; then
    run="$(date +%Y-%m-%d)-$slug"
    [[ ! -d "$root/runs/$run" ]] || { echo "run $run is closed; choose a new slug" >&2; exit 2; }
fi
dir="$root/runs/$run"
# The feature guard, for a new run only.
if [[ ! -d "$dir" && "$type" != feat ]]; then
    # The land order is the PR number of the done row (a row with no PR is older); each run once.
    # A done row says `done`, `done: ...`, or `done, ...`. The PR number is the pull/<n> URL of the
    # Result cell, else `PR <n>` or `PR #<n>` of the Status cell.
    last="$(awk -F'|' '{ n = $2; gsub(/ /, "", n); st = $4; gsub(/ /, "", st) }
        n ~ /^[0-9]{4}-/ && st ~ /^done([,:]|$)/ {
            pr = 0
            if (match($5, /pull\/[0-9]+/)) pr = substr($5, RSTART + 5, RLENGTH - 5)
            else if (match($4, /PR #?[0-9]+/)) { pr = substr($4, RSTART, RLENGTH); gsub(/[^0-9]/, "", pr) }
            print pr + 0, NR, n
        }' \
        "$root/ledger.md" 2>/dev/null | sort -k1,1n -k2,2n | awk '{ print $3 }' | tail -r | awk '!seen[$0]++' | head -n 2)"
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
touch "$root/learnings.md" "$root/backlog.md"

[[ -f "$root/ledger.md" ]] || printf '# Run ledger\n\n| Run | Goal | Status | Result |\n|---|---|---|---|\n' > "$root/ledger.md"
grep -q "| $run |" "$root/ledger.md" || printf '| %s | %s | open | |\n' "$run" "$slug" >> "$root/ledger.md"

# Report the backlog sections on stderr; stdout stays the run folder. Phase 0 reads ## Next at
# each run start, so a long ## Next costs each run. A backlog item has no date, so the Later
# count of the last run.md is the record of the change.
backlog="$root/backlog.md"
next_words="$(awk '/^## /{s=$0; next} s=="## Next"{n+=NF} END{print n+0}' "$backlog")"
(( next_words <= 1000 )) || echo "warning: ## Next of backlog.md has $next_words words, over 1000; move items to ## Later" >&2
later="$(awk '/^## /{s=$0; next} s=="## Later" && /^- /{n++} END{print n+0}' "$backlog")"
last=""
for d in "$root"/runs/*/; do [[ "${d%/}" == "$dir" ]] || last="${d%/}"; done
prev=""
[[ -f "$last/run.md" ]] && prev="$(sed -n 's/^- Later items: \([0-9][0-9]*\)$/\1/p' "$last/run.md" | head -n 1)"
if [[ -n "$prev" ]]; then
    printf 'backlog: ## Later has %d items (%+d since %s)\n' "$later" $((later - prev)) "$(basename "$last")" >&2
else
    echo "backlog: ## Later has $later items" >&2
fi
# Reflect rule 6: with 8 or more upkeep items in ## Next, this run is a workflow upkeep run.
upkeep="$(awk '/^## /{s=$0; next} s=="## Next" && /^- upkeep /{n++} END{print n+0}' "$backlog")"
echo "upkeep items: $upkeep" >&2
(( upkeep < 8 )) || echo "warning: $upkeep upkeep items wait; make this run a workflow upkeep run (reflect rule 6)" >&2
# The distinct product runs after the done row of the last run whose name has architecture: an
# open audit has not audited yet. A run has an open and a done row. A product run has a run.md
# branch of type feat, fix, or perf, and a slug with no hardening. The current run does not count.
product=0
while IFS= read -r r; do
    [[ "$r" != *hardening* ]] || continue
    t="$(sed -n 's/^- Branch: \([^/]*\)\/.*/\1/p' "$root/runs/$r/run.md" 2>/dev/null | head -n 1)" || true
    [[ "$t" != feat && "$t" != fix && "$t" != perf ]] || product=$((product + 1))
done < <(awk -F'|' -v cur="$run" '
    { name = $2; gsub(/ /, "", name); state = $4; gsub(/ /, "", state) }
    name !~ /^[0-9]{4}-/ { next }
    name ~ /architecture/ { if (state ~ /^done([,:]|$)/) { split("", seen); split("", list); n = 0 }; next }
    name != cur && !(name in seen) { seen[name] = 1; list[++n] = name }
    END { for (i = 1; i <= n; i++) print list[i] }' "$root/ledger.md")
(( product < 5 )) || echo "architecture audit due: $product product runs since the last architecture run;" \
    "audit the module boundaries, the files near 400 lines, the copies, and the red flags of" \
    ".claude/skills/architect/references/design-red-flags.md, and the tooling (scripts/, .claude/hooks," \
    ".claude/skills/*/scripts, .githooks, the Makefile): see docs/workflow/release-cycle.md" >&2
# Decision 0028, Word budgets: a consolidation is due when the workflow doc words pass TOTAL x 1.03.
top="$(git rev-parse --show-toplevel)"
total="$(awk -F'\t' '$1 == "TOTAL" { print $2 }' "$top/docs/workflow/budgets.tsv" 2>/dev/null || true)"
if [[ "$total" =~ ^[0-9]+$ ]]; then
    sum="$("$(cd "$(dirname "$0")/../../../.." && pwd)/scripts/workflow-words.sh" sum --root "$top")"
    (( sum * 100 <= total * 103 )) || echo "consolidation due: the workflow docs have $sum words, over TOTAL x 1.03 ($total in docs/workflow/budgets.tsv);" \
        "add one consolidation item to ## Next unless it has one (reflect rule 6)" >&2
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
