#!/bin/bash
# Print the IDs of the docs/workflow/evals.md scenarios whose Files cell names a changed file:
# a commit since <base>, a working tree change, or an untracked file. Deliver Phase 7 and the
# eval pass of an upkeep run (reflect rule 8) run the scenarios of --quoted.
# Usage: scripts/evals-for.sh [--quoted] <base>
# --quoted keeps only a scenario that is new since <base>, a holdout, or a scenario whose key
# points quote a changed line (a deleted or an added line) of a changed file of its Files cell:
# a backticked term of 8 or more characters, as a whole term and not in the stop list, or a run
# of 5 words (case and punctuation ignored).
# A bad base exits nonzero with nothing on stdout. scripts/evals-for.test.sh tests it.
set -euo pipefail
quoted=""
[[ ${1:-} == --quoted ]] && { quoted=1; shift; }
[[ $# -eq 1 ]] || { echo "usage: scripts/evals-for.sh [--quoted] <base>" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)"
committed="$(git diff --name-only --no-renames "$1...HEAD")"
untracked="$(git ls-files --others --exclude-standard)"
changed="$committed"$'\n'"$(git diff --name-only --no-renames HEAD)"$'\n'"$untracked"
if [[ -z $quoted ]]; then
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
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
{
    git diff -U0 --no-renames "$1...HEAD"
    git diff -U0 --no-renames HEAD
    while IFS= read -r f; do
        [[ -f $f ]] || continue
        printf 'diff --git a/%s b/%s\n+++ b/%s\n@@\n' "$f" "$f" "$f"
        sed 's/^/+/' "$f"
    done <<<"$untracked"
} > "$tmp/diff"
git show "$1:docs/workflow/evals.md" > "$tmp/base.md" 2>/dev/null || : > "$tmp/base.md"
printf '%s\n' "$changed" > "$tmp/files"
python3 - "$tmp/diff" "$tmp/base.md" "$tmp/files" docs/workflow/evals.md <<'PY'
import re
import sys

diff, base, files, evals = sys.argv[1:5]
STOP = {"decisions.tsv", "analysis.md", "run.md", "plan.md"}

# The changed lines of each file: the - and + lines of each hunk.
lines, cur, in_hunk = {}, None, False
for raw in open(diff, encoding="utf-8", errors="replace"):
    raw = raw.rstrip("\n")
    if raw.startswith("diff --git "):
        cur, in_hunk = None, False
    elif not in_hunk:
        if raw.startswith(("--- a/", "+++ b/")):
            cur = raw[6:]
        elif raw.startswith("@@"):
            in_hunk = True
    elif raw[:1] in "+-" and cur:
        lines.setdefault(cur, []).append(raw[1:])


def rows(path):
    """(ID, key points, Files) of each row of the Scenarios table."""
    inside = False
    for line in open(path, encoding="utf-8"):
        if line.startswith("## "):
            inside = line.startswith("## Scenarios")
        elif inside and re.match(r"\| [EH][0-9]+ \|", line):
            cells = line.replace("\\|", "").split("|")
            yield cells[1].strip(), cells[-5], cells[-4]


def words(text):
    return " ".join(re.findall(r"[a-z0-9]+", re.sub(r"\([a-z]\)", " ", text.lower())))


changed = {f for f in open(files, encoding="utf-8").read().split("\n") if f}
base_ids = {row[0] for row in rows(base)}
for sid, keys, cell in rows(evals):
    hit = [f for f in re.findall(r"`([^`]+)`", cell) if f in changed]
    if not hit:
        continue
    if sid not in base_ids or "holdout" in keys:
        print(sid)
        continue
    text = [line for f in hit for line in lines.get(f, [])]
    terms = [t for t in re.findall(r"`([^`]+)`", keys) if len(t) >= 8 and t not in STOP]
    pattern = [re.compile(r"(?<![A-Za-z0-9_-])" + re.escape(t) + r"(?![A-Za-z0-9_-])") for t in terms]
    w = words(keys).split()
    grams = {" ".join(w[i : i + 5]) for i in range(len(w) - 4)}
    for line in text:
        padded = " " + words(line) + " "
        if any(p.search(line) for p in pattern) or any(" " + g + " " in padded for g in grams):
            print(sid)
            break
PY
