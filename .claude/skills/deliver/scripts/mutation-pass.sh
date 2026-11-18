#!/bin/bash
# Run the mutation pass of a risk: yes run (mutation-controls.md, Run the pass): each mutant of a
# batch file once, under one hold of the build lock.
# Usage: mutation-pass.sh <tree> <batch file>
# - <tree> is the absolute root of the run worktree. The script runs there, because a mutant
#   changes, builds, and tests the tree that it runs in. It refuses the main checkout, a tree with
#   changes, and a tree whose mutate.py lock a live process holds.
# - The batch file (outside the tree, for example in the run folder) has one line for each mutant:
#   `mutant <mutate.py arguments>`, in bash words ($'...' for a line break). The script reads it
#   with a mutant function that writes the arguments of mutant n to <batch file>.schema/<n>
#   (NUL-separated; the script makes the folder again on each run). The lines with --switch go to
#   one `mutate.py --schema` call (one build for all of them). Then each other line, and each line
#   that the schema call gives `own build`, runs one mutate.py call, in batch order, after the line
#   `<n>: own build: <reason>`. A mutant whose baseline failed does not run again: its reason line
#   counts as other. The batch has only mutant lines, comments, and blank lines.
# - The batch has the line `# head: <sha>`, the HEAD where its writer proved each killer. When HEAD
#   of the tree is another commit, `git diff --name-only <sha> HEAD` decides: a file under Tests/ or
#   Sources/, or a file of a mutant line, makes the script exit 2 before the lock, with the files;
#   else it prints the new head and runs. A missing head line, or a head that the repo does not
#   have, is also exit 2.
# - The script runs again under scripts/with-lock.sh of the tree once, so the lock calls of each
#   build and test command run at once, and no other run builds between two mutants. No sleep
#   between two mutants.
# - Each mutant prints `<n>: <result line>`; a switch mutant with no line of a refused schema call
#   (exit 2) prints `<n>: mutate: no result`. A mutate.py exit 3 (a failed restore: a mutant can be
#   in the tree) or 130 (stopped) stops the batch with that exit. The last two lines are
#   `schema: S mutants in one build; R with its own build` and
#   `pass: N mutants; killed K; survived S; other O` (other: BUILD FAILED, WRONG FAILURE, NO TESTS,
#   or a mutate.py refusal, which need a decision). After a SIGKILL, the refusal of the tree with
#   changes names <batch file>.schema/orig.tsv, the list of the files to restore.
# - Stop a pass with `pkill -TERM -f "mutation-pass.sh <tree>"` (a background job ignores INT;
#   <tree> is the absolute root: the pattern matches only it). On INT or TERM the script waits
#   for the running mutate.py, which restores its file, and stops the batch with exit 130; the
#   background job, with-lock.sh, exits 143. The line `stopped after mutant <n> (mutate.py exit 3)` means a failed restore.
#   A TERM to the process group (with-lock.sh) reaches mutate.py at once; after 1 s the script
#   sends mutate.py a TERM of its own, so a signal to the script alone stops it too. The wait of
#   1 s keeps a second signal out of the restore of mutate.py.
# mutation-pass.test.sh tests it.
set -uo pipefail
[[ $# -eq 2 ]] || { echo "usage: mutation-pass.sh <tree> <batch file>" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
mutate="$here/mutate.py"
batch="$(cd "$(dirname "$2")" 2>/dev/null && pwd)/$(basename "$2")"
[[ -f "$batch" ]] || { echo "mutation-pass: no batch file $2" >&2; exit 2; }
# The script reads the whole batch before the first mutant, so another line would run once at the start.
other="$(grep -nvE '^[[:space:]]*(mutant[[:space:]]|#|$)' "$batch" | head -1)"
[[ -z "$other" ]] || { echo "mutation-pass: $batch has a line that is not a mutant, a comment, or a blank line: line ${other/:/: }" >&2; exit 2; }
top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" && [[ "$top" == "$(cd "$1" && pwd -P)" ]] ||
    { echo "mutation-pass: $1 is not the root of a worktree" >&2; exit 2; }
common="$(git -C "$top" rev-parse --path-format=absolute --git-common-dir)"
[[ "$(dirname "$common")" != "$top" ]] || { echo "mutation-pass: $1 is the main checkout; run the pass in the worktree of the run" >&2; exit 2; }
schema="$batch.schema"
if [[ -n "$(git -C "$top" status --porcelain)" ]]; then
    if [[ -f "$schema/orig.tsv" ]]; then
        echo "mutation-pass: $top has changes, and a pass did not restore its files; the tree was clean at the start: run git diff, then git restore the listed paths of $schema/orig.tsv" >&2
    else
        echo "mutation-pass: $top has changes; commit them, or wait for the pass that runs there" >&2
    fi
    exit 2
fi
lock="$(git -C "$top" rev-parse --absolute-git-dir)/dirigible-mutate.lock"
[[ -d "$lock" ]] && kill -0 "$(cat "$lock/pid" 2>/dev/null)" 2>/dev/null &&
    { echo "mutation-pass: a mutate.py run holds $lock; wait for it to end" >&2; exit 2; }
head="$(sed -n 's/^# head: \([0-9a-f]\{7,40\}\)[[:space:]]*$/\1/p' "$batch" | head -1)"
[[ -n "$head" ]] || { echo "mutation-pass: $batch has no head line (# head: <sha>); write the batch again at HEAD" >&2; exit 2; }
changed="$(git -C "$top" diff --name-only "$head" HEAD -- 2>/dev/null)" ||
    { echo "mutation-pass: head $head not found: write the batch again at HEAD" >&2; exit 2; }
if [[ -n "$changed" ]]; then
    stale=""
    while IFS= read -r f; do
        case "$f" in
            Tests/* | Sources/*) stale+="$f"$'\n' ;;
            *) ! grep -E '^[[:space:]]*mutant[[:space:]]' "$batch" | grep -qF -- "$f" || stale+="$f"$'\n' ;;
        esac
    done <<<"$changed"
    [[ -z "$stale" ]] || { echo "mutation-pass: $batch was written at $head, and these files changed since; write the batch again at HEAD:" >&2; printf '%s' "$stale" >&2; exit 2; }
    [[ -n "${MUTATION_PASS_HELD:-}" ]] || echo "mutation-pass: head is now $(git -C "$top" rev-parse HEAD); no Tests/, Sources/, or mutant file changed since $head"
fi
cd "$top" || exit 2
# One lock hold for the batch: run again under with-lock.sh once.
[[ -n "${MUTATION_PASS_HELD:-}" ]] || MUTATION_PASS_HELD=1 exec "$top/scripts/with-lock.sh" "$here/mutation-pass.sh" "$top" "$batch"

rm -rf "$schema" && mkdir "$schema" || exit 2
n=0 killed=0 survived=0 other=0 one=0 own=0 stop="" switch=() results=() reasons=()
trap 'stop=1' INT TERM
output="$(mktemp)"
trap 'rm -f "$output"' EXIT
count() {
    echo "schema: $one mutants in one build; $own with its own build"
    echo "pass: $n mutants; killed $killed; survived $survived; other $other"
}
# mutant <mutate.py arguments>: one batch line. It keeps the arguments, and the number of a --switch line.
mutant() {
    local i=1
    n=$((n + 1))
    printf '%s\0' "$@" > "$schema/$n"
    while [[ "${!i:-}" =~ ^--(expect|timeout|switch)$ ]]; do
        [[ "${!i}" != --switch ]] || { switch+=("$n"); break; }
        i=$((i + 2))
    done
}
# call <mutate.py arguments>: runs mutate.py, sets code, and stops it on INT or TERM.
call() {
    local child again
    python3 -I "$mutate" "$@" > "$output" 2>&1 &
    child=$!
    wait "$child"
    code=$?
    if [[ -n "$stop" ]]; then
        sleep 1
        ! kill -0 "$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null
        wait "$child" 2>/dev/null
        again=$?
        [[ $again -eq 127 ]] || code=$again
        [[ $code -eq 3 ]] || code=130
    fi
}
tally() {
    echo "$1: $2"
    case "$2" in
        killed*) killed=$((killed + 1)) ;;
        survived*) survived=$((survived + 1)) ;;
        *) other=$((other + 1)) ;;
    esac
}
# shellcheck source=/dev/null
source "$batch"
total=$n n=0
if [[ ${#switch[@]} -gt 0 ]]; then
    call --schema "$schema" "${switch[@]}"
    if [[ $code -eq 3 || $code -eq 130 ]]; then
        echo "mutation-pass: stopped after the schema call (mutate.py exit $code)"
        count
        exit "$code"
    fi
    for m in "${switch[@]}"; do
        line="$(grep -m1 "^$m " "$output")"
        line="${line#"$m "}"
        case "$line" in
            # A kill needs a passing baseline, so this mutant does not run again: it counts as other.
            'own build: the baseline failed'*) results[m]="$line" ;;
            'own build:'*) reasons[m]="$line" ;;
            '') results[m]='mutate: no result' ;;
            mutate:*) results[m]="$line" ;;
            *) results[m]="$line" one=$((one + 1)) ;;
        esac
    done
fi
for ((m = 1; m <= total; m++)); do
    [[ -z "$stop" ]] || { echo "mutation-pass: stopped before mutant $m"; count; exit 130; }
    n=$m
    if [[ -n "${results[m]:-}" ]]; then
        tally "$m" "${results[m]}"
        continue
    fi
    [[ -z "${reasons[m]:-}" ]] || echo "$m: ${reasons[m]}"
    args=()
    while IFS= read -r -d '' a; do args+=("$a"); done < "$schema/$m"
    call "${args[@]}"
    own=$((own + 1))
    tally "$m" "$(grep -m1 -E '^(killed|survived|BUILD FAILED|WRONG FAILURE|NO TESTS|stopped|mutate:)' "$output" || tail -1 "$output")"
    if [[ $code -eq 3 || $code -eq 130 ]]; then
        echo "mutation-pass: stopped after mutant $m (mutate.py exit $code)"
        count
        exit "$code"
    fi
done
count
