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
#   branch is docs, at most one rules.tsv row changes to delete or merge (reflect rule 7). A run.md
#   with a `- Cut run: <item id>` line has no cap: each such row then needs `class:` and `found by:`
#   in its reason.
# - On every branch, the reason of a rules.tsv row that changes to delete starts with `stale:` or
#   `no-op:` and has text after it (reflect rule 7). A merge row and a row that was delete at the
#   base are free.
# - With a run folder whose run.md has a `- Cut run:` line, each rules.tsv row that changes to merge
#   has one or more `kept: "<text>"` parts in its reason. Each text has no double quote and at least
#   5 words, and is on one line of a file of the target row at HEAD: its file cell, or its target cell
#   when its verdict is keep, new, or move. This proves that the quoted line exists, not that it keeps the meaning.
# - With a run folder, check-plan.sh passes on it (the Unknowns table and the plan), and each
#   research-<name>.md of the run folder has a docs/research/<name>.md that the branch adds or changes,
#   or that a commit of the base changed on or after the run start date (the YYYY-MM-DD prefix of
#   the run folder name; a run that lands in steps copied it in an earlier landing).
# - With a run folder, no holdout is in eval/holdout-fails.txt (grade.py verdict) both in this run
#   and in the newest done run of the run log of the wiki (`scripts/wiki.py runs`: the last row of a
#   run name is its status) whose eval/scores.tsv has a row of that holdout.
# - With a run folder that has a reflect row (phase 8), or with GOVERNANCE_LAND set (land.sh), the
#   wiki has no item with status next that this run took (`scripts/wiki.py list next --taken
#   <run folder name>`). A later item that the run took passes. With no wiki the check fails:
#   wiki.py names the path, `scripts/wiki.py init`, and DIRIGIBLE_WIKI.
# - The base files of these checks (budgets.tsv, rules.tsv, features.md) are read at the merge base of
#   the base and HEAD, so a branch that is behind its base is not blamed for what the base changed
#   after the branch point. Only the top run number of a release reads the base tip.
# - Each `| F<n> |` row of docs/requirements/features.md at the merge base keeps its ID, Feature, and Req cells
#   in the work tree file: a drop sets `Dropped (<reason>)`, and a new idea gets a new ID.
# - A run number that HEAD adds to a done State of features.md is 1 + the highest run number of its
#   Release at the base tip. Each run number of a done State at the merge base stays in its row.
# - With a run folder whose run.md has a `- Lands:` line, each F-ID of the newest (last) such line has a
#   done state in features.md that differs from its state at the merge base, on any branch type. `- Lands: none`
#   names no F-ID; an empty line fails. The value is `none` or a comma list of F-IDs (`F35, F89`); a
#   note goes on its own line. A `feat/`, `fix/`, or `perf/` branch that changes Sources/,
#   Package.swift, Package.resolved, or Support/ needs the line. A `feat/` branch that changes
#   Sources/ cannot write `- Lands: none`: scripts/tag-release.sh needs a done row for its run number.
#   The branch of HEAD gives the branch type. On a detached HEAD, the last `- Branch:` line of run.md
#   gives it, with backticks and a note after it removed.
# - With a run folder, scripts/check-eval-keys.sh passes on this tree: each evals.md key that the
#   branch adds or changes has an eval folder of the run with its exact key text and a scores.tsv line.
# - The done runs of the holdout stop are the log statuses `done`, `done:`, and `done,`.
# - With a run folder, each line of a rerun-due.txt of an eval* folder (grade.py verdict) is due, except a
#   `pooled <ID>: ...: PASS` line. A `policy` line (a policy miss under six runs that six runs can still
#   pass) clears when another eval* folder of the run has scores.tsv rows of its ID, newer than that
#   rerun-due.txt. A `below` line (a retention drop of a small sample) clears through a
#   `pooled <ID>: ...: PASS` line of the same file: a rerun in the same folder replaces its rerun-due.txt
#   and writes that line when the pooled verdict passes. A `below` line or a `pooled <ID>: ...: FAIL`
#   line also clears when another eval* folder of the run, at another commit (logs/build-b.commit) and
#   with scores.tsv newer than that rerun-due.txt, has at least the runs of the line in each set and
#   passes the ID by the pooled rule of grade.py (a docs fix: run.sh refuses the old folder at a new
#   commit). The pooled rule grades a rerun due ID on the bound of its counts: new passes over old passes
#   minus 2, or, with 12 or more runs in the smaller set, old minus new at or under 2 x sqrt(k x p x
#   (1 - p)), k the runs of both sets and p the pooled pass rate.
# scripts/check-governance.test.sh tests it.
set -euo pipefail

