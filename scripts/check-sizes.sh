#!/bin/bash
# Check that no Swift file under Sources/ or Tests/ has more than 400 lines, unless
# scripts/check-sizes.allow names it with a reason. An allow line is <path><TAB><reason>, and a
# line that starts with # is a comment. An entry with no reason, for a file of 400 lines or
# fewer, or for a missing file also fails, so the list stays true.
# Usage: scripts/check-sizes.sh [root]. `make check` runs it.
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
limit=400
allow="$root/scripts/check-sizes.allow"
problems=""
entries=""

if [[ -f "$allow" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    file="${line%%$'\t'*}"
    reason=""
    [[ "$line" == *$'\t'* ]] && reason="${line#*$'\t'}"
    entries+="$file"$'\n'
    if [[ -z "${reason//[[:space:]]/}" ]]; then
      problems+="$file: an allow entry with no reason"$'\n'
    elif [[ ! -f "$root/$file" ]]; then
      problems+="$file: an allow entry for a missing file"$'\n'
    elif (($(wc -l <"$root/$file") <= limit)); then
      problems+="$file: an allow entry for a file of $limit lines or fewer"$'\n'
    fi
  done <"$allow"
fi

while IFS= read -r file; do
  count=$(($(wc -l <"$root/$file")))
  ((count > limit)) || continue
  grep -qxF "$file" <<<"$entries" || problems+="$file: $count lines, over $limit with no allow entry"$'\n'
done < <(cd "$root" && find Sources Tests -name '*.swift' -type f 2>/dev/null | sort)

problems="$(sed '/^$/d' <<<"$problems")"
[[ -z "$problems" ]] || { sed 's/^/check-sizes: /' <<<"$problems" >&2; exit 1; }
