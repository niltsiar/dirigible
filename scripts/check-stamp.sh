#!/bin/bash
# The pass stamp of a push check (`make check-changed BASE=<base>`), so that land.sh does not run
# the same checks again. The file is `git rev-parse --git-path dirigible-check-stamp`: one
# worktree, outside the tree. It is append-only, so a later check with another base (the reflect
# check) does not hide a usable line. A line is: <commit> <tree> <base commit> <targets>.
# Usage: scripts/check-stamp.sh write <HEAD at the start> <clean|dirty at the start> <base commit|none> <targets>
#          Only the check-changed recipe of the Makefile calls it, after a pass. The guardrail
#          hook blocks a direct call. It appends a line only when the tree was clean at the
#          start, has a base, and HEAD and the tree did not change.
#        scripts/check-stamp.sh read <base>
#          Prints "<commit> <targets>" of the newest line whose base is the commit of <base> and
#          whose commit is an ancestor of HEAD. Else it prints the reason and exits 1.
# scripts/check-stamp.test.sh tests it.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
file="$(git rev-parse --git-path dirigible-check-stamp)"

case "${1:-}" in
write)
    [[ $# -ge 5 ]] || { echo "usage: scripts/check-stamp.sh write <head> <clean|dirty> <base|none> <targets>" >&2; exit 2; }
    head="$2" tree="$3" base="$4"
    shift 4
    reason=""
    if [[ $base == none ]]; then reason="no base"
    elif [[ $tree != clean ]]; then reason="the tree was dirty"
    elif [[ "$(git rev-parse HEAD)" != "$head" ]]; then reason="HEAD moved"
    elif [[ -n "$(git status --porcelain)" ]]; then reason="the tree is dirty"
    fi
    if [[ -n $reason ]]; then
        echo "check-stamp: no stamp ($reason)"
    else
        echo "$head $(git rev-parse "$head^{tree}") $base $*" >> "$file"
        echo "check-stamp: wrote $head"
    fi
    ;;
read)
    [[ $# -eq 2 ]] || { echo "usage: scripts/check-stamp.sh read <base>" >&2; exit 2; }
    base="$(git rev-parse --verify "$2^{commit}")"
    [[ -s "$file" ]] || { echo "no stamp"; exit 1; }
    reason="base moved"
    # The newest line first.
    while read -r commit tree line_base targets; do
        [[ $line_base == "$base" ]] || continue
        reason="not an ancestor"
        git merge-base --is-ancestor "$commit" HEAD 2>/dev/null || continue
        [[ "$(git rev-parse "$commit^{tree}")" == "$tree" ]] || continue
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
