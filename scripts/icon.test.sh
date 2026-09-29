#!/bin/bash
# Check that icon.sh compiles the icon, and that a failed compile fails and leaves no stale
# catalog. Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
failures=0
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# No .icon and a stale catalog: actool exits 0 and writes nothing, so only the guard can refuse.
mkdir -p "$tmp/bad/scripts" "$tmp/bad/build/icon"
cp "$here/icon.sh" "$tmp/bad/scripts/"
echo stale > "$tmp/bad/build/icon/Assets.car"
output="$("$tmp/bad/scripts/icon.sh" 2>&1)" && fail "no .icon: exit 0"
grep -qF "icon.sh: actool did not compile $tmp/bad/Support/AppIcon.icon" <<<"$output" \
    || fail "no .icon: no guard message in: $output"
[[ -e "$tmp/bad/build/icon/Assets.car" ]] && fail "no .icon: the stale Assets.car stays"

# Five groups: actool writes both files, prints an error, and exits 1 (probe-warn of the
# app-icon run). Only the exit check can refuse this input.
mkdir -p "$tmp/five/scripts" "$tmp/five/Support"
cp "$here/icon.sh" "$tmp/five/scripts/"
cp -R "$here/../Support/AppIcon.icon" "$tmp/five/Support/"
json="$tmp/five/Support/AppIcon.icon/icon.json"
group="$(plutil -extract groups.0 json -o - "$json")"
plutil -insert groups -json "$group" -append "$json"
plutil -insert groups -json "$group" -append "$json"
output="$("$tmp/five/scripts/icon.sh" 2>&1)" && fail "five groups: exit 0"
grep -qF "Too many visible groups" <<<"$output" || fail "five groups: no actool error in: $output"
[[ -e "$tmp/five/build/icon" ]] && fail "five groups: build/icon exists"

# The real .icon gives both files.
mkdir -p "$tmp/good/scripts" "$tmp/good/Support"
cp "$here/icon.sh" "$tmp/good/scripts/"
cp -R "$here/../Support/AppIcon.icon" "$tmp/good/Support/"
output="$("$tmp/good/scripts/icon.sh" 2>&1)" || fail "real .icon: nonzero exit: $output"
[[ -f "$tmp/good/build/icon/Assets.car" && -f "$tmp/good/build/icon/AppIcon.icns" ]] \
    || fail "real .icon: Assets.car or AppIcon.icns is missing"

[[ $failures -eq 0 ]] && echo "icon tests: all passed"
exit $((failures > 0))
