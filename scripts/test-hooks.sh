#!/bin/bash
# Runs the hook and script tests of make test-hooks, and reuses a pass with the same input key.
# Usage: scripts/test-hooks.sh <test script>...
#   Only the test-hooks recipe of the Makefile calls it, with the HOOK_TESTS list. An argument can
#   hold several tests joined with commas: scripts/check-changed.sh gives make one HOOK_TESTS word
#   for the tests of the changed paths, and make passes that word as one argument. Each part is a
#   test. A list of some of the tests gets no stamp. The whole list (that of the Makefile at HEAD,
#   or that of the Makefile in the work tree) runs only when one of these is set to 1:
#   DIRIGIBLE_PUSH_CHECK (the push check), DIRIGIBLE_FULL_SUITE (a person), or DIRIGIBLE_HOOKS_ALL
#   (scripts/check-changed.sh gives it to a local run that needs the whole list). Else the script
#   prints the reason and exits 1, before the key and the stamp reuse. Before the first test, the
#   script unsets BASE, FILTER, SINCE, CHECK_RISK, HOOK_TESTS, MAKEFLAGS, MFLAGS, MAKELEVEL,
#   GIT_DIR, GIT_INDEX_FILE, GIT_WORK_TREE, and each variable that starts with WITH_LOCK_ or
#   DIRIGIBLE_ (make and the caller put them in the environment of each recipe), so no hook test
#   reads the context of its caller. PATH and HOME stay. A test that needs one of them sets it
#   itself.
# The key is the tree of the work tree with no Sources/, Tests/, docs/, or README.md, plus the
# existence of each floor path of scripts/check-changed.sh --floor, the sorted test list, the tool
# versions, and the date: a pass is good for one day. The tests run `bash` as /bin/bash (a link first
# on their PATH), so the key holds no bash version. The tree is HEAD with the changes of a dirty
# tree and its untracked files that no ignore rule hides: git add -A on a copy of the real index
# makes it, so the real index stays as it is. The script computes the key once, before the tests.
# The tests run from a key tree: a clone with a commit of that tree checked out, in a temporary
# folder of the git common dir, with a sparse checkout of the key paths only, so a test that reads
# a path outside the key fails. Each floor file in it is empty: the key holds only its existence.
# The sparse checkout stays inside the clone: in a linked worktree it changes the shared config. A
# trap removes the folder at the exit and after INT or TERM. A hook test reads only the work tree
# of the key tree. The clone holds each object of the repo, so a read of an excluded path through
# git (for example git show HEAD:docs/x.md) is outside the key: a hook test must not do it.
# A pass appends "<key> <commit> <date>" to dirigible-hooks-stamp in the git common dir, and drops
# the lines of other days. The next run with the same key prints "test-hooks: reuse <key>" and runs
# no test. At the start, the script removes each key tree folder over one hour old.
# No reuse and no stamp: when the list is not the HOOK_TESTS list of the Makefile at HEAD, after a
# failed test, when the first word of MAKEFLAGS has -n, -t, -i, or -q (as scripts/check-stamp.sh),
# and when HOOK_CASES is set. After a failed test, the summary names each failed test and prints the
# last 40 lines of its output.
# HOOK_CASES=<label pattern> reaches the test, which runs only the case blocks that match (the
# header of .claude/hooks/git-guardrails.test.sh). With DIRIGIBLE_PUSH_CHECK=1 or
# DIRIGIBLE_HOOKS_ALL=1 the script prints a message that names HOOK_CASES and exits 1, before the
# key: a push check or a hooks pass runs every case, or fails.
# scripts/test-hooks.test.sh tests it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
common="$(git rev-parse --path-format=absolute --git-common-dir)" || exit 1
stamp="$common/dirigible-hooks-stamp"
sha="$(git rev-parse HEAD)" || exit 1
today="$(date +%F)"
# A killed run (no trap) leaves its key tree: remove each one over one hour old. A run takes about
# 10 min, so the run of another worktree keeps its tree.
find "$common" -maxdepth 1 -type d -name 'dirigible-hooks-tree.*' -mmin +60 -exec rm -rf {} +

if [[ -n ${HOOK_CASES:-} && ( ${DIRIGIBLE_PUSH_CHECK:-} == 1 || ${DIRIGIBLE_HOOKS_ALL:-} == 1 ) ]]; then
    echo "test-hooks: HOOK_CASES is set, and a push check or a hooks pass runs every hook case. Unset HOOK_CASES." >&2
    exit 1
fi

args=()
for a in "$@"; do
    IFS=, read -ra parts <<< "$a"
    args+=("${parts[@]}")
done
set -- ${args[@]+"${args[@]}"}

reason="" flags="${MAKEFLAGS:-}"
flags="${flags%% *}"
[[ $flags == *=* ]] && flags=""
hook_list() { awk '/^HOOK_TESTS *=/ { on = 1 } on { print; if (!/\\$/) exit }' \
    | sed 's/^HOOK_TESTS *=//; s/\\$//' | tr -s ' \t' '\n' | grep . | sort; }
