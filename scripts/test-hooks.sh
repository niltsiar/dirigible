#!/bin/bash
# Runs the hook and script tests of make test-hooks, and reuses a pass with the same input key.
# Usage: scripts/test-hooks.sh <test script>...
#   Only the test-hooks recipe of the Makefile calls it, with the HOOK_TESTS list.
# The key is the HEAD tree with no Sources/, Tests/, docs/, or README.md, plus the existence of
# each floor path of scripts/check-changed.sh --floor, the sorted test list, the tool versions,
# and the date: a pass is good for one day. The script computes the key once, before the tests.
# On a clean tree, the tests run from a key tree: a clone of HEAD in a temporary folder of the git
# common dir with a sparse checkout of the key paths only, so a test that reads a path outside the
# key fails. Each floor file in it is empty: the key holds only its existence. The sparse
# checkout stays inside the clone: in a linked worktree it changes the shared config. A trap
# removes the folder at the exit and after INT or TERM.
# A pass appends the key to dirigible-hooks-stamp in `git rev-parse --git-common-dir`. The next
# run with the same key prints "test-hooks: reuse <key>" and runs no test.
# No reuse and no stamp: on a dirty tree (the tests run in place), when the list is not the
# HOOK_TESTS list of the Makefile at HEAD, after a failed test, and when the first word of
# MAKEFLAGS has -n, -t, -i, or -q (as scripts/check-stamp.sh).
# scripts/test-hooks.test.sh tests it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
common="$(git rev-parse --path-format=absolute --git-common-dir)" || exit 1
stamp="$common/dirigible-hooks-stamp"
sha="$(git rev-parse HEAD)" || exit 1

reason="" flags="${MAKEFLAGS:-}"
flags="${flags%% *}"
[[ $flags == *=* ]] && flags=""
listed="$(git show "$sha:Makefile" | awk '/^HOOK_TESTS *=/ { on = 1 } on { print; if (!/\\$/) exit }' \
    | sed 's/^HOOK_TESTS *=//; s/\\$//' | tr -s ' \t' '\n' | grep . | sort)"
dirty=no
[[ -n "$(git status --porcelain)" ]] && dirty=yes
if [[ $flags == *[ntiq]* ]]; then reason="make ran with -n, -t, -i, or -q"
elif [[ $dirty == yes ]]; then reason="the tree is dirty"
elif [[ "$(printf '%s\n' "$@" | sort)" != "$listed" ]]; then reason="the list is not HOOK_TESTS of the Makefile"
fi

key=""
if [[ $dirty == no ]]; then
    floor="$(scripts/check-changed.sh --floor)" || exit 1
    key="$({
        git ls-tree "$sha" | grep -vE $'\t(Sources|Tests|docs|README\\.md)$'
        for f in $floor; do
            if git cat-file -e "$sha:${f%/}" 2>/dev/null; then echo "$f yes"; else echo "$f no"; fi
        done
        printf '%s\n' "$@" | sort
        for tool in 'swift --version' sw_vers 'xcodebuild -version' 'python3 --version' 'node --version' \
            'git --version' 'make --version'; do
            echo "$tool: $($tool 2>&1 | head -2 | tr '\n' ' ')"
        done
        date +%F
    } | shasum -a 256 | cut -c1-64)"
    if [[ -z $reason ]] && grep -q "^$key " "$stamp" 2>/dev/null; then
        echo "test-hooks: reuse $key"
        exit 0
    fi
    # Not in TMPDIR: probe.test.sh needs a repo outside /private/var/folders, where the probe.sh
    # sandbox allows each write.
    work="$(mktemp -d "$common/dirigible-hooks-tree.XXXXXX")" || exit 1
    trap 'rm -rf "$work"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    git clone -q --shared --no-checkout "$common" "$work/tree" \
        && git -C "$work/tree" sparse-checkout set --no-cone '/*' '!/Sources/' '!/Tests/' '!/docs/' '!/README.md' \
            $(sed 's|^|/|' <<< "$floor") \
        && git -C "$work/tree" checkout -q --detach "$sha" || exit 1
    cd "$work/tree" || exit 1
    # The key holds only the existence of a floor path, so a test that reads floor content fails.
    find $floor -type f | while IFS= read -r f; do : > "$f"; done
fi

failed=()
for t in "$@"; do
    "$t" || failed+=("$t")
done
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "test-hooks: ${#failed[@]} of $# failed: ${failed[*]}"
    exit 1
fi
if [[ -n $reason ]]; then
    echo "test-hooks: no stamp ($reason)"
else
    echo "$key $sha" >> "$stamp"
    echo "test-hooks: wrote $key"
fi
