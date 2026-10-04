#!/bin/bash
# Check that check-sizes.sh passes a tree with no Swift file over 400 lines, and fails each tree
# with a file over the limit and no allow entry, or with an allow entry that is not true. Run by
# `make check-sizes`.
set -uo pipefail
check="$(cd "$(dirname "$0")" && pwd)/check-sizes.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A new tree in $tmp with Sources/A, Tests/B, and an empty allow file.
tree() {
  rm -rf "$tmp"/* && mkdir -p "$tmp/Sources/A" "$tmp/Tests/B" "$tmp/scripts" && : > "$tmp/scripts/check-sizes.allow"
}
# lines <count> <path>: a Swift file of <count> lines.
lines() { for ((i = 0; i < $1; i++)); do echo "// $i"; done > "$tmp/$2"; }

# expect pass <name>, or expect fail <name> <message>. A failure counts only with its message.
expect() {
  local want="$1" name="$2" message="${3:-}" got output
  output="$("$check" "$tmp" 2>&1 >/dev/null)" && got=pass || got=fail
  if [[ "$got" == fail && "$want" == fail ]] && ! grep -qF "check-sizes: $message" <<<"$output"; then
    got="fail without '$message'"
  fi
  [[ "$got" == "$want" ]] || { echo "FAIL: expected $want, got $got: $name"; failures=$((failures + 1)); }
}

tree; lines 400 Sources/A/a.swift; expect pass 'a file of 400 lines'
tree; lines 401 Sources/A/a.swift; expect fail 'a file of 401 lines' 'Sources/A/a.swift: 401 lines'
tree; lines 401 Tests/B/b.swift; expect fail 'a test file of 401 lines' 'Tests/B/b.swift: 401 lines'
tree; lines 401 Sources/A/a.txt; expect pass 'a file that is not Swift'
tree; lines 401 Sources/A/a.swift; printf '# a comment\nSources/A/a.swift\treal-time code\n' > "$tmp/scripts/check-sizes.allow"
expect pass 'a file of 401 lines with an allow entry and a reason'
tree; lines 401 Sources/A/a.swift; printf 'Sources/A/a.swift\t \n' > "$tmp/scripts/check-sizes.allow"
expect fail 'an allow entry with no reason' 'Sources/A/a.swift: an allow entry with no reason'
tree; lines 401 Sources/A/a.swift; printf 'Sources/A/a.swift\n' > "$tmp/scripts/check-sizes.allow"
expect fail 'an allow entry with no tab' 'Sources/A/a.swift: an allow entry with no reason'
tree; lines 400 Sources/A/a.swift; printf 'Sources/A/a.swift\tsplit later\n' > "$tmp/scripts/check-sizes.allow"
expect fail 'an allow entry for a file of 400 lines' 'Sources/A/a.swift: an allow entry for a file of 400 lines or fewer'
tree; printf 'Sources/A/gone.swift\tsplit later\n' > "$tmp/scripts/check-sizes.allow"
expect fail 'an allow entry for a missing file' 'Sources/A/gone.swift: an allow entry for a missing file'

[[ $failures -eq 0 ]] && echo "check-sizes tests: all passed"
exit $((failures > 0))
