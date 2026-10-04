#!/bin/bash
# Open a deliver run: .scratchpads/runs/<date>-<slug>/ with run.md, decisions.tsv, and logs/,
# plus one line in .scratchpads/ledger.md. Running it again for the slug of an open run,
# on any day, returns the same folder and changes nothing. It prints the backlog section sizes,
# the upkeep items of ## Next, and a due architecture audit on stderr.
set -euo pipefail

slug="${1:?usage: new-run.sh <slug>}"
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "slug must be kebab-case: $slug" >&2; exit 2; }

root="$(git rev-parse --show-toplevel)/.scratchpads"
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
# Reflect rule 6: with 3 or more upkeep items in ## Next, this run is a workflow upkeep run.
upkeep="$(awk '/^## /{s=$0; next} s=="## Next" && /^- upkeep /{n++} END{print n+0}' "$backlog")"
echo "upkeep items: $upkeep" >&2
(( upkeep < 3 )) || echo "warning: $upkeep upkeep items wait; make this run a workflow upkeep run (reflect rule 6)" >&2
# The distinct product runs after the last run whose name has architecture. A run has an open and
# a done row. The current run, and a run whose name has workflow, upkeep, or docs, do not count.
product="$(awk -F'|' -v cur="$run" '
    { name = $2; gsub(/ /, "", name) }
    name !~ /^[0-9]{4}-/ { next }
    name ~ /architecture/ { split("", seen); n = 0; next }
    name != cur && name !~ /workflow|upkeep|docs/ && !(name in seen) { seen[name] = 1; n++ }
    END { print n + 0 }' "$root/ledger.md")"
(( product < 5 )) || echo "architecture audit due: $product product runs since the last architecture run; audit the module boundaries, the files near 400 lines, the copies, and the red flags of .claude/skills/architect/references/design-red-flags.md" >&2

[[ -f "$dir/decisions.tsv" ]] || printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n' > "$dir/decisions.tsv"
[[ -f "$dir/run.md" ]] || cat > "$dir/run.md" <<MD
# Run $run

- Status: open
- Goal: $slug
- Requirements:
- Branch:
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

echo "$dir"
