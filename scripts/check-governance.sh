#!/bin/bash
# Check the reflect governance of decision 0028 against a base. land.sh runs it before the push.
# Usage: scripts/check-governance.sh <base> [<run folder>]
# - A row of docs/workflow/budgets.tsv whose words go up names a decisions.tsv row in its
#   decision cell, as `decisions.tsv <YYYY-MM-DDTHH:MM>`. A raised TOTAL row also differs from the
#   cell of the base, and with a run folder the cited time is a row of its decisions.tsv. A changed
#   TOTAL is within 3 % of `scripts/workflow-words.sh sum`; a raise is at most the sum.
# - The always-on words (`scripts/workflow-words.sh always-on`: the start files and the description
#   lines of the skills and agents) and the count of skills plus agents (`workflow-words.sh count`)
#   stay at or below their value at the merge base of the base and HEAD (decision 0028, Word
#   budgets).
# - When the run folder has a reflect row (phase 8) in decisions.tsv and the only class of the
#   branch is docs, at most one rules.tsv row changes to delete or merge (reflect rule 7).
# - With a run folder, check-plan.sh passes on it (the Unknowns table and the plan), and each
#   research-<name>.md of the run folder has a docs/research/<name>.md that the branch adds or changes,
#   or that a commit of the base changed on or after the run start date (the YYYY-MM-DD prefix of
#   the run folder name; a run that lands in steps copied it in an earlier landing).
# - With a run folder, no holdout is in eval/holdout-fails.txt (grade.py verdict) both in this run
#   and in the newest done run (Status done) of the ledger.md beside runs/ whose eval/scores.tsv has
#   a row of that holdout.
# - With a run folder that has a reflect row (phase 8), or with GOVERNANCE_LAND set (land.sh),
#   ## Next of the main-checkout .scratchpads/backlog.md has no taken item of that run: a line with
#   `(taken: run <run folder name>` and then a space, a comma, or `)`. A backlog with no line that
#   starts with `## Next` fails.
# - Each `| F<n> |` row of docs/requirements/features.md at the base keeps its ID, Feature, and Req cells
#   in the work tree file: a drop sets `Dropped (<reason>)`, and a new idea gets a new ID.
# - A run number that HEAD adds to a done State of features.md is 1 + the highest run number of its
#   Release at the base. Each run number of a done State at the base stays in its row.
# - With a run folder whose run.md has a `- Lands:` line, each F-ID of the newest (last) such line has a
#   done state in features.md that differs from its state at the base, on any branch type. `- Lands: none`
#   names no F-ID; an empty line fails. A `feat/`, `fix/`, or `perf/` branch that changes Sources/,
#   Package.swift, Package.resolved, or Support/ needs the line. A `feat/` branch that changes
#   Sources/ cannot write `- Lands: none`: scripts/tag-release.sh needs a done row for its run number.
# - With a run folder, scripts/check-eval-keys.sh passes on this tree: each evals.md key that the
#   branch adds or changes has an eval folder of the run with its exact key text and a scores.tsv line.
# - The done runs of the holdout stop are the ledger statuses `done`, `done:`, and `done,`.
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
words="$here/workflow-words.sh"
if [[ -f "$budgets" ]]; then
    while IFS= read -r msg; do echo "check-governance: $msg" >&2; fail=1; done < <(at_base "$budgets" | awk -F'\t' '
        NR == FNR { if (FNR > 1) old[$1] = $2; next }
        FNR > 1 && ($1 in old) && $2 + 0 > old[$1] + 0 &&
            $3 !~ /decisions\.tsv [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]/ {
            print "budgets.tsv: the row for " $1 " goes up from " old[$1] " to " $2 "; name the decisions.tsv row in its decision cell as decisions.tsv <YYYY-MM-DDTHH:MM>"
        }' - "$budgets")
    # The TOTAL row: a raise cites a row of its own run, and a changed value is near the sum of the docs.
    total_row() { awk -F'\t' '$1 == "TOTAL" { print $2 "\t" $3; exit }'; }
    IFS=$'\t' read -r old_total old_cell <<<"$(at_base "$budgets" | total_row)"
    IFS=$'\t' read -r new_total new_cell <<<"$(total_row < "$budgets")"
    if [[ -n "${old_total:-}" && -n "${new_total:-}" && "$new_total" != "$old_total" ]]; then
        if [[ ! "$old_total$new_total" =~ ^[0-9]+$ ]]; then
            echo "check-governance: budgets.tsv: TOTAL is not a number: $old_total at the base, $new_total now" >&2
            fail=1
        else
            if ((new_total > old_total)); then
                cited='decisions\.tsv ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2})'
                if [[ "$new_cell" == "$old_cell" ]]; then
                    echo "check-governance: budgets.tsv: TOTAL goes up from $old_total to $new_total, but its decision cell is the cell of the base; it names a decisions.tsv row of its own" >&2
                    fail=1
                elif [[ -n "$run" && "$new_cell" =~ $cited ]] \
                    && ! awk -F'\t' -v t="${BASH_REMATCH[1]}" '$1 == t { found = 1 } END { exit !found }' "$run/decisions.tsv" 2>/dev/null; then
                    echo "check-governance: budgets.tsv: TOTAL cites decisions.tsv ${BASH_REMATCH[1]}, but $run/decisions.tsv has no row with that time" >&2
                    fail=1
                fi
            fi
            sum="$("$words" sum)"
            # A raise takes no room above the sum: the tripwire fires at 3 % over TOTAL.
            if ((new_total > old_total)); then over=$((new_total > sum)); else over=$((new_total * 100 > sum * 103)); fi
            if ((sum * 100 > new_total * 103 || over)); then
                echo "check-governance: budgets.tsv: TOTAL is $new_total, which is not the sum of the workflow docs ($sum words; a raise sets it at most to the sum, a cut within 3 % of it); set TOTAL to the output of scripts/workflow-words.sh sum" >&2
                fail=1
            fi
        fi
    fi
fi

# The always-on words and the count of skills plus agents stay at or below the merge base: the work
# tree is the branch as it lands, and the tip of the base can hold changes that the branch lacks.
mb="$(git merge-base "$base" HEAD)" || die "no merge base of $base and HEAD"
base_words="$("$words" always-on --rev "$mb")" tree_words="$("$words" always-on)"
if ((tree_words > base_words)); then
    echo "check-governance: the always-on words go from $base_words at the merge base to $tree_words (the start files, which are AGENTS.md, CLAUDE.md, .claude/CLAUDE.md, the .claude/rules files with no paths:, and the files they import; and the description lines of the skills and agents); move a whole part to a references file and leave a one-line pointer; do not trim the words of a rule" >&2
    fail=1
fi
base_count="$("$words" count --rev "$mb")" tree_count="$("$words" count)"
if ((tree_count > base_count)); then
    echo "check-governance: the branch has $tree_count skills and agents, the merge base has $base_count; delete one for each new one" >&2
    fail=1
fi

# features.md keeps the row of each feature ID of the base; a base with no file has none to keep.
features=docs/requirements/features.md
cells() { awk -F'|' '/^\| F[0-9]+ \|/ { for (i = 2; i <= 6; i++) gsub(/^ +| +$/, "", $i); print $2 "|" $3 "|" $6 }'; }
if [[ -n "$(at_base "$features")" ]]; then
    lost="$(comm -23 <(at_base "$features" | cells | sort) <({ [[ ! -f "$features" ]] || cells < "$features"; } | sort))"
    while IFS= read -r row; do
        [[ -z "$row" ]] || { echo "check-governance: features.md lost or changed the row of ${row%%|*}; keep its ID, Feature, and Req cells; a drop sets Dropped (<reason>)" >&2; fail=1; }
    done <<<"$lost"
fi

# A done State is `done, ` and parts `Release <r> run <n>` or `Release <r> runs <list>`, joined by
# ` and Release `. A `; Later:` part and each (note) are cut first. runs() prints `ID|r|run` for each run.
runs() {
    awk -F'|' '/^\| F[0-9]+ \|/ {
        id = $2; s = $5; gsub(/^ +| +$/, "", id); gsub(/^ +| +$/, "", s)
        if (s !~ /^done, /) next
        sub(/; Later:.*/, "", s); gsub(/ [(][^)]*[)]/, "", s); sub(/^done, /, "", s)
        k = split(s, part, / and Release /)
        for (i = 1; i <= k; i++) {
            p = part[i]; sub(/^Release /, "", p); r = p; sub(/ .*/, "", r)
            sub(/^[0-9]+ runs? /, "", p); gsub(/ and /, ", ", p)
            m = split(p, run, /, /)
            for (j = 1; j <= m; j++) print id "|" r "|" run[j]
        }
    }'
}
# A run number that HEAD adds to a row is 1 + the highest run number of its release at the base. A
# land adds one number to each release, so all new parts of the land share it. A run number of the
# base stays in its row. A base with no features.md has no number to continue or keep. The printf
# gives each awk input a first line, so an empty list does not read the next input as the first.
if [[ -n "$(at_base "$features")" ]]; then
    base_runs="$(at_base "$features" | runs | sort)"
    head_runs="$([[ ! -f "$features" ]] || runs < "$features" | sort)"
    while IFS= read -r msg; do
        [[ -z "$msg" ]] || { echo "check-governance: $msg" >&2; fail=1; }
    done < <(awk -F'|' '
        NR == FNR { old[$0] = 1; n = $3 + 0; if (!($2 in top) || n > top[$2]) top[$2] = n; next }
        NF >= 3 && !($0 in old) {
            want = ($2 in top ? top[$2] : 0) + 1
            if ($3 "" != want "") print "features.md: " $1 " has Release " $2 " run " $3 ", but the next run number of Release " $2 " is " want
        }' <(printf '%s\n' "$base_runs") <(printf '%s\n' "$head_runs"))
    while IFS='|' read -r id r n; do
        [[ -z "$id" ]] || { echo "check-governance: features.md lost or changed the done part Release $r run $n of $id; a done state stays" >&2; fail=1; }
    done < <(comm -23 <(printf '%s\n' "$base_runs") <(printf '%s\n' "$head_runs"))
fi

# A run with a reflect row (phase 8) in its decisions.tsv.
reflected() { [[ -n "$run" && -f "$run/decisions.tsv" ]] && awk -F'\t' '$2 == "8" { found = 1 } END { exit !found }' "$run/decisions.tsv"; }
rules=docs/workflow/rules.tsv
if [[ -f "$rules" ]] && reflected; then
    # The classes come from the paths, not from check-changed.sh <base>: that mode refuses a rerun
    # of a flaky test, and a refusal is no governance fault.
    paths="$(git diff --name-only --no-renames "$base...HEAD")"$'\n'"$(git diff --name-only --no-renames HEAD)"$'\n'"$(git ls-files --others --exclude-standard)"
    out="$("$here/check-changed.sh" --paths <<<"$paths")" || die "check-changed.sh --paths failed"
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
    # since is the run start date, the YYYY-MM-DD prefix of the run folder name, or empty.
    since="$(basename "${run%/}")"
    [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}- ]] && since="${since:0:10}" || since=
    for f in "$run"/research-*.md; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f")"
        copy="docs/research/${name#research-}"
        if [[ -f "$copy" ]]; then
            ! git diff --quiet "$base" -- "$copy" && continue
            [[ -z "$since" || -z "$(git log -1 --since="$since 00:00:00" --format=%H "$base" -- "$copy")" ]] || continue
        fi
        echo "check-governance: $name has no $copy that this branch adds or changes${since:+, or that a commit of $base since $since changed}; research findings go to docs/research" >&2
        fail=1
    done
