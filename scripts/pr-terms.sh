#!/bin/bash
# List the tokens of a PR body that a reader cannot look up (the writing-for-humans skill).
# land.sh runs it on the body before the land, and refuses the body on exit 1.
# Usage: scripts/pr-terms.sh <file>
# It reads prose, code spans, and fenced blocks, and prints one line for each token:
#   pr-terms: <file>:<line>: <token>: <reason>
# The reasons:
# - run-internal ID: a short ID (`U3`, `G12c`, `C1`) or a rule ID (`AGT-099`) that the repo does
#   not resolve. An R-number resolves with a row in docs/requirements/brief.md, an E or H ID with
#   a row in docs/workflow/evals.md, and a rule ID with a row in docs/workflow/rules.tsv. A C-ID
#   never resolves: run criteria and the brief constraints use the same IDs. A missing lookup
#   file resolves nothing.
# - cause key: `ABC-123/word` or `NEW-<class>-<word>`.
# - commit hash: a hex token of 7 to 40 characters that `git cat-file` finds as a commit, also in
#   parentheses. The land rebase gives each commit a new hash, so the body says the change in
#   words.
# The repo is the git top folder of the working folder.
# Exit 0 when it prints nothing, 1 when it prints a token, 2 on an error (a missing file, a bad
# argument, no git repo). scripts/pr-terms.test.sh tests it.
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: scripts/pr-terms.sh <file>" >&2; exit 2; }
body="$1"
[[ -f "$body" ]] || { echo "pr-terms: no file $body" >&2; exit 2; }
root="$(git rev-parse --show-toplevel 2> /dev/null)" || { echo "pr-terms: not in a git repo" >&2; exit 2; }
brief="$root/docs/requirements/brief.md"
evals="$root/docs/workflow/evals.md"
rules="$root/docs/workflow/rules.tsv"

# row <file> <id>: the file has a table row for the ID.
row() { [[ -f "$1" ]] && grep -qE "^\| *$2 *\|" "$1"; }

found=0
say() { echo "pr-terms: $body:$1: $2: $3"; found=1; }

while IFS=: read -r ln tok; do
    case "$tok" in
        R*) row "$brief" "$tok" && continue ;;
        E* | H*) row "$evals" "$tok" && continue ;;
    esac
    say "$ln" "$tok" "run-internal ID"
done < <(grep -noE '\b[A-Z][0-9]+[a-z]?\b' "$body" || true)

while IFS=: read -r ln tok; do
    case "$tok" in
        */* | NEW-*) say "$ln" "$tok" "cause key" ;;
        *) [[ -f "$rules" ]] && grep -q "^$tok"$'\t' "$rules" || say "$ln" "$tok" "run-internal ID" ;;
    esac
done < <(grep -noE '\b[A-Z]{2,4}-[0-9]{3}\b(/[a-z]+)?|\bNEW-[A-Za-z]+-[A-Za-z-]+' "$body" || true)

while IFS=: read -r ln tok; do
    if git -C "$root" cat-file -e "$tok^{commit}" 2> /dev/null; then say "$ln" "$tok" "commit hash"; fi
done < <(grep -noE '\b[0-9a-f]{7,40}\b' "$body" || true)
exit "$found"
