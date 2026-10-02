#!/bin/bash
# List the tokens of a PR body that a reader cannot look up (the writing-for-humans skill).
# land.sh runs it on the body before the land, and refuses the body on exit 1.
# Usage: scripts/pr-terms.sh <file>
#        scripts/pr-terms.sh --lost <original> <revision>
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
# With --lost, it prints `pr-terms: <revision>: lost number: <n>` for each number of the
# original that the revision does not have. It first removes the tokens above from both files,
# so a removed ID or hash loses no number. It compares sets: "3 of 3" to "0 of 3" loses nothing.
# The repo is the git top folder of the working folder.
# Exit 0 when it prints nothing, 1 when it prints a line, 2 on an error (a missing file, a bad
# argument, no git repo). scripts/pr-terms.test.sh tests it.
set -euo pipefail
usage="usage: scripts/pr-terms.sh <file> | --lost <original> <revision>"
if [[ "${1:-}" == --lost ]]; then
    [[ $# -eq 3 ]] || { echo "$usage" >&2; exit 2; }
    files=("$2" "$3")
else
    [[ $# -eq 1 ]] || { echo "$usage" >&2; exit 2; }
    files=("$1")
fi
for f in "${files[@]}"; do
    [[ -f "$f" ]] || { echo "pr-terms: no file $f" >&2; exit 2; }
done
root="$(git rev-parse --show-toplevel 2> /dev/null)" || { echo "pr-terms: not in a git repo" >&2; exit 2; }
brief="$root/docs/requirements/brief.md"
evals="$root/docs/workflow/evals.md"
rules="$root/docs/workflow/rules.tsv"

# row <file> <id>: the file has a table row for the ID.
row() { [[ -f "$1" ]] && grep -qE "^\| *$2 *\|" "$1"; }

# scan <file>: one line for each token that a reader cannot look up.
scan() {
    local body="$1" ln tok
    while IFS=: read -r ln tok; do
        case "$tok" in
            R*) row "$brief" "$tok" && continue ;;
            E* | H*) row "$evals" "$tok" && continue ;;
        esac
        echo "pr-terms: $body:$ln: $tok: run-internal ID"
    done < <(grep -noE '\b[A-Z][0-9]+[a-z]?\b' "$body" || true)

    while IFS=: read -r ln tok; do
        case "$tok" in
            */* | NEW-*) echo "pr-terms: $body:$ln: $tok: cause key" ;;
            *) [[ -f "$rules" ]] && grep -q "^$tok"$'\t' "$rules" || echo "pr-terms: $body:$ln: $tok: run-internal ID" ;;
        esac
    done < <(grep -noE '\b[A-Z]{2,4}-[0-9]{3}\b(/[a-z]+)?|\bNEW-[A-Za-z]+-[A-Za-z-]+' "$body" || true)

    while IFS=: read -r ln tok; do
        if git -C "$root" cat-file -e "$tok^{commit}" 2> /dev/null; then echo "pr-terms: $body:$ln: $tok: commit hash"; fi
    done < <(grep -noE '\b[0-9a-f]{7,40}\b' "$body" || true)
}

# numbers <file>: the numbers of the file, once each, after the flagged tokens are removed. A
# digit run glued to a letter (`k6`, `R13`) is part of a name, not a number.
numbers() {
    local toks
    toks="$(scan "$1" | awk -F': ' '{ print length($3) "\t" $3 }' | sort -rn | cut -f2)"
    TOKS="$toks" awk '
        BEGIN { n = split(ENVIRON["TOKS"], tok, "\n") }
        {
            for (i = 1; i <= n; i++)
                if (tok[i] != "")
                    while ((p = index($0, tok[i])) > 0) $0 = substr($0, 1, p - 1) " " substr($0, p + length(tok[i]))
            print
        }' "$1" | { grep -oE '(^|[^0-9A-Za-z_.])[0-9]+(\.[0-9]+)?' || true; } | sed -E 's/^[^0-9]//' | sort -u
}

if [[ "${1:-}" == --lost ]]; then
    old="$(numbers "$2")"
    new="$(numbers "$3")"
    out="$(comm -23 <(echo "$old") <(echo "$new") | sed '/^$/d' | sed "s|^|pr-terms: $3: lost number: |")"
else
    out="$(scan "$1")"
fi
[[ -z "$out" ]] && exit 0
echo "$out"
exit 1
