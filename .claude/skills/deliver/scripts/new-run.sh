#!/bin/bash
# Open a deliver run: .scratchpads/runs/<date>-<slug>/ with run.md and decisions.tsv,
# plus one line in .scratchpads/ledger.md. Running it again for the slug of an open run,
# on any day, returns the same folder and changes nothing.
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
mkdir -p "$dir"
touch "$root/learnings.md" "$root/backlog.md"

[[ -f "$root/ledger.md" ]] || printf '# Run ledger\n\n| Run | Goal | Status | Result |\n|---|---|---|---|\n' > "$root/ledger.md"
grep -q "| $run |" "$root/ledger.md" || printf '| %s | %s | open | |\n' "$run" "$slug" >> "$root/ledger.md"

[[ -f "$dir/decisions.tsv" ]] || printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n' > "$dir/decisions.tsv"
[[ -f "$dir/run.md" ]] || cat > "$dir/run.md" <<MD
# Run $run

- Status: open
- Goal: $slug
- Requirements:
- Branch:

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