fi
# A run.md with a `- Lands:` line names the F-IDs of this land, on any branch type: each one gets a
# done state that the base lacks. `- Lands: none` names no F-ID. A run that lands in steps replaces
# the line before each land, so the last line counts. A feat, fix, or perf run that changes app code
# (the paths of the DMG rule) must have the line, because a run can land in steps. A hardening run
# (fix/) that lands no feature writes `- Lands: none`.
lands_state() { awk -F'|' -v id="$1" '{ i = $2; gsub(/ /, "", i) } i == id { s = $5; gsub(/^ +| +$/, "", s); print s }'; }
if [[ -n "$run" && -f "$run/run.md" ]]; then
    line="$(grep '^- Lands:' "$run/run.md" | tail -n 1 || true)"
    if [[ -z "$line" ]]; then
        if grep -qE '^- Branch: (feat|fix|perf)/' "$run/run.md" \
            && git diff --name-only "$base...HEAD" | grep -qE '^(Sources/|Package\.swift$|Package\.resolved$|Support/)'; then
            echo "check-governance: this branch changes app code and run.md has no '- Lands:' line; name the F-IDs of this land in - Lands: of run.md, or write - Lands: none" >&2
            fail=1
        fi
    else
        ids="$(grep -oE 'F[0-9]+' <<<"$line" | sort -u || true)"
        value="$(sed 's/^- Lands: *//; s/ *$//' <<<"$line")"
        if [[ -z "$ids" && "$value" != none ]]; then
            echo "check-governance: run.md has a - Lands: line with no F-ID; name the F-IDs of this land, or write - Lands: none" >&2
            fail=1
        fi
        if [[ "$value" == none ]] && grep -q '^- Branch: feat/' "$run/run.md" \
            && git diff --name-only "$base...HEAD" | grep -q '^Sources/'; then
            echo "check-governance: a feat/ landing that changes Sources/ writes - Lands: none; scripts/tag-release.sh needs a done row in features.md for the run number, so name at least one F-ID in - Lands:" >&2
            fail=1
        fi
        for id in $ids; do
            new="$([[ ! -f "$features" ]] || lands_state "$id" < "$features")" old="$(at_base "$features" | lands_state "$id")"
            if [[ "$new" != done,* || "$new" == "$old" ]]; then
                echo "check-governance: run.md lands $id, but features.md keeps its state ${new:-none}" >&2
                fail=1
            fi
        done
    fi
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
    done_runs="$(awk -F' *[|] *' -v me="$(basename "${run%/}")" '$4 ~ /^done($|[,:])/ && $2 != me { name[++n] = $2 } END { for (i = n; i > 0; i--) print name[i] }' \
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
# Each evals.md key that this branch adds or changes has a graded eval folder in the run folder.
if [[ -n "$run" ]] && ! "$here/check-eval-keys.sh" "$base" "$run" "$PWD"; then
    echo "check-governance: check-eval-keys.sh $run failed" >&2
    fail=1
fi
exit "$fail"
