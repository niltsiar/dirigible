#!/bin/bash
# Run the mutation pass of a risk: yes run (mutation-controls.md, Run the pass): each mutant of a
# batch file once, under one hold of the build lock.
# Usage: mutation-pass.sh <tree> <batch file>
# - <tree> is the absolute root of the run worktree. The script runs there, because a mutant
#   changes, builds, and tests the tree that it runs in. It refuses the main checkout, a tree with
#   changes, and a tree whose mutate.py lock a live process holds.
# - The batch file (outside the tree, for example in the run folder) has one line for each mutant:
#   `mutant <mutate.py arguments>`, in bash words ($'...' for a line break). The script reads it
#   with a mutant function that runs mutate.py once.
# - The script runs again under scripts/with-lock.sh of the tree once, so the lock calls of each
#   build and test command run at once, and no other run builds between two mutants. No sleep.
# - Each mutant prints `<n>: <result line>`. A mutate.py exit 3 (a failed restore: a mutant can be
#   in the tree) or 130 (stopped) stops the batch with that exit. The last line is
#   `pass: N mutants; killed K; survived S; other O` (other: BUILD FAILED, WRONG FAILURE, NO TESTS,
#   or a mutate.py refusal, which need a decision).
# mutation-pass.test.sh tests it.
set -uo pipefail
[[ $# -eq 2 ]] || { echo "usage: mutation-pass.sh <tree> <batch file>" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
mutate="$here/mutate.py"
batch="$(cd "$(dirname "$2")" 2>/dev/null && pwd)/$(basename "$2")"
[[ -f "$batch" ]] || { echo "mutation-pass: no batch file $2" >&2; exit 2; }
top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" && [[ "$top" == "$(cd "$1" && pwd -P)" ]] ||
    { echo "mutation-pass: $1 is not the root of a worktree" >&2; exit 2; }
common="$(git -C "$top" rev-parse --path-format=absolute --git-common-dir)"
[[ "$(dirname "$common")" != "$top" ]] || { echo "mutation-pass: $1 is the main checkout; run the pass in the worktree of the run" >&2; exit 2; }
[[ -z "$(git -C "$top" status --porcelain)" ]] ||
    { echo "mutation-pass: $top has changes; commit them, or wait for the pass that runs there" >&2; exit 2; }
lock="$(git -C "$top" rev-parse --absolute-git-dir)/dirigible-mutate.lock"
[[ -d "$lock" ]] && kill -0 "$(cat "$lock/pid" 2>/dev/null)" 2>/dev/null &&
    { echo "mutation-pass: a mutate.py run holds $lock; wait for it to end" >&2; exit 2; }
cd "$top" || exit 2
# One lock hold for the batch: run again under with-lock.sh once.
[[ -n "${MUTATION_PASS_HELD:-}" ]] || MUTATION_PASS_HELD=1 exec "$top/scripts/with-lock.sh" "$here/mutation-pass.sh" "$top" "$batch"

n=0 killed=0 survived=0 other=0
count() { echo "pass: $n mutants; killed $killed; survived $survived; other $other"; }
mutant() {
    local result code line
    n=$((n + 1))
    result="$(python3 -I "$mutate" "$@" 2>&1)"
    code=$?
    line="$(grep -m1 -E '^(killed|survived|BUILD FAILED|WRONG FAILURE|NO TESTS|stopped|mutate:)' <<<"$result" || tail -1 <<<"$result")"
    echo "$n: $line"
    case "$line" in
        killed*) killed=$((killed + 1)) ;;
        survived*) survived=$((survived + 1)) ;;
        *) other=$((other + 1)) ;;
    esac
    if [[ $code -eq 3 || $code -eq 130 ]]; then
        echo "mutation-pass: stopped after mutant $n (mutate.py exit $code)"
        count
        exit "$code"
    fi
}
# shellcheck source=/dev/null
source "$batch"
count
