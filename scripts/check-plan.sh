#!/bin/bash
# Check the Unknowns table of analysis.md and the plan.md of a run folder before the plan gate
# (deliver Phase 3). check-governance.sh runs it again before the land.
# Usage: scripts/check-plan.sh <run folder>
# - analysis.md has a `## Unknowns` table. Each row has an answer and a row cell with a
#   decisions.tsv time (YYYY-MM-DDTHH:MM). A row with the resolver `split` has a child row (a row
#   whose parent is its id). The columns are id, parent, question, resolver, answer, and row;
#   the script finds them by the header names. A bar in a cell is written as \|.
# - plan.md has an `Agents:` line, and each ### heading in its `## Slices` section (a suffix such
#   as `## Slices (serial)` is allowed) has a `- Check:` line. Each research-<name>.md of the run
#   folder has docs/research/<name>.md in plan.md, so the plan routes the findings before the
#   build (check-governance.sh checks the copy at the land). A bare research.md is refused: the land check reads only research-<name>.md.
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
#   CHECK_PLAN_GATE_CLOSE=1 (log-decision.sh, for the phase 3 row that closes the plan gate, and for
#   each phase 3 row once the last round file has a `## Fix check` heading) counts that pending
#   row, so the phase 3 row test passes; the review-plan-<n>.md test stays.
# - With CHECK_PLAN_AT_PHASE4=1 only, when a round file review-plan-<n>.md (a per-lens name is none)
#   has a numbered item under `## Act on`, the round file with the highest number has a `## Fix check`
#   heading (lead-judgment.md, Fix check). A run whose first decisions.tsv row is older than the rule needs none.
#   A run whose first row is at or after fixline_cutoff also needs, in that section, a `- <round>.<item>`
#   line for each numbered Act on item of each round file. Each line has the parts, and a plan gate item
#   that changes a criterion has the control, that lead-judgment.md, Fix check names.
# - With CHECK_PLAN_AT_PHASE7=1 only (log-decision.sh sets it before the first phase 7 row), the
#   `## Fix check` of the review-diff-<n>.md file with the highest number has a line with the whole
#   word <round>.<item> for each numbered item under `## Act on` of each review-diff-<n>.md file
#   (lead-judgment.md, Fix check). A run whose first decisions.tsv row is older than the rule needs none.
#   From fixline_cutoff, each `- <round>.<item>` line there has the parts that lead-judgment.md, Fix check
#   names, and each deferred control of the last review-plan-<n>.md has its file in the run folder.
# - With CHECK_PLAN_FIX_CHECK=1 (log-decision.sh sets it for a phase 6 row that reports a fix check),
#   the same Fix check line and parts rule runs, with the same cutoffs, but not the deferred control
#   files and not the quote rule below. CHECK_PLAN_FIX_ITEMS (words <round>.<item>, separated by
#   spaces) limits the lines and the parts to those items; empty means each item.
# - When analysis-gate.md exists (log-decision.sh copies analysis.md to it at the first phase 4 row)
#   and the run has a phase 4 row (or CHECK_PLAN_AT_PHASE4=1), each criterion line of its
#   `## Acceptance criteria` section whose line differs in analysis.md, or is gone, needs a
#   decisions.tsv row after the first phase 4 row whose decision starts with `criterion change` and
#   names the ID as a whole word. A run with phase 4 rows and no analysis-gate.md needs none.
# - With CHECK_PLAN_AT_PHASE7=1 only, when run.md and a phase 6 row exist: a fix commit (a commit of
#   origin/main..<the branch of the last `- Branch:` line of run.md> whose author time is at or after the
#   minute of the first phase 6 row) that removes a double-quoted text of a criterion line of analysis.md,
#   when no fix commit adds a line that holds the text, needs a decisions.tsv row from the first phase 6
#   row on whose decision starts with `criterion change` and names the ID as a whole word. A text that is
#   empty, or that starts or ends with a space, is a fragment of a nested quote and is skipped. A branch
#   that git does not know fails. A run whose first decisions.tsv row is older than quote_cutoff needs none.
#   The same holds for the pattern of each backticked rg grader of a criterion line (the grader reader of
#   the graders rule below), when the first decisions.tsv row is at or after graders_cutoff: a fix commit
#   that removes a line that the pattern matches, from a file that the command names (each file when it
#   names none), needs the row when no fix commit adds such a line to such a file. The words of the first
#   rg command up to a word that starts with |, ;, &, <, or > are its patterns (-e values, else the first
#   word that is no flag) and its files, folders, and globs. rg itself matches the lines of the commits,
#   without their - or + marker, with the flags -F (also in a bundle such as -Fc, and --fixed-strings), -i,
#   -s, -S, -w, -x, and -P of the grader: a grader with -F matches a literal, one without -F a regex of
#   the Rust dialect (\d, \b, (?i)). A pattern that rg cannot read matches nothing. rg must be on the PATH.
# - Each numbered item under `## Act on` of a review-*.md file has an `Invariant` and a `Siblings`
#   field (lead-judgment.md), and the section has no item in another form. So does each `## Consider`
#   bullet whose text has a `(nit` tag and `taken` (not `not taken`). A nit tagged
#   `no behavior change` needs no field. A review file older than the rule is not checked; one
#   older than the nit rule needs no field for a nit. A Siblings field whose first word is none, n/a,
#   no, or nothing needs `grepped` or an `rg` or `grep` word in its value (the text after its colon,
#   up to the next Invariant, Siblings, or Fix field; the first non-empty next line when the colon ends
#   its line); a review file older than
#   none_cutoff keeps a bare none.
# - Each numbered item under `## Act on` of a review-diff-<n>.md file of a run whose first decisions.tsv
#   row is at or after graders_cutoff also has a `Criteria` field: the IDs of the criteria whose value
#   the fix moves, or none, as the `Criteria:` field of a plan gate change. A nit tagged
#   `no behavior change` needs none. With CHECK_PLAN_AT_PHASE7=1, each ID needs a decisions.tsv row
#   from the first phase 6 row on whose decision starts with `criterion change` and names the ID as a
#   whole word. A review-plan-<n>.md file and a run with no decisions.tsv row are not checked.
# - Before the first phase 4 row only: each Swift path under Sources/ or Tests/ of a slice `- Check:`
#   line that has the check-sizes.sh limit minus 20 lines or more at origin/main, and that
#   scripts/check-sizes.allow at origin/main does not list, needs a `- Split:` line in that slice
#   that names the file name and either a target .swift file or scripts/check-sizes.allow with a
#   reason. A path that is not on origin/main is new and passes. A run whose first decisions.tsv
#   row is older than the rule is not checked.
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
# - A table row of plan.md whose Branch (or Branch and worktree) cell starts with `feat/` and whose
#   Lands cell starts with `none` has no Sources/ word in the `- Check:` lines of its slices:
#   scripts/tag-release.sh needs an F-ID (check-governance.sh refuses it at the land). The Slices cell
#   lists slice IDs or a range `L2-S1 to L2-S3`, with backticks dropped; a colon after the ID of a
#   `###` heading is dropped, and the `## Slices` heading may have a suffix. With no Slices column the
#   rule reads each `- Check:` line of the plan. A run whose first decisions.tsv row is older than the rule is not checked.
# - A round file review-plan-<n>.md or review-diff-<n>.md has no `## ` heading that starts with an
#   item ID (`## G1:`, `## R2 (`, `## 3.`), also next to `## Act on`, and no `## Fix check` without
#   a `## Act on` heading: each finding is a numbered item under `## Act on` or another verdict
#   section. A round file older than the rule is not checked; a per-lens file is none.
# - A criterion line of the `## Acceptance criteria` section of analysis.md (an item or a table row
#   with an ID) that names a bench (`make bench` or a word that ends in Benchmark) and a time budget
#   in one sentence has a statistic word (p50, p90, p95, p99, median, max; not a part of a name
#   such as WITH_LOCK_MAX_HOLD): a bench time with no statistic cannot be graded. A time budget is
#   under, at most, budget, or takes before a number with ms or s, or a number with ms or s before
#   "or less"; a table row is one sentence, so a compare with main, a fixture length, and a
#   tolerance are no budget. The rule reads the current line only, so a criterion change that drops
#   the bench or the budget passes. A run whose first decisions.tsv row is older than
#   bench_stat_cutoff is not checked.
# - A criterion line of the `## Acceptance criteria` section of analysis.md (its indented lines
#   count) has each backticked rg grader copied whole to the `- Graders:` line of a slice that lists
#   the ID. A grader is a span that starts with `rg ` and has a word after it that does not start
#   with `-`; it ends at the next backtick outside a quoted argument, so a pattern with backticks in
#   quotes stays whole. A slice lists an ID in its `###` heading or a `- Criteria:` line, alone or in
#   a range (`C2 to C5`, `C2-C5`). The `## Criteria map` does not list. A criterion writes a case
#   input in double quotes, so it is no grader. A run whose first decisions.tsv row is older than
#   graders_cutoff is not checked. No check proves that a slice runs its graders.
# - A review-diff-<n>.md file with the line `review: lead <commit>` needs the line `review: lead` in
#   review-plan-1.md, and `scripts/check-changed.sh origin/main`, run at <commit> in a detached worktree of the
#   run tree, must print `review: lead`. <commit> is the commit that the code gate reviewed, so a later commit
#   (the Phase 7 states, screenshots) does not change the verdict. A lead line with no commit, or with a commit
#   that the run tree lacks, fails. The run tree is the worktree of the branch of the last `- Branch:` line of
#   run.md, so the rule reads the run diff from any caller tree. It fails with no such tree and with no
#   changed path there. It runs in each mode.
# It prints each failure and exits 1. scripts/check-plan.test.sh tests it.
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: scripts/check-plan.sh <run folder>" >&2; exit 2; }
run="${1%/}"
fail=0
say() { echo "check-plan: $1" >&2; fail=1; }

