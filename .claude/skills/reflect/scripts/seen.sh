#!/bin/bash
# Print each line of .scratchpads/learnings.md and .scratchpads/backlog.md that holds a cause key,
# with its file and line number: a key that is already queued in the backlog is a second occurrence
# too. The files are those of the main checkout, also in a worktree. A match is a candidate only: the synthesizer decides
# if it is a second occurrence (reflect skill). A key is <prefix>-<nnn>/<class> (a rules.tsv ID) or
# NEW-<prefix>-<slug>/<class>, and the class is on the `Failure classes:` line of
# references/synthesizer.md. Exit 0 with a match or none; exit 2 for a bad key.
set -euo pipefail

key="${1-}"
usage='usage: seen.sh <ID>/<class>   (ID: <PREFIX>-<nnn> or NEW-<PREFIX>-<lowercase-slug>)'
[[ "$key" =~ ^([A-Z]+-[0-9]{3}|NEW-[A-Z]+-[a-z0-9]+(-[a-z0-9]+)*)/([a-z]+)$ ]] || { echo "bad key '$key'; $usage" >&2; exit 2; }
class="${BASH_REMATCH[3]}"

list="$(dirname "$0")/../references/synthesizer.md"
classes="$(grep '^Failure classes:' "$list" | grep -o '`[a-z]*`' | tr -d '`' || true)"
[[ -n "$classes" ]] || { echo "no Failure classes line in $list" >&2; exit 2; }
grep -qx "$class" <<< "$classes" || { echo "class '$class' is not one of: $(echo $classes)" >&2; exit 2; }

cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.scratchpads"
files=()
for f in learnings.md backlog.md; do [[ -f "$f" ]] && files+=("$f"); done
[[ ${#files[@]} -gt 0 ]] || exit 0
# -w: the key matches only as a whole key, so DLV-016/hook does not match XDLV-016/hook.
grep -HnwF -- "$key" "${files[@]}" || [[ $? -eq 1 ]]