listed="$(git show "$sha:Makefile" | hook_list)"
current="$(hook_list < Makefile)"
given="$(printf '%s\n' "$@" | sort)"
whole=no
[[ $given == "$listed" ]] && whole=yes
if [[ $given == "$listed" || $given == "$current" ]] \
    && [[ ${DIRIGIBLE_PUSH_CHECK:-} != 1 && ${DIRIGIBLE_FULL_SUITE:-} != 1 && ${DIRIGIBLE_HOOKS_ALL:-} != 1 ]]; then
    echo "test-hooks: the whole HOOK_TESTS list runs only in the push check. Run make check-changed: it runs the hook tests of the changed paths. A person who needs the whole list sets DIRIGIBLE_FULL_SUITE=1." >&2
    exit 1
fi
if [[ $flags == *[ntiq]* ]]; then reason="make ran with -n, -t, -i, or -q"
elif [[ $whole == no ]]; then reason="the list is not HOOK_TESTS of the Makefile"
elif [[ -n ${HOOK_CASES:-} ]]; then reason="HOOK_CASES is set"
fi

# Not in TMPDIR: probe.test.sh needs a repo outside /private/var/folders, where the probe.sh
# sandbox allows each write.
work="$(mktemp -d "$common/dirigible-hooks-tree.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# git rev-parse --git-path returns GIT_INDEX_FILE when it is set, so read the path of the real
# index before the variable is set for the two commands that use the copy.
real_index="$(git rev-parse --path-format=absolute --git-path index)" || exit 1
cp "$real_index" "$work/index" || exit 1
tree="$(GIT_INDEX_FILE="$work/index" git add -A && GIT_INDEX_FILE="$work/index" git write-tree)" || exit 1

floor="$(scripts/check-changed.sh --floor)" || exit 1
key="$({
    git ls-tree "$tree" | grep -vE $'\t(Sources|Tests|docs|README\\.md)$'
    for f in $floor; do
        if git cat-file -e "$tree:${f%/}" 2>/dev/null; then echo "$f yes"; else echo "$f no"; fi
    done
    printf '%s\n' "$@" | sort
    # Each tool that a hook test or the script under it runs. sw_vers covers the tools of macOS
    # (plutil, osascript, codesign, bc, awk), and xcodebuild those of Xcode (actool).
    for tool in 'swift --version' sw_vers 'xcodebuild -version' 'python3 --version' 'node --version' \
        'git --version' 'make --version' 'jq --version' 'perl --version' 'gh --version'; do
        echo "$tool: $($tool 2>&1 | head -2 | tr '\n' ' ')"
    done
    echo "$today"
} | shasum -a 256 | cut -c1-64)"
if [[ -z $reason ]] && grep -q "^$key " "$stamp" 2>/dev/null; then
    echo "test-hooks: reuse $key"
    exit 0
fi
# The key and the stamp are read: remove the context of the caller before the clone and the tests.
unset BASE FILTER SINCE CHECK_RISK HOOK_TESTS MAKEFLAGS MFLAGS MAKELEVEL GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
for v in $(compgen -v WITH_LOCK_) $(compgen -v DIRIGIBLE_); do unset "$v"; done
# A commit of the key tree, so the checkout has a clean status.
keycommit="$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git commit-tree "$tree" -m key)" || exit 1
git clone -q --shared --no-checkout "$common" "$work/tree" \
    && git -C "$work/tree" sparse-checkout set --no-cone '/*' '!/Sources/' '!/Tests/' '!/docs/' '!/README.md' \
        $(sed 's|^|/|' <<< "$floor") \
    && git -C "$work/tree" checkout -q --detach "$keycommit" || exit 1
cd "$work/tree" || exit 1
# The key holds only the existence of a floor path, so a test that reads floor content fails.
find $floor -type f | while IFS= read -r f; do : > "$f"; done
# A hook test calls bash by name, and the first bash on the PATH can be a newer one than the 3.2
# of macOS. The tests must run on /bin/bash.
mkdir "$work/bin" && ln -s /bin/bash "$work/bin/bash" || exit 1
export PATH="$work/bin:$PATH"

# The output of each test goes to the log of the caller and to a file, so the summary can repeat
# the end of each failed test.
logs="$(mktemp -d)" || exit 1
trap 'rm -rf "$logs" "$work"' EXIT
failed=() n=0
for t in "$@"; do
    n=$((n + 1))
    "$t" 2>&1 | tee "$logs/$n.log" || failed+=("$n")
done
if [[ ${#failed[@]} -gt 0 ]]; then
    names=()
    for n in "${failed[@]}"; do names+=("${!n}"); done
    echo "test-hooks: ${#failed[@]} of $# failed: ${names[*]}"
    for n in "${failed[@]}"; do
        echo "test-hooks: the last 40 lines of ${!n}:"
        tail -n 40 "$logs/$n.log"
    done
    exit 1
fi
if [[ -n $reason ]]; then
    echo "test-hooks: no stamp ($reason)"
else
    # The key holds the date, so only the lines of today can match: drop the others.
    { grep " $today\$" "$stamp" 2>/dev/null; echo "$key $sha $today"; } > "$stamp.new" && mv "$stamp.new" "$stamp"
    echo "test-hooks: wrote $key"
fi
