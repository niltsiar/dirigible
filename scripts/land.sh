#!/bin/bash
# Land the run branch through a pull request (deliver Phase 9).
# Usage: scripts/land.sh <title> <body-file>
# It rebases on origin/main, runs `make check-changed BASE=origin/main`, pushes the branch, creates
# the pull request, refuses the merge when origin/main moved after the checks, merges with a
# rebase, and updates main. It stops at the first failure and never force-pushes. It prints the
# PR URL and the commit range on main. scripts/land.test.sh tests it.
set -euo pipefail

die() { echo "land.sh: $1" >&2; exit 1; }

[[ $# -eq 2 ]] || { echo "usage: scripts/land.sh <title> <body-file>" >&2; exit 2; }
title="$1" body="$2"
[[ -f "$body" ]] || die "no body file $body; write it with the pr skill first"
[[ "$body" == /* ]] || body="$PWD/$body"
cd "$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "HEAD is detached; switch to the run branch"
[[ "$branch" != main ]] || die "refuses to run on main; switch to the run branch"

git fetch origin
git rebase origin/main || die "the rebase on origin/main stopped; resolve it with the resolving-merge-conflicts skill"
make check-changed BASE=origin/main || die "the checks failed; nothing is pushed"
git push -u origin "$branch"
url="$(gh pr create --base main --head "$branch" --title "$title" --body-file "$body")"
echo "pr: $url"
git fetch origin
git merge-base --is-ancestor origin/main HEAD ||
    die "origin/main moved after the checks, so they did not test the merge; land again from a fresh branch"
old="$(git rev-parse origin/main)"
gh pr merge "$branch" --rebase --delete-branch
git switch main
git pull --ff-only origin main
git fetch --prune origin
echo "range: $old..$(git rev-parse HEAD)"
