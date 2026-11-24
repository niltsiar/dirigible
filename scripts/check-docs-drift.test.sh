#!/bin/bash
# Check that check-docs-drift.py passes a good docs tree and fails each broken one: for each rule
# (menus, menutables, decstatus, releases, deccites, private), one bad input with its message and
# the near-good inputs that must pass. Run by `make test-hooks`.
set -uo pipefail
check="$(cd "$(dirname "$0")" && pwd)/check-docs-drift.py"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ell=$'\xe2\x80\xa6'
# check-changed.test.sh needs a bundle path that no hook test names: build the table name from parts.
table="Localizable"'.strings'

# A good tree: a menu File with one item that has a key, a menu View, a menu Edit with a submenu
# choice, a non-menu string "New Session", a guide with its menu tables and one prose line of paths,
# a closed Release 7 and an open Release 8 whose features are done or open, one accepted record, one
# proposed record that names the open feature F04, and a docs map with the gap sentence.
good() {
  rm -rf "${tmp:?}"/* "$tmp"/.claude
  mkdir -p "$tmp/Support/Resources/en.lproj" "$tmp/Support/Resources/es.lproj" "$tmp/Sources/DirigibleApp" \
    "$tmp/docs/decisions" "$tmp/docs/requirements" "$tmp/docs/workflow"
  printf '%s\n' '"menu.file" = "File";' '"menu.file.importSession" = "Import Session\U2026";' '"menu.view" = "View";' \
    '"menu.view.showTracks" = "Show Tracks";' '"menu.edit" = "Edit";' '"menu.edit.drag.mode" = "Drag Mode";' \
    '"menu.edit.drag.mode.shuffle" = "Shuffle";' '"start.newSession" = "New Session";' \
    > "$tmp/Support/Resources/en.lproj/$table"
  printf '%s\n' '"menu.file" = "Archivo";' '"menu.file.importSession" = "Importar sesi\U00F3n\U2026";' '"menu.view" = "Ver";' \
    '"menu.view.showTracks" = "Mostrar pistas";' '"menu.edit" = "Edici\U00F3n";' '"menu.edit.drag.mode" = "Modo de arrastre";' \
    '"menu.edit.drag.mode.shuffle" = "Mezclar";' '"start.newSession" = "Nueva sesi\U00F3n";' \
    > "$tmp/Support/Resources/es.lproj/$table"
  printf '%s\n' 'Button("x").keyboardShortcut("i", modifiers: [.command, .shift])' \
    'Button("y").keyboardShortcut("t", modifiers: [.command, .option])' > "$tmp/Sources/DirigibleApp/Menus.swift"
  printf '%s\n' '# Guide' '' 'Use **File > Import Session...** (Shift-Command-I) or **View > Show Tracks**.' \
    'Allow it in **System Settings > Privacy & Security > Microphone**.' '' '## Menu commands and keys' '' '### File' '' \
    '| Item | Key |' '|---|---|' '| **Import Session** | Shift-Command-I |' '' '### View' '' '| Item | Key |' '|---|---|' \
    '| **Show Tracks** | Option-Command-T |' '' '### Edit' '' '| Item | Key |' '|---|---|' '| **Drag Mode** | None |' '' \
    '## Next' '' 'End.' > "$tmp/docs/guide.md"
  printf '# Readme\n\nSee the guide.\n' > "$tmp/README.md"
  printf '# Releases\n\n## Release 7: a\n\nStatus: closed\n\n1. **x (F01).**\n\n## Release 8: b\n\n1. **y (F02, F03).**\n' \
    > "$tmp/docs/requirements/releases.md"
  printf '%s\n' '# Features' '' '| ID | Feature | From | State | Req |' '|---|---|---|---|---|' \
    '| F01 | One | user | done, Release 7 run 1 | R1 |' '| F02 | Two | user | done, Release 8 run 1 | R1 |' \
    '| F03 | Three | user | Release 8 | R1 |' '| F04 | Four | user | Later | R1 |' > "$tmp/docs/requirements/features.md"
  printf '# 0002. X\n\n- Status: accepted\n\n## Context\n\nx\n' > "$tmp/docs/decisions/0002-x.md"
  printf '# 0003. Y\n\nFeature F04.\n\n- Status: proposed\n\n## Context\n\nSee 0002.\n' > "$tmp/docs/decisions/0003-y.md"
  printf '# 0005. Z\n\n- Status: accepted\n' > "$tmp/docs/decisions/0005-z.md"
  printf '%s\n' '# Docs' '' '| Number | Title | Status |' '|---|---|---|' '| [0002](decisions/0002-x.md) | X | accepted |' \
    '| [0003](decisions/0003-y.md) | Y | proposed |' '' 'The numbers 0004 are not used.' > "$tmp/docs/README.md"
  printf 'id\tfile\tverdict\ttarget\treason\tsource\tkey\tsummary\n' > "$tmp/docs/workflow/rules.tsv"
  printf '# Agents\n\nSee item 0001 and `0001`.\n' > "$tmp/AGENTS.md"
}

# ok <name>: the tree passes. bad <name> <message>: it fails with exit 1 and a line `check-docs: ...<message>`.
ok() {
  local out
  out="$(python3 -I "$check" "$tmp" 2>&1)" || { echo "FAIL: expected pass, got [$out]: $1"; failures=$((failures + 1)); return; }
  [[ -z "$out" ]] || { echo "FAIL: a pass printed [$out]: $1"; failures=$((failures + 1)); }
}
bad() {
  local out rc
  out="$(python3 -I "$check" "$tmp" 2>&1 >/dev/null)" && rc=0 || rc=$?
  [[ $rc -eq 1 ]] || { echo "FAIL: expected exit 1, got $rc: $1"; failures=$((failures + 1)); return; }
  grep -E "^check-docs: .*$2" <<<"$out" > /dev/null || { echo "FAIL: no line with '$2' in [$out]: $1"; failures=$((failures + 1)); }
}
# guide <text>: add a line to the prose of the guide, after its first line.
guide() { printf '%s\n' "$1" >> "$tmp/docs/guide.md"; }

good; ok 'good tree'
rm -rf "${tmp:?}"/*; printf '# Readme\n' > "$tmp/README.md"; ok 'a tree with none of the input files'

# menus
good; guide '**File > Import Teleport**'; bad 'a path with no menu string' 'path \*\*File > Import Teleport\*\*: no menu string "Import Teleport"'
good; guide '**File > Import Session**'; bad 'a path whose menu string ends in an ellipsis' 'no menu string "Import Session" \(the menu string ends in an ellipsis\)'
good; guide '**File > New Session**'; bad 'a path part that only a non-menu string has' 'no menu string "New Session"'
good; guide '**View > Show Tracks** (Option-Command-Q)'; bad 'a key that no shortcut has' 'menu key Option-Command-Q'
good; guide '**System Settings > Privacy & Security > Microphones**'; bad 'a System Settings path with a wrong pane' 'no UI string "Microphones"'
good; guide "**File > Import Session$ell**"; ok 'a path with the ellipsis character'
good; guide '**View > Show Tracks** (Option-Command-T), **Archivo > Importar sesión...**'; ok 'a real key and a Spanish path'
good; guide '**System Settings > Privacy & Security > Screen & System Audio Recording**, **System Settings > Accessibility**'; ok 'other System Settings paths'
good; guide '**Window > Zoom**'; bad 'a path part of a menu that has no such string' 'path \*\*Window > Zoom\*\*'
good; guide 'Press **Cancel > Retry** or **New Session**'; bad 'a path of two parts that no UI string names' 'path \*\*Cancel > Retry\*\*'
good; guide '**File > Import Session...** and **Edit > Customize Toolbar...**'; ok 'a path part that macOS owns'
good; guide '**Edit > Undo** and **Edit > Redo**'; ok 'the Undo and Redo items of AppKit'
good; guide '**Edit > Undo Import Session**'; ok 'the form Undo <action> of AppKit'
good; guide '**File > Undo**'; bad 'Undo under a menu that is not Edit' 'path \*\*File > Undo\*\*: no menu string "Undo"'
good; guide '**View > Undo Import Session**'; bad 'the form Undo <action> under a menu that is not Edit' 'no menu string "Undo Import Session"'

# menutables
good; sed -i '' 's/| \*\*Drag Mode\*\* | None |/| **Drag Mode** | - |/' "$tmp/docs/guide.md"; bad 'a Key cell of a dash' "the key cell is '-'"
good; sed -i '' 's/| \*\*Import Session\*\* |/| Import Session |/' "$tmp/docs/guide.md"; bad 'a menu string with no bold name' 'has no \*\*Import Session\*\* \(menu.file.importSession\)'
good; sed -i '' '/Drag Mode/d' "$tmp/docs/guide.md"; bad 'a menu string with no row, beside the submenu choice' 'has no \*\*Drag Mode\*\*'

# decstatus
good; sed -i '' 's/F04/F02/' "$tmp/docs/decisions/0003-y.md"; bad 'a proposed record whose head names only a done F-ID' 'Status proposed, and its head names no F-ID that is not done'
good; sed -i '' 's/| X | accepted |/| X | proposed |/' "$tmp/docs/README.md"; bad 'a docs map cell that differs from its record' "0002 has the Status cell 'proposed', and its record has 'accepted'"
good; sed -i '' 's/Feature F04\./Feature F04 and F02./' "$tmp/docs/decisions/0003-y.md"; ok 'a proposed record that names an open and a done F-ID'

# releases
good; sed -i '' 's/| F03 | Three | user | Release 8 |/| F03 | Three | user | done, Release 9 run 1 |/' "$tmp/docs/requirements/features.md"
bad 'an open Release 8 while a feature of Release 9 is done' 'Release 8 has no `Status: closed` line'
good; sed -i '' 's/| F03 | Three | user | Release 8 |/| F03 | Three | user | done, Release 9 run 1 |/' "$tmp/docs/requirements/features.md"
printf '\nStatus: closed\n' >> "$tmp/docs/requirements/releases.md"; ok 'a closed Release 8 while a feature of Release 9 is done'
good; sed -i '' 's/| F03 | Three | user | Release 8 |/| F03 | Three | user | done, Release 8 run 2 |/' "$tmp/docs/requirements/features.md"; ok 'each feature of the open Release 8 done'
good; sed -i '' 's/| F03 | Three | user | Release 8 |/| F03 | Three | user | done, Release 8 run 3 (moved from Release 10) |/' "$tmp/docs/requirements/features.md"; ok 'a done State of Release 8 with a note that names Release 10'
good; sed -i '' 's/| F03 | Three | user | Release 8 |/| F03 | Three | user | done, Release 8 runs 1, 2 and 3 |/' "$tmp/docs/requirements/features.md"; ok 'a done State of Release 8 with a runs list'
good; sed -i '' 's/| F03 | Three | user | Release 8 |/| F03 | Three | user | done, Release 8 run 1; Later: a note of Release 12 |/' "$tmp/docs/requirements/features.md"; ok 'a done State of Release 8 with a Later part'
good; sed -i '' 's/^1\. \*\*x (F01)\.\*\*/1. **x (F01).** (done in a run)/' "$tmp/docs/requirements/releases.md"; bad 'a done mark in releases.md' 'a `\(done ...\)` mark'

# deccites
good; printf 'See 0001 for the format.\n' >> "$tmp/AGENTS.md"; bad 'a cite of a number with no record' '0001 names no decision record'
good; printf 'See 0099 and `0001` and item 0001.\n' >> "$tmp/AGENTS.md"; ok 'a number above the last record, a code span, and an item number'
good; printf 'See 0004.\n' >> "$tmp/AGENTS.md"; bad 'a cite of a gap number outside the gap sentence' '0004 names no decision record'
good; printf 'Backlog 0001 and Item 0001 come first.\n' >> "$tmp/AGENTS.md"; ok 'a capital Backlog or Item before a number'

# private
good; printf 'See .scratchpads/runs/x for it.\n' >> "$tmp/README.md"; bad 'a path into the scratch folder in the README' 'README.md:[0-9]+: a path into the local scratch folder'
good; printf 'See the .scratchpads folder.\n' >> "$tmp/README.md"; printf 'Use .scratchpads/runs/x.\n' >> "$tmp/AGENTS.md"; ok 'the bare folder name, and a path in AGENTS.md'
good; printf 'It waits for backlog item 1234.\n' >> "$tmp/docs/decisions/0002-x.md"; bad 'a backlog number in a decision record' 'docs/decisions/0002-x.md:[0-9]+: a backlog number'
good; printf 'Deferred: each take has one clock. Backlog 1530 runs it first.\n' >> "$tmp/docs/decisions/0002-x.md"; bad 'a capital Backlog number in a decision record' 'docs/decisions/0002-x.md:[0-9]+: a backlog number, which a reader cannot open: Backlog 1530'
good; printf 'VER-1\tx\tkeep\tx\t(backlog 4321): why\n' >> "$tmp/docs/workflow/rules.tsv"; bad 'a backlog number in a table of docs' 'docs/workflow/rules.tsv:[0-9]+: a backlog number'
good; printf 'See item 1234 and item 12.\n' >> "$tmp/AGENTS.md"; ok 'an item number outside docs'

[[ $failures -eq 0 ]] && echo "check-docs-drift tests: all passed"
exit $((failures > 0))
