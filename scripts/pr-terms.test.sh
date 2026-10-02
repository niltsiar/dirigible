#!/bin/bash
# Check that pr-terms.sh lists each run-internal token of a PR body with its line and exits 1,
# and passes each token that the repo resolves. Each case uses a temporary git repo with one
# fixture row each in brief.md, evals.md, and rules.tsv, and one commit. Run by `make test-hooks`.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/pr-terms.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

repo="$tmp/repo"
mkdir -p "$repo/docs/requirements" "$repo/docs/workflow"
git init -q "$repo"
printf '| ID | Requirement |\n|---|---|\n| R13 | The UI is in English and Spanish. |\n| C1 | The DMG is not notarized. |\n' > "$repo/docs/requirements/brief.md"
printf '| ID | Type |\n|---|---|\n| E4 | policy |\n' > "$repo/docs/workflow/evals.md"
printf 'id\tfile\tverdict\nAGT-001\tAGENTS.md\tkeep\n' > "$repo/docs/workflow/rules.tsv"
git -C "$repo" add -A
git -C "$repo" commit -q -m fixture
hash="$(git -C "$repo" rev-parse --short=7 HEAD)"
full="$(git -C "$repo" rev-parse HEAD)"

# flag <case> <token>: a body with the token on line 2 makes the script print the token, its
# line, and its reason, and exit 1.
flag() {
    printf 'The run is done.\nThe fix of %s holds.\n' "$2" > "$repo/body.md"
    out="$(cd "$repo" && "$script" body.md 2>&1)"
    code=$?
    [[ $code -eq 1 && "$out" == *"pr-terms: body.md:2: $3: $4"* ]] || fail "$1: exit $code: $out"
}

# pass <case> <token>: a body with the token prints nothing and exits 0.
pass() {
    printf 'The run is done.\nThe fix of %s holds.\n' "$2" > "$repo/body.md"
    out="$(cd "$repo" && "$script" body.md 2>&1)"
    code=$?
    [[ $code -eq 0 && -z "$out" ]] || fail "$1: exit $code: $out"
}

flag 'a run-internal ID' 'U3' 'U3' 'run-internal ID'
flag 'an ID in a code span' '`U3`' 'U3' 'run-internal ID'
flag 'an ID with a letter' 'G12c' 'G12c' 'run-internal ID'
flag 'a C-ID, also with a row in the brief' 'C1' 'C1' 'run-internal ID'
pass 'an R-number with a row in the brief' 'R13'
pass 'an eval ID with a row in evals.md' 'E4'
flag 'an eval ID with no row' 'E99' 'E99' 'run-internal ID'
flag 'a cause key' 'INT-054/scope' 'INT-054/scope' 'cause key'
flag 'a new cause key' 'NEW-VER-x' 'NEW-VER-x' 'cause key'
flag 'a rule ID with no row' 'AGT-099' 'AGT-099' 'run-internal ID'
pass 'a rule ID with a row in rules.tsv' 'AGT-001'
flag 'a commit hash' "$hash" "$hash" 'commit hash'
flag 'a commit hash in parentheses' "(see $hash)" "$hash" 'commit hash'
flag 'a full commit hash' "$full" "$full" 'commit hash'
pass 'a hex word that is not a commit' 'deadbee'

# No lookup files: nothing resolves.
bare="$tmp/bare"
git init -q "$bare"
printf 'See R13.\n' > "$bare/body.md"
out="$(cd "$bare" && "$script" body.md 2>&1)"
code=$?
[[ $code -eq 1 && "$out" == *"pr-terms: body.md:1: R13: run-internal ID"* ]] || fail "no lookup files: exit $code: $out"

# An error exits 2: a missing body file, a bad argument.
out="$(cd "$repo" && "$script" missing.md 2>&1)"
code=$?
[[ $code -eq 2 && "$out" == *"no file missing.md"* ]] || fail "a missing body file: exit $code: $out"
mkdir "$tmp/nogit"
printf 'See U3.\n' > "$tmp/nogit/body.md"
out="$(cd "$tmp/nogit" && "$script" body.md 2>&1)"
code=$?
[[ $code -eq 2 && "$out" == *"not in a git repo"* ]] || fail "a folder outside git: exit $code: $out"
out="$(cd "$repo" && "$script" a b 2>&1)"
code=$?
[[ $code -eq 2 && "$out" == usage:* ]] || fail "two file arguments: exit $code: $out"

[[ $failures -eq 0 ]] && echo "pr-terms tests: all passed"
exit $((failures > 0))