# Local time at which the rule for the Fix check line parts was written, before its commit (YYYY-MM-DDTHH:MM,
# as decisions.tsv writes it): a run whose first row is older needs none of them.
fixline_cutoff=2026-11-02T04:58
# The same for the rule on a fix commit that removes a quoted criterion text.
quote_cutoff=2026-11-03T00:00
# The same for the rule that a bench criterion with a time value names a statistic word.
bench_stat_cutoff=2026-11-18T21:30
# The same for the rule that a slice copies the rg graders of its criteria to a - Graders: line, for the
# rg graders of the phase 7 quote rule, and for the Criteria: field of a code gate Act on item.
graders_cutoff=2026-11-19T00:00

# The awk functions that read the criteria of analysis.md and the rg graders of a criterion line; the
# slice rule and the phase 7 quote rule share them. A program is "$rg_awk" followed by its own text.
rg_awk='
function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
# criteria(file): fill order[1..no] with the ID of each criterion line of the ## Acceptance criteria
# section of file, and ctext[id] with its line and its indented lines.
function criteria(file,  line, inside, cur, t, id) {
    while ((getline line < file) > 0) {
        if (line ~ /^## /) { inside = (line ~ /^## Acceptance criteria[[:space:]]*$/); cur = ""; continue }
        if (!inside || line ~ /^[[:space:]]*$/) continue
        if (line ~ /^[[:space:]]/) { if (cur != "") ctext[cur] = ctext[cur] " " line; continue }
        cur = ""
        if (line !~ /^(- |[0-9]+\. |\|)/) continue
        t = line; sub(/^(- |[0-9]+\. |\|)[*[:space:]]*/, "", t)
        if (!match(t, /^[A-Z]+[0-9]+[a-z]*/) || substr(t, RLENGTH + 1, 1) ~ /[A-Za-z0-9]/) continue
        id = substr(t, 1, RLENGTH)
        if (id in ctext) continue
        cur = id; order[++no] = id; ctext[id] = line
    }
    close(file)
}
# graders(s, out): fill out[1..n] with each rg grader of s, and return n. A span opens at a
# backtick and starts with "rg ". It ends at the next backtick outside a quoted argument, or at
# the next backtick when a quote stays open. A span with no word after rg that does not start
# with "-" (rg -c) is no grader.
function graders(s, out,  n, len, i, j, c, q, t, k, w, m, ok) {
    split("", out); n = 0; len = length(s); i = 1
    while (i <= len) {
        if (substr(s, i, 1) != "`") { i++; continue }
        if (substr(s, i + 1, 3) != "rg ") {
            j = index(substr(s, i + 1), "`")
            if (!j) break
            i += j + 1; continue
        }
        q = ""; j = i + 1
        while (j <= len) {
            c = substr(s, j, 1)
            if (q != "") { if (c == q) q = "" }
            else if (c == "\047" || c == "\"") q = c
            else if (c == "`") break
            j++
        }
        if (j > len) { j = index(substr(s, i + 1), "`"); if (!j) break; j += i }
        t = trim(substr(s, i + 1, j - i - 1)); i = j + 1
        k = split(substr(t, 3), w, /[[:space:]]+/); ok = 0
        for (m = 1; m <= k; m++) if (w[m] != "" && w[m] !~ /^-/) ok = 1
        if (ok) out[++n] = t
    }
    return n
}
# words(s, w): split s into shell words in w[1..n] (quotes and backslashes removed), and return n.
function words(s, w,  n, len, i, c, q, cur, has, x) {
    split("", w); n = 0; len = length(s); q = ""; cur = ""; has = 0
    for (i = 1; i <= len; i++) {
        c = substr(s, i, 1)
        if (q == "\047") { if (c == q) q = ""; else cur = cur c; continue }
        if (q == "\"") {
            x = substr(s, i + 1, 1)
            if (c == "\"") q = ""
            else if (c == "\\" && x != "" && index("\"\\$`", x)) { cur = cur x; i++ }
            else cur = cur c
            continue
        }
        if (c == "\047" || c == "\"") { q = c; has = 1; continue }
        if (c == "\\") { cur = cur substr(s, i + 1, 1); i++; has = 1; continue }
        if (c ~ /[[:space:]]/) { if (has) w[++n] = cur; cur = ""; has = 0; continue }
        cur = cur c; has = 1
    }
    if (has) w[++n] = cur
    return n
}
# shq(s): s as one single-quoted shell word.
function shq(s,  out, j) {
    out = ""
    while ((j = index(s, "\047")) > 0) { out = out substr(s, 1, j - 1) "\047\\\047\047"; s = substr(s, j + 1) }
    return "\047" out s "\047"
}
# rgread(cmd): read the first rg command of cmd. It sets rgpat[1..rgnp] (the patterns: -e values, else the
# first word that is no flag), rgpath[1..rgnq] (the file words, up to a word that starts with |, ;, &, <,
# or >), and rgopts (the flags that change what matches, written as rg gets them: -F -i -s -S -w -x -P).
function rgread(cmd,  w, n, i, x, k, ch, val, dd, pos, npos, long) {
    n = words(cmd, w); rgnp = 0; rgnq = 0; rgopts = ""; dd = 0; npos = 0; split("", pos)
    for (i = 2; i <= n; i++) {
        x = w[i]
        if (!dd && x ~ /^([0-9]?>|[|;&<])/) break
        if (dd || x !~ /^-./) { pos[++npos] = x; continue }
        if (x == "--") { dd = 1; continue }
        if (x ~ /^--/) {
            long = x; val = ""
            if (index(x, "=")) { long = substr(x, 1, index(x, "=") - 1); val = substr(x, index(x, "=") + 1) }
            if (long == "--fixed-strings") rgopts = rgopts " -F"
            else if (long == "--ignore-case") rgopts = rgopts " -i"
            else if (long == "--case-sensitive") rgopts = rgopts " -s"
            else if (long == "--smart-case") rgopts = rgopts " -S"
            else if (long == "--word-regexp") rgopts = rgopts " -w"
            else if (long == "--line-regexp") rgopts = rgopts " -x"
            else if (long == "--pcre2") rgopts = rgopts " -P"
            else if (long ~ /^--(regexp|glob|iglob|type|type-not|type-add|max-count|after-context|before-context|context|max-depth|maxdepth|replace|threads|file|encoding|sort|sortr|max-columns|colors|pre|pre-glob|engine|path-separator|ignore-file|max-filesize|dfa-size-limit|regex-size-limit|context-separator|field-context-separator|field-match-separator|hyperlink-format|generate)$/) {
                if (val == "" && !index(x, "=")) val = w[++i]
                if (long == "--regexp") rgpat[++rgnp] = val
            }
            continue
        }
        for (k = 2; k <= length(x); k++) {
            ch = substr(x, k, 1)
            if (ch == "F" || ch == "i" || ch == "s" || ch == "S" || ch == "w" || ch == "x" || ch == "P") rgopts = rgopts " -" ch
            else if (index("efgtTABCmjMEdr", ch)) {
                val = substr(x, k + 1)
                if (val == "") val = w[++i]
                if (ch == "e") rgpat[++rgnp] = val
                break
            }
        }
    }
    k = 1
    if (!rgnp && npos) rgpat[++rgnp] = pos[k++]
    for (; k <= npos; k++) { x = pos[k]; sub(/^\.\//, "", x); sub(/\/+$/, "", x); if (x != "" && x != ".") rgpath[++rgnq] = x }
}
# named(file, p): file is the file, a file under the folder, or a match of the glob p.
function named(file, p,  g, j, c) {
    if (file == p || index(file, p "/") == 1) return 1
    if (p !~ /[*?]/) return 0
    g = ""
    for (j = 1; j <= length(p); j++) {
        c = substr(p, j, 1)
        if (c == "*") { if (substr(p, j + 1, 1) == "*") { g = g ".*"; j++ } else g = g "[^/]*" }
        else if (c == "?") g = g "[^/]"
        else if (index(".+()[]{}^$|\\", c)) g = g "\\" c
        else g = g c
    }
    return file ~ ("^" g "$")
}
'

# fix_lines <plan|diff> <lines|parts|files>: read the ## Fix check of the last round file review-<kind>-<n>.md.
# lines (plan gate): a "- <round>.<item>" line for each Act on item of each round file, the new failure part
# of each line, and the control of each item that a criterion change row or a Plan gate changes item names.
# parts (code gate): the new failure part of each line, of the items of CHECK_PLAN_FIX_ITEMS when it is set.
# files (phase 7): the file of each deferred control.
fix_lines() {
    local kind="$1" mode="$2" files="" last_file="" last=0 file n msg
    for file in "$run"/review-"$kind"-*.md; do
        [[ "${file##*/}" =~ ^review-$kind-([0-9]+)\.md$ ]] || continue
        n=$((10#${BASH_REMATCH[1]}))
        files+="$file"$'\n'
        ((n > last)) && { last=$n; last_file="$file"; }
    done
    ((last)) || return 0
    while IFS= read -r msg; do say "$msg"; done < <(FIX_FILES="$files" FIX_ITEMS="${CHECK_PLAN_FIX_ITEMS:-}" awk -v run="$run" -v last_file="$last_file" -v mode="$mode" '
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        # nf_ok(line): the text after "new failure:" is not empty, and "none" has ": <reason>" after it.
        function nf_ok(line,  i, t) {
            i = index(line, "new failure:")
            if (!i) return 0
            t = substr(line, i + 12)
            i = index(t, "control:"); if (i) t = substr(t, 1, i - 1)
            t = trim(t)
            if (tolower(t) ~ /^none([^[:alnum:]]|$)/) return substr(t, 5) ~ /^[[:space:]]*:[[:space:]]*[[:alnum:]]/
            return t ~ /[[:alnum:]]/
        }
        # ctl(line): the text of the control part, up to the next ";" or "new failure:".
        function ctl(line,  i, t) {
            i = index(line, "control:"); if (!i) return ""
            t = substr(line, i + 8)
            i = index(t, "new failure:"); if (i) t = substr(t, 1, i - 1)
            i = index(t, ";"); if (i) t = substr(t, 1, i - 1)
            gsub(/`/, "", t); t = trim(t); sub(/[.]$/, "", t)
            return t
        }
        # form(c): "a" for "<path> <result>", "b" for "<path> after <slice>", else "". Sets cpath.
        function form(c,  n, t) {
            n = split(c, t, /[[:space:]]+/); cpath = t[1]
            if (cpath !~ /^(logs|probes)\/[^[:space:]]+$/ || cpath ~ /(^|\/)\.\.(\/|$)/) return ""
            if (n == 3 && t[2] == "after") return (t[3] in slice) ? "b" : ""
            if (n == 3 && t[2] == "exit" && t[3] ~ /^[0-9]+$/) return "a"
            if (n == 4 && t[2] ~ /^[0-9]+$/ && t[3] == "of" && t[4] ~ /^[0-9]+$/) return "a"
            if (n == 2 && (t[2] == "PASS" || t[2] == "FAIL")) return "a"
            return ""
        }
        function exists(path,  r) { r = (getline junk < (run "/" path)); close(run "/" path); return r >= 0 }
        # flush_item: a Plan gate changes item with a Criteria ID names the gate item that its start gives.
        function flush_item(  v, s, w) {
            if (!pitem) return
            pitem = 0
            if (ptext !~ /Criteria[*]*:/) return
            v = ptext; sub(/.*Criteria[*]*:/, "", v); sub(/\n.*/, "", v)
            if (!match(v, /[A-Z]+[0-9]+[a-z]*/)) return
            s = ptext; sub(/^(- |[0-9]+\. )[*[:space:]]*/, "", s); s = tolower(s)
            if (match(s, /^act on [0-9]+/)) { split(substr(s, RSTART, RLENGTH), w, " "); need[pround "." (w[3] + 0)] = 1 }
            else if (match(s, /^gate [0-9]+ item [0-9]+/)) { split(substr(s, RSTART, RLENGTH), w, " "); need[(w[2] + 0) "." (w[4] + 0)] = 1 }
            else if (match(s, /^plan gate [0-9]+ item [0-9]+/)) { split(substr(s, RSTART, RLENGTH), w, " "); need[(w[3] + 0) "." (w[5] + 0)] = 1 }
        }
        BEGIN {
            nfiles = split(ENVIRON["FIX_FILES"], F, "\n")
            for (i = 1; i <= nfiles; i++) {
                if (F[i] == "") continue
                name = F[i]; sub(/.*\//, "", name)
                r = name; sub(/^review-[a-z]+-/, "", r); sub(/\.md$/, "", r); r += 0
                act = 0
                while ((getline line < F[i]) > 0) {
                    if (line ~ /^## /) act = (line ~ /^## Act on/)
                    else if (act && line ~ /^[0-9]+\. /) {
                        k = line; sub(/\..*/, "", k); key = r "." (k + 0)
                        if (!(key in seen)) { seen[key] = 1; order[++norder] = key }
                    }
                }
                close(F[i])
            }
            lastname = last_file; sub(/.*\//, "", lastname)
            infix = 0; cur = 0
            while ((getline line < last_file) > 0) {
                if (line ~ /^## /) { infix = (line ~ /^## Fix check/); cur = 0; continue }
                if (!infix) continue
                if (line ~ /^- +[0-9]+\.[0-9]+/) {
                    t = line; sub(/^- +/, "", t); match(t, /^[0-9]+\.[0-9]+/); split(substr(t, RSTART, RLENGTH), kk, ".")
                    ltext[++nl] = line; lkey[nl] = (kk[1] + 0) "." (kk[2] + 0); has[lkey[nl]] = 1; cur = nl
                } else if (cur && line ~ /[^[:space:]]/ && line !~ /^- /) ltext[cur] = ltext[cur] " " line
                else cur = 0
            }
            close(last_file)
            while ((getline line < (run "/decisions.tsv")) > 0) {
                split(line, cols, "\t"); d = tolower(cols[3])
                if (d !~ /^criterion change/) continue
                while (match(d, /plan gate [0-9]+ item [0-9]+/)) {
                    split(substr(d, RSTART, RLENGTH), w, " ")
                    need[(w[3] + 0) "." (w[5] + 0)] = 1
                    d = substr(d, RSTART + RLENGTH)
                }
            }
            inslices = ingate = pitem = 0
            while ((getline line < (run "/plan.md")) > 0) {
                if (line ~ /^## /) {
                    flush_item()
                    inslices = (line ~ /^## Slices([[:space:]].*)?$/); ingate = (line ~ /^## Plan gate( [0-9]+)? changes/)
                    pround = 1
                    if (match(line, /^## Plan gate [0-9]+ changes/)) { split(line, w, " "); pround = w[4] + 0 }
                    continue
                }
                if (inslices && line ~ /^### /) { split(line, w, " "); id = w[2]; gsub(/`/, "", id); sub(/:$/, "", id); slice[id] = 1; continue }
                if (!ingate) continue
                if (line ~ /^(- |[0-9]+\. )/) { flush_item(); pitem = 1; ptext = line }
                else if (pitem) ptext = ptext "\n" line
            }
            flush_item()
            if (mode == "lines") {
                for (i = 1; i <= norder; i++) if (!(order[i] in has)) missing = missing " " order[i]
                if (missing != "")
                    print lastname ": the ## Fix check has no \"- <round>.<item>\" line for the Act on item(s)" missing "; write one line for each item of each round, starting with its <round>.<item> (lead-judgment.md, Fix check)"
            }
            nonly = split(ENVIRON["FIX_ITEMS"], O, " ")
            for (i = 1; i <= nonly; i++) only[O[i]] = 1
            for (i = 1; i <= nl; i++) {
                key = lkey[i]
                if (mode == "parts" && nonly && !(key in only)) continue
                if (mode != "files" && !nf_ok(ltext[i]))
                    print lastname ": the Fix check line for " key " has no valid new failure: part; write new failure: <what the fix can break>, or new failure: none: <reason> (lead-judgment.md, Fix check)"
                c = ctl(ltext[i]); f = form(c)
                if (mode == "lines" && (key in need) && f == "")
                    print lastname ": the Fix check line for " key " names a plan gate item that changes a criterion, and needs control: <logs/ or probes/ file> <exit n, k of n, PASS, or FAIL> with the file in the run folder, or control: <logs/ or probes/ file> after <slice ID of plan.md> (lead-judgment.md, Fix check)"
                else if (mode == "lines" && (key in need) && f == "a" && !exists(cpath))
                    print lastname ": the Fix check line for " key " has control: " cpath ", and that file is not in the run folder; run the control and save its log there"
                else if (mode == "files" && f == "b" && !exists(cpath))
                    print lastname ": the Fix check line for " key " defers its control to " cpath ", and that file is not in the run folder; run the slice and save the log there, then log this row"
            }
        }')
}

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
        /^## / { close_slice(); inside = ($0 ~ /^## Slices([[:space:]].*)?$/); next }
        !inside { next }
        /^### / { close_slice(); slice = $0; checked = 0; next }
        /^- Check:/ { checked = 1 }
        END { close_slice() }' "$run/plan.md")
    while IFS= read -r msg; do say "$msg"; done < <(awk -v rows="$run/decisions.tsv" -v run="$run" \
        -v at4="${CHECK_PLAN_AT_PHASE4:-}" '
        # load_criteria(file, arr, order): the text of each criterion of the section, as log-decision.sh
        # writes it to criteria-logged.tsv: its line, then its indented lines joined by single spaces.
        function load_criteria(file, arr, order,  l, on, cur, t, id) {
            while ((getline l < file) > 0) {
                if (l ~ /^## /) { on = (l ~ /^## Acceptance criteria[[:space:]]*$/); cur = ""; continue }
                if (!on || l ~ /^[[:space:]]*$/) continue
                if (l ~ /^[[:space:]]/) {
                    if (cur != "") { t = l; gsub(/[\t ]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t); arr[cur] = arr[cur] " " t }
                    continue
                }
                cur = ""
                if (l !~ /^(- |[0-9]+\. |\|)/) continue
                t = l; sub(/^(- |[0-9]+\. |\|)[*[:space:]]*/, "", t)
                if (!match(t, /^[A-Z]+[0-9]+(\.[0-9]+)*[a-z]*/) || substr(t, RLENGTH + 1, 1) ~ /[A-Za-z0-9]/) continue
                id = substr(t, 1, RLENGTH)
                if (id in arr) continue
                cur = id; order[++order[0]] = id; gsub(/\t/, " ", l); arr[id] = l
            }
            close(file)
        }
        # changed_ids(): the IDs whose text in analysis.md differs from the last line for the ID in
        # criteria-logged.tsv, else from analysis-gate.md. An ID with neither is new: no change.
        function changed_ids(  now, order, base, border, l, i, id, out) {
            load_criteria(run "/analysis.md", now, order)
            load_criteria(run "/analysis-gate.md", base, border)
            while ((getline l < (run "/criteria-logged.tsv")) > 0) {
                i = index(l, "\t"); id = substr(l, 1, i - 1)
                if (id != "#file") base[id] = substr(l, i + 1)
            }
            close(run "/criteria-logged.tsv")
            for (i = 1; i <= order[0]; i++) {
                id = order[i]
                if ((id in base) && now[id] != base[id]) out = out (out == "" ? "" : ", ") id
            }
            return out
        }
        function close_item(  v) {
            if (!item) return
            if (text !~ /Criteria[*]*:/) {
                print "plan.md: Plan gate changes item " item " has no Criteria: field; write Criteria: <IDs separated by commas> or Criteria: none" \
                    ((v = changed_ids()) == "" ? "" : "; criteria whose text changed since their baseline: " v)
            } else {
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
    if [[ -f "$run/analysis.md" && ( -z "$start" || ! "$start" < "$bench_stat_cutoff" ) ]]; then
        while IFS= read -r msg; do say "$msg"; done < <(awk '
            /^## / { inside = ($0 ~ /^## Acceptance criteria[[:space:]]*$/); next }
            inside && /^(- |[0-9]+\. |\|)/ {
                t = $0; sub(/^(- |[0-9]+\. |\|)[*[:space:]]*/, "", t)
                if (!match(t, /^[A-Z]+[0-9]+[a-z]*/) || substr(t, RLENGTH + 1, 1) ~ /[A-Za-z0-9]/) next
                id = substr(t, 1, RLENGTH)
                if (tolower($0) ~ /(^|[^a-z0-9_])(p50|p90|p95|p99|median|maximum|max)([^a-z0-9_]|$)/) next
                if ($0 ~ /^\|/) { n = 1; sentence[1] = $0 } else n = split($0, sentence, /\. /)
                for (i = 1; i <= n; i++)
                    if (sentence[i] ~ /(make bench|[A-Za-z]+Benchmark)([^A-Za-z0-9]|$)/ &&
                        (sentence[i] ~ /(under|at most|budget|takes) [0-9]+(\.[0-9]+)? ?(ms|s)([^A-Za-z0-9]|$)/ ||
                         sentence[i] ~ /(^|[^A-Za-z0-9.])[0-9]+(\.[0-9]+)? ?(ms|s) or less/)) {
                        print "analysis.md: criterion " id " names a bench and a time budget with no statistic word (p50, p90, p95, p99, median, or max); name the statistic that the bench measures over its span, for example \"p95 of FooBenchmark at most 8 ms\""
                        break
                    }
            }' "$run/analysis.md")
    fi
    if [[ -f "$run/analysis.md" && -f "$run/plan.md" && ( -z "$start" || ! "$start" < "$graders_cutoff" ) ]]; then
        while IFS= read -r msg; do say "$msg"; done < <(awk -v plan="$run/plan.md" -v analysis="$run/analysis.md" "$rg_awk"'
            # parse(id): prefix gp, number gn, and lower-case suffix gs of a criterion ID.
            function parse(id) {
                gp = id; sub(/[0-9]+[a-z]*$/, "", gp)
                gn = id; sub(/^[A-Z]+/, "", gn); gn += 0
                gs = id; sub(/^[A-Z]+[0-9]+/, "", gs)
            }
            # ranges(s): the ranges "C2 to C5" and "C2-C5" of the listing text of slice s.
            function ranges(s,  rest, r, e, p, ln, lsf) {
                rest = ltext[s]
                while (match(rest, /[A-Z]+[0-9]+[a-z]*( to |-)[A-Z]+[0-9]+[a-z]*/)) {
                    r = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
                    gsub(/ to |-/, " ", r); split(r, e, " ")
                    parse(e[1]); p = gp; ln = gn; lsf = gs
                    parse(e[2])
                    if (p != gp) continue
                    nr[s]++; rp[s, nr[s]] = p; lo[s, nr[s]] = ln; los[s, nr[s]] = lsf; hi[s, nr[s]] = gn; his[s, nr[s]] = gs
                }
            }
            # lists(s, id): the ### heading or a "- Criteria:" line of slice s names id, alone or in a range.
            function lists(s, id,  k) {
                if (ltext[s] ~ ("(^|[^A-Za-z0-9])" id "([^A-Za-z0-9]|$)")) return 1
                parse(id)
                for (k = 1; k <= nr[s]; k++)
                    if (rp[s, k] == gp && (gn > lo[s, k] || (gn == lo[s, k] && gs >= los[s, k])) && (gn < hi[s, k] || (gn == hi[s, k] && (his[s, k] == "" || gs <= his[s, k])))) return 1
                return 0
            }
            BEGIN {
                while ((getline line < plan) > 0) {
                    if (line ~ /^## /) { inslices = (line ~ /^## Slices([[:space:]].*)?$/); mode = ""; continue }
                    if (!inslices) continue
                    if (line ~ /^### /) { ns++; ltext[ns] = line; gline[ns] = ""; mode = ""; continue }
                    if (!ns) continue
                    if (line ~ /^- Criteria:/) { ltext[ns] = ltext[ns] "\n" line; mode = "c"; continue }
                    if (line ~ /^- Graders:/) { gline[ns] = gline[ns] " " line; mode = "g"; continue }
                    if (line ~ /^[[:space:]]+[^[:space:]]/ && mode == "c") { ltext[ns] = ltext[ns] "\n" line; continue }
                    if (line ~ /^[[:space:]]+[^[:space:]]/ && mode == "g") { gline[ns] = gline[ns] " " line; continue }
                    mode = ""
                }
                close(plan)
                for (s = 1; s <= ns; s++) {
                    ranges(s)
                    n = graders(gline[s], g)
                    for (m = 1; m <= n; m++) held[s, g[m]] = 1
                }
                criteria(analysis)
                fix ="copy the grader whole to the \"- Graders:\" line of a slice that lists the criterion, or write a case input in double quotes"
                for (o = 1; o <= no; o++) {
                    id = order[o]; n = graders(ctext[id], g)
                    for (m = 1; m <= n; m++) {
                        if ((id SUBSEP g[m]) in done) continue
                        done[id, g[m]] = 1
                        owners = 0; ok = 0
                        for (s = 1; s <= ns; s++) if (lists(s, id)) { owners++; if ((s, g[m]) in held) ok = 1 }
                        if (!owners)
                            print "analysis.md: criterion " id " has the grader `" g[m] "`, and no slice lists " id " in its ### heading or its \"- Criteria:\" line; " fix
                        else if (!ok)
                            print "analysis.md: criterion " id " has the grader `" g[m] "`, and no slice that lists " id " holds it in a \"- Graders:\" line; " fix
                    }
                }
            }')
    fi
    # Cutoff 2026-10-24T10:00, the commit that added the Landings rule: a run that started earlier passes without it.
    if [[ -z "$start" || ! "$start" < 2026-10-24T10:00 ]]; then
        while IFS= read -r msg; do say "$msg"; done < <(awk '
            # sources(s): each Sources/ word of s; a literal \n of a path list and the quotes break words.
            function sources(s,  i, k, out) {
                gsub(/\\n|[$\047"`<>]/, " ", s)
                k = split(s, w, /[[:space:]]+/)
                for (i = 1; i <= k; i++) if (w[i] ~ /^Sources\//) out = out " " w[i]
                return out
            }
            function num(id) { match(id, /[0-9]+[a-z]*$/); return substr(id, RSTART, RLENGTH) + 0 }
            function prefix(id) { sub(/[0-9]+[a-z]*$/, "", id); return id }
            # listed(id, spec): id is a slice ID of the Slices cell: a listed ID, or inside "A to B" of one prefix.
            function listed(id, spec,  k, i, t) {
                gsub(/ to /, " ~ ", spec); k = split(spec, t, /[[:space:],;]+/)
                for (i = 1; i <= k; i++) {
                    if (t[i] == id) return 1
                    if (t[i + 1] == "~" && prefix(t[i]) == prefix(id) && num(id) >= num(t[i]) && num(id) <= num(t[i + 2])) return 1
                }
                return 0
            }
            /^## / { inslices = ($0 ~ /^## Slices([[:space:]].*)?$/); table = 0 }
            inslices && /^### / { slice = $2; gsub(/`/, "", slice); sub(/:$/, "", slice); ids[slice] = 1; next }
            inslices && /^- Check:/ { p = sources($0); paths[slice] = paths[slice] p; all = all p; next }
            /^\|/ {
                line = $0; gsub(/\\\|/, "\001", line); n = split(line, cell, "|")
                for (i = 2; i < n; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell[i])
                if (!table) {
                    table = 1; bc = lc = sc = 0
                    for (i = 2; i < n; i++) {
                        if (cell[i] == "Branch" || cell[i] == "Branch and worktree") bc = i
                        if (cell[i] == "Lands") lc = i
                        if (cell[i] == "Slices") sc = i
                    }
                    next
                }
                if (!bc || !lc || cell[2] ~ /^-+$/) next
                branch = cell[bc]; gsub(/`/, "", branch)
                if (branch !~ /^feat\// || cell[lc] !~ /^none/) next
                rows++; name[rows] = cell[2]; br[rows] = branch; spec[rows] = sc ? cell[sc] : ""; gsub(/`/, "", spec[rows])
                next
            }
            !/^### / { table = 0 }
            END {
                for (r = 1; r <= rows; r++) {
                    hit = ""; matched = 0
                    if (spec[r] != "") for (id in ids) if (listed(id, spec[r])) { matched = 1; hit = hit paths[id] }
                    if (!matched) hit = all
                    if (hit == "") continue
                    k = split(hit, h, " ")
                    print "plan.md: Landings row \"" name[r] "\" has branch " br[r] " and Lands none, and its slices change " k " Sources/ paths, for example " h[1] "; scripts/tag-release.sh needs a done row in features.md for the run number, so name at least one F-ID in the Lands cell"
                }
            }' "$run/plan.md")
    fi
    # Cutoff 2026-10-31T06:19, the land time of the size rule: a run that started earlier passes without it.
    size_cutoff=2026-10-31T06:19
    if [[ -z "$start" || ! "$start" < "$size_cutoff" ]] &&
        ! awk -F'\t' '$2 == "4" { f = 1 } END { exit !f }' "$run/decisions.tsv" 2>/dev/null; then
        root="$(cd "$(dirname "$0")/.." && pwd)"
        # size_slice: the checks of one slice (slice, paths, and split_lines). The file name goes into the
        # pattern with each ERE metacharacter escaped, so a Split line names it as fixed text.
        size_slice() {
            local p n base base_re ok l rest
            for p in $paths; do
                n="$(git -C "$root" show "origin/main:$p" 2>/dev/null | wc -l | tr -d ' ' || true)"
                ((${n:-0} >= limit - 20)) || continue
                if git -C "$root" show origin/main:scripts/check-sizes.allow 2>/dev/null | cut -f1 | grep -qxF "$p"; then continue; fi
                base="${p##*/}" ok=""
                base_re="$(sed 's/[][\\.*^$+?(){}|]/\\&/g' <<<"$base")"
                for l in ${split_lines[@]+"${split_lines[@]}"}; do
                    [[ "$l" =~ (^|[^A-Za-z0-9_+])${base_re}([^A-Za-z0-9_+]|$) ]] || continue
                    rest="${l//"$base"/}"
                    if [[ "$rest" =~ [A-Za-z0-9_+]+\.swift ]] || [[ "$rest" =~ scripts/check-sizes\.allow[^A-Za-z0-9]*[A-Za-z]{3,} ]]; then ok=1; fi
                done
                [[ -n "$ok" ]] ||
                    say "plan.md: slice $slice names $p, which has $n lines at origin/main (limit $limit; a file of $((limit - 20)) lines or more is near it); before the first phase 4 row add a \"- Split:\" line to the slice that names $base and a target .swift file, or names scripts/check-sizes.allow with a reason (the file also passes when scripts/check-sizes.allow lists it at origin/main)"
            done
        }
        # The awk prints "P<TAB>slice<TAB>paths" for a slice and "S<TAB>line" for each of its Split lines:
        # one record per line, because bash 3.2 does not split on a \001 separator.
        size_in="$(awk '
            # swift(s): each Sources/ or Tests/ Swift word of s; a literal \n of a path list and the quotes break words.
            function swift(s,  i, k, out, w) {
                gsub(/\\n|[$\047"`<>]/, " ", s); k = split(s, w, /[[:space:]]+/)
                for (i = 1; i <= k; i++) if (w[i] ~ /^(Sources|Tests)\/.*\.swift$/) out = out " " w[i]
                return out
            }
            function flush(  i) {
                if (paths != "") { print "P\t" slice "\t" paths; for (i = 1; i <= ns; i++) print "S\t" splits[i] }
                slice = paths = ""; ns = 0
            }
            /^## / { flush(); inslices = ($0 ~ /^## Slices([[:space:]].*)?$/); next }
            inslices && /^### / { flush(); slice = $2; gsub(/`/, "", slice); sub(/:$/, "", slice); next }
            slice == "" { next }
            /^- Check:/ { paths = paths swift($0) }
            /^- Split:/ { splits[++ns] = $0 }
            END { flush() }' "$run/plan.md")"
        limit="$(sed -n 's/^limit=\([0-9]*\)$/\1/p' "$root/scripts/check-sizes.sh" 2>/dev/null || true)"
        if [[ -n "$size_in" && -z "$limit" ]]; then
            say "plan.md: a slice names a Swift file, and $root/scripts/check-sizes.sh has no limit= line to compare it with"
        elif [[ -n "$size_in" ]]; then
            slice="" paths="" split_lines=()
            while IFS= read -r record; do
                if [[ "$record" == P$'\t'* ]]; then
                    [[ -z "$paths" ]] || size_slice
                    record="${record#P$'\t'}"
                    slice="${record%%$'\t'*}" paths="${record#*$'\t'}" split_lines=()
                else
                    split_lines+=("${record#S$'\t'}")
                fi
            done <<<"$size_in"
            size_slice
        fi
    fi
    # Cutoff 2026-10-28T23:50, the commit that added the Fix check line rule: a run that started earlier needs none.
    if [[ ( -n "${CHECK_PLAN_AT_PHASE7:-}" || -n "${CHECK_PLAN_FIX_CHECK:-}" ) && ( -z "$start" || ! "$start" < 2026-10-28T23:50 ) ]]; then
        last=0 missing=""
        for file in "$run"/review-diff-*.md; do
            [[ "${file##*/}" =~ ^review-diff-([0-9]+)\.md$ ]] || continue
            n=$((10#${BASH_REMATCH[1]}))
            ((n > last)) && { last=$n; last_file="$file"; }
        done
        if ((last)); then
            fix="$(awk '/^## / { on = ($0 ~ /^## Fix check/); next } on' "$last_file")"
            for file in "$run"/review-diff-*.md; do
                [[ "${file##*/}" =~ ^review-diff-([0-9]+)\.md$ ]] || continue
                n=$((10#${BASH_REMATCH[1]}))
                while IFS= read -r k; do
                    [[ -z "${CHECK_PLAN_FIX_ITEMS:-}" || " $CHECK_PLAN_FIX_ITEMS " == *" $n.$((10#$k)) "* ]] || continue
                    grep -qE "(^|[^0-9.])$n\\.$k([^0-9]|\$)" <<<"$fix" || missing+=" $n.$k"
                done < <(awk '/^## / { act = ($0 ~ /^## Act on/); next } act && /^[0-9]+\. / { k = $0; sub(/\..*/, "", k); print k }' "$file")
            done
            [[ -z "$missing" ]] ||
                say "${last_file##*/} has no ## Fix check line for the Act on item(s)$missing; write one line for each item of each round, starting with its <round>.<item> (lead-judgment.md, Fix check)"
        fi
        if [[ -z "$start" || ! "$start" < "$fixline_cutoff" ]]; then
            fix_lines diff parts
            [[ -z "${CHECK_PLAN_AT_PHASE7:-}" ]] || fix_lines plan files
        fi
        first6="$(awk -F'\t' '$2 == "6" { print $1; exit }' "$run/decisions.tsv" 2>/dev/null || true)"
        if [[ -n "${CHECK_PLAN_AT_PHASE7:-}" && -f "$run/run.md" && -f "$run/analysis.md" && -n "$first6" && ! "$start" < "$quote_cutoff" ]]; then
            root="$(cd "$(dirname "$0")/.." && pwd)"
            branch="$(grep '^- Branch:' "$run/run.md" | tail -n 1 | sed -E 's/^- Branch: *//; s/[ ,].*$//; s/`//g' || true)"
            if ! git -C "$root" rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
                say "run.md: the last - Branch: line names '$branch', and the repo $root has no such branch; write the run branch on a new - Branch: line"
            else
                since="$(date -j -f %Y-%m-%dT%H:%M:%S "$first6:00" +%s)"
                # The grader reading writes the removed and the added lines of each file of each fix commit to
                # files of gtmp, and lets rg match them.
                gon=0 have_rg=0
                [[ "$start" < "$graders_cutoff" ]] || gon=1
                ! command -v rg > /dev/null || have_rg=1
                gtmp="$(mktemp -d)"
                trap 'rm -rf "$gtmp"' EXIT
                # The awk reads a "commit <short hash>" line, then the -U0 diff of that commit, for each fix commit.
                while IFS= read -r msg; do say "$msg"; done < <(
                    while read -r hash short at; do
                        ((at >= since)) || continue
                        echo "commit $short"
                        git -C "$root" show --format= --no-color -U0 "$hash"
                    done < <(git -C "$root" log --no-merges --format='%H %h %at' "origin/main..$branch") |
                        awk -v rows="$run/decisions.tsv" -v analysis="$run/analysis.md" -v run="$run" -v gtmp="$gtmp" -v gon="$gon" -v have_rg="$have_rg" "$rg_awk"'
                        # pair(h, p): the number of the pair of fix commit h and file p, for the lines of the grader reading.
                        function pair(h, p,  key) {
                            key = h SUBSEP p
                            if (!(key in pk)) { pk[key] = ++npair; ph[npair] = h; pp[npair] = p }
                            return pk[key]
                        }
                        # first_match(files): the lowest pair number of the files (names r<n> or a<n> in gtmp) that
                        # the first rg command of cmd matches; 0 when none, and when rg cannot read the pattern.
                        function first_match(files, pats,  cmd, f, k, low) {
                            cmd = "rg -l --no-config --no-messages" rgopts pats " -- " files " 2>/dev/null"
                            low = 0
                            while ((cmd | getline f) > 0) { k = substr(f, length(gtmp) + 3) + 0; if (!low || k < low) low = k }
                            close(cmd)
                            return low
                        }
                        # removed_by(cmd): the fix commit that removes a line that the pattern of the first rg command
                        # of cmd matches, in a file that the command names, when no fix commit adds such a line.
                        function removed_by(cmd,  i, k, rfiles, afiles, pats, low, ok) {
                            rgread(cmd)
                            if (!rgnp) return ""
                            for (i = 1; i <= rgnp; i++) pats = pats " -e " shq(rgpat[i])
                            for (k = 1; k <= npair; k++) {
                                ok = !rgnq
                                for (i = 1; i <= rgnq && !ok; i++) if (named(pp[k], rgpath[i])) ok = 1
                                if (!ok) continue
                                if (k in rbuf) rfiles = rfiles " " shq(gtmp "/r" k)
                                if (k in abuf) afiles = afiles " " shq(gtmp "/a" k)
                            }
                            if (rfiles == "") return ""
                            if (!have_rg) {
                                if (!told_rg++) print "analysis.md: the grader rule of the quote check needs rg on the PATH; install ripgrep"
                                return ""
                            }
                            low = first_match(rfiles, pats)
                            if (!low) return ""
                            if (afiles != "" && first_match(afiles, pats)) return ""
                            return ph[low]
                        }
                        # texts(line): the double-quoted texts of line outside backtick spans, in q[1..n].
                        function texts(line,  n, c, j, t) {
                            n = 0
                            while (match(line, /[`"]/)) {
                                c = substr(line, RSTART, 1); line = substr(line, RSTART + 1)
                                j = index(line, c)
                                if (!j) break
                                t = substr(line, 1, j - 1); line = substr(line, j + 1)
                                if (c == "\"" && t != "" && t !~ /^ | $/) q[++n] = t
                            }
                            return n
                        }
                        /^commit / { h = $2; hunk = 0; next }
                        /^diff --git / { hunk = 0; path = $0; sub(/^.* b\//, "", path); next }
                        /^@@/ { hunk = 1; next }
                        hunk && /^-/ { rl[++nr] = substr($0, 2); rh[nr] = h; if (gon) { k = pair(h, path); rbuf[k] = rbuf[k] rl[nr] "\n" }; next }
                        hunk && /^\+/ { al[++na] = substr($0, 2); if (gon) { k = pair(h, path); abuf[k] = abuf[k] al[na] "\n" } }
                        END {
                            for (k in rbuf) { printf "%s", rbuf[k] > (gtmp "/r" k); close(gtmp "/r" k) }
                            for (k in abuf) { printf "%s", abuf[k] > (gtmp "/a" k); close(gtmp "/a" k) }
                            while ((getline line < rows) > 0) {
                                split(line, c, "\t")
                                if (c[2] == "6") seen6 = 1
                                if (seen6 && tolower(c[3]) ~ /^criterion change/) changes[++m] = c[3]
                            }
                            while ((getline line < analysis) > 0) {
                                if (line ~ /^## /) { on = (line ~ /^## Acceptance criteria[[:space:]]*$/); continue }
                                if (!on || line !~ /^(- |[0-9]+\. |\|)/) continue
                                t = line; sub(/^(- |[0-9]+\. |\|)[*[:space:]]*/, "", t)
                                if (!match(t, /^[A-Z]+[0-9]+[a-z]*/) || substr(t, RLENGTH + 1, 1) ~ /[A-Za-z0-9]/) continue
                                id = substr(t, 1, RLENGTH)
                                covered = 0
                                for (k = 1; k <= m; k++) if (changes[k] ~ ("(^|[^A-Za-z0-9])" id "([^A-Za-z0-9]|$)")) covered = 1
                                if (covered || id in told) continue
                                n = texts(line)
                                for (k = 1; k <= n; k++) {
                                    by = ""
                                    for (i = 1; i <= nr && by == ""; i++) if (index(rl[i], q[k])) by = rh[i]
                                    if (by == "") continue
                                    for (i = 1; i <= na; i++) if (index(al[i], q[k])) break
                                    if (i <= na) continue
                                    told[id] = 1
                                    print "analysis.md: criterion " id " quotes \"" substr(q[k], 1, 60) "\", and fix commit " by " removes it; edit the criterion in analysis.md first, then log it with .claude/skills/deliver/scripts/log-decision.sh " run " --from <file>: line 1 6, line 2 criterion change " id ": old ..., new ..., then the why, the evidence, and the result"
                                    break
                                }
                            }
                            if (!gon) exit
                            close(analysis)
                            criteria(analysis)
                            for (o = 1; o <= no; o++) {
                                id = order[o]
                                covered = 0
                                for (k = 1; k <= m; k++) if (changes[k] ~ ("(^|[^A-Za-z0-9])" id "([^A-Za-z0-9]|$)")) covered = 1
                                if (covered || id in told) continue
                                n = graders(ctext[id], gl)
                                for (g = 1; g <= n; g++) {
                                    by = removed_by(gl[g])
                                    if (by == "") continue
                                    told[id] = 1
                                    print "analysis.md: criterion " id " has the grader `" gl[g] "`, and fix commit " by " removes a line with its pattern; edit the criterion in analysis.md first, then log it with .claude/skills/deliver/scripts/log-decision.sh " run " --from <file>: line 1 6, line 2 criterion change " id ": old ..., new ..., then the why, the evidence, and the result"
                                    break
                                }
                            }
                        }')
            fi
        fi
    fi
    # Each criterion of analysis-gate.md (the copy that log-decision.sh makes at the first phase 4 row)
    # whose line changed or is gone needs a criterion change row after the first phase 4 row.
    if [[ -f "$run/analysis-gate.md" && -f "$run/analysis.md" ]] &&
        { [[ -n "${CHECK_PLAN_AT_PHASE4:-}" ]] || awk -F'\t' '$2 == "4" { f = 1 } END { exit !f }' "$run/decisions.tsv" 2>/dev/null; }; then
        while IFS= read -r msg; do say "$msg"; done < <(awk -v rows="$run/decisions.tsv" -v run="$run" '
            function criteria(file, isgate,  line, t, id, on) {
                while ((getline line < file) > 0) {
                    if (line ~ /^## /) { on = (line ~ /^## Acceptance criteria[[:space:]]*$/); continue }
                    if (!on || line !~ /^(- |[0-9]+\. |\|)/) continue
                    t = line; sub(/^(- |[0-9]+\. |\|)[*[:space:]]*/, "", t)
                    if (!match(t, /^[A-Z]+[0-9]+[a-z]*/) || substr(t, RLENGTH + 1, 1) ~ /[A-Za-z0-9]/) continue
                    id = substr(t, 1, RLENGTH)
                    if (isgate) { if (!(id in gate)) { gate[id] = line; gid[++ng] = id } }
                    else if (!(id in now)) now[id] = line
                }
                close(file)
            }
            BEGIN {
                criteria(run "/analysis-gate.md", 1)
                criteria(run "/analysis.md", 0)
                while ((getline line < rows) > 0) {
                    split(line, c, "\t")
                    if (c[2] == "4") seen4 = 1
                    if (seen4 && tolower(c[3]) ~ /^criterion change/) changes[++m] = c[3]
                }
                for (i = 1; i <= ng; i++) {
                    id = gid[i]
                    if (id in now && now[id] == gate[id]) continue
                    found = 0
                    for (k = 1; k <= m; k++) if (changes[k] ~ ("(^|[^A-Za-z0-9])" id "([^A-Za-z0-9]|$)")) found = 1
                    if (!found)
                        print "analysis.md: criterion " id (id in now ? " differs from" : " is gone since") " analysis-gate.md and no criterion change row follows the first phase 4 row; a default, a wording pick, a fix, or a new value changes a criterion; edit analysis.md first, then log it: .claude/skills/deliver/scripts/log-decision.sh " run " 4 \"criterion change " id ": old ..., new ...\" <why> <evidence> <result>"
                }
            }' </dev/null)
    fi
    # Row order, not the clock, decides which phase row is last.
    if [[ -n "${CHECK_PLAN_AT_PHASE4:-}" ]]; then
        compgen -G "$run/review-plan-*.md" >/dev/null || say "no review-plan-<n>.md in $run: the plan gate is not closed; run the plan gate (deliver Phase 3), write review-plan-<n>.md, and log its phase 3 row before the first phase 4 row"
        if [[ -z "${CHECK_PLAN_GATE_CLOSE:-}" ]] && ! awk -F'\t' '$2 == "2" { l2 = NR } $2 == "3" { l3 = NR } END { exit !(l3 > l2) }' "$run/decisions.tsv" 2>/dev/null; then
            say "the last phase 2 row of decisions.tsv has no phase 3 row after it: the plan gate is not closed; run the plan gate (deliver Phase 3), write review-plan-<n>.md, and log a new phase 3 row before the first phase 4 row"
        fi
        # Round files are review-plan-<n>.md: a per-lens file such as review-plan-1-premortem.md is none.
        # Cutoff 2026-10-24T10:09, the commit that added the fix check rule: a run that started earlier needs none.
        last=0 acts=0
        for file in "$run"/review-plan-*.md; do
            [[ "${file##*/}" =~ ^review-plan-([0-9]+)\.md$ ]] || continue
            n=$((10#${BASH_REMATCH[1]}))
            ((n > last)) && { last=$n; last_file="$file"; }
            awk '/^## / { act = ($0 ~ /^## Act on/); next } act && /^[0-9]+\. / { found = 1 } END { exit !found }' "$file" && acts=1
        done
        if ((acts)) && [[ -z "$start" || ! "$start" < 2026-10-24T10:09 ]] && ! grep -q '^## Fix check' "$last_file"; then
            say "${last_file##*/} has no ## Fix check, and a round file has a numbered Act on item; run the fix check after the last round (lead-judgment.md, Fix check) and write its result under ## Fix check"
        fi
        if ((acts)) && [[ -z "$start" || ! "$start" < "$fixline_cutoff" ]] && grep -q '^## Fix check' "$last_file"; then
            fix_lines plan lines
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
                    say "plan.md makes $record: reserve $n with scripts/wiki.py reserve --from <file>; write the file with the Write tool, one line: \"$n <title> (run $folder)\", with no comma and no parenthesis in the title"
                fi
            fi
        done
    fi
fi
lead_diff=""
for file in "$run"/review-diff-*.md; do
    [[ "${file##*/}" =~ ^review-diff-[0-9]+\.md$ ]] && grep -qE '^review: lead( |$)' "$file" && { lead_diff="${file##*/}"; break; }
done
if [[ -n "$lead_diff" ]]; then
    grep -qx 'review: lead' "$run/review-plan-1.md" 2>/dev/null ||
        say "$lead_diff has the line review: lead, and review-plan-1.md has none: a code gate is a lead review only when the plan gate was one (deliver, class table)"
    branch="$(grep '^- Branch:' "$run/run.md" 2>/dev/null | tail -n 1 | sed -E 's/^- Branch: *//; s/[ ,].*$//; s/`//g' || true)"
    tree=""
    [[ -z "$branch" ]] || tree="$(git -C "$(dirname "$0")/.." worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$branch" '$1 == "worktree" { w = substr($0, 10) } $1 == "branch" && $2 == b { print w; exit }' || true)"
    if [[ -z "$tree" ]]; then
        say "$lead_diff has the line review: lead, and no worktree holds the branch '$branch' of the last - Branch: line of run.md; the rule needs the run tree"
    else
        gate="$(grep -m1 -xE 'review: lead [0-9a-f]{7,40}' "$run/$lead_diff" | cut -d' ' -f3 || true)"
        if [[ -z "$gate" ]] || ! git -C "$tree" rev-parse -q --verify "$gate^{commit}" >/dev/null 2>&1; then
            say "$lead_diff has the line review: lead with no gate commit that the run tree holds; write review: lead <commit> with the commit that the code gate reviewed"
        else
            gate_tree="$(mktemp -d)"
            if ! git -C "$tree" worktree add -q --detach "$gate_tree" "$gate" >/dev/null 2>&1; then
                say "$lead_diff has the line review: lead $gate, and git cannot check out the gate commit in $tree"
            elif ! got="$(cd "$gate_tree" && "$(cd "$(dirname "$0")" && pwd)/check-changed.sh" origin/main 2>&1)"; then
                say "$lead_diff has the line review: lead, and check-changed.sh origin/main failed at the gate commit $gate: $got"
            elif ! grep -qx 'review: lead' <<<"$got"; then
                say "$lead_diff has the line review: lead, and check-changed.sh origin/main at the gate commit $gate prints $(grep '^review:' <<<"$got" || echo 'no review line'); ask for a panel review or fix the line"
            fi
            git -C "$tree" worktree remove --force "$gate_tree" >/dev/null 2>&1 || rm -rf "$gate_tree"
        fi
    fi
fi
# 2026-10-05, the commit that added the field rule: an older review file has no fields.
cutoff=1791222684
# 2026-10-09, the commit that added the nit rule (INT-042): an older review file keeps the nit exempt.
nit_cutoff=1791510511
# 2026-10-31, the land time of the round file heading rule (INT-043): an older round file is not read by it.
round_cutoff=1793423981
# 2026-11-07, the land time of the Siblings none rule (INT-080): an older review file keeps a bare none.
none_cutoff=1794022636
for review in "$run"/review-*.md; do
    [[ -f "$review" ]] || continue
    mtime=$(stat -f %m "$review")
    ((mtime >= cutoff)) || continue
    if [[ "${review##*/}" =~ ^review-(plan|diff)-[0-9]+\.md$ ]] && ((mtime >= round_cutoff)); then
        while IFS= read -r msg; do say "$msg"; done < <(awk -v file="${review##*/}" '
            /^## / {
                if ($0 ~ /^## ([A-Z]+[0-9]+[a-z]?|[0-9]+\.)([: (]|$)/)
                    print file ": the heading \"" $0 "\" is an item; write each finding as a numbered item under ## Act on (lead-judgment.md) (a review file from before the rule: do not edit it)"
                if ($0 ~ /^## Act on/) act = 1
                if ($0 ~ /^## Fix check/) fix = 1
            }
            END { if (fix && !act) print file ": has ## Fix check and no ## Act on heading; write ## Act on with a numbered item for each finding, or None. (lead-judgment.md) (a review file from before the rule: do not edit it)" }' "$review")
    fi
    # A code gate round file of a run that started at or after graders_cutoff has a Criteria field in each Act on item.
    critrule=0
    if [[ "${review##*/}" =~ ^review-diff-[0-9]+\.md$ && -n "${start-}" && ! "${start-}" < "$graders_cutoff" ]]; then critrule=1; fi
    while IFS= read -r msg; do say "$msg"; done < <(awk -v file="${review##*/}" -v nitrule=$((mtime >= nit_cutoff)) -v nonerule=$((mtime >= none_cutoff)) -v critrule="$critrule" -v phase7="${CHECK_PLAN_AT_PHASE7:+1}" -v rows="$run/decisions.tsv" -v run="$run" '
        # crit <what>: the Criteria field of text names a criterion ID or none (its value is the rest of its line,
        # or the first non-empty next line when the colon ends the line, up to the next field). At phase 7,
        # each ID needs a criterion change row from the first phase 6 row on.
        function crit(what,  n, lines, i, j, rest, id, found, k) {
            if (text !~ "Criteria[*[:space:]]*(\\([^)]*\\))?[*[:space:]]*:") {
                print file ": " what " has no Criteria field; write Criteria: <IDs separated by commas> or Criteria: none"
                return
            }
            n = split(text, lines, "\n")
            for (i = 1; i <= n; i++) {
                if (!match(lines[i], "Criteria[*[:space:]]*(\\([^)]*\\))?[*[:space:]]*:")) continue
                rest = substr(lines[i], RSTART + RLENGTH)
                sub(/^[-*[:space:]]+/, "", rest)
                for (j = i + 1; rest == "" && j <= n; j++) { rest = lines[j]; sub(/^[-*[:space:]]+/, "", rest) }
                if (match(rest, /(^|[^A-Za-z])(Invariant|Siblings|Fix)[*[:space:]]*(\([^)]*\))?[*[:space:]]*:/)) rest = substr(rest, 1, RSTART - 1)
                break
            }
            if (tolower(rest) ~ /^none([^a-z]|$)/) return
            if (!match(rest, /[A-Z]+[0-9]+[a-z]*/)) {
                print file ": " what " has a Criteria field with no criterion ID and no none; write Criteria: <IDs separated by commas> or Criteria: none"
                return
            }
            if (!phase7) return
            while (match(rest, /[A-Z]+[0-9]+[a-z]*/)) {
                id = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
                found = 0
                for (k = 1; k <= nchanges; k++) if (changes[k] ~ ("(^|[^A-Za-z0-9])" id "([^A-Za-z0-9]|$)")) found = 1
                if (!found)
                    print file ": " what " has Criteria: " id ", and no criterion change row for " id " follows the first phase 6 row; edit the criterion in analysis.md first, then log it with .claude/skills/deliver/scripts/log-decision.sh " run " --from <file>: line 1 6, line 2 criterion change " id ": old ..., new ..., then the why, the evidence, and the result"
            }
        }
        # missing <what>: print each field that text does not have, and a Siblings field that says
        # none with no search in its value (the text after its colon, or the first non-empty next line
        # when the colon ends the line, up to the next field).
        function missing(what,  n, lines, i, j, rest) {
            for (f = 1; f <= 2; f++)
                if (text !~ (field[f] "[*[:space:]]*(\\([^)]*\\))?[*[:space:]]*:"))
                    print file ": " what " has no " field[f] " field (a review file from before the rule: add the fields, or do not edit it)"
            if (!nonerule) return
            n = split(text, lines, "\n")
            for (i = 1; i <= n; i++) {
                if (!match(lines[i], field[2] "[*[:space:]]*(\\([^)]*\\))?[*[:space:]]*:")) continue
                rest = tolower(substr(lines[i], RSTART + RLENGTH))
                sub(/^[-*[:space:]]+/, "", rest)
                for (j = i + 1; rest == "" && j <= n; j++) { rest = tolower(lines[j]); sub(/^[-*[:space:]]+/, "", rest) }
                if (match(rest, /(^|[^a-z])(invariant|siblings|fix)[*[:space:]]*(\([^)]*\))?[*[:space:]]*:/)) rest = substr(rest, 1, RSTART - 1)
                if (rest ~ /^(none|n\/a|no|nothing)([^a-z]|$)/ && rest !~ /grepped/ && rest !~ /(^|[^a-z])(rg|grep)([^a-z]|$)/) {
                    print file ": " what " has a Siblings field with no sibling and no search; write \"none, grepped <what you searched>\" (a review file from before the rule: name the search, or do not edit it)"
                    return
                }
            }
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
            if (item && !skip) { missing("Act on item " item); if (critrule) crit("Act on item " item) }
            if (note && !skip && taken()) missing("Consider item " note)
            item = note = ""
        }
        function close_section() {
            if (inside == "act" && other && !numbered) print file ": ## Act on has no numbered item (a review file from before the rule: do not edit it)"
            inside = numbered = other = 0
        }
        BEGIN {
            field[1] = "Invariant"; field[2] = "Siblings"
            while (phase7 && (getline line < rows) > 0) {
                split(line, c, "\t")
                if (c[2] == "6") seen6 = 1
                if (seen6 && tolower(c[3]) ~ /^criterion change/) changes[++nchanges] = c[3]
            }
        }
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
