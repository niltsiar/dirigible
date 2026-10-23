#!/bin/bash
# Print each line of a lesson page (wiki/lessons) or an item page (wiki/items) of the wiki that
# holds a cause key, with its page and line number: a key that is already queued as an item is a
# second occurrence too. The front matter of a page is skipped. The wiki is the one of
# scripts/wiki.py, the same from each worktree. With no wiki, the script exits 1 and wiki.py names
# the path, `scripts/wiki.py init`, and DIRIGIBLE_WIKI. A match is a candidate only: the
# synthesizer decides if it is a second occurrence (reflect skill). A key is <prefix>-<nnn>/<class>
# (a rules.tsv ID) or NEW-<prefix>-<slug>/<class>, and the class is on the `Failure classes:` line
# of references/synthesizer.md. Exit 0 with a match or none; exit 2 for a bad key.
set -euo pipefail

key="${1-}"
usage='usage: seen.sh <ID>/<class>   (ID: <PREFIX>-<nnn> or NEW-<PREFIX>-<lowercase-slug>)'
[[ "$key" =~ ^([A-Z]+-[0-9]{3}|NEW-[A-Z]+-[a-z0-9]+(-[a-z0-9]+)*)/([a-z]+)$ ]] || { echo "bad key '$key'; $usage" >&2; exit 2; }
class="${BASH_REMATCH[3]}"

list="$(dirname "$0")/../references/synthesizer.md"
classes="$(grep '^Failure classes:' "$list" | grep -o '`[a-z]*`' | tr -d '`' || true)"
[[ -n "$classes" ]] || { echo "no Failure classes line in $list" >&2; exit 2; }
grep -qx "$class" <<< "$classes" || { echo "class '$class' is not one of: $(echo $classes)" >&2; exit 2; }

wiki_tool="$(cd "$(dirname "$0")/../../../.." && pwd)/scripts/wiki.py"
"$wiki_tool" count next > /dev/null
cd "$("$wiki_tool" path)/wiki"
pages=()
while IFS= read -r page; do pages+=("$page"); done < <(for d in lessons items; do find "$d" -name '*.md' ! -name index.md | LC_ALL=C sort; done)
[[ ${#pages[@]} -gt 0 ]] || exit 0
# The awk step drops the front matter (the first two --- lines). -w: the key matches only as a
# whole key, so DLV-016/hook does not match XDLV-016/hook.
awk 'FNR == 1 { fences = 0 } fences < 2 { if ($0 == "---") fences++; next } { print FILENAME ":" FNR ":" $0 }' "${pages[@]}" |
  grep -wF -- "$key" || [[ $? -eq 1 ]]
