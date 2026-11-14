#!/bin/bash
# Refuse an ungraded eval key. A Scenarios row of docs/workflow/evals.md that the branch adds, or
# whose key points the branch changes, needs an eval folder in the run folder (at any depth: the
# folder that scripts/eval/run.sh wrote) with two parts: a keys.md that holds the exact key text
# under `## <ID>`, and a scores.tsv line of the ID in the same folder. The text counts, not a
# commit hash, so a rebased branch passes. A holdout and a row of type agent are skipped.
# log-decision.sh (each phase 6 row) and check-governance.sh (the land) run it.
# The lead grades a key: the refusal says so, and a run agent returns to the lead.
# A holdout key line stands only in holdout-keys.md of the run folder: each other file of the run
# folder (a review file, the analysis, the plan, a brief) names only the ID. Eval copies of the docs
# lack evals.md (scripts/eval/build-copy.sh), so this header holds the rule for them. The check
# also refuses a file that holds the key line of a `## H<n>` heading of holdout-keys.md (the line
# after the heading), because an agent that read the copy has seen the key: replace the holdout.
# The walk runs only when holdout-keys.md has an H key. It skips holdout-keys.md, each eval folder
# (a subfolder that holds a keys.md, with its subfolders), each .build, *.app, and *.dirigible
# folder (as teardown-run.sh does), each link, and each file that is no UTF-8 text of the
# extensions .md .tsv .txt .json .csv .log .xml or is over 1 MiB (1048576 bytes).
# Usage: scripts/check-eval-keys.sh <base> <run folder> [<tree>]
# The check diffs evals.md from `git merge-base <base> HEAD` to the HEAD of the run tree, so a key
# change that only the base made after the branch point is no fault of the branch. <tree> is that
# tree. With no <tree>, it is the worktree of the last `- Branch:` line of the run.md of the run
# folder (one line for each landing). A caller in another tree, for example the main checkout, sees
# the branch keys. With no such worktree the script exits 2 and names the branch. It also exits 2
# when that branch is landed (git cherry <base> HEAD prints no + line): the run needs the
# `- Branch:` line of the next landing. A <tree> argument skips this check.
# Exit: 0 pass, 1 an ungraded key or a holdout key copy, 2 bad input. scripts/check-eval-keys.test.sh tests it.
set -euo pipefail

die() { echo "check-eval-keys: $2" >&2; exit "$1"; }

[[ $# -eq 2 || $# -eq 3 ]] || die 2 "usage: scripts/check-eval-keys.sh <base> <run folder> [<tree>]"
base="$1" run="${2%/}" tree="${3:-}"
[[ -d $run ]] || die 2 "no run folder $run"

if [[ -z $tree ]]; then
    [[ -f $run/run.md ]] || die 2 "no run.md in $run: the run folder names the branch to check"
    line="$(grep '^- Branch:' "$run/run.md" | tail -n 1 || true)"
    [[ -n $line ]] || die 2 "$run/run.md has no '- Branch:' line"
    branch="$(sed -E 's/^- Branch: *//; s/[ ,].*$//; s/`//g' <<<"$line")"
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
import os
import re
import stat
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
folders = [graded(d) for d, _, names in sorted(os.walk(run)) if "keys.md" in names]
bad = 0
for sid, (kind, key) in after.items():
    if kind == "agent" or "(holdout)" in key or (sid in before and before[sid][1] == key):
        continue
    if not any(keys.get(sid) == key and sid in scored for keys, scored in folders):
        print(
            f"check-eval-keys: {sid} has a new or changed key and no eval folder in {run} "
            "with its exact key text in keys.md and a scores.tsv line; the lead runs "
            "scripts/eval/run.sh for it in the background from the branch worktree, before the "
            "gates; a run agent returns to the lead",
            file=sys.stderr,
        )
        bad = 1

TEXT = (".md", ".tsv", ".txt", ".json", ".csv", ".log", ".xml")
CAP = 1048576


def holdout_keys(path):
    """{ID: key line} of each `## H<n>` heading of holdout-keys.md; the key line follows the heading."""
    if not os.path.isfile(path):
        return {}
    lines = open(path, encoding="utf-8").read().split("\n")
    return {
        m.group(1): lines[i + 1].strip()
        for i, line in enumerate(lines[:-1])
        if (m := re.match(r"## (H[0-9]+)\s*$", line)) and lines[i + 1].strip()
    }


def key_copies(folder, secrets):
    """(ID, run-relative path) of each file of the run folder that holds a holdout key line."""
    found = []
    for d, dirs, names in os.walk(folder):
        dirs[:] = sorted(
            n for n in dirs if n != ".build" and not n.endswith((".app", ".dirigible"))
        )
        if d != folder and "keys.md" in names:
            dirs[:] = []
            continue
        for name in sorted(names):
            path = os.path.join(d, name)
            rel = os.path.relpath(path, folder)
            if rel == "holdout-keys.md" or not name.endswith(TEXT):
                continue
            info = os.lstat(path)
            if not stat.S_ISREG(info.st_mode) or info.st_size > CAP:
                continue
            try:
                text = open(path, encoding="utf-8").read()
            except UnicodeDecodeError:
                continue
            found += [(sid, rel) for sid, key in secrets.items() if key in text]
    return found


for sid, rel in key_copies(run, holdout_keys(run + "/holdout-keys.md")):
    print(
        f"check-eval-keys: the key of {sid} stands in {rel}; a holdout key stays only in "
        "holdout-keys.md; replace the holdout, because an agent that read the file has seen its key",
        file=sys.stderr,
    )
    bad = 1
sys.exit(bad)
PY
