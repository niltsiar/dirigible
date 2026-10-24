#!/bin/bash
# Check that check-waits.sh passes a tree with no raw `.wait(timeout:` in Tests/, and fails each
# tree with a raw wait and no allow entry, or with an allow entry that is not true. Run by
# `make test-hooks`.
set -uo pipefail
check="$(cd "$(dirname "$0")" && pwd)/check-waits.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A new tree in $tmp with Tests/B, Sources/A, and an empty allow file.
tree() {
  rm -rf "$tmp"/* && mkdir -p "$tmp/Sources/A" "$tmp/Tests/B" "$tmp/scripts" && : > "$tmp/scripts/check-waits.allow"
}
raw() { echo '        _ = hold.wait(timeout: .now() + 30)' > "$tmp/$1"; }
allow() { printf '%b' "$1" > "$tmp/scripts/check-waits.allow"; }

# expect pass <name>, or expect fail <name> <message>. A failure counts only with its message.
expect() {
  local want="$1" name="$2" message="${3:-}" got output
  output="$("$check" "$tmp" 2>&1 >/dev/null)" && got=pass || got=fail
  if [[ "$got" == fail && "$want" == fail ]] && ! grep -qF "check-waits: $message" <<<"$output"; then
    got="fail without '$message'"
  fi
  [[ "$got" == "$want" ]] || { echo "FAIL: expected $want, got $got: $name"; failures=$((failures + 1)); }
}

tree; echo 'let gate = Gate(limit: .seconds(5))' > "$tmp/Tests/B/b.swift"; expect pass 'a test with no raw wait'
tree; raw Tests/B/b.swift; expect fail 'a raw wait with no allow entry' 'Tests/B/b.swift:1: a raw .wait(timeout:'
tree; raw Sources/A/a.swift; expect pass 'a raw wait outside Tests/'
tree; raw Tests/B/b.txt; expect pass 'a file that is not Swift'
tree; raw Tests/B/b.swift; allow '# a comment\nTests/B/b.swift\tthe wait of the test\n'
expect pass 'a raw wait with an allow entry and a reason'
tree; raw Tests/B/b.swift; allow 'Tests/B/b.swift\t \n'
expect fail 'an allow entry with no reason' 'Tests/B/b.swift: an allow entry with no reason'
tree; raw Tests/B/b.swift; allow 'Tests/B/b.swift\n'
expect fail 'an allow entry with no tab' 'Tests/B/b.swift: an allow entry with no reason'
tree; echo 'let x = 1' > "$tmp/Tests/B/b.swift"; allow 'Tests/B/b.swift\tthe wait of the test\n'
expect fail 'an allow entry for a file with no raw wait' 'Tests/B/b.swift: an allow entry for a file with no raw wait'
tree; allow 'Tests/B/gone.swift\tthe wait of the test\n'
expect fail 'an allow entry for a missing file' 'Tests/B/gone.swift: an allow entry for a file with no raw wait'

quarantine() { printf '    withKnownIssue(%s, isIntermittent: true) {\n' "$1" > "$tmp/$2"; }
tree; quarantine '"quarantine: the stop misses"' Tests/B/b.swift
expect fail 'a quarantine marker with no FLAKE word' 'Tests/B/b.swift:1: a "quarantine: marker with no FLAKE word'
tree; quarantine '"quarantine: the stop misses, see backlog FLAKE LINE 40"' Tests/B/b.swift
expect pass 'a quarantine marker with a FLAKE word'
tree; quarantine '"quarantine: the stop misses"' Sources/A/a.swift; expect pass 'a quarantine marker outside Tests/'
tree; quarantine '"quarantine: the stop misses"' Tests/B/b.txt; expect pass 'a quarantine marker in a file that is not Swift'
tree; quarantine '"quarantine: the stop misses, FLAKEY"' Tests/B/b.swift
expect fail 'a word that only starts with FLAKE' 'Tests/B/b.swift:1: a "quarantine: marker with no FLAKE word'
tree; quarantine 'flake' Tests/B/b.swift
expect fail 'isIntermittent with no quarantine marker' 'Tests/B/b.swift: an isIntermittent: true with no "quarantine: marker that has a FLAKE word'
tree; quarantine 'flake' Tests/B/b.swift; echo '    "quarantine: the stop misses, see backlog FLAKE LINE 40"' >> "$tmp/Tests/B/b.swift"
expect pass 'isIntermittent with a quarantine marker on another line'
tree; quarantine 'flake' Sources/A/a.swift; expect pass 'isIntermittent outside Tests/'

[[ $failures -eq 0 ]] && echo "check-waits tests: all passed"
exit $((failures > 0))
