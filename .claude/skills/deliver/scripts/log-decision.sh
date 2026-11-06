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
# `criterion change` (any case) needs a criterion of analysis.md whose text differs from its text at
# the last row for that ID (the rule below), and the words old and new. A decision or why with "red tree", "red-tree", "passed on the
# red", "old tree", or "old-tree" at a word start (any case) claims a test result on that tree:
# its evidence then names a file of the logs/ folder of the run (logs/<file>, or a path that ends
# in /<run name>/logs/<file>) that exists. Name the rule by its key (INR-030/claim), not by those
# words. Each phase 4 row of a run folder with a plan.md needs a
# passing scripts/check-plan.sh (CHECK_PLAN_AT_PHASE4=1): a Criteria: field for each plan gate
# change, and a criterion change row for each of its IDs, while such a row can still come before
# Phase 4. The plan gate must be closed: a review-plan-<n>.md file, and a phase 3 row after the
# last phase 2 row. For a run that starts after the cutoff in check-plan.sh, the Fix check of the last
# review-plan-<n>.md also has its lines (lead-judgment.md, Fix check). A phase 6 row needs a passing
# scripts/check-plan.sh with no variable, the check
# of the land: the review files have their fields. A criterion change row skips that check. A phase
# 6 row of a run folder with a run.md also needs a passing scripts/check-eval-keys.sh against
# origin/main: each evals.md key that the branch of the last `- Branch:` line adds or changes has a
# graded eval folder. The first phase 4 row copies analysis.md to analysis-gate.md; check-plan.sh then
# needs a criterion change row for each criterion line that differs from the copy. A phase 4 row
# that is a criterion change row skips the plan check once the copy exists. The first phase 7 row of a run folder with a plan.md needs a passing
# scripts/check-plan.sh (CHECK_PLAN_AT_PHASE7=1): the Fix check has a line for each Act on item of
# each review-diff-<n>.md round, with the parts that lead-judgment.md, Fix check names, and each deferred
# control of the plan gate has its file. Else the script appends nothing and exits 2.
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
# A criterion change row needs a criterion whose text in analysis.md differs from its text at the
# last row for that ID. The text of a criterion is its line of the ## Acceptance criteria section
# and the indented lines under it, joined by single spaces (the rule of check-plan.sh for the first
# line). The last row for an ID is its last line in criteria-logged.tsv of the run folder; an ID with
# no line there reads analysis-gate.md, and an ID with neither counts as new. The row names the ID
# (a whole word). A row that names an ID which is in no criteria section is refused: a criterion
# outside the section has no text to compare, so no edit buys the row. Such a word is an ID only when
# it starts with C or with the capitals of a criterion ID, or when it starts an item line of analysis.md
# or analysis-gate.md, so a word such as MP3 is no ID. A row that names no ID needs an
# analysis.md whose hash differs from the #file line of criteria-logged.tsv (else from analysis-gate.md).
# A run with no baseline at all (no line in criteria-logged.tsv and no analysis-gate.md) has none to
# compare: its first row needs an analysis.md newer than decisions.tsv, the old file-time rule.
# A passing row appends one line "<ID><TAB><text>" for each ID that it names, and a #file line.
# criteria-logged.tsv is append-only, as decisions.tsv is: only this script writes it.
# criteria <file> prints "<ID><TAB><text>" for each criterion of the section.
criteria() {
    [[ -f "$1" ]] || return 0
    awk '
        function flush() { if (cur != "") print cur "\t" txt; cur = "" }
        /^## / { flush(); on = ($0 ~ /^## Acceptance criteria[[:space:]]*$/); next }
        !on { next }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]/ {
            if (cur != "") { t = $0; gsub(/[\t ]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t); txt = txt " " t }
            next
        }
        {
            flush()
            if ($0 !~ /^(- |[0-9]+\. |\|)/) next
            t = $0; sub(/^(- |[0-9]+\. |\|)[*[:space:]]*/, "", t)
            if (!match(t, /^[A-Z]+[0-9]+[a-z]*/) || substr(t, RLENGTH + 1, 1) ~ /[A-Za-z0-9]/) next
            id = substr(t, 1, RLENGTH)
            if (id in seen) next
            seen[id] = 1; cur = id; txt = $0; gsub(/\t/, " ", txt)
        }
        END { flush() }' "$1"
}
new_logged=""
if [[ "$(lower "$2")" == "criterion change"* ]]; then
    run_dir="${file%/*}"
    [[ -f "$run_dir/analysis.md" ]] || {
        echo "a criterion change row needs ${run_dir}/analysis.md: change the criterion there, then log the row" >&2
        exit 2
    }
    word='(^|[^a-z])old([^a-z]|$)'
    text="$(lower "$2 $3")"
    [[ "$text" =~ $word && "$text" =~ ${word/old/new} ]] || { echo "a criterion change row names the old and new value (the words old and new)" >&2; exit 2; }
    criteria "$run_dir/analysis.md" > "$run_dir/.criteria-now.$$"
    criteria "$run_dir/analysis-gate.md" > "$run_dir/.criteria-gate.$$"
    file_sha="$(shasum -a 256 < "$run_dir/analysis.md")"
    gate_sha=""
    [[ ! -f "$run_dir/analysis-gate.md" ]] || gate_sha="$(shasum -a 256 < "$run_dir/analysis-gate.md")"
    baseless=0 newer=0
    if [[ ! -s "$run_dir/criteria-logged.tsv" && ! -f "$run_dir/analysis-gate.md" ]]; then
        baseless=1
        ! awk -v a="$(stat -f %Fm "$run_dir/analysis.md")" -v d="$(stat -f %Fm "$file")" 'BEGIN { exit !(a > d) }' || newer=1
    fi
    code=0
    new_logged="$(BASELESS="$baseless" NEWER="$newer" DECISION="$2" NOW="$run_dir/.criteria-now.$$" GATE="$run_dir/.criteria-gate.$$" LOGGED="$run_dir/criteria-logged.tsv" FILESHA="$file_sha" GATESHA="$gate_sha" ANALYSIS="$run_dir/analysis.md" GATEFILE="$run_dir/analysis-gate.md" awk '
        function load(file, text, has,  l, i, id) {
            while ((getline l < file) > 0) { i = index(l, "\t"); id = substr(l, 1, i - 1); text[id] = substr(l, i + 1); has[id] = 1; known[id] = 1 }
            close(file)
        }
        # items(file): the ID of each item line of the file, in any section.
        function items(file,  l, t) {
            while ((getline l < file) > 0) {
                if (l !~ /^(- |[0-9]+\. |\|)/) continue
                t = l; sub(/^(- |[0-9]+\. |\|)[*[:space:]]*/, "", t)
                if (match(t, /^[A-Z]+[0-9]+[a-z]*/) && substr(t, RLENGTH + 1, 1) !~ /[A-Za-z0-9]/) item[substr(t, 1, RLENGTH)] = 1
            }
            close(file)
        }
        BEGIN {
            load(ENVIRON["NOW"], now, hasnow); load(ENVIRON["GATE"], gate, hasgate); load(ENVIRON["LOGGED"], logged, haslogged)
            delete known["#file"]
            items(ENVIRON["ANALYSIS"]); items(ENVIRON["GATEFILE"])
            prefix["C"] = 1
            for (id in known) { p = id; sub(/[0-9].*/, "", p); prefix[p] = 1 }
            rest = ENVIRON["DECISION"]
            while (match(rest, /(^|[^A-Za-z0-9])[A-Z]+[0-9]+[a-z]*([^A-Za-z0-9]|$)/)) {
                tok = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
                gsub(/^[^A-Z]+/, "", tok); gsub(/[^A-Za-z0-9]+$/, "", tok)
                p = tok; sub(/[0-9].*/, "", p)
                if (tok in known) named[tok] = 1; else if ((p in prefix) || (tok in item)) outside[tok] = 1
            }
            if (length(named) == 0 && length(outside) > 0) exit 4
            ok = 0
            for (id in named) {
                base = (id in haslogged) ? logged[id] : ((id in hasgate) ? gate[id] : "")
                if (((id in hasnow) ? now[id] : "") != base) ok = 1
            }
            if (length(named) == 0) ok = (ENVIRON["FILESHA"] != (("#file" in haslogged) ? logged["#file"] : ENVIRON["GATESHA"]))
            if (ENVIRON["BASELESS"] == 1) ok = (ENVIRON["NEWER"] == 1)
            if (!ok) exit 3
            for (id in named) print id "\t" ((id in hasnow) ? now[id] : "")
            print "#file\t" ENVIRON["FILESHA"]
        }')" || code=$?
    rm -f "$run_dir/.criteria-now.$$" "$run_dir/.criteria-gate.$$"
    case "$code" in
        0) ;;
        4)
            echo "a criterion change row names an ID that is in no ## Acceptance criteria section of ${run_dir}/analysis.md or analysis-gate.md: put the criterion in that section (scripts/check-plan.sh reads it there), and name its ID" >&2
            exit 2 ;;
        *)
            echo "a criterion change row needs a criterion whose text in ${run_dir}/analysis.md differs from its text at the last row for that ID (the first row reads analysis-gate.md; a run with no baseline needs an analysis.md newer than decisions.tsv): change the criterion there, and name its ID in the row" >&2
            exit 2 ;;
    esac
