#!/bin/bash
# Check the reflect governance of decision 0028 against a base. land.sh runs it before the push.
# Usage: scripts/check-governance.sh <base> [<run folder>]
# - A row of docs/workflow/budgets.tsv whose words go up names a decisions.tsv row in its
#   decision cell, as `decisions.tsv <YYYY-MM-DDTHH:MM>`. The TOTAL row goes up by at most 50
#   words, unless the branch has a QUOTA row at or above its new TOTAL (a consolidation run).
# - When the run folder has a reflect row (phase 8) in decisions.tsv and the only class of the
#   branch is docs, at most one rules.tsv row changes to delete or merge (reflect rule 7).
# - With a run folder, check-plan.sh passes on it (the Unknowns table and the plan), and each
#   research-<name>.md of the run folder has a docs/research/<name>.md that the branch adds or changes.
# - With a run folder, no holdout is in eval/holdout-fails.txt (grade.py verdict) both in this run
#   and in the newest done run (Status done) of the ledger.md beside runs/ whose eval/scores.tsv has
#   a row of that holdout.
# - With a run folder that has a reflect row (phase 8), or with GOVERNANCE_LAND set (land.sh),
#   ## Next of the main-checkout .scratchpads/backlog.md has no taken item of that run: a line with
#   `(taken: run <run folder name>` and then a space, a comma, or `)`. A backlog with no line that
#   starts with `## Next` fails.
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
    up="$(at_base "$budgets" | awk -F'\t' '
        NR == FNR { if ($1 == "TOTAL") t = $2; if ($1 == "QUOTA") q = $2; next }
        $1 == "TOTAL" { nt = $2 } $1 == "QUOTA" { nq = $2 }
        END { if (t != "" && nt - t > 50 && !(nq != "" && nt + 0 <= nq + 0)) print nt - t }' - "$budgets")"
    if [[ -n "$up" ]]; then
        echo "check-governance: budgets.tsv: TOTAL goes up by $up words, over the cap of 50 for a branch; trim; only a consolidation run raises it more, and its TOTAL stays at or below its QUOTA row (decision 0028, Word budgets)" >&2
        fail=1
    fi
fi

# A run with a reflect row (phase 8) in its decisions.tsv.
reflected() { [[ -n "$run" && -f "$run/decisions.tsv" ]] && awk -F'\t' '$2 == "8" { found = 1 } END { exit !found }' "$run/decisions.tsv"; }
rules=docs/workflow/rules.tsv
if [[ -f "$rules" ]] && reflected; then
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
# parent of the git common dir, also when the branch is in a worktree. Phase 8 moves the items,
# so the check waits for the reflect row: Phase 7 runs this script before it. land.sh sets
# GOVERNANCE_LAND, so a land with no reflect row still fails on a taken item.
backlog="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.scratchpads/backlog.md"
if [[ -f "$backlog" ]] && { reflected || [[ -n "$run" && -n "${GOVERNANCE_LAND:-}" ]]; }; then
    name="$(basename "${run%/}")"
    while IFS= read -r hit; do
        if [[ $hit == none ]]; then
            echo "check-governance: backlog.md has no line that starts with ## Next; restore the heading" >&2
        else
            echo "check-governance: backlog.md:${hit%%:*}: ## Next has a taken item of $name; move it to ledger.md or ## Later" >&2
        fi
        fail=1
    done < <(awk -v key="[(]taken: run $name[ ,)]" '
        /^## / { s = $0; if (index(s, "## Next") == 1) seen = 1; next }
        index(s, "## Next") == 1 && $0 ~ key { print FNR ":" }
        END { if (!seen) print "none" }' "$backlog")
fi
# Two holdout fails in a row stop the land. grade.py verdict writes its `holdout fail <H>` lines to
# <run>/eval/holdout-fails.txt. For each H of this run, the run to compare is the newest done run
# of the ledger.md beside runs/ whose eval/scores.tsv has a row of H: a run that did not run H is
# skipped (docs/workflow/evals.md, the pass rule).
failed_holdouts() { sed -n 's/^holdout fail \(H[0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | sort -u; }
if [[ -n "$run" && -s "$run/eval/holdout-fails.txt" ]]; then
    runs="$(dirname "${run%/}")"
    done_runs="$(awk -F' *[|] *' -v me="$(basename "${run%/}")" '$4 ~ /^done($|:)/ && $2 != me { name[++n] = $2 } END { for (i = n; i > 0; i--) print name[i] }' \
        "$(dirname "$runs")/ledger.md" 2>/dev/null || true)"
    while IFS= read -r h; do
        while IFS= read -r prev; do
            [[ -n "$prev" ]] && awk -F'\t' -v h="$h" '$2 == h { found = 1 } END { exit !found }' "$runs/$prev/eval/scores.tsv" 2>/dev/null || continue
            if failed_holdouts "$runs/$prev/eval/holdout-fails.txt" | grep -qx "$h"; then
                echo "check-governance: holdout $h failed in this run and in $prev; fix its grader or docs before the land" >&2
                fail=1
            fi
            break
        done <<<"$done_runs"
    done < <(failed_holdouts "$run/eval/holdout-fails.txt")
fi
if [[ -n "$run" ]] && ! "$here/check-plan.sh" "$run"; then
    echo "check-governance: check-plan.sh $run failed" >&2
    fail=1
fi
exit "$fail"
