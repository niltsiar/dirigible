#!/bin/bash
# Refuse an ungraded eval key. A Scenarios row of docs/workflow/evals.md that the branch adds, or
# whose key points the branch changes, needs an eval folder of the run (<run folder>/eval*/) with
# two parts: a keys.md that holds the exact key text under `## <ID>`, and a scores.tsv line of the
# ID. The text counts, not a commit hash, so a rebased branch passes. A holdout and a row of type
# agent are skipped. log-decision.sh (each phase 6 row) and check-governance.sh (the land) run it.
# Usage: scripts/check-eval-keys.sh <base> <run folder> [<tree>]
# The check diffs evals.md from `git merge-base <base> HEAD` to the HEAD of the run tree, so a key
# change that only the base made after the branch point is no fault of the branch. <tree> is that
# tree. With no <tree>, it is the worktree of the last `- Branch:` line of the run.md of the run
# folder (one line for each landing). A caller in another tree, for example the main checkout, sees
# the branch keys. With no such worktree the script exits 2 and names the branch. It also exits 2
# when that branch is landed (git cherry <base> HEAD prints no + line): the run needs the
# `- Branch:` line of the next landing. A <tree> argument skips this check.
# Exit: 0 pass, 1 an ungraded key, 2 bad input. scripts/check-eval-keys.test.sh tests it.
set -euo pipefail

die() { echo "check-eval-keys: $2" >&2; exit "$1"; }

[[ $# -eq 2 || $# -eq 3 ]] || die 2 "usage: scripts/check-eval-keys.sh <base> <run folder> [<tree>]"
base="$1" run="${2%/}" tree="${3:-}"
[[ -d $run ]] || die 2 "no run folder $run"

if [[ -z $tree ]]; then
    [[ -f $run/run.md ]] || die 2 "no run.md in $run: the run folder names the branch to check"
    line="$(grep '^- Branch:' "$run/run.md" | tail -n 1 || true)"
    [[ -n $line ]] || die 2 "$run/run.md has no '- Branch:' line"
    branch="$(sed -E 's/^- Branch: *//; s/[ ,].*$//' <<<"$line")"
    list="$(git -C "$run" worktree list --porcelain 2>/dev/null)" || die 2 "$run is not in a git repository"
    tree="$(awk -v ref="refs/heads/$branch" '/^worktree /{ p = substr($0, 10) } $1 == "branch" && $2 == ref { print p; exit }' <<<"$list")"
    [[ -n $tree ]] || die 2 "no worktree holds the branch $branch; check it out in a worktree"
    cherry="$(git -C "$tree" cherry "$base" HEAD 2>/dev/null)" || die 2 "no merge base of $base and HEAD in $tree"
    grep -q '^+' <<<"$cherry" || die 2 "the branch $branch of the last '- Branch:' line is landed: add the line of the next landing to $run/run.md"
fi

merge_base="$(git -C "$tree" merge-base "$base" HEAD 2>/dev/null)" || die 2 "no merge base of $base and HEAD in $tree"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tree" show "$merge_base:docs/workflow/evals.md" > "$tmp/old.md" 2>/dev/null || : > "$tmp/old.md"
git -C "$tree" show "HEAD:docs/workflow/evals.md" > "$tmp/new.md" 2>/dev/null || : > "$tmp/new.md"

python3 -I - "$tmp/old.md" "$tmp/new.md" "$run" <<'PY'
import glob
import os
import re
import sys

old_md, new_md, run = sys.argv[1:4]


def rows(path):
    """{ID: (type, key points)} of the Scenarios table, split as scripts/eval/run.sh splits it."""
    out, section = {}, ""
    for line in open(path, encoding="utf-8"):
        if line.startswith("## "):
            section = line[3:].strip()
        if section == "Scenarios" and re.match(r"\| [EH][0-9]+ \|", line):
            c = [x.strip().replace("\\|", "|") for x in re.split(r"(?<!\\)\|", line)]
            out[c[1]] = (c[2], c[5])
    return out


def graded(folder):
    """The key text of each ID of keys.md, and the IDs that scores.tsv scored."""
    keys, lines = {}, []
    if os.path.isfile(folder + "/keys.md"):
        lines = open(folder + "/keys.md", encoding="utf-8").read().split("\n")
    for i, line in enumerate(lines[:-1]):
        if line.startswith("## "):
            keys[line[3:].strip()] = lines[i + 1].strip()
    scored = set()
    if os.path.isfile(folder + "/scores.tsv"):
        for line in open(folder + "/scores.tsv", encoding="utf-8"):
            cells = line.rstrip("\n").split("\t")
            if len(cells) > 1:
                scored.add(cells[1])
    return keys, scored


before, after = rows(old_md), rows(new_md)
folders = [graded(d) for d in sorted(glob.glob(run + "/eval*/")) if os.path.isdir(d)]
bad = 0
for sid, (kind, key) in after.items():
    if kind == "agent" or "(holdout)" in key or (sid in before and before[sid][1] == key):
        continue
    if not any(keys.get(sid) == key and sid in scored for keys, scored in folders):
        print(
            f"check-eval-keys: {sid} has a new or changed key and no eval folder in {run} "
            "with its exact key text in keys.md and a scores.tsv line; grade it with "
            "scripts/eval/run.sh of the branch worktree before the gates",
            file=sys.stderr,
        )
        bad = 1
sys.exit(bad)
PY
