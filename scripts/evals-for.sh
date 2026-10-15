#!/bin/bash
# Print the IDs of the docs/workflow/evals.md scenarios whose Files cell names a changed file:
# a commit since <base>, a working tree change, or an untracked file. Deliver Phase 7 and the
# eval pass of an upkeep run (reflect rule 8) run the scenarios of --quoted.
# Usage: scripts/evals-for.sh [--quoted] <base>
# --quoted keeps only a scenario that is new since <base>, a holdout, a row of type agent (its key
# points are a pass rule, not quotes of a file), or a scenario whose key points quote the changed
# words of a hunk of a changed file of its Files cell: a backticked term
# of 8 or more characters (a whole term, not in the stop list) whose count differs between the
# deleted and the added lines, or a run of 5 words (case and punctuation ignored) that touches a
# changed word span of the hunk.
# A bad base exits nonzero with nothing on stdout. scripts/evals-for.test.sh tests it.
# --staged [<base>] (the commit-msg hook) prints '<ID> <file>: <cut text>' and exits 1 for each
# real cut of a file of the Files cell by the index: a key term (as above) that the staged file
# holds fewer times than the file at <base> (default HEAD), or a 5-word run of the key points that
# the whole file at <base> holds and the whole staged file does not. An insertion next to kept key
# text is no cut. It reads the key points from the staged evals.md, so a rule and its key that
# change in one commit pass, and it skips a holdout, a row of type agent, and a row new since <base>.
set -euo pipefail
quoted="" staged=""
case "${1:-}" in
    --quoted) quoted=1; shift ;;
    --staged) staged=1; shift ;;
esac
[[ $# -eq 1 || ($staged && $# -eq 0) ]] || { echo "usage: scripts/evals-for.sh [--quoted] <base> | --staged [<base>]" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [[ -n $staged ]]; then
    base="${1:-HEAD}"
    # No commit at the base (a first commit) or no staged evals.md: nothing to cut.
    git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || exit 0
    git show ":docs/workflow/evals.md" > "$tmp/staged.md" 2>/dev/null || exit 0
    git show "$base:docs/workflow/evals.md" > "$tmp/base.md" 2>/dev/null || : > "$tmp/base.md"
    git diff --cached --name-only --no-renames "$base" > "$tmp/files"
    args=(staged "$base" "$tmp/files" "$tmp/base.md" "$tmp/staged.md")
else
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
    args=(quoted "$tmp/diff" "$tmp/base.md" "$tmp/files" docs/workflow/evals.md)
fi
python3 - "${args[@]}" <<'PY'
import difflib
import re
import subprocess
import sys

mode = sys.argv[1]
STOP = {"decisions.tsv", "analysis.md", "run.md", "plan.md"}

def rows(path):
    """(ID, Type, key points, Files) of each row of the Scenarios table."""
    inside = False
    for line in open(path, encoding="utf-8"):
        if line.startswith("## "):
            inside = line.startswith("## Scenarios")
        elif inside and re.match(r"\| [EH][0-9]+ \|", line):
            cells = line.replace("\\|", "").split("|")
            yield cells[1].strip(), cells[2].strip(), cells[-5], cells[-4]


def words(text):
    """The words of a text, with case and punctuation ignored."""
    return re.findall(r"[a-z0-9]+", re.sub(r"\([a-z]\)", " ", text.lower()))


def grams(w):
    """The runs of 5 words of a word list."""
    return {" ".join(w[i : i + 5]) for i in range(len(w) - 4)}


def changed_grams(gone, added):
    """The 5-word runs that touch a changed word span, on both sides. A span grows by 5 words on
    each side, so a negation before a quoted rule or a qualifier after it changes the rule."""
    a, b = words(gone), words(added)
    out = set()
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag != "equal":
            out |= grams(a[max(0, i1 - 5) : i2 + 5]) | grams(b[max(0, j1 - 5) : j2 + 5])
    return out


def key_terms(keys):
    """The backticked terms of 8 or more characters of the key points, as whole-term patterns."""
    terms = [t for t in re.findall(r"`([^`]+)`", keys) if len(t) >= 8 and t not in STOP]
    return [(t, re.compile(r"(?<![A-Za-z0-9_-])" + re.escape(t) + r"(?![A-Za-z0-9_-])")) for t in terms]


if mode == "staged":
    base, files, base_md, staged_md = sys.argv[2:6]
    changed = {f for f in open(files, encoding="utf-8").read().split("\n") if f}
    base_ids = {row[0] for row in rows(base_md)}

    def show(spec):
        out = subprocess.run(["git", "show", spec], capture_output=True, text=True, errors="replace")
        return out.stdout if out.returncode == 0 else ""

    cut = 0
    for sid, kind, keys, cell in rows(staged_md):
        if sid not in base_ids or "holdout" in keys or kind == "agent":
            continue
        for f in (f for f in re.findall(r"`([^`]+)`", cell) if f in changed):
            old, new = show(f"{base}:{f}"), show(f":{f}")
            lost = [t for t, p in key_terms(keys) if len(p.findall(new)) < len(p.findall(old))]
            runs = sorted(grams(words(keys)) & grams(words(old)) - grams(words(new)))
            if lost or runs:
                print(f"{sid} {f}: {'`' + lost[0] + '`' if lost else runs[0]}")
                cut = 1
    sys.exit(cut)

diff, base, files, evals = sys.argv[2:6]
# The hunks of each file: the deleted lines and the added lines of each hunk.
hunks, cur, in_hunk = {}, None, False
for raw in open(diff, encoding="utf-8", errors="replace"):
    raw = raw.rstrip("\n")
    if raw.startswith("diff --git "):
        cur, in_hunk = None, False
    elif raw.startswith("@@") and cur:
        in_hunk = True
        hunks.setdefault(cur, []).append(([], []))
    elif not in_hunk:
        if raw.startswith(("--- a/", "+++ b/")):
            cur = raw[6:]
    elif raw[:1] in "+-":
        hunks[cur][-1][raw[0] == "+"].append(raw[1:])


changed = {f for f in open(files, encoding="utf-8").read().split("\n") if f}
base_ids = {row[0] for row in rows(base)}
for sid, kind, keys, cell in rows(evals):
    hit = [f for f in re.findall(r"`([^`]+)`", cell) if f in changed]
    if not hit:
        continue
    if sid not in base_ids or "holdout" in keys or kind == "agent":
        print(sid)
        continue
    pattern = [p for _, p in key_terms(keys)]
    for gone, added in (h for f in hit for h in hunks.get(f, [])):
        gone, added = "\n".join(gone), "\n".join(added)
        if any(len(p.findall(gone)) != len(p.findall(added)) for p in pattern) or grams(
            words(keys)
        ) & changed_grams(gone, added):
            print(sid)
            break
PY
