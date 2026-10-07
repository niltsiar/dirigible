#!/bin/bash
# Check the argument parsing of ax.swift, and the choice of the element to press in a tree from a
# dump file (press --tree). It reads no live tree: each case ends before the Accessibility check.
# Run by `make test-hooks`.
set -uo pipefail
ax="$(cd "$(dirname "$0")" && pwd -P)/ax.swift"
failures=0

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# expect_usage <case> <args...>: exit 2 and the usage text on stderr.
expect_usage() {
    local name="$1"
    shift
    local err
    err="$(swift "$ax" "$@" 2>&1 >/dev/null)"
    local code=$?
    [[ $code -eq 2 ]] || fail "$name: exit $code, not 2"
    [[ "$err" == *"usage: ax.swift"* ]] || fail "$name: no usage text: $err"
}

expect_usage "no command"
expect_usage "unknown command" walk
expect_usage "dump with a word" dump deep
expect_usage "find with no text" find
expect_usage "press with two titles" press a b
expect_usage "press with --tree and no file" press a --tree
expect_usage "press with --role and no role" press a --role
expect_usage "step with no action" step AXSplitter
expect_usage "step with an unknown action" step AXSplitter wiggle

# An empty DIRIGIBLE_BUNDLE_ID is a usage error, before the Accessibility check (exit 3).
err="$(DIRIGIBLE_BUNDLE_ID= swift "$ax" dump 2>&1 >/dev/null)"
code=$?
[[ $code -eq 2 && "$err" == *"DIRIGIBLE_BUNDLE_ID"* ]] || fail "empty bundle ID: exit $code: $err"

# press: a title that matches two elements is refused, and a path selects one element. The Apple
# menu is out of the search unless the path starts with it. A press of the first match pressed
# Apple > Recent Items > Clear Menu and cleared the Recent Items list of the Mac (run
# 2026-09-30-start-window, Phase 7). A path with an empty title is refused, because a separator has
# an empty title. The fixture has the lines of a real dump: an AXMenu has no title, and a separator
# is an AXMenuItem with "Title=". The item File > File has the title of its menu.
tree="$(mktemp -d)"
trap 'rm -rf "$tree"' EXIT
cat >"$tree/dump.txt" <<'DUMP'
Role=AXApplication RoleDescription=application Title=Dirigible
 Role=AXWindow RoleDescription=standard window Title=Welcome to Dirigible
  Role=AXButton RoleDescription=button Title=Clear Menu Help=Removes the rows
 Role=AXMenuBar RoleDescription=menu bar
  Role=AXMenuBarItem RoleDescription=menu bar item Title=Apple MenuItemCmdModifiers=0
   Role=AXMenu RoleDescription=menu
    Role=AXMenuItem RoleDescription=menu item Title=About This Mac MenuItemCmdModifiers=0
    Role=AXMenuItem RoleDescription=menu item Title= MenuItemCmdModifiers=0
    Role=AXMenuItem RoleDescription=menu item Title=Recent Items MenuItemCmdModifiers=0
     Role=AXMenu RoleDescription=menu
      Role=AXMenuItem RoleDescription=menu item Title=Applications MenuItemCmdModifiers=0
      Role=AXMenuItem RoleDescription=menu item Title= MenuItemCmdModifiers=0
      Role=AXMenuItem RoleDescription=menu item Title=Clear Menu MenuItemCmdModifiers=0
  Role=AXMenuBarItem RoleDescription=menu bar item Title=File MenuItemCmdModifiers=0
   Role=AXMenu RoleDescription=menu
    Role=AXMenuItem RoleDescription=menu item Title=New Session… MenuItemCmdChar="N" MenuItemCmdModifiers=0
    Role=AXMenuItem RoleDescription=menu item Title=Open Recent MenuItemCmdModifiers=8
     Role=AXMenu RoleDescription=menu
      Role=AXMenuItem RoleDescription=menu item Title=Pilot Episode MenuItemCmdModifiers=8
      Role=AXMenuItem RoleDescription=menu item Title= MenuItemCmdModifiers=0
      Role=AXMenuItem RoleDescription=menu item Title=Clear Menu MenuItemCmdModifiers=8
    Role=AXMenuItem RoleDescription=menu item Title=File MenuItemCmdModifiers=0
    Role=AXMenuItem RoleDescription=menu item Title= MenuItemCmdModifiers=0
    Role=AXMenuItem RoleDescription=menu item Title=Close MenuItemCmdChar="W" MenuItemCmdModifiers=0 Enabled=0
DUMP

# expect_press <case> <path> <exit> <stdout> [<text that stderr must have>...]. With ROLE set,
# the press has --role "$ROLE".
expect_press() {
    local name="$1" path="$2" want_code="$3" want_out="$4"
    shift 4
    local out err extra=()
    [[ -n "${ROLE:-}" ]] && extra=(--role "$ROLE")
    out="$(swift "$ax" press "$path" --tree "$tree/dump.txt" ${extra[@]+"${extra[@]}"} 2>"$tree/err")"
    local code=$?
    err="$(cat "$tree/err")"
    [[ $code -eq $want_code ]] || fail "$name: exit $code, not $want_code: $err"
    [[ "$out" == "$want_out" ]] || fail "$name: stdout: $out"
    local text
    for text in "$@"; do [[ "$err" == *"$text"* ]] || fail "$name: no \"$text\" on stderr: $err"; done
    [[ "$err" != *"Apple > Recent Items"* || "$path" == Apple* ]] || fail "$name: the Apple menu was searched: $err"
}

expect_press "an ambiguous title" "Clear Menu" 4 "" "2 elements match" \
    "Dirigible > Welcome to Dirigible > Clear Menu" "Dirigible > File > Open Recent > Clear Menu"
expect_press "a menu path" "File > Open Recent > Clear Menu" 0 "match: Dirigible > File > Open Recent > Clear Menu"
expect_press "a path in the Apple menu with no Apple" "Recent Items > Clear Menu" 1 "" "No element matches"
expect_press "a path from the Apple menu" "Apple > Recent Items > Clear Menu" 0 \
    "match: Dirigible > Apple > Recent Items > Clear Menu"
expect_press "an item with the title of its menu" "File > File" 0 "match: Dirigible > File > File"
# A menu has the title of its menu bar item, and in English the Record menu has a Record item. A
# role keeps only the matches with that role, so the title of a menu opens the menu.
expect_press "a menu title" "File" 4 "" "2 elements match" "Dirigible > File > File"
ROLE=AXMenuBarItem expect_press "a menu title with the menu bar item role" "File" 0 "match: Dirigible > File"
ROLE=AXMenuBarItem expect_press "a role that no match has" "Close" 1 "" "No element matches"
# A dump line ends in Enabled=: the title stops at the next key.
expect_press "an item with an Enabled field" "File > Close" 0 "match: Dirigible > File > Close"
expect_press "an empty title at the end" "File > " 2 "" "has an empty title"
expect_press "an empty title in the middle" "File >  > Close" 2 "" "has an empty title"

[[ $failures -eq 0 ]] && echo "ax tests: all passed" || { echo "ax tests: $failures failed"; exit 1; }
