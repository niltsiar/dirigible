#!/bin/bash
# The pass stamp of a push check (`make check-changed BASE=<base>`), so that land.sh does not run
# the same checks again. The file is dirigible-check-stamp in `git rev-parse --git-common-dir`:
# all worktrees share it, and `git worktree remove` keeps it. It is append-only, so a later check
# with another base (the reflect check) does not hide a usable line. A line is: <commit> <base
# commit> <targets>.
# Usage: scripts/check-stamp.sh write <HEAD at the start> <clean|dirty at the start> <base commit|none> <targets>
#          Only the check-changed recipe of the Makefile calls it, after a pass. The guardrail
#          hook blocks a direct call. It appends a line only when the tree was clean at the
#          start, has a base, and HEAD and the tree did not change, and not when make runs with
#          -n, -t, -i, or -q (the first word of MAKEFLAGS has these flags; a word with = is a
#          variable).
#        scripts/check-stamp.sh read <base> [<commit>]
#          Prints "<commit> <targets>" of the newest line whose base is the commit of <base> or an
#          older commit of it (a branch commit is no base) and whose commit is an ancestor of
#          HEAD. Else it prints the reason and exits 1. With <commit>, it takes the newest line
#          of that commit with such a base and tests no ancestry: land.sh uses it for a branch
#          that an earlier land rebased.
# scripts/check-stamp.test.sh tests it.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
file="$(git rev-parse --git-common-dir)/dirigible-check-stamp"

case "${1:-}" in
write)
    [[ $# -ge 5 ]] || { echo "usage: scripts/check-stamp.sh write <head> <clean|dirty> <base|none> <targets>" >&2; exit 2; }
    head="$2" tree="$3" base="$4"
    shift 4
    reason="" flags="${MAKEFLAGS:-}"
    flags="${flags%% *}"
    [[ $flags == *=* ]] && flags=""
    if [[ $flags == *[ntiq]* ]]; then reason="make ran with -n, -t, -i, or -q"
    elif [[ $base == none ]]; then reason="no base"
    elif [[ $tree != clean ]]; then reason="the tree was dirty"
    elif [[ "$(git rev-parse HEAD)" != "$head" ]]; then reason="HEAD moved"
    elif [[ -n "$(git status --porcelain)" ]]; then reason="the tree is dirty"
    fi
    if [[ -n $reason ]]; then
        echo "check-stamp: no stamp ($reason)"
    else
        echo "$head $base $*" >> "$file"
        echo "check-stamp: wrote $head"
    fi
    ;;
read)
    [[ $# -eq 2 || $# -eq 3 ]] || { echo "usage: scripts/check-stamp.sh read <base> [<commit>]" >&2; exit 2; }
    base="$(git rev-parse --verify "$2^{commit}")" want="${3:-}"
    [[ -s "$file" ]] || { echo "no stamp"; exit 1; }
    # A line is usable when its base is the commit of <base> or an older commit of it (another
    # land moved <base> after the check). A base that is a branch commit is no pass.
    base_ok() { [[ $1 == "$base" ]] || git merge-base --is-ancestor "$1" "$base" 2>/dev/null; }
    reason="base moved"
    if [[ -n $want ]]; then
        while read -r commit line_base targets; do
            [[ $commit == "$want" ]] && base_ok "$line_base" || continue
            echo "$commit $targets"
            exit 0
        done < <(tail -r "$file")
        echo "$reason"
        exit 1
    fi
    # A line whose commit is not on this branch costs no git call: the lines of the file grow with
    # each check, the lines of this branch do not. The base commit itself needs the ancestry test.
    mine=$'\n'"$(git rev-list HEAD --not "$base")"$'\n'
    # The newest line first.
    while read -r commit line_base targets; do
        if [[ $mine == *$'\n'"$commit"$'\n'* ]] || { [[ $commit == "$base" ]] && git merge-base --is-ancestor "$commit" HEAD 2>/dev/null; }; then
            base_ok "$line_base" || continue
            echo "$commit $targets"
            exit 0
        fi
        [[ $line_base != "$base" ]] || reason="not an ancestor"
    done < <(tail -r "$file")
    echo "$reason"
    exit 1
    ;;
*)
    echo "usage: scripts/check-stamp.sh write|read ..." >&2
    exit 2
    ;;
esac
