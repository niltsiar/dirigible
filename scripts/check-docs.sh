#!/bin/bash
# Check the structure of the docs that plans and reviews depend on.
# Usage: scripts/check-docs.sh [repo root]. `make check` runs it.
# Rules of the provenance statement (the last rules of this script):
#   No text file names a clean room, except docs/research and the two check-docs scripts.
#   NOTICE names each file in Support/Resources and each Sources/C<name> folder that is not own code.
#   README.md links docs/provenance.md, and that file exists.
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)}"
fail=0
err() { echo "check-docs: $*" >&2; fail=1; }

# Every research file has a date and cites its sources.
for f in "$root"/docs/research/*.md; do
    [[ -e "$f" ]] || continue
    grep -q '^Date: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' "$f" || err "${f#"$root"/}: no 'Date: YYYY-MM-DD' line"
    grep -q '^## Sources' "$f" || err "${f#"$root"/}: no '## Sources' section"
done

# Every requirement ID in the brief has a row in a release table.
brief="$root/docs/requirements/brief.md"
releases="$root/docs/requirements/releases.md"
ids="$(grep -oE '^\|[[:space:]]*R[0-9]+[[:space:]]*\|' "$brief" | grep -oE 'R[0-9]+' || true)"
[[ -n "$ids" ]] || err "brief.md: no requirement rows"
if [[ ! -f "$releases" ]]; then
    err "docs/requirements/releases.md is missing"
else
    for id in $ids; do
        grep -qE "^\|[[:space:]]*$id[[:space:]]*\|" "$releases" || err "releases.md: no release row for $id"
    done
fi

# Every feature ID of the catalog has one row in features.md, with a state of its header grammar
# and the catalog Req. releases.md names only IDs that have a row, and an open Release section
# (no `Status: closed` line) names the IDs whose state is that release.
features="$root/docs/requirements/features.md"
catalog="$root/docs/research/podcast-features.md"
if [[ ! -f "$features" ]]; then
    err "docs/requirements/features.md is missing"
elif [[ ! -f "$catalog" ]]; then
    err "docs/research/podcast-features.md is missing"
else
    # A run ID of Release 1 to 3 can have letters; from Release 4 on it is digits only (tag-release.sh).
    oldid='[0-9][0-9a-z-]*' newid='[0-9]+'
    part="(Release [1-3] runs? $oldid((, | and )$oldid)*|Release ([4-9]|[1-9][0-9]+) runs? $newid((, | and )$newid)*)"
    done_state="^done, $part( and $part)*( [(][^)]*[)])?(; Later: .+)?\$"
    if out="$(awk -F'|' -v done_state="$done_state" '
        function t(x) { gsub(/^ +| +$/, "", x); return x }
        function bad(m) { print m; failed = 1 }
        function released(s, n,   x) {
            x = s; sub(/; Later:.*/, "", x); gsub(/ [(][^)]*[)]/, "", x)
            return x ~ ("^done, .*Release " n " runs? ")
        }
        FILENAME == ARGV[1] {
            if ($0 ~ /^\| ID \|/) {
                delete col; for (i = 2; i < NF; i++) col[t($i)] = i
                ok = ("Req" in col)
                if (!ok) bad("podcast-features.md: a table with an ID header has no Req column")
            } else if ($0 !~ /^\|/) ok = 0
            else if (ok && $0 ~ /^\| F[0-9]+ \|/) { cid[++nc] = t($2); cat[t($2)] = t($(col["Req"])) }
            next
        }
        FILENAME == ARGV[2] {
            if ($0 !~ /^\|/) { intable = 0; next }
            if (!intable) {
                intable = 1; delete col; for (i = 2; i < NF; i++) col[t($i)] = i
                for (k = 1; k <= 3; k++) { c = (k == 1 ? "ID" : (k == 2 ? "State" : "Req")); if (!(c in col)) { bad("features.md: no " c " column"); nocol = 1 } }
                next
            }
            if ($0 ~ /^\| F[0-9]+ \|/ && !nocol) {
                id = t($2); if (!(id in rows)) fid[++nf] = id
                rows[id]++; st[id] = t($(col["State"])); rq[id] = t($(col["Req"]))
            }
            next
        }
        FILENAME == ARGV[3] {
            if ($0 ~ /^## /) {
                sec = ""
                if (match($0, /^## Release [0-9]+:/)) { sec = substr($0, 12, RLENGTH - 12); exists[sec] = 1 }
            }
            if (sec != "" && $0 ~ /^Status: closed( |$)/) closed[sec] = 1
            line = $0
            while (match(line, /F[0-9]+/)) {
                before = (RSTART > 1) ? substr(line, RSTART - 1, 1) : " "
                id = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
                if (before ~ /[A-Za-z0-9]/ || line ~ /^[A-Za-z0-9]/) continue
                if (!(id in named)) rid[++nr] = id
                named[id] = 1
                if (sec != "" && !((sec, id) in names)) { names[sec, id] = 1; sid[sec, ++ns[sec]] = id }
            }
            next
        }
        END {
            if (nocol) exit 1
            if (nf == 0) { bad("features.md has no F row"); exit 1 }
            for (i = 1; i <= nc; i++) if (!(cid[i] in rows)) bad("features.md: no row for " cid[i])
            for (i = 1; i <= nf; i++) {
                id = fid[i]
                if (rows[id] > 1) bad("features.md: " id " has more than one row")
                s = st[id]
                if (s == "") bad("features.md: " id " has no state")
                else if (s !~ done_state && s !~ /^Release [0-9]+( [(].+[)])?$/ && s !~ /^Later( [(].+[)])?$/ && s !~ /^Dropped [(].+[)]$/)
                    bad("features.md: " id " has a bad state: " s)
                if (id in cat) { if (rq[id] != cat[id]) bad("features.md: " id " Req " rq[id] " is not the Req " cat[id] " of podcast-features.md") }
                else if (s !~ /^Dropped/ && rq[id] !~ /^R[0-9]+/) bad("features.md: " id " has no Req")
                if (s ~ /^Release [0-9]+( |$)/) {
                    n = s; sub(/^Release /, "", n); sub(/[^0-9].*/, "", n)
                    if (!(n in exists) || (n in closed) || !((n, id) in names)) bad("features.md: " id " has the state Release " n ", but the open Release " n " section does not name it")
                }
            }
            for (i = 1; i <= nr; i++) if (!(rid[i] in rows)) bad("releases.md names " rid[i] ", which has no features.md row")
            for (n in exists) {
                if (n in closed) continue
                for (j = 1; j <= ns[n]; j++) {
                    id = sid[n, j]; s = st[id]
                    if (!(id in rows)) continue
                    if (s !~ ("^Release " n "( |$)") && !released(s, n)) bad("releases.md: the Release " n " section names " id ", whose state is " s)
                }
            }
            exit failed
        }' "$catalog" "$features" "$([[ -f "$releases" ]] && echo "$releases" || echo /dev/null)" 2>&1)"; then :; else
        [[ -n "$out" ]] || out="the feature check failed"
        while IFS= read -r msg; do err "$msg"; done <<<"$out"
    fi
fi

# Every answered question links to a file that exists. A linked decision record is accepted.
answered="$(awk '/^## Answered questions/{p=1; next} /^## /{p=0} p' "$brief")"
[[ -n "$answered" ]] || err "brief.md: no '## Answered questions' section"
while IFS= read -r line; do
    [[ "$line" == "- "* ]] || continue
    links="$(grep -oE '\]\([^)#]+' <<<"$line" | cut -c3- || true)"
    [[ -n "$links" ]] || { err "brief.md: answered question has no link: ${line:0:60}"; continue; }
    for link in $links; do
        target="$root/docs/requirements/$link"
        if [[ ! -f "$target" ]]; then
            err "brief.md: link to a missing file: $link"
        elif [[ "$link" == *decisions/* ]] && [[ "$(grep -m1 '^- Status:' "$target")" != "- Status: accepted" ]]; then
            err "brief.md: $link is not accepted"
        fi
    done
done <<<"$answered"

# The Commands table of AGENTS.md has one row for each make target, and the Makefile has that target.
if [[ -f "$root/AGENTS.md" ]]; then
    targets="$(grep -oE '^\| `make [a-z-]+' "$root/AGENTS.md" | cut -c9- || true)"
    for t in $(sort <<<"$targets" | uniq -d); do err "AGENTS.md: more than one row for make $t"; done
    for t in $targets; do
        grep -qE "^$t:" "$root/Makefile" 2>/dev/null || err "AGENTS.md: row for make $t, but the Makefile has no $t target"
    done
fi

# The Folders line of the module map names each folder of Sources/<target>/ that holds a Swift file,
# at any depth: as `<folder>/` for DirigibleAudio (the line scopes its bare names), else as
# `<target>/<folder>/`.
map="$root/docs/decisions/0002-module-map.md"
swift_folders=""
[[ ! -d "$root/Sources" ]] || swift_folders="$(cd "$root/Sources" && find . -mindepth 3 -name '*.swift' | awk -F/ '{ print $2 "/" $3 }' | sort -u)"
if [[ -n "$swift_folders" && ! -f "$map" ]]; then
    err "no docs/decisions/0002-module-map.md for the folders of Sources/"
elif [[ -n "$swift_folders" ]]; then
    folders_line="$(grep -m1 '^- \*\*Folders\.\*\*' "$map" || true)"
    while IFS=/ read -r target folder; do
        name="$target/$folder"
        [[ "$target" != DirigibleAudio ]] || name="$folder"
        [[ "$folders_line" == *"\`$name/\`"* ]] || err "docs/decisions/0002-module-map.md: Folders does not name Sources/$target/$folder/"
    done <<<"$swift_folders"
fi

# Every menu name of the app, in English and Spanish, is in bold in the user guide.
guide="$root/docs/guide.md"
if [[ -f "$root/Support/Resources/en.lproj/Localizable.strings" ]]; then
    if [[ ! -f "$guide" ]]; then
        err "docs/guide.md is missing"
    else
        for lang in en es; do
            while IFS= read -r name; do
                grep -qF "**$name**" "$guide" || err "docs/guide.md: no **$name** ($lang menu name)"
            done < <(sed -nE 's/^"menu\.[^"]*" = "(.*)";$/\1/p' "$root/Support/Resources/$lang.lproj/Localizable.strings" | sed 's/\\U2026$//' | sed 's/…$//' | sort -u)
        done
    fi
fi

# Each relative link and image of the README and the guide names a file, with the case of its
# name: the macOS disk ignores case, GitHub does not. A link to a heading of a .md file names a
# heading slug of GitHub in that file: lower case, punctuation other than - and _ removed, spaces to -.
for doc in README.md docs/guide.md; do
    [[ -f "$root/$doc" ]] || continue
    dir="$(dirname "$root/$doc")"
    links="$(grep -oE '\]\([^)[:space:]]+\)|(src|srcset)="[^"[:space:]]+' "$root/$doc" | sed -E 's/^\]\(//; s/\)$//; s/^[a-z]+="//' || true)"
    for link in $links; do
        [[ "$link" =~ ^[a-z]+: ]] && continue
        path="${link%%#*}"
        target="$dir/${path:-$(basename "$doc")}"
        target="${target%/}"
        if ! ls -1A "$(dirname "$target")" 2>/dev/null | grep -xF "$(basename "$target")" >/dev/null; then
            err "$doc: link to a missing file: $path"
        elif [[ "$link" == *#* && "$target" == *.md ]]; then
            name="$(cd "$(dirname "$target")" && pwd -L)/$(basename "$target")"
            name="${name#"$(cd "$root" && pwd -L)"/}"
            sed -nE 's/^#+ +//p' "$target" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 _-]//g; s/ /-/g' \
                | grep -xF "${link#*#}" >/dev/null || err "$doc: no heading for #${link#*#} in $name"
        fi
    done
done

# The app bundle shows the guide as an HTML page. A guide change runs only check-docs, so check-docs
# runs the converter that scripts/bundle.sh runs: it refuses what the page cannot show.
# GUIDE_HTML is a compiled converter: check-docs.test.sh compiles it once for all its cases.
if [[ -f "$root/docs/guide.md" ]]; then
    page="$(mktemp)"
    converter=("${GUIDE_HTML:-swift}")
    [[ -n "${GUIDE_HTML:-}" ]] || converter+=("$(dirname "$0")/guide-html.swift")
    if ! refused="$("${converter[@]}" "$root/docs/guide.md" "$page" 2>&1 >/dev/null)"; then
        err "docs/guide.md: $refused"
    fi
    rm -f "$page"
fi

# Each agentType of the review panel has its agent file, and that file names the agent in its
# frontmatter. The panel calls a lens by this name, so a rename on one side breaks the lens.
panel="$root/.claude/workflows/review-panel.js"
if [[ -f "$panel" ]]; then
    types="$(grep -oE "agentType: ['\"][^'\"]+['\"]" "$panel" | sed -E "s/agentType: ['\"]//; s/['\"]$//" | sort -u || true)"
    [[ -n "$types" ]] || err "review-panel.js: no literal agentType"
    for a in $types; do
        f="$root/.claude/agents/$a.md"
        if [[ ! -f "$f" ]]; then
            err "review-panel.js: agentType $a has no .claude/agents/$a.md"
        elif ! awk 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { exit } f' "$f" | grep -qxF "name: $a"; then
            err "review-panel.js: .claude/agents/$a.md has no 'name: $a' in its frontmatter"
        fi
    done
fi

# The workflow docs: scripts/workflow-words.sh holds the one list of them.
words_sh="$(cd "$(dirname "$0")" && pwd)/workflow-words.sh"
workflow_docs=()
while IFS= read -r f; do workflow_docs+=("$root/$f"); done < <("$words_sh" list --root "$root")

# A start file imports another file with a line that is only @<path>: the always-on count reads
# those lines. Claude Code also imports an @<path> inside a line, outside a code span or a fence,
# which the count would not see.
while IFS= read -r f; do
    [[ -f "$root/$f" ]] || continue
    while IFS= read -r n; do
        err "$f:$n: an inline @ import (put the import on a line of its own, so that the always-on count reads it)"
    done < <(awk '
        /^[ \t]*(```|~~~)/ { fence = !fence; next }
        fence || /^@[^ \t]+[ \t]*$/ { next }
        { line = $0; gsub(/`[^`]*`/, "", line) }
        line ~ /(^|[ \t(])@[A-Za-z0-9_.~\/-]+/ { print FNR }' "$root/$f")
done < <("$words_sh" start-files --root "$root")

# docs/workflow/budgets.tsv holds the header and one TOTAL row with a decision. This check caps no
# words: new-run.sh warns when the docs pass TOTAL x 1.03 (decision 0028, Word budgets).
budgets="$root/docs/workflow/budgets.tsv"
if [[ -f "$budgets" ]]; then
    while IFS= read -r msg; do err "budgets.tsv: $msg"; done < <(awk -F'\t' '
        FNR == 1 { next }
        $1 != "TOTAL" { print "a row other than TOTAL: " $1; next }
        { n++; if ($3 == "") print "the row for TOTAL has no decision" }
        END { if (n == 0) print "no TOTAL row"; else if (n > 1) print "more than one TOTAL row" }' "$budgets")
else
    err "docs/workflow/budgets.tsv is missing"
fi

# A loaded workflow doc holds no date: the story of a rule (the date, the run) stays in
# decisions.tsv, the wiki lessons, and the commit body. A `Source:` line can give its fetch date.
for f in "${workflow_docs[@]}"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r hit; do err "${f#"$root"/}:${hit%%:*}: a date in a loaded doc; put the story in the commit body"; done \
        < <(grep -nE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$f" | grep -vE '^[0-9]+:Source: ' || true)
done

# A SKILL.md names each of its references files by path, so an agent can find it. A references
# file over 100 lines starts with a contents list.
for f in "$root"/.claude/skills/*/references/*.md; do
    [[ -f "$f" ]] || continue
    rel="${f#"$root"/}"
    skill="${rel%%/references/*}/SKILL.md"
    grep -qF "references/$(basename "$f")" "$root/$skill" 2>/dev/null || err "$rel: $skill does not name it by path"
    if [[ "$(wc -l <"$f")" -gt 100 ]] && ! grep -qiE '^(#+ +)?contents' <(head -n 10 "$f"); then
        err "$rel: over 100 lines with no contents list in its first 10 lines"
    fi
done

# The rule register has a stable, unique ID for each rule and a well-formed verdict. It holds no
# rule text (decision 0028). The check is structural: it does not look for the rule in its target.
register="$root/docs/workflow/rules.tsv"
if [[ ! -f "$register" ]]; then
    err "docs/workflow/rules.tsv is missing"
else
    while IFS= read -r msg; do err "rules.tsv: $msg"; done < <(awk -F'\t' '
        NR == 1 { if ($0 != "id\tfile\tverdict\ttarget\treason\tsource\tkey\tsummary") print "the header is not id file verdict target reason source key summary"; next }
        NF != 8 { print $1 " has " NF " fields; each row has 8" }
        { n++; id[n] = $1; verdict[n] = $3; target[n] = $4; reason[n] = $5; source[n] = $6; if (seen[$1]++) print "duplicate id " $1 }
        END {
            for (i = 1; i <= n; i++) {
                v = verdict[i]
                if (v !~ /^(keep|merge|move|enforced|delete|new)$/) print id[i] " has verdict " v "; the verdicts are keep, merge, move, enforced, delete, new"
                if (v == "merge" && !(target[i] in seen)) print id[i] " merges into an unknown id " target[i]
                if (v == "delete" && reason[i] == "") print id[i] " is delete with no reason"
                if (source[i] == "") print id[i] " has no source"
            }
        }' "$register")
    # A keep, move, enforced, or new row names the file that holds the rule now.
    while IFS=$'\t' read -r id verdict target; do
        if [[ -z "$target" ]]; then err "rules.tsv: $id is $verdict with no target"
        elif [[ ! -e "$root/$target" ]]; then err "rules.tsv: $id targets $target, which does not exist"; fi
    done < <(awk -F'\t' 'NR > 1 && $3 ~ /^(keep|move|enforced|new)$/ { print $1 "\t" $3 "\t" $4 }' "$register")
fi

# The deliver Autonomy rules name each friction token of reflect cost.sh in backticks, in any case.
# A row result that starts with no token is not friction for cost.sh. A doc-only edit runs this check.
cost="$root/.claude/skills/reflect/scripts/cost.sh"
deliver="$root/.claude/skills/deliver/SKILL.md"
if [[ -f "$cost" ]]; then
    tokens="$(grep -oE '\(not verified[|][^)]*\)' "$cost" | head -n 1 | tr -d '()' | tr '|' '\n' || true)"
    rules="$(awk '/^## /{ s = $0; next } s == "## Autonomy rules"' "$deliver" 2>/dev/null || true)"
    if [[ -z "$tokens" ]]; then err "${cost#"$root"/}: no token list (not verified|...)"
    elif [[ -z "$rules" ]]; then err "${deliver#"$root"/}: no ## Autonomy rules section"
    else
        while IFS= read -r t; do
            grep -qiF -- "\`$t\`" <<<"$rules" || err "${deliver#"$root"/}: the Autonomy rules have no \`$t\` (a cost.sh friction token)"
        done <<<"$tokens"
    fi
fi

# Each `dirigible <command>` or `swift run dirigible <command>` in AGENTS.md, the README, the
# guide, a skill, or an agent (backticked, or in a fenced block) names a root command of the CLI:
# a type of the subcommands list of Dirigible.swift, by the commandName of its configuration,
# else by its type name in kebab case. An option passes.
cli="$root/Sources/DirigibleCLI"
if [[ ! -f "$cli/Dirigible.swift" ]]; then
    err "Sources/DirigibleCLI/Dirigible.swift is missing; the dirigible command check reads it"
else
    commands=" "
    for t in $(awk '/subcommands: \[/ { p = 1 } p { print } p && /\]/ { exit }' "$cli/Dirigible.swift" | grep -oE '[A-Za-z]+\.self' | sed 's/\.self$//'); do
        name="$(awk -v t="$t" '
            $0 ~ "^struct " t "[:{ ]" { s = 1; next }
            s && /^    static let configuration/ { c = 1 }
            c && !/^    static let configuration/ && !/^        / { exit }
            c && match($0, /commandName: "[^"]+"/) { print substr($0, RSTART + 14, RLENGTH - 15); exit }
        ' "$cli"/*.swift)"
        commands+="${name:-$(sed -E 's/([a-z0-9])([A-Z])/\1-\2/g' <<<"$t" | tr '[:upper:]' '[:lower:]')} "
    done
    while IFS=: read -r f n word; do
        [[ "$word" == -* || "$commands" == *" $word "* ]] || err "${f#"$root"/}:$n: \`dirigible $word\` is not a command of Sources/DirigibleCLI"
    done < <(find "$root/AGENTS.md" "$root/README.md" "$root/docs/guide.md" "$root/.claude/skills" "$root/.claude/agents" \
        -name '*.md' -type f 2>/dev/null | sort | xargs awk '
        FNR == 1 { fence = 0 }
        /^ *```/ { fence = !fence; next }
        {
            line = $0
            re = fence ? "(^|[^A-Za-z0-9_./-])dirigible [^ `]+" : "`(swift run )?dirigible [^ `]+"
            while (match(line, re)) {
                word = substr(line, RSTART, RLENGTH)
                sub(/.*dirigible /, "", word)
                print FILENAME ":" FNR ":" word
                line = substr(line, RSTART + RLENGTH)
            }
        }')
fi

# Each scenario of the ## Scenarios table of the eval set has its own ID: evals-for.sh and the
# grader find a scenario by its ID.
evals="$root/docs/workflow/evals.md"
if [[ ! -f "$evals" ]]; then
    err "docs/workflow/evals.md is missing"
else
    while IFS= read -r id; do err "docs/workflow/evals.md: duplicate scenario id $id"; done < <(awk -F'|' '
        /^## / { inside = ($0 ~ /^## Scenarios[[:space:]]*$/); next }
        inside && /^\|/ { id = $2; gsub(/[[:space:]]/, "", id); if (id ~ /^[EH][0-9]+$/ && seen[id]++ == 1) print id }' "$evals")
    # Each file of Sources/DirigibleMCP that defines a tools array is in the Files cell of the agent
    # eval E38, as a full backticked path, so a tool change runs the eval (evals-for.sh --quoted).
    # The Files cell is the third cell from the end, as in evals-for.sh.
    e38="$(awk '/^## / { inside = ($0 ~ /^## Scenarios[[:space:]]*$/); next }
        inside && /^\| E38 \|/ { k = split($0, cell, "|"); print cell[k - 3]; exit }' "$evals")"
    for f in "$root"/Sources/DirigibleMCP/*.swift; do
        [[ -f "$f" ]] && grep -qE '^ *((public|package|internal|private|fileprivate) )?(static )?let [A-Za-z0-9_]+Tools *[:=]' "$f" || continue
        rel="${f#"$root"/}"
        [[ "$e38" == *"\`$rel\`"* ]] || err "docs/workflow/evals.md: the Files cell of E38 has no \`$rel\` (it defines a tools array)"
    done
fi

# The Act on line of the interrogate ## Output format names the two fields that check-plan.sh
# requires of each Act on item, so a docs-only edit of the format meets the check here.
# check-plan.test.sh builds its fixture from the same line.
interrogate="$root/.claude/skills/interrogate/SKILL.md"
act_on="$(awk '/^## /{ s = $0; next } s == "## Output format" && /^- \*\*Act on:\*\*/' "$interrogate" 2>/dev/null || true)"
plan_fields="$(grep -oE 'field\[[12]\] = "[A-Za-z]+"' "$root/scripts/check-plan.sh" 2>/dev/null | cut -d'"' -f2 || true)"
if [[ -z "$act_on" ]]; then err "${interrogate#"$root"/}: no Act on line in ## Output format"
elif [[ "$(wc -l <<<"$plan_fields" | tr -d ' ')" -ne 2 ]]; then err "scripts/check-plan.sh: no field[1] and field[2] names"
else
    while IFS= read -r f; do
        grep -qw -- "$f" <<<"$act_on" || err "${interrogate#"$root"/}: the Act on line of ## Output format has no $f (a field of scripts/check-plan.sh)"
    done <<<"$plan_fields"
fi

# No text file claims a clean room. find, not git ls-files: the test builds a tree with no index.
while IFS= read -r f; do
    err "${f#./}: names a clean room; docs/provenance.md states how the code was made"
done < <(cd "$root" && find . \( -path ./.git -o -path ./.build -o -path ./build -o -path ./.scratchpads -o -path ./docs/research \) -prune -o \
    -type f ! -path ./scripts/check-docs.sh ! -path ./scripts/check-docs.test.sh \
    -exec grep -I -i -l -E 'clean[ -]room' {} + 2>/dev/null | sort)

# NOTICE names each file in Support/Resources at any depth (not a hidden file or a *.lproj folder) and each
# Sources/C<name> folder that is not own code, as a whole name: x.bin does not match x.bin.old.
own_c_folders=(CMainStack)
named_in_notice() {
    local escaped
    escaped="$(sed 's/[][\.*^$+?(){}|]/\\&/g' <<<"$1")"
    grep -qE "(^|[^A-Za-z0-9._-])${escaped}(\$|[^A-Za-z0-9_.-]|\\.(\$|[^A-Za-z0-9_-]))" "$root/NOTICE" 2>/dev/null
}
while IFS= read -r f; do
    named_in_notice "$(basename "$f")" || err "NOTICE: no line names ${f#"$root"/}"
done < <(find "$root/Support/Resources" -name '*.lproj' -prune -o -type f ! -name '.*' -print 2>/dev/null | sort)
while IFS= read -r d; do
    name="$(basename "$d")"
    [[ " ${own_c_folders[*]} " == *" $name "* ]] && continue
    named_in_notice "Sources/$name" || err "NOTICE: no line names Sources/$name"
done < <(find "$root/Sources" -mindepth 1 -maxdepth 1 -type d -name 'C*' 2>/dev/null | sort)

grep -qF '](docs/provenance.md)' "$root/README.md" 2>/dev/null || err "README.md: no link to docs/provenance.md"
[[ -f "$root/docs/provenance.md" ]] || err "docs/provenance.md: file is missing"

exit "$fail"
