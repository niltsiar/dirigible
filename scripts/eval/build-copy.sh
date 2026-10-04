#!/bin/bash
# Build the docs copy of a commit for the eval (docs/workflow/evals.md): git archive of the doc
# paths minus evals.md, plus each tracked file that the copy names by full path, to closure.
# Usage: scripts/eval/build-copy.sh <commit> <copy folder> <log>
# The copy folder is new or empty, under a .scratchpads/ folder or $TMPDIR, with no .. part.
# Else it exits 2 and changes nothing. scripts/evals-for.test.sh tests the refusals.
set -euo pipefail
[[ $# -eq 3 ]] || { echo "usage: scripts/eval/build-copy.sh <commit> <copy folder> <log>" >&2; exit 2; }
h="$1" d="$2" log="$3"
here="$(cd "$(dirname "$0")" && pwd)"
tmpd="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
refuse() { echo "build-copy: $d $1" >&2; exit 2; }
# inside <folder>: the folder, with its links resolved, is under a .scratchpads/ folder or $TMPDIR.
inside() {
    local p="$1" rest=""
    while [[ ! -d $p ]]; do rest="/$(basename "$p")$rest"; p="$(dirname "$p")"; done
    p="$(cd "$p" && pwd -P)$rest/"
    [[ $p == */.scratchpads/* || $p == "$tmpd"/* ]]
}
[[ /$d/ != */../* ]] || refuse "is outside .scratchpads/ and TMPDIR (a .. part)"
[[ $d == /* ]] || d="$PWD/$d"
inside "$d" || refuse "is outside .scratchpads/ and TMPDIR"
[[ ! -e $d || -z "$(ls -A "$d")" ]] || refuse "holds files; give a new or an empty folder"
mkdir -p "$d"
inside "$d" || { rmdir "$d"; refuse "is outside .scratchpads/ and TMPDIR"; }
git archive "$h" AGENTS.md CLAUDE.md README.md Package.swift .claude docs/principles.md scripts docs/decisions docs/guide.md docs/images docs/requirements docs/research docs/workflow Support/Info.plist Support/Resources Tests/DirigibleTests/AppBundleTests.swift Tests/DirigibleTests/DiskImageTests.swift | tar -x -C "$d"
rm -f "$d/docs/workflow/evals.md"
while :; do
    missing="$(python3 "$here/pointed-missing.py" "$d" "$h" | sed -n 's/^MISSING \([^ ]*\) .*/\1/p' | grep -vx 'docs/workflow/evals.md' || true)"
    [[ -z "$missing" ]] && break
    while IFS= read -r f; do mkdir -p "$d/$(dirname "$f")"; git show "$h:$f" > "$d/$f"; done <<< "$missing"
done
{
    echo "copy: git archive $h (the doc paths) minus docs/workflow/evals.md, plus each tracked file that the copy names by full path, to closure (pointed-missing.py)"
    python3 "$here/pointed-missing.py" "$d" "$h"
    echo "files:      $(find "$d" -type f | wc -l | tr -d ' ')"
    echo "byte check: each file against git show $h:<path>"
    (cd "$d" && find . -type f | sed 's|^\./||') | while IFS= read -r f; do git show "$h:$f" | cmp -s - "$d/$f" || echo "DIFF $f"; done
    echo "byte check end"
} > "$log"
