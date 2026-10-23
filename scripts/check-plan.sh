#!/bin/bash
# Check the Unknowns table of analysis.md and the plan.md of a run folder before the plan gate
# (deliver Phase 3). check-governance.sh runs it again before the land.
# Usage: scripts/check-plan.sh <run folder>
# - analysis.md has a `## Unknowns` table. Each row has an answer and a row cell with a
#   decisions.tsv time (YYYY-MM-DDTHH:MM). A row with the resolver `split` has a child row (a row
#   whose parent is its id). The columns are id, parent, question, resolver, answer, and row;
#   the script finds them by the header names. A bar in a cell is written as \|.
# - plan.md has an `Agents:` line, and each ### heading in its `## Slices` section has a
#   `- Check:` line. Each research-<name>.md of the run folder has docs/research/<name>.md in
#   plan.md, so the plan routes the findings before the build (check-governance.sh checks the copy
#   at the land). A bare research.md is refused: the land check reads only research-<name>.md.
# - Each item (a line that starts with `- ` or `<n>. `) of a plan.md section whose heading starts
#   with `## Plan gate changes` or `## Plan gate <n> changes` has a `Criteria:` field: the
#   criterion IDs that the change moves, separated by commas (an ID is capitals, digits, and an
#   optional lower-case suffix: C3b), or `none`. From the start of Phase 4 (a phase 4 row in
#   decisions.tsv, or CHECK_PLAN_AT_PHASE4=1, which log-decision.sh sets before each phase 4 row),
#   each ID needs a decisions.tsv row whose decision starts with `criterion change` and names the
#   ID as a whole word. log-decision.sh runs this check before the first phase 4 row, so each
#   plan gate change gets its row while a fix is still possible; a later row is for a change that
#   came after Phase 4 started (the code gate).
# - With CHECK_PLAN_AT_PHASE4=1 only, the plan gate is closed: the run folder has a
#   review-plan-<n>.md file, and a phase 3 row follows the last phase 2 row. The land check has no
#   such variable, so a run with phase 4 rows and no review-plan file passes it.
# - Each numbered item under `## Act on` of a review-*.md file has an `Invariant` and a `Siblings`
#   field (lead-judgment.md), and the section has no item in another form. So does each `## Consider`
#   bullet whose text has a `(nit` tag and `taken` (not `not taken`). A nit tagged
#   `no behavior change` needs no field. A review file older than the rule is not checked; one
#   older than the nit rule needs no field for a nit.
# - Each record file `docs/decisions/<n>-<name>.md` that plan.md names, and that is not on
#   origin/main, is a record that the plan makes (also when the run has written it in the work
#   tree). Its number needs an entry "<n> <title> (run <run folder>" on the `Decision numbers`
#   line that `scripts/wiki.py numbers` prints (`scripts/wiki.py reserve --from <file>` adds an
#   entry from a file that the Write tool made), so two parallel runs cannot take one number.
#   With no wiki the check fails: wiki.py names the path, `scripts/wiki.py init`, and
#   DIRIGIBLE_WIKI. Another record with that number in the work tree or on origin/main fails. A
#   cited number with no record file path does not count. A run whose first phase 3 row is older
#   than the rule is not checked.
# - plan.md names each criterion ID of the `## Acceptance criteria` section of analysis.md (up to
#   the next `## ` heading). An ID is the first token of an item line (`- `, `<n>. `) or of a table
#   row, after any `**`: capitals, digits, and an optional lower-case suffix. The sections of plan.md
#   `## Slices`, `## Criteria map` (each may have a suffix after a space), and `## Plan gate changes`
#   or `## Plan gate <n> changes` name it as a whole word, or in a range `C2 to C5` or `C2-C5` of
#   the same prefix (each end may have a suffix: `C4a to C4d`). A run whose first decisions.tsv row
#   is older than the rule is not checked.
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
    while IFS= read -r msg; do say "$msg"; done < <(awk -v rows="$run/decisions.tsv" -v run="$run" \
        -v at4="${CHECK_PLAN_AT_PHASE4:-}" '
        function close_item(  v) {
            if (!item) return
            if (text !~ /Criteria[*]*:/)
                print "plan.md: Plan gate changes item " item " has no Criteria: field; write Criteria: <IDs separated by commas> or Criteria: none"
            else {
                v = text; sub(/.*Criteria[*]*:/, "", v); sub(/\n.*/, "", v)
                while (match(v, /[A-Z]+[0-9]+[a-z]*/)) { ids[substr(v, RSTART, RLENGTH)] = 1; v = substr(v, RSTART + RLENGTH) }
            }
            item = 0
        }
        /^## / { close_item(); inside = ($0 ~ /^## Plan gate( [0-9]+)? changes/); next }
        !inside { next }
        /^(- |[0-9]+\. )/ { close_item(); item = ++n; text = $0; next }
        item { text = text "\n" $0 }
        END {
            close_item()
            # The criterion change decisions. log-decision.sh refuses the first phase 4 row while an ID
            # has no row, so a row after it can only be for a change that came later (the code gate).
            while ((getline line < rows) > 0) {
                split(line, c, "\t")
                if (c[2] == "4") has4 = 1
                if (tolower(c[3]) ~ /^criterion change/) changes[++m] = c[3]
            }
            if (!at4 && !has4) exit
            when = has4 ? "" : " before Phase 4"
            for (id in ids) {
                found = 0
                for (k = 1; k <= m; k++) if (changes[k] ~ ("(^|[^A-Za-z0-9])" id "([^A-Za-z0-9]|$)")) found = 1
                if (!found)
                    print "plan.md: criterion " id " of a plan gate change has no criterion change row" when "; edit analysis.md first, then log it: .claude/skills/deliver/scripts/log-decision.sh " run " 3 \"criterion change " id ": old ..., new ...\" <why> <evidence> <result>"
            }
        }' "$run/plan.md")
    for research in "$run"/research*.md; do
        [[ -f "$research" ]] || continue
        name="${research##*/}"
        if [[ "$name" == research.md ]]; then
            say "$name: name it research-<name>.md, so check-governance.sh checks its docs/research/<name>.md copy at the land"
        else
            copy="docs/research/${name#research-}"
            grep -qF "$copy" "$run/plan.md" || say "$name: plan.md does not name $copy; research findings go to docs/research"
        fi
    done
    # Cutoff 2026-10-20T11:35, one minute after the commit that added the coverage rule: a run that started earlier passes without it.
    start="$(awk -F'\t' '$1 ~ /^[0-9][0-9][0-9][0-9]-/ { print $1; exit }' "$run/decisions.tsv" 2>/dev/null || true)"
    if [[ -f "$run/analysis.md" && ( -z "$start" || ! "$start" < 2026-10-20T11:35 ) ]]; then
        while IFS= read -r msg; do say "$msg"; done < <(awk -v plan="$run/plan.md" '
            # parse(id): prefix gp, number gn, and lower-case suffix gs of a criterion ID.
            function parse(id) {
                gp = id; sub(/[0-9]+[a-z]*$/, "", gp)
                gn = id; sub(/^[A-Z]+/, "", gn); gn += 0
                gs = id; sub(/^[A-Z]+[0-9]+/, "", gs)
            }
            BEGIN {
                while ((getline line < plan) > 0) {
                    if (line ~ /^## /) inside = (line ~ /^## (Slices|Criteria map)( .*)?$/ || line ~ /^## Plan gate( [0-9]+)? changes/)
                    if (inside) text = text "\n" line
                }
                rest = text
                while (match(rest, /[A-Z]+[0-9]+[a-z]*( to |-)[A-Z]+[0-9]+[a-z]*/)) {
                    r = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
                    gsub(/ to |-/, " ", r); split(r, e, " ")
                    parse(e[1]); p = gp; ln = gn; lsf = gs
                    parse(e[2])
                    if (p != gp) continue
                    nr++; rp[nr] = p; lo[nr] = ln; los[nr] = lsf; hi[nr] = gn; his[nr] = gs
                }
                inside = 0
            }
            /^## / { inside = ($0 ~ /^## Acceptance criteria[[:space:]]*$/); next }
            inside && /^(- |[0-9]+\. |\|)/ {
                t = $0; sub(/^(- |[0-9]+\. |\|)[*[:space:]]*/, "", t)
                if (!match(t, /^[A-Z]+[0-9]+[a-z]*/) || substr(t, RLENGTH + 1, 1) ~ /[A-Za-z0-9]/) next
                id = substr(t, 1, RLENGTH)
                if (id in seen) next
                seen[id] = 1
                if (text ~ ("(^|[^A-Za-z0-9])" id "([^A-Za-z0-9]|$)")) next
                parse(id); covered = 0
                for (k = 1; k <= nr; k++)
                    if (rp[k] == gp && (gn > lo[k] || (gn == lo[k] && gs >= los[k])) && (gn < hi[k] || (gn == hi[k] && (his[k] == "" || gs <= his[k])))) covered = 1
                if (!covered)
                    print "plan.md does not name criterion " id " of analysis.md; name it under ## Slices, ## Criteria map, or ## Plan gate changes (a range such as C2 to C5 counts)"
            }' "$run/analysis.md")
    fi
    # Row order, not the clock, decides which phase row is last.
    if [[ -n "${CHECK_PLAN_AT_PHASE4:-}" ]]; then
        compgen -G "$run/review-plan-*.md" >/dev/null || say "no review-plan-<n>.md in $run: the plan gate is not closed; run the plan gate (deliver Phase 3), write review-plan-<n>.md, and log its phase 3 row before the first phase 4 row"
        if ! awk -F'\t' '$2 == "2" { l2 = NR } $2 == "3" { l3 = NR } END { exit !(l3 > l2) }' "$run/decisions.tsv" 2>/dev/null; then
            say "the last phase 2 row of decisions.tsv has no phase 3 row after it: the plan gate is not closed; run the plan gate (deliver Phase 3), write review-plan-<n>.md, and log a new phase 3 row before the first phase 4 row"
        fi
    fi
    # 2026-10-14, the commit that added the number rule: a run with an older plan gate passed without it.
    first3="$(awk -F'\t' '$2 == "3" { print $1; exit }' "$run/decisions.tsv" 2>/dev/null || true)"
    if [[ -z "$first3" || ! "$first3" < 2026-10-14T03:00 ]]; then
        root="$(cd "$(dirname "$0")/.." && pwd)"
        folder="$(basename "$run")"
        for record in $(grep -oE 'docs/decisions/0[0-9]{3}-[a-z0-9-]+\.md' "$run/plan.md" | sort -u); do
            n="${record#docs/decisions/}" n="${n%%-*}"
            held="$( (cd "$root" && ls docs/decisions/"$n"-*.md 2>/dev/null; git ls-tree --name-only origin/main docs/decisions/ 2>/dev/null) |
                grep "^docs/decisions/$n-" | sort -u || true)"
            others="$(grep -vxF "$record" <<<"$held" || true)"
            if [[ -n "$others" ]]; then
                say "plan.md makes $record, but $(head -1 <<<"$others") has the number $n; take the next free number"
            elif git -C "$root" ls-tree --name-only origin/main -- "$record" 2>/dev/null | grep -q .; then
                continue
            elif ! numbers="$("$root/scripts/wiki.py" numbers 2>&1)"; then
                say "plan.md makes $record, and the wiki cannot give the decision numbers to reserve $n: $numbers"
            else
                # Each entry of the number on the line; one that names another run folder owns it.
                entries="$(grep -m1 '^Decision numbers' <<<"$numbers" | grep -oE "(^|[:,] )$n [^,(]*\([^)]*\)" | sed -E 's/^[:,]? //' || true)"
                other="$(grep -vE "\(run $folder[,)]" <<<"$entries" | grep . | head -1 || true)"
                if [[ -n "$other" ]]; then
                    say "plan.md makes $record, but $n is reserved for another run: $other; take the next free number"
                elif [[ -z "$entries" ]]; then
                    say "plan.md makes $record: reserve $n with scripts/wiki.py reserve --from <file>; write the file with the Write tool, one line: \"$n <title> (run $folder)\""
                fi
            fi
        done
    fi
fi
# 2026-10-05, the commit that added the field rule: an older review file has no fields.
cutoff=1791222684
# 2026-10-09, the commit that added the nit rule (INT-042): an older review file keeps the nit exempt.
nit_cutoff=1791510511
for review in "$run"/review-*.md; do
    [[ -f "$review" ]] || continue
    mtime=$(stat -f %m "$review")
    ((mtime >= cutoff)) || continue
    while IFS= read -r msg; do say "$msg"; done < <(awk -v file="${review##*/}" -v nitrule=$((mtime >= nit_cutoff)) '
        # missing <what>: print each field that text does not have.
        function missing(what) {
            for (f = 1; f <= 2; f++)
                if (text !~ (field[f] "[*[:space:]]*(\\([^)]*\\))?[*[:space:]]*:"))
                    print file ": " what " has no " field[f] " field (a review file from before the rule: add the fields, or do not edit it)"
        }
        # paren: the first parenthesis of $0 in lower case, or nothing.
        function paren(  t) { t = tolower($0); return match(t, /\([^)]*\)/) ? substr(t, RSTART, RLENGTH) : "" }
        # exempt: the first parenthesis is a nit tag that needs no field. With the nit rule, only a
        # nit tagged `no behavior change` is exempt.
        function exempt(  t) { t = paren(); return t ~ /^\(nit/ && (!nitrule || t ~ /no behavior change/) }
        # taken: the text of the whole bullet has a nit tag and taken (not "not taken"), in or
        # outside the tag, for example "(nit, x) ... Taken: a test case.". "nit" outside a tag does
        # not count: a warning can name the taken-nit rule.
        function taken(  t) {
            t = tolower(text); gsub(/not taken/, "", t)
            return t ~ /\(nit[^a-z]/ && t ~ /(^|[^a-z])taken([^a-z]|$)/
        }
        function close_item() {
            if (item && !skip) missing("Act on item " item)
            if (note && !skip && taken()) missing("Consider item " note)
            item = note = ""
        }
        function close_section() {
            if (inside == "act" && other && !numbered) print file ": ## Act on has no numbered item"
            inside = numbered = other = 0
        }
        BEGIN { field[1] = "Invariant"; field[2] = "Siblings" }
        /^## / {
            close_item(); close_section(); notes = 0
            inside = $0 ~ /^## Act on/ ? "act" : nitrule && $0 ~ /^## Consider/ ? "consider" : ""
            next
        }
        !inside { next }
        inside == "act" && /^[0-9]+\. / {
            close_item(); item = $0 + 0; numbered = 1; text = $0
            # The tag starts the item: a nit tag in the middle of the text does not count.
            tag = tolower($0); sub(/^[0-9]+\.[[:space:]]*\**/, "", tag)
            skip = tag ~ /^\(nit/ && exempt()
            next
        }
        inside == "consider" && /^[-*] / {
            close_item(); note = ++notes; text = $0
            skip = exempt()
            next
        }
        inside == "act" && /^([-*] |### )/ { other = 1 }
        { text = text "\n" $0 }
        END { close_item(); close_section() }' "$review")
done
exit "$fail"
