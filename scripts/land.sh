#!/bin/bash
# Land the run branch through a pull request (deliver Phase 9).
# Usage: scripts/land.sh <title> <body-file> [<decisions.tsv time>]
# It refuses a body that scripts/pr-terms.sh flags (run-internal IDs or commit hashes), and a body
# that lost a number of logs/pr-draft.md of its folder (pr-terms.sh --lost), before the fetch.
# It refuses a working tree with changes, because the checks build the working tree and the
# push sends only the commits. It rebases on origin/main (on a conflict, it aborts the rebase and
# stops), runs check-governance.sh with the run folder of the body file, and with `risk: yes` from
# check-changed.sh it needs the mutation pass row in the decisions.tsv of that folder: phase 7, a
# decision that starts with "mutation pass", and a log under controls/ (a red log, a slice row, or
# a pass measure row is not the pass). The newest pass row must not be older than the
# author minute of the last Sources/ commit of the branch. The third argument names the row that
# says why no pass applies. Then
# it runs the checks: none when the pass stamp of check-stamp.sh has HEAD, the targets of the
# delta after the load wait of check-changed.sh when the stamp has an ancestor of HEAD, else
# `make check-changed BASE=origin/main`. The delta runs through run-checks.sh with the risk of
# origin/main. It prints the stamp line. Before the push, it writes one flake row (phase 7) for
# each dirigible-flakes line of run-checks.sh whose commit is an ancestor of HEAD before or after
# the rebase, and removes those lines. Then it pushes the branch, creates the pull request,
# refuses the merge when origin/main moved after the checks, merges with a rebase, and prints
# the PR URL and the commit range on main. Then it updates main: in this worktree, or with a
# fast-forward in the worktree that holds main when its status is clean; with changes there, it
# prints the command. It stops at the first failure and never force-pushes.
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
# The body check comes before the fetch: pr-terms.sh resolves the hashes in this clone.
code=0
"$here/pr-terms.sh" "$body" >&2 || code=$?
[[ $code -ne 1 ]] || die "the body has run-internal IDs or commit hashes (listed above); revise it with the writing-for-humans skill"
[[ $code -eq 0 ]] || die "pr-terms.sh failed (exit $code)"
draft="$run/logs/pr-draft.md"
if [[ -f "$draft" ]]; then
    "$here/pr-terms.sh" --lost "$draft" "$body" >&2 || code=$?
    [[ $code -ne 1 ]] || die "the body lost numbers of $draft (listed above); restore them in the body, or correct $draft when its number is wrong"
    [[ $code -eq 0 ]] || die "pr-terms.sh --lost failed (exit $code)"
fi

[[ -z "$(git status --porcelain)" ]] ||
    die "the working tree has changes that the push does not send; commit them or move them out of the repo"
git fetch origin
before="$(git rev-parse HEAD)"
if ! git rebase origin/main; then
    git rebase --abort
    die "the rebase on origin/main stopped on a conflict; the rebase is aborted, so the branch is as before; resolve the conflict with a rebase on a fresh branch"
fi
# GOVERNANCE_LAND: the taken-item check runs also when the run has no reflect row.
GOVERNANCE_LAND=1 "$here/check-governance.sh" origin/main "$run" || die "the governance check failed; nothing is pushed"
out="$("$here/check-changed.sh" origin/main)" || die "check-changed.sh origin/main failed; nothing is pushed"
risk="$(sed -n 's/^risk: //p' <<<"$out")"
if [[ "$risk" == yes ]]; then
    log="$run/decisions.tsv"
    [[ -f "$log" ]] || die "risk: yes and no decisions.tsv in $run"
    if [[ -n "$why" ]]; then
        awk -F'\t' -v t="$why" '$1 == t { f = 1 } END { exit !f }' "$log" || die "no row $why in $log"
    else
        pass="$(awk -F'\t' '$2 == "7" && $3 ~ /^mutation pass/ && $5 ~ /controls\// && $1 > t { t = $1 } END { print t }' "$log")"
        [[ -n "$pass" ]] ||
            die "risk: yes, and $log has no mutation pass row (phase 7, a decision that starts with \"mutation pass\", a log under controls/); run the pass of mutation-controls.md, or pass the time of the row that says why no pass applies"
        # The rebase keeps the author dates; the row time is local, so the date is too.
        last="$(git log -1 --format=%ad --date=format-local:%FT%R origin/main..HEAD -- Sources)"
        [[ "$pass" > "$last" || "$pass" == "$last" ]] ||
            die "risk: yes, and the last mutation pass row of $log ($pass) is older than the last Sources/ commit ($last); run one new mutant for each guard that the fix touched, or pass the time of the phase 7 row that says the fix touches no guard"
    fi