die() { echo "check-governance: $1" >&2; exit 1; }

[[ $# -ge 1 ]] || { echo "usage: scripts/check-governance.sh <base> [<run folder>]" >&2; exit 2; }
base="$1" run="${2:-}"
here="$(cd "$(dirname "$0")" && pwd)"
cd "$(git rev-parse --show-toplevel)"
git rev-parse -q --verify "$base^{commit}" > /dev/null || die "no commit $base"
fail=0

# The file at the merge base of the base and HEAD, or nothing when it has no such file. The work tree
# is the branch as it lands, and the tip of the base can hold changes that the branch lacks.
mb="$(git merge-base "$base" HEAD)" || die "no merge base of $base and HEAD"
at_base() { git show "$mb:$1" 2>/dev/null || true; }

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

# The always-on words and the count of skills plus agents stay at or below the merge base.
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
# A run number that HEAD adds to a row (one that the merge base lacks) is 1 + the highest run number
# of its release at the base tip, so a collision shows before the land rebase. A land adds one number
# to each release, so all new parts of the land share it. A run number of the merge base stays in its
# row. A merge base with no features.md has no number to continue or keep. Each list line gets a tag
# (T tip, O merge base, H HEAD), so one awk reads the three lists.
if [[ -n "$(at_base "$features")" ]]; then
    base_runs="$(at_base "$features" | runs | sort)"
    tip_runs="$(git show "$base:$features" 2>/dev/null | runs | sort || true)"
    head_runs="$([[ ! -f "$features" ]] || runs < "$features" | sort)"
    while IFS= read -r msg; do
        [[ -z "$msg" ]] || { echo "check-governance: $msg" >&2; fail=1; }
    done < <(awk -F'|' '
        NF >= 4 && ($1 == "T" || $1 == "O") {
            if ($1 == "O") old[$2 "|" $3 "|" $4] = 1
            n = $4 + 0; if (!($3 in top) || n > top[$3]) top[$3] = n
        }
        NF >= 4 && $1 == "H" && !(($2 "|" $3 "|" $4) in old) {
            want = ($3 in top ? top[$3] : 0) + 1
            if ($4 "" != want "") print "features.md: " $2 " has Release " $3 " run " $4 ", but the next run number of Release " $3 " is " want
        }' <(sed 's/^/T|/' <<<"$tip_runs") <(sed 's/^/O|/' <<<"$base_runs") <(sed 's/^/H|/' <<<"$head_runs"))
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
        changed="$(at_base "$rules" | awk -F'\t' '
            NR == FNR { if (FNR > 1) old[$1] = $3; next }
            FNR > 1 && $3 ~ /^(delete|merge)$/ && old[$1] !~ /^(delete|merge)$/ { print $1 "\t" $5 }' - "$rules")"
        removed="$(grep -c . <<<"$changed" || true)"
        if grep -qE '^- Cut run: [^[:space:]]' "$run/run.md" 2>/dev/null; then
            while IFS=$'\t' read -r id reason; do
                [[ -n "$id" ]] || continue
                [[ "$reason" =~ class:[[:space:]]*[^[:space:]] && "$reason" =~ found\ by:[[:space:]]*[^[:space:]] ]] && continue
                echo "check-governance: rules.tsv: $id changes to delete or merge in a cut run; its reason needs class: and found by:" >&2
                fail=1
            done <<<"$changed"
        elif [[ "$removed" -gt 1 ]]; then
            echo "check-governance: rules.tsv: $removed rows change to delete or merge; a reflect run removes at most one rule" >&2
            fail=1
        fi
    fi
fi
# A row that changes to delete against the base has a reason that starts with stale: or no-op: and
# gives the evidence (reflect rule 7), on every branch.
if [[ -f "$rules" ]]; then
    while IFS=$'\t' read -r id reason; do
        [[ -n "$id" ]] || continue
        [[ "$reason" =~ ^(stale|no-op):[[:space:]]*[^[:space:]] ]] && continue
        echo "check-governance: rules.tsv: $id changes to delete; its reason must start with stale: or no-op: and give the evidence (reflect rule 7)" >&2
        fail=1
    done < <(at_base "$rules" | awk -F'\t' '
        NR == FNR { if (FNR > 1) old[$1] = $3; next }
        FNR > 1 && $3 == "delete" && old[$1] != "delete" { print $1 "\t" $5 }' - "$rules")
fi
# In a cut run, a row that changes to merge quotes the text of its target that keeps each removed
# sentence (reflect rule 7): a fixed string on one line of a file of the target row on HEAD. A reflect
# row and the class of the branch do not matter, so Phase 7 finds a gap before the land.
kept_re='kept:[[:space:]]*"([^"]+)"'
if [[ -f "$rules" && -n "$run" ]] && grep -qE '^- Cut run: [^[:space:]]' "$run/run.md" 2>/dev/null; then
    while IFS=$'\t' read -r id target reason; do
        [[ -n "$id" ]] || continue
        # The file cell of the target row, and its target cell (a path in a keep, new, or move row).
        files="$(awk -F'\t' -v t="$target" 'FNR > 1 && $1 == t { print $2; if ($3 ~ /^(keep|new|move)$/) print $4; exit }' "$rules")"
        if [[ -z "$files" ]]; then
            echo "check-governance: rules.tsv: $id merges into $target, which has no row" >&2
            fail=1
            continue
        fi
        rest="$reason" quotes=0
        while [[ "$rest" =~ $kept_re ]]; do
            quote="${BASH_REMATCH[1]}" rest="${rest#*"${BASH_REMATCH[0]}"}" quotes=$((quotes + 1)) found=""
            read -ra words <<<"$quote"
            if ((${#words[@]} < 5)); then
                echo "check-governance: rules.tsv: $id quotes kept: \"$quote\", which has fewer than 5 words; quote 5 words or more of one line of $target" >&2
                fail=1
                continue
            fi
            while IFS= read -r f; do
                [[ -n "$f" ]] && text="$(git cat-file blob "HEAD:$f" 2>/dev/null)" && grep -qF -- "$quote" <<<"$text" && { found=1; break; }
            done <<<"$files"
            [[ -n "$found" ]] && continue
            echo "check-governance: rules.tsv: $id quotes kept: \"$quote\", which no file of $target holds on one line at HEAD; quote one line of the target that keeps the removed sentence, or keep the sentence" >&2
            fail=1
        done
        if ((quotes == 0)); then
            echo "check-governance: rules.tsv: $id changes to merge in a cut run; its reason needs one kept: \"<text>\" quote of $target (5 words or more of one line of the target file, no double quote)" >&2
            fail=1
        fi
    done < <(at_base "$rules" | awk -F'\t' '
        NR == FNR { if (FNR > 1) old[$1] = $3; next }
        FNR > 1 && $3 == "merge" && old[$1] != "merge" { print $1 "\t" $4 "\t" $5 }' - "$rules")
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
# done state that the base lacks. `- Lands: none` names no F-ID. The value is `none` or a comma list
# of F-IDs, so a note on the line fails. A run that lands in steps replaces the line before each
# land, so the last line counts. A feat, fix, or perf run that changes app code (the paths of the
# DMG rule) must have the line, because a run can land in steps. A hardening run (fix/) that lands
# no feature writes `- Lands: none`.
lands_state() { awk -F'|' -v id="$1" '{ i = $2; gsub(/ /, "", i) } i == id { s = $5; gsub(/^ +| +$/, "", s); print s }'; }
if [[ -n "$run" && -f "$run/run.md" ]]; then
    line="$(grep '^- Lands:' "$run/run.md" | tail -n 1 || true)"
    # HEAD names the landing. A run of several landings may write its later branches ahead, so the
    # last `- Branch:` line counts only on a detached HEAD.
    branch="$(git symbolic-ref --short -q HEAD || true)"
    [[ -n "$branch" ]] || branch="$(grep '^- Branch:' "$run/run.md" | tail -n 1 | sed -E 's/^- Branch: *//; s/[ ,].*$//; s/`//g' || true)"
    if [[ -z "$line" ]]; then
        if [[ "$branch" =~ ^(feat|fix|perf)/ ]] \
            && grep -qE '^(Sources/|Package\.swift$|Package\.resolved$|Support/)' <<<"$(git diff --name-only "$base...HEAD")"; then
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
        lands_format='^(none|F[0-9]+[a-z]?(, *F[0-9]+[a-z]?)*)$'
        if [[ -n "$value" && ! "$value" =~ $lands_format ]]; then
            echo "check-governance: the - Lands: value '$value' is not none or a comma list of F-IDs; put a note on its own line after - Lands:" >&2
            fail=1
        fi
        if [[ "$value" == none && "$branch" == feat/* ]] \
            && grep -q '^Sources/' <<<"$(git diff --name-only "$base...HEAD")"; then
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
# A run moves its own taken items out of the next list of the wiki before the land: each run reads
# the list at Phase 0, so a long list costs each run. The wiki is the same from each worktree.
# Phase 8 moves the items, so the check waits for the reflect row: Phase 7 runs this script before
# it. land.sh sets GOVERNANCE_LAND, so a land with no reflect row still fails on a taken item.
if reflected || [[ -n "$run" && -n "${GOVERNANCE_LAND:-}" ]]; then
    name="$(basename "${run%/}")"
    if taken="$("$here/wiki.py" list next --taken "$name")"; then
        while IFS= read -r hit; do
            [[ -n "$hit" ]] || continue
            echo "check-governance: wiki item ${hit%% *} is next and taken by $name; move it to done or later: scripts/wiki.py move ${hit%% *} done" >&2
            fail=1
        done <<<"$taken"
    else
        echo "check-governance: the wiki is not readable, so the taken items of $name are not checked" >&2
        fail=1
    fi
fi
# Two holdout fails in a row stop the land. grade.py verdict writes its `holdout fail <H>` lines to
# <run>/eval/holdout-fails.txt. For each H of this run, the run to compare is the newest done run
# of the run log of the wiki whose eval/scores.tsv has a row of H: a run that did not run H is
# skipped (docs/workflow/evals.md, the pass rule). The log is append-only, so a run takes its last row.
failed_holdouts() { sed -n 's/^holdout fail \(H[0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | sort -u; }
if [[ -n "$run" && -s "$run/eval/holdout-fails.txt" ]]; then
    runs="$(dirname "${run%/}")"
    done_runs="$("$here/wiki.py" runs | awk -F' *[|] *' -v me="$(basename "${run%/}")" '
        /^[|]/ && $2 ~ /^[0-9]{4}-/ { last[$2] = NR; who[NR] = $2; state[NR] = $4 }
        END { for (i = NR; i > 0; i--) if ((i in who) && last[who[i]] == i && state[i] ~ /^done($|[,:])/ && who[i] != me) print who[i] }')" || {
        echo "check-governance: the wiki is not readable, so the holdout stop cannot compare runs" >&2
        fail=1
        done_runs=""
    }
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
# A rerun due ID is no fail yet, but the land waits for its pooled verdict: the same folder after a
# rerun with a new tag (the folder replaces its rerun-due.txt), or a later eval* folder: with rows of a
# policy ID, or, after a docs fix, at another commit with a full-size pooled pass of a below or pooled ID.
# run.sh refuses a rerun in the same folder at another commit.
runs_re='old [0-9]+/([0-9]+), new [0-9]+/([0-9]+)'
background='as a background run (AGENTS.md, Commands); a subagent returns to the lead'
if [[ -n "$run" ]]; then
    for due in "$run"/eval*/rerun-due.txt; do
        [[ -s "$due" ]] || continue
        folder="$(dirname "$due")"
        while read -r kind id rest; do
            [[ -n "$kind" ]] || continue
            id="${id%:}" cleared=
            [[ "$kind" == pooled && "$rest" == *': PASS' ]] && continue
            if [[ "$kind" == policy ]]; then
                for scores in "$run"/eval*/scores.tsv; do
                    [[ "$(dirname "$scores")" != "$folder" && "$scores" -nt "$due" ]] || continue
                    awk -F'\t' -v id="$id" '$2 == id { found = 1 } END { exit !found }' "$scores" && { cleared=1; break; }
                done
                [[ -n "$cleared" ]] || { echo "check-governance: $(basename "$folder")/rerun-due.txt: $id is rerun due; the lead runs scripts/eval/run.sh again in that eval folder with a new tag, $background" >&2; fail=1; }
                continue
            fi
            old_runs=6 new_runs=6
            [[ "$rest" =~ $runs_re ]] && old_runs="${BASH_REMATCH[1]}" new_runs="${BASH_REMATCH[2]}"
            # The pooled rule of grade.py verdict on the later folder: the below clause, or the bound at 12 runs.
            for scores in "$run"/eval*/scores.tsv; do
                later="$(dirname "$scores")"
                [[ "$later" != "$folder" && "$scores" -nt "$due" && -s "$later/logs/build-b.commit" ]] || continue
                [[ "$(cat "$later/logs/build-b.commit")" != "$(cat "$folder/logs/build-b.commit" 2> /dev/null)" ]] || continue
                awk -F'\t' -v id="$id" -v ro="$old_runs" -v rn="$new_runs" '
                    $2 == id && $4 == "a" { oa++; op += ($6 == "PASS") }
                    $2 == id && $4 == "b" { nb++; np += ($6 == "PASS") }
                    END {
                        k = oa + nb; p = k ? (op + np) / k : 0
                        exit !(oa >= ro && nb >= rn && (np > op - 2 || (oa >= 12 && nb >= 12 && op - np <= 2 * sqrt(k * p * (1 - p)))))
                    }' "$scores" && { cleared=1; break; }
            done
            [[ -z "$cleared" ]] || continue
            fail=1
            if [[ "$kind" == pooled ]]; then
                echo "check-governance: $(basename "$folder")/rerun-due.txt: $id failed the pooled verdict; fix its docs, then the lead runs scripts/eval/run.sh in a new eval folder with at least $old_runs runs of set a and $new_runs of set b, $background" >&2
            else
                echo "check-governance: $(basename "$folder")/rerun-due.txt: $id is rerun due; the lead runs scripts/eval/run.sh again in that eval folder with a new tag, or after a docs fix in a new eval folder with at least $old_runs runs of set a and $new_runs of set b, $background" >&2
            fi
        done < "$due"
    done
fi
if [[ -n "$run" ]] && ! "$here/check-plan.sh" "$run"; then
    echo "check-governance: check-plan.sh $run failed" >&2
    fail=1
fi
if [[ -n "$run" ]] && ! "$here/check-eval-keys.sh" "$base" "$run" "$PWD"; then
    echo "check-governance: check-eval-keys.sh $run failed" >&2
    fail=1
fi
exit "$fail"
