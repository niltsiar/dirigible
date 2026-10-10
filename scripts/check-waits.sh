#!/bin/bash
# Check that no Swift file under Tests/ calls `.wait(timeout:` (a raw DispatchSemaphore or
# DispatchGroup wait), unless scripts/check-waits.allow names the file with a reason. A hold of
# product work goes through `Gate` (Tests/DirigibleAudioTests/Support.swift): `Gate(limit:)` has no
# default, so the compiler names each limit, and a raw wait has a wall limit that expires when a
# loaded test runs slow. An allow line is <path><TAB><reason>, and a line that starts with # is a
# comment. An entry with no reason, or for a file with no raw wait, also fails, so the list stays
# true. The match is one line: a call split over two lines passes.
# Usage: scripts/check-waits.sh [root]. `make check-slow-gates` runs it.
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
allow="$root/scripts/check-waits.allow"
problems=""
entries=""
hits="$(cd "$root" && { grep -rnF --include='*.swift' '.wait(timeout:' Tests 2>/dev/null || true; } | sort)"

if [[ -f "$allow" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    file="${line%%$'\t'*}"
    reason=""
    [[ "$line" == *$'\t'* ]] && reason="${line#*$'\t'}"
    entries+="$file"$'\n'
    if [[ -z "${reason//[[:space:]]/}" ]]; then
      problems+="$file: an allow entry with no reason"$'\n'
    elif ! grep -q "^$file:" <<<"$hits"; then
      problems+="$file: an allow entry for a file with no raw wait"$'\n'
    fi
  done <"$allow"
fi

while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  file="${hit%%:*}"
  grep -qxF "$file" <<<"$entries" || problems+="${hit%%:*}:$(cut -d: -f2 <<<"$hit"): a raw .wait(timeout: with no allow entry; hold product work with Gate"$'\n'
done <<<"$hits"

problems="$(sed '/^$/d' <<<"$problems")"
[[ -z "$problems" ]] || { sed 's/^/check-waits: /' <<<"$problems" >&2; exit 1; }