fi
claim='(^|[^a-z])(red[- ]tree|passed on the red|old[- ]tree)'
if [[ "$(lower "$2 $3")" =~ $claim ]]; then
    run_dir="${file%/*}"
    run_name="$(basename "$run_dir")"
    named=0
    while IFS= read -r evidence_word; do
        evidence_word="${evidence_word%.}"
        evidence_word="${evidence_word%%:*}"
        if [[ "$evidence_word" == logs/* ]]; then log_file="${evidence_word#logs/}"
        elif [[ "$evidence_word" == */"$run_name"/logs/* ]]; then log_file="${evidence_word##*/"$run_name"/logs/}"
        else continue
        fi
        [[ "$log_file" != *..* && -f "$run_dir/logs/$log_file" ]] && named=1
    done < <(tr ',;() \t' '\n' <<<"$4")
    [[ $named -eq 1 ]] || {
        echo "a row that claims a red-tree or old-tree test result names a file of $run_dir/logs/ in its evidence: write the log there, then log the row, or, for no test claim, name the rule INR-030/claim" >&2
        exit 2
    }
fi

plan_check="$(cd "$(dirname "$0")/../../../.." && pwd)/scripts/check-plan.sh"
# A phase 4 row: the plan gate is closed, so plan.md must pass check-plan.sh now.
if [[ "$1" == 4 && -f "${file%/*}/plan.md" ]] && ! [[ "$(lower "$2")" == "criterion change"* && -f "${file%/*}/analysis-gate.md" ]]; then
    if ! out="$(CHECK_PLAN_AT_PHASE4=1 "$plan_check" "${file%/*}" 2>&1)"; then
        printf '%s\na phase 4 row needs a passing check-plan.sh: fix plan.md, log the rows above, or add the Fix check lines, then log this row\n' "$out" >&2
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
        printf '%s\nthe first phase 7 row needs a passing check-plan.sh: add or fix the Fix check lines, then log this row\n' "$out" >&2
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
[[ -z "$new_logged" ]] || printf '%s\n' "$new_logged" >> "${file%/*}/criteria-logged.tsv"
[[ -z "$from_file" ]] || rm -f "$from_file"
