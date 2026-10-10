#!/bin/bash
# Check the reflect governance of decision 0028 against a base. land.sh runs it before the push.
# Usage: scripts/check-governance.sh <base> [<run folder>]
# - A row of docs/workflow/budgets.tsv whose words go up names a decisions.tsv row in its
#   decision cell, as `decisions.tsv <YYYY-MM-DDTHH:MM>`.
# - When the run folder has a reflect row (phase 8) in decisions.tsv and the only class of the
#   branch is docs, at most one rules.tsv row changes to delete or merge (reflect rule 7).
# - With a run folder, check-plan.sh passes on it (the Unknowns table and the plan), and each
#   research-<name>.md of the run folder has a docs/research/<name>.md that the branch adds or changes.
# - With a run folder, ## Next of the main-checkout .scratchpads/backlog.md has no taken item of
#   that run: a line with `(taken: run <run folder name>`.
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
        copy="docs/research/${name#research-}"
        [[ -f "$copy" ]] && ! git diff --quiet "$base" -- "$copy" && continue
        echo "check-governance: $name has no $copy that this branch adds or changes; research findings go to docs/research" >&2
        fail=1
    done
fi
# A run moves its own taken items out of ## Next of the backlog before the land: each run reads
# ## Next at Phase 0, so a long ## Next costs each run. The backlog is in the main checkout, the
# parent of the git common dir, also when the branch is in a worktree.
backlog="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.scratchpads/backlog.md"
if [[ -n "$run" && -f "$backlog" ]]; then
    name="$(basename "${run%/}")"
    while IFS= read -r hit; do
        echo "check-governance: backlog.md:${hit%%:*}: ## Next has a taken item of $name; move it to ledger.md or ## Later" >&2
        fail=1
    done < <(awk -v key="(taken: run $name" '/^## /{ s = $0; next } s == "## Next" && index($0, key) { print FNR ":" }' "$backlog")
fi
if [[ -n "$run" ]] && ! "$here/check-plan.sh" "$run"; then
    echo "check-governance: check-plan.sh $run failed" >&2
    fail=1
fi
exit "$fail"
