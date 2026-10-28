#!/bin/bash
# Append one row to the decisions.tsv of a run. The script writes the ts column from the clock,
# so no agent types or estimates a time.
# Usage: log-decision.sh <run folder> <phase> <decision> <why> <evidence> <result>
#        log-decision.sh <run folder> --from <file>
# With --from, the file has five lines: phase, decision, why, evidence, result. Use it when a
# field has text that the guardrail hook blocks in a command, for example the check and the commit.
# The script removes the file after the row is appended, as .githooks/post-commit does for the
# commit message; a refused row keeps it.
# A row whose decision or result starts with `default` (any case) needs `Reverse:` (any case) in
# its why: the word or line that reverses the default (deliver autonomy rules). The phase is one
# digit (0-9), so land.sh finds the mutation pass row of phase 7. A decision that starts with
# `criterion change` (any case) needs an analysis.md in the run folder that changed after the last
# row, and the words old and new. Each phase 4 row of a run folder with a plan.md needs a
# passing scripts/check-plan.sh (CHECK_PLAN_AT_PHASE4=1): a Criteria: field for each plan gate
# change, and a criterion change row for each of its IDs, while such a row can still come before
# Phase 4. The plan gate must be closed: a review-plan-<n>.md file, and a phase 3 row after the
# last phase 2 row. A phase 6 row needs a passing scripts/check-plan.sh with no variable, the check
# of the land: the review files have their fields. A criterion change row skips that check. A phase
# 6 row of a run folder with a run.md also needs a passing scripts/check-eval-keys.sh against
# origin/main: each evals.md key that the branch of the last `- Branch:` line adds or changes has a
# graded eval folder. The first phase 4 row copies analysis.md to analysis-gate.md; check-plan.sh then
# needs a criterion change row for each criterion line that differs from the copy. A phase 4 row
# that is a criterion change row skips the plan check once the copy exists. The first phase 7 row of a run folder with a plan.md needs a passing
# scripts/check-plan.sh (CHECK_PLAN_AT_PHASE7=1): the Fix check has a line for each Act on item of
# each review-diff-<n>.md round. Else the script appends nothing and exits 2.
set -euo pipefail

usage="usage: log-decision.sh <run folder> <phase> <decision> <why> <evidence> <result>
       log-decision.sh <run folder> --from <file>"
from_file=""
if [[ $# -eq 3 && "$2" == --from ]]; then
    [[ -f "$3" ]] || { echo "no file $3" >&2; exit 2; }
    from_file="$3"
    fields=()
    while IFS= read -r line || [[ -n "$line" ]]; do fields+=("$line"); done < "$3"
    [[ ${#fields[@]} -eq 5 ]] || { echo "$3 has ${#fields[@]} lines; it must have five lines" >&2; exit 2; }
    set -- "$1" "${fields[@]}"
fi
[[ $# -eq 6 ]] || { echo "$usage" >&2; exit 2; }
file="$1/decisions.tsv"
[[ -f "$file" ]] || { echo "no decisions.tsv in $1; open the run with new-run.sh" >&2; exit 2; }
shift
[[ "$1" =~ ^[0-9]$ ]] || { echo "the phase '$1' is not one digit; write the phase number only, for example 4" >&2; exit 2; }
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
if [[ "$(lower "$2")" == default* || "$(lower "$5")" == default* ]] && [[ "$(lower "$3")" != *reverse:* ]]; then
    echo "the decision or the result starts with default, and the why has no Reverse: <the word or line that reverses it>" >&2
    exit 2
fi
# analysis.md is gitignored, so the test is its mtime. Two criterion change rows need two edits.
if [[ "$(lower "$2")" == "criterion change"* ]]; then
    [[ "${file%/*}/analysis.md" -nt "$file" ]] || {
        echo "a criterion change row needs an analysis.md that is newer than the last row: change the criterion in ${file%/*}/analysis.md, then log the row" >&2
        exit 2
    }
    word='(^|[^a-z])old([^a-z]|$)'
    text="$(lower "$2 $3")"
    [[ "$text" =~ $word && "$text" =~ ${word/old/new} ]] || { echo "a criterion change row names the old and new value (the words old and new)" >&2; exit 2; }
fi

plan_check="$(cd "$(dirname "$0")/../../../.." && pwd)/scripts/check-plan.sh"
# A phase 4 row: the plan gate is closed, so plan.md must pass check-plan.sh now.
if [[ "$1" == 4 && -f "${file%/*}/plan.md" ]] && ! [[ "$(lower "$2")" == "criterion change"* && -f "${file%/*}/analysis-gate.md" ]]; then
    if ! out="$(CHECK_PLAN_AT_PHASE4=1 "$plan_check" "${file%/*}" 2>&1)"; then
        printf '%s\na phase 4 row needs a passing check-plan.sh: fix plan.md or log the rows above, then log this row\n' "$out" >&2
        exit 2
    fi
fi
# The first phase 4 row: analysis.md is copied to analysis-gate.md, so check-plan.sh can find a criterion
# that a later row changes. A run that has phase 4 rows and no copy is older than the rule.
if [[ "$1" == 4 && -f "${file%/*}/analysis.md" && ! -e "${file%/*}/analysis-gate.md" ]] && ! awk -F'\t' '$2 == "4" { f = 1 } END { exit !f }' "$file"; then
    cp "${file%/*}/analysis.md" "${file%/*}/analysis-gate.md"
fi
# A phase 6 row: check-plan.sh passes as the land check runs it (no plan gate test), so the review
# fields are complete before the fixer starts. The criterion change row repairs a missing criterion
# change row, which that check refuses, so it skips the check.
if [[ "$1" == 6 && -f "${file%/*}/plan.md" && "$(lower "$2")" != "criterion change"* ]]; then
    if ! out="$("$plan_check" "${file%/*}" 2>&1)"; then
        printf '%s\na phase 6 row needs a passing check-plan.sh: fix the review file or the plan, then log this row\n' "$out" >&2
        exit 2
    fi
fi
# The first phase 7 row: the Fix check of the last review round has a line for each Act on item.
if [[ "$1" == 7 && -f "${file%/*}/plan.md" ]] && ! awk -F'\t' '$2 == "7" { f = 1 } END { exit !f }' "$file"; then
    if ! out="$(CHECK_PLAN_AT_PHASE7=1 "$plan_check" "${file%/*}" 2>&1)"; then
        printf '%s\nthe first phase 7 row needs a passing check-plan.sh: add the Fix check lines, then log this row\n' "$out" >&2
        exit 2
    fi
fi
# A phase 6 row: each evals.md key of the branch has its grade before the gates (RFL-037).
if [[ "$1" == 6 && -f "${file%/*}/run.md" ]]; then
    if ! out="$("${plan_check%/*}/check-eval-keys.sh" origin/main "${file%/*}" 2>&1)"; then
        printf '%s\na phase 6 row needs a graded key for each new evals.md key\n' "$out" >&2
        exit 2
    fi
fi

# A tab or a line break in a field would break the TSV columns. Change each one to a space.
row="$(date +%FT%R)"
for field in "$@"; do
    row+=$'\t'"$(printf '%s' "$field" | tr '\t\n\r' '   ')"
done
printf '%s\n' "$row" >> "$file"
[[ -z "$from_file" ]] || rm -f "$from_file"
