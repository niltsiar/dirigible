#!/bin/bash
# Check that evals-for.sh prints the IDs of the Scenarios rows whose Files cell names a changed
# file (a commit since the base, a working tree change, or an untracked file), ignores a row of
# another section, prints nothing for no change, and fails closed on a bad base.
# Run by `make test-hooks`.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo/scripts/evals-for.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
g() { git -C "$tmp/r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

mkdir -p "$tmp/r/docs/workflow"
g init -q -b main
cat > "$tmp/r/docs/workflow/evals.md" <<'EOF'
# Evals

## Result

| E9 | 0 of 3 | `a.md` |

## Scenarios

| ID | Type | Source | Question | Key points | Files | Old | New |
|---|---|---|---|---|---|---|---|
| E1 | policy | s | q | k | `a.md` | - | - |
| E2 | policy | s | q with a \| bar | k | `b.md`, `c.md` | - | - |
| H1 | retention | s | q | In the run folder (holdout). | `a.md`, `d.md` | 1 of 3 | - |
EOF
printf 'a\n' > "$tmp/r/a.md"
g add -A
g commit -q -m base
g switch -q -c feat/x

run() { (cd "$tmp/r" && "$script" "$@"); }

got="$(run main)" || fail "no change: exit $?"
[[ -z "$got" ]] || fail "no change: got [$got]"

printf 'a2\n' > "$tmp/r/a.md"
g commit -q -am a
got="$(run main)" || fail "a committed change: exit $?"
[[ "$got" == $'E1\nH1' ]] || fail "a committed change: got [$got], want [E1 H1]"

printf 'c\n' > "$tmp/r/c.md"
got="$(run main)" || fail "an untracked file: exit $?"
[[ "$got" == $'E1\nE2\nH1' ]] || fail "an untracked file: got [$got], want [E1 E2 H1]"

got="$(run does-not-exist 2>/dev/null)" && fail 'a bad base exits 0'
[[ -z "$got" ]] || fail "a bad base prints [$got]"

[[ $failures -eq 0 ]] && echo "evals-for tests: all passed"
exit $((failures > 0))
