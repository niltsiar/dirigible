#!/bin/bash
# Print the IDs of the docs/workflow/evals.md scenarios whose Files cell names a changed file:
# a commit since <base>, a working tree change, or an untracked file. Deliver Phase 7 and the
# eval pass of an upkeep run (reflect rule 8) run these scenarios.
# Usage: scripts/evals-for.sh <base>
# A bad base exits nonzero with nothing on stdout. scripts/evals-for.test.sh tests it.
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: scripts/evals-for.sh <base>" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)"
committed="$(git diff --name-only --no-renames "$1...HEAD")"
changed="$committed"$'\n'"$(git diff --name-only --no-renames HEAD)"$'\n'"$(git ls-files --others --exclude-standard)"
# A row of the Scenarios table: the ID is the first cell, Files is the third cell from the end.
# A bar inside a cell is written as \|, so the split ignores it.
awk '
    FILENAME == "-" { if ($0 != "") c[++n] = $0; next }
    /^## / { inside = ($0 ~ /^## Scenarios/); next }
    inside && /^\| [EH][0-9]+ \|/ {
        line = $0
        gsub(/\\\|/, "", line)
        k = split(line, cell, "|")
        id = cell[2]; files = cell[k - 3]
        gsub(/ /, "", id)
        for (i = 1; i <= n; i++) if (index(files, "`" c[i] "`")) { print id; break }
    }' - docs/workflow/evals.md <<<"$changed"
