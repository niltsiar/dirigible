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
#          Prints "<commit> <targets>" of the newest line whose base is the commit of <base> and
#          whose commit is an ancestor of HEAD. Else it prints the reason and exits 1. With
#          <commit>, it takes the newest line of that commit with that base and tests no
#          ancestry: land.sh uses it for a branch that an earlier land rebased.
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
    reason="base moved"
    # The newest line first.
    while read -r commit line_base targets; do
        [[ -z $want || $commit == "$want" ]] || continue
        [[ $line_base == "$base" ]] || continue
        if [[ -z $want ]]; then
            reason="not an ancestor"
            git merge-base --is-ancestor "$commit" HEAD 2>/dev/null || continue
        fi
        echo "$commit $targets"
        exit 0
    done < <(tail -r "$file")
    echo "$reason"
    exit 1
    ;;
*)
    echo "usage: scripts/check-stamp.sh write|read ..." >&2
    exit 2
    ;;
esac
