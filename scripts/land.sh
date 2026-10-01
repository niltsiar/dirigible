#!/bin/bash
# Land the run branch through a pull request (deliver Phase 9).
# Usage: scripts/land.sh <title> <body-file> [<decisions.tsv time>]
# It refuses a working tree with changes, because the checks build the working tree and the
# push sends only the commits. It rebases on origin/main, runs check-governance.sh with the run
# folder of the body file, and with `risk: yes` from check-changed.sh it needs a control row in
# the decisions.tsv of that folder: phase 2 or 4, with a log under controls/. The third argument
# names the row that says why no control applies. Then it runs `make check-changed
# BASE=origin/main`, pushes the branch, creates the pull request, refuses the merge when
# origin/main moved after the checks, merges with a rebase, and updates main. It stops at the
# first failure and never force-pushes. It prints the PR URL and the commit range on main.
# scripts/land.test.sh tests it.
set -euo pipefail

die() { echo "land.sh: $1" >&2; exit 1; }

[[ $# -eq 2 || $# -eq 3 ]] || { echo "usage: scripts/land.sh <title> <body-file> [<decisions.tsv time>]" >&2; exit 2; }
title="$1" body="$2" why="${3:-}"
[[ -f "$body" ]] || die "no body file $body; write it with the pr skill first"
[[ "$body" == /* ]] || body="$PWD/$body"
here="$(cd "$(dirname "$0")" && pwd)" run="$(dirname "$body")"
cd "$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "HEAD is detached; switch to the run branch"
[[ "$branch" != main ]] || die "refuses to run on main; switch to the run branch"

[[ -z "$(git status --porcelain)" ]] ||
    die "the working tree has changes that the push does not send; commit them or move them out of the repo"
git fetch origin
git rebase origin/main || die "the rebase on origin/main stopped; resolve it with the resolving-merge-conflicts skill"
"$here/check-governance.sh" origin/main "$run" || die "the governance check failed; nothing is pushed"
out="$("$here/check-changed.sh" origin/main)" || die "check-changed.sh origin/main failed; nothing is pushed"
if [[ "$(sed -n 's/^risk: //p' <<<"$out")" == yes ]]; then
    log="$run/decisions.tsv"
    [[ -f "$log" ]] || die "risk: yes and no decisions.tsv in $run"
    if [[ -n "$why" ]]; then
        awk -F'\t' -v t="$why" '$1 == t { f = 1 } END { exit !f }' "$log" || die "no row $why in $log"
    else
        awk -F'\t' '($2 == "2" || $2 == "4") && /controls\// { f = 1 } END { exit !f }' "$log" ||
            die "risk: yes, and $log has no control row (phase 2 or 4, with a log under controls/); add the controls, or pass the time of the row that says why no control applies"
    fi
fi
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
