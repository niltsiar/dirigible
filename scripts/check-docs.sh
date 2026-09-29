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
# name: the macOS disk ignores case, GitHub does not. A link to a heading of the guide names a
# heading slug of GitHub: lower case, punctuation other than - and _ removed, spaces to -.
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
        elif [[ "$link" == *#* && "$target" == "$guide" ]]; then
            sed -nE 's/^#+ +//p' "$guide" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 _-]//g; s/ /-/g' \
                | grep -xF "${link#*#}" >/dev/null || err "$doc: no heading for #${link#*#} in docs/guide.md"
        fi
    done
done

exit "$fail"
