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

exit "$fail"
