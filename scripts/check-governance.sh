#!/bin/bash
# Check the reflect governance of decision 0028 against a base. land.sh runs it before the push.
# Usage: scripts/check-governance.sh <base> [<run folder>]
# - A row of docs/workflow/budgets.tsv whose words go up names a decisions.tsv row in its
#   decision cell, as `decisions.tsv <YYYY-MM-DDTHH:MM>`.
# - When the run folder has a reflect row (phase 8) in decisions.tsv and the only class of the
#   branch is docs, at most one rules.tsv row changes to delete or merge (reflect rule 7).
# - With a run folder, check-plan.sh passes on it (the Unknowns table and the plan), and each
#   research-<name>.md of the run folder has docs/research/<name>.md.
# scripts/check-governance.test.sh tests it.
set -euo pipefail

die() { echo "check-governance: $1" >&2; exit 1; }

[[ $# -ge 1 ]] || { echo "usage: scripts/check-governance.sh <base> [<run folder>]" >&2; exit 2; }
base="$1" run="${2:-}"
here="$(cd "$(dirname "$0")" && pwd)"
cd "$(git rev-parse --show-toplevel)"
git rev-parse -q --verify "$base^{commit}" > /dev/null || die "no commit $base"
fail=0

# The file at the base, or nothing when the base has no such file.
at_base() { git show "$base:$1" 2>/dev/null || true; }

budgets=docs/workflow/budgets.tsv
if [[ -f "$budgets" ]]; then
    while IFS= read -r msg; do echo "check-governance: $msg" >&2; fail=1; done < <(at_base "$budgets" | awk -F'\t' '
        NR == FNR { if (FNR > 1) old[$1] = $2; next }
        FNR > 1 && ($1 in old) && $2 + 0 > old[$1] + 0 &&
            $3 !~ /decisions\.tsv [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]/ {
            print "budgets.tsv: the row for " $1 " goes up from " old[$1] " to " $2 "; name the decisions.tsv row in its decision cell as decisions.tsv <YYYY-MM-DDTHH:MM>"
        }' - "$budgets")
fi

rules=docs/workflow/rules.tsv
if [[ -n "$run" && -f "$run/decisions.tsv" && -f "$rules" ]] &&
    awk -F'\t' '$2 == "8" { found = 1 } END { exit !found }' "$run/decisions.tsv"; then
    out="$("$here/check-changed.sh" "$base")" || die "check-changed.sh $base failed"
    if [[ "$(sed -n 's/^classes: //p' <<<"$out")" == docs ]]; then
        removed="$(at_base "$rules" | awk -F'\t' '
            NR == FNR { if (FNR > 1) old[$1] = $3; next }
            FNR > 1 && $3 ~ /^(delete|merge)$/ && old[$1] !~ /^(delete|merge)$/ { n++ }
            END { print n + 0 }' - "$rules")"
        if [[ "$removed" -gt 1 ]]; then
            echo "check-governance: rules.tsv: $removed rows change to delete or merge; a reflect run removes at most one rule" >&2
            fail=1
        fi
    fi
fi
if [[ -n "$run" ]]; then
    for f in "$run"/research-*.md; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f")"
        [[ -f "docs/research/${name#research-}" ]] && continue
        echo "check-governance: $name has no docs/research/${name#research-}; research findings go to docs/research" >&2
        fail=1
    done
fi
if [[ -n "$run" ]] && ! "$here/check-plan.sh" "$run"; then
    echo "check-governance: check-plan.sh $run failed" >&2
    fail=1
fi
exit "$fail"
