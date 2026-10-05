#!/bin/bash
# Check the Unknowns table of analysis.md and the plan.md of a run folder before the plan gate
# (deliver Phase 3). check-governance.sh runs it again before the land.
# Usage: scripts/check-plan.sh <run folder>
# - analysis.md has a `## Unknowns` table. Each row has an answer and a row cell with a
#   decisions.tsv time (YYYY-MM-DDTHH:MM). A row with the resolver `split` has a child row (a row
#   whose parent is its id). The columns are id, parent, question, resolver, answer, and row;
#   the script finds them by the header names. A bar in a cell is written as \|.
# - plan.md has an `Agents:` line, and each ### heading in its `## Slices` section has a
#   `- Check:` line.
# - Each numbered item under `## Act on` of a review-*.md file that is not a nit has an `Invariant`
#   and a `Siblings` field (lead-judgment.md), and the section has no item in another form. A
#   review file older than the rule is not checked.
# It prints each failure and exits 1. scripts/check-plan.test.sh tests it.
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: scripts/check-plan.sh <run folder>" >&2; exit 2; }
run="${1%/}"
fail=0
say() { echo "check-plan: $1" >&2; fail=1; }

if [[ ! -f "$run/analysis.md" ]]; then
    say "no analysis.md in $run"
else
    while IFS= read -r msg; do say "$msg"; done < <(awk '
        /^## / { inside = ($0 ~ /^## Unknowns[[:space:]]*$/); next }
        !inside || !/^\|/ { next }
        {
            line = $0
            gsub(/\\\|/, "\001", line)
            n = split(line, cell, "|")
            for (i = 2; i < n; i++) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell[i]) }
        }
        !header { for (i = 2; i < n; i++) col[cell[i]] = i; header = 1; next }
        cell[2] ~ /^-+$/ { next }
        {
            rows++
            id = cell[col["id"]]
            parent[cell[col["parent"]]] = 1
            if (cell[col["resolver"]] == "split") split_ids[id] = 1
            if (cell[col["answer"]] == "" || cell[col["row"]] !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]/)
                print "open unknown: " $0
        }
        END {
            if (!rows) print "analysis.md has no ## Unknowns table with rows"
            for (id in split_ids) if (!(id in parent)) print "split unknown " id " has no child row"
        }' "$run/analysis.md")
fi

if [[ ! -f "$run/plan.md" ]]; then
    say "no plan.md in $run"
else
    grep -qE '^(- )?Agents:' "$run/plan.md" || say "plan.md has no Agents: line"
    while IFS= read -r msg; do say "$msg"; done < <(awk '
        function close_slice() { if (slice != "" && !checked) print "slice \"" slice "\" has no \"- Check:\" line"; slice = "" }
        /^## / { close_slice(); inside = ($0 ~ /^## Slices[[:space:]]*$/); next }
        !inside { next }
        /^### / { close_slice(); slice = $0; checked = 0; next }
        /^- Check:/ { checked = 1 }
        END { close_slice() }' "$run/plan.md")
fi
# 2026-10-05, the commit that added the field rule: an older review file has no fields.
cutoff=1791222684
for review in "$run"/review-*.md; do
    [[ -f "$review" && $(stat -f %m "$review") -ge $cutoff ]] || continue
    while IFS= read -r msg; do say "$msg"; done < <(awk -v file="${review##*/}" '
        function close_item() {
            if (item && !nit)
                for (f = 1; f <= 2; f++)
                    if (text !~ (field[f] "[*[:space:]]*(\\([^)]*\\))?[*[:space:]]*:"))
                        print file ": Act on item " item " has no " field[f] " field (a review file from before the rule: add the fields, or do not edit it)"
            item = ""
        }
        function close_section() {
            if (inside && other && !numbered) print file ": ## Act on has no numbered item"
            inside = numbered = other = 0
        }
        BEGIN { field[1] = "Invariant"; field[2] = "Siblings" }
        /^## / { close_item(); close_section(); inside = ($0 ~ /^## Act on/); next }
        !inside { next }
        /^[0-9]+\. / {
            close_item(); item = $0 + 0; numbered = 1; text = $0
            tag = tolower($0); sub(/^[0-9]+\.[[:space:]]*\**/, "", tag); nit = (tag ~ /^\(nit/)
            next
        }
        /^([-*] |### )/ { other = 1 }
        { text = text "\n" $0 }
        END { close_item(); close_section() }' "$review")
done
exit "$fail"