fi
# The pass stamp: a passing push check of HEAD or of an ancestor of HEAD, with this base.
# --no-renames lists the old path of a move too, as check-changed.sh does.
if stamp="$("$here/check-stamp.sh" read origin/main)"; then
    commit="${stamp%% *}"
    delta="$(git diff --name-only --no-renames "$commit" HEAD)"
    if [[ -z "$delta" ]]; then
        echo "stamp: reuse $commit"
    else
        out="$("$here/check-changed.sh" --paths --push <<<"$delta")" || die "check-changed.sh failed on the delta after $commit; nothing is pushed"
        targets="$(sed -n 's/^targets: //p' <<<"$out")"
        [[ -n "$targets" ]] || die "check-changed.sh gave no targets for the delta after $commit; nothing is pushed"
        echo "stamp: delta $targets"
        BASE=origin/main CHECK_RISK="$risk" "$here/run-checks.sh" $targets || die "the checks failed; nothing is pushed"
    fi
else
    echo "stamp: none ($stamp)"
    make check-changed BASE=origin/main || die "the checks failed; nothing is pushed"
fi
# A test that passed only on a rerun of run-checks.sh gets a flake row (flake-triage.md). The file
# is renamed first, so a line that another worktree appends meanwhile goes to a new file and stays.
# Until the loop ends, a stop (a failed row, an error, INT, or TERM) puts the renamed copy back.
# The copy of another land.sh is not taken: it puts back its own copy.
flakes="$(git rev-parse --path-format=absolute --git-common-dir)/dirigible-flakes"
if [[ -s "$flakes" ]]; then
    taken="$flakes.$$" keep="$(mktemp)" row="$(mktemp)"
    restore() { [[ ! -e "$taken" ]] || { cat "$taken" >> "$flakes"; rm -f "$taken"; }; }
    trap restore EXIT
    trap 'restore; exit 130' INT
    trap 'restore; exit 143' TERM
    mv "$flakes" "$taken"
    while read -r commit name _ load; do
        if git merge-base --is-ancestor "$commit" "$before" 2>/dev/null || git merge-base --is-ancestor "$commit" HEAD 2>/dev/null; then
            printf '7\nflake: %s passed only on a rerun of the push check, load %s at the end of the check\n%s\n%s\nflake\n' "$name" "$load" \
                "run-checks.sh reran the failed test, and flake-triage.md still applies to it" \
                "dirigible-flakes line of commit $commit" > "$row"
            "$here/../.claude/skills/deliver/scripts/log-decision.sh" "$run" --from "$row" ||
                die "no flake row for $name; nothing is pushed"
        else
            echo "$commit $name load $load" >> "$keep"
        fi
    done < "$taken"
    cat "$keep" >> "$flakes"
    rm -f "$taken" "$keep" "$row"
fi
git push -u origin "$branch"
url="$(gh pr create --base main --head "$branch" --title "$title" --body-file "$body")"
echo "pr: $url"
git fetch origin
git merge-base --is-ancestor origin/main HEAD ||
    die "origin/main moved after the checks, so they did not test the merge; land again from a fresh branch"
old="$(git rev-parse origin/main)"
gh pr merge "$branch" --rebase --delete-branch
git fetch --prune origin
echo "range: $old..$(git rev-parse origin/main)"
# git switch main fails while another worktree holds main (often the main checkout). This
# worktree is on the run branch, so a worktree on main is another one.
holder="$(git worktree list --porcelain | awk '/^worktree /{ w = substr($0, 10) } $0 == "branch refs/heads/main" { print w }')"
if [[ -n "$holder" && -z "$(git -C "$holder" status --porcelain)" ]]; then
    if git -C "$holder" merge -q --ff-only origin/main; then
        echo "land.sh: main is checked out in $holder; fast-forwarded it"
    else
        echo "land.sh: the merge is done, but the fast-forward of main in $holder failed; run git -C $holder merge --ff-only origin/main"
    fi
elif [[ -n "$holder" ]]; then
    echo "land.sh: main is checked out in $holder, which has changes; fast-forward it there with git merge --ff-only origin/main"
else
    git switch main
    git pull --ff-only origin main
fi
