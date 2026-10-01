#!/bin/bash
# Check the structure of the docs that plans and reviews depend on.
# Usage: scripts/check-docs.sh [repo root]. `make check` runs it.
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

# Every menu name of the app, in English and Spanish, is in bold in the user guide.
guide="$root/docs/guide.md"
if [[ -f "$root/Support/Resources/en.lproj/Localizable.strings" ]]; then
    if [[ ! -f "$guide" ]]; then
        err "docs/guide.md is missing"
    else
        for lang in en es; do
            while IFS= read -r name; do
                grep -qF "**$name**" "$guide" || err "docs/guide.md: no **$name** ($lang menu name)"
            done < <(sed -nE 's/^"menu\.[^"]*" = "(.*)";$/\1/p' "$root/Support/Resources/$lang.lproj/Localizable.strings" | sed 's/…$//' | sort -u)
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

# Each workflow doc stays within its row of docs/workflow/budgets.tsv (path, words, decision), in
# words of `wc -w`. A row that ends in / limits the sum of the budgeted files of that folder, and
# the TOTAL row limits the sum of all of them. Each row names the reason of its value (decision 0028).
budgets="$root/docs/workflow/budgets.tsv"
[[ -f "$budgets" ]] || { err "docs/workflow/budgets.tsv is missing"; budgets=/dev/null; }
counts=""
for f in "$root"/AGENTS.md "$root"/.claude/skills/*/*.md "$root"/.claude/skills/*/references/*.md "$root"/.claude/agents/*.md; do
    [[ -f "$f" ]] || continue
    counts+="${f#"$root"/}	$(wc -w <"$f" | tr -d ' ')"$'\n'
done
while IFS= read -r msg; do err "budgets.tsv: $msg"; done < <(printf '%s' "$counts" | awk -F'\t' '
    FILENAME == "-" { words[$1] = $2; sum += $2; next }
    FNR == 1 { next }
    { row[$1] = $2; if ($3 == "") print "the row for " $1 " has no decision" }
    END {
        for (f in words) {
            if (!(f in row)) print "no row for " f
            else if (words[f] > row[f] + 0) print f " is over its row: " words[f] " > " row[f]
        }
        for (p in row) {
            if (p == "TOTAL") continue
            if (p !~ /\/$/) { if (!(p in words)) print "row for a missing file: " p; continue }
            total = 0; seen = 0
            for (f in words) if (index(f, p) == 1) { total += words[f]; seen = 1 }
            if (!seen) print "row for a missing file: " p
            else if (total > row[p] + 0) print p " is over its total row: " total " > " row[p]
        }
        if (!("TOTAL" in row)) print "no TOTAL row"
        else if (sum > row["TOTAL"] + 0) print "the budgeted files are over the TOTAL row: " sum " > " row["TOTAL"]
    }' - "$budgets")

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

exit "$fail"
