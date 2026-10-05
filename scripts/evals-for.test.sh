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
got="$(run --quoted does-not-exist 2>/dev/null)" && fail '--quoted with a bad base exits 0'
[[ -z "$got" ]] || fail "--quoted with a bad base prints [$got]"

# --quoted prints a scenario with a changed Files cell only when a key point quotes the changed
# words of a hunk of such a file, it is a holdout, or the base lacks it. A quoted term has 8 or
# more characters, matches as a whole term, and is not in the stop list.
rm -rf "$tmp/r"
mkdir -p "$tmp/r/docs/workflow"
g init -q -b main
scenarios() {
  cat <<'EOF'
# Evals

## Scenarios

| ID | Type | Source | Question | Key points | Files | Old | New |
|---|---|---|---|---|---|---|---|
| E1 | retention | s | q | (a) Stop the replays first (`pkill -INT -f mutate.py`). | `a.md` | - | - |
| E2 | retention | s | q | (a) Keep `unchanged-term` as it is. | `a.md` | - | - |
| E3 | retention | s | q | (a) `plan.md`, `decisions.tsv`, and `short`. | `a.md` | - | - |
| E4 | retention | s | q | (a) Run `make check`. | `b.md` | - | - |
| E5 | policy | s | q | (a) Set the absolute limit beside the relative budget. | `b.md` | - | - |
| E7 | retention | s | q | (a) `untracked-term`. | `c.md` | - | - |
| H1 | retention | s | q | In the run folder (holdout). | `a.md` | - | - |
EOF
}
scenarios > "$tmp/r/docs/workflow/evals.md"
printf 'Run `pkill -INT -f mutate.py` to stop.\nKeep `unchanged-term` here.\n' > "$tmp/r/a.md"
printf 'b\n' > "$tmp/r/b.md"
g add -A
g commit -q -m base
g switch -q -c feat/x
{ scenarios; echo '| E6 | policy | s | q | (a) Nothing in a changed line. | `b.md` | - | - |'; } > "$tmp/r/docs/workflow/evals.md"
printf 'Keep `unchanged-term` here.\nSee short, then decisions.tsv and plan.md.\n' > "$tmp/r/a.md"
g commit -q -am change
printf 'b\nRun make check-changed now.\nWrite the absolute limit beside the relative budget.\n' > "$tmp/r/b.md"
printf 'An `untracked-term` line.\n' > "$tmp/r/c.md"
got="$(run --quoted main)" || fail "--quoted: exit $?"
[[ "$got" == $'E1\nE5\nE7\nH1\nE6' ]] || fail "--quoted: got [$(tr '\n' ' ' <<<"$got")], want [E1 E5 E7 H1 E6]"
got="$(run main)" || fail "no --quoted: exit $?"
[[ "$got" == $'E1\nE2\nE3\nE4\nE5\nE7\nH1\nE6' ]] || fail "no --quoted: got [$(tr '\n' ' ' <<<"$got")]"

# --quoted matches a key point only against the words that differ between the deleted and the
# added lines of one hunk: a clause that stays the same on a changed line does not count. A
# paragraph that moves to another hunk counts as changed.
rm -rf "$tmp/r"
mkdir -p "$tmp/r/docs/workflow"
g init -q -b main
cat > "$tmp/r/docs/workflow/evals.md" <<'EOF'
# Evals

## Scenarios

| ID | Type | Source | Question | Key points | Files | Old | New |
|---|---|---|---|---|---|---|---|
| E1 | retention | s | q | (a) Wait for a quiet machine before the bench. | `a.md` | - | - |
| E2 | retention | s | q | (a) Stop the replays first with `pkill -INT -f mutate.py`. | `a.md` | - | - |
| E3 | retention | s | q | (a) Log each default in the decisions file. | `b.md` | - | - |
| E4 | retention | s | q | (a) Keep `moved-term-x` in place. | `b.md` | - | - |
EOF
printf 'Wait for a calm machine before the bench, and stop the replays first with `pkill -INT -f mutate.py`.\n' > "$tmp/r/a.md"
printf 'Log each default in the decisions file.\nKeep `moved-term-x` here.\nOne.\nTwo.\nThree.\n' > "$tmp/r/b.md"
g add -A
g commit -q -m base
g switch -q -c feat/x
printf 'Wait for a quiet machine before the bench, and stop the replays first with `pkill -INT -f mutate.py`.\n' > "$tmp/r/a.md"
printf 'One.\nTwo.\nThree.\nLog each default in the decisions file.\nKeep `moved-term-x` here.\n' > "$tmp/r/b.md"
g commit -q -am change
got="$(run --quoted main)" || fail "--quoted changed words: exit $?"
[[ "$got" == $'E1\nE3\nE4' ]] || fail "--quoted changed words: got [$(tr '\n' ' ' <<<"$got")], want [E1 E3 E4]"

# A word added next to a quoted rule changes it: a negation before it, a qualifier after it.
rm -rf "$tmp/r"
mkdir -p "$tmp/r/docs/workflow"
g init -q -b main
cat > "$tmp/r/docs/workflow/evals.md" <<'EOF'
# Evals

## Scenarios

| ID | Type | Source | Question | Key points | Files | Old | New |
|---|---|---|---|---|---|---|---|
| E1 | retention | s | q | (a) Stop the replays first with the stop flag. | `a.md` | - | - |
| E2 | retention | s | q | (a) Log each default in the decisions file. | `a.md` | - | - |
EOF
printf 'Stop the replays first with the stop flag.\nLog each default in the decisions file.\n' > "$tmp/r/a.md"
g add -A
g commit -q -m base
g switch -q -c feat/x
printf 'Never stop the replays first with the stop flag.\nLog each default in the decisions file only for a product run.\n' > "$tmp/r/a.md"
g commit -q -am change
got="$(run --quoted main)" || fail "--quoted added words: exit $?"
[[ "$got" == $'E1\nE2' ]] || fail "--quoted added words: got [$(tr '\n' ' ' <<<"$got")], want [E1 E2]"

# The eval runner of scripts/eval/. The run files (keys.md, labels.tsv) stay in the eval folder of
# the run, never in the runner folder.
eval_dir="$repo/scripts/eval"
for f in build-copy.sh quote-check.py pointed-missing.py grade.py; do
  [[ -f "$eval_dir/$f" ]] || fail "scripts/eval/$f is missing"
done
for f in keys.md labels.tsv; do [[ ! -e "$eval_dir/$f" ]] || fail "scripts/eval/$f is a run file"; done

# build-copy.sh refuses a copy folder outside .scratchpads/ and $TMPDIR, and a folder that holds
# files, before it changes anything.
copy_refused() {
  local name="$1" dir="$2" reason="$3" err code
  err="$(cd "$tmp/r" && TMPDIR="$tmp/t" "$eval_dir/build-copy.sh" HEAD "$dir" "$tmp/copy.log" 2>&1)"
  code=$?
  [[ $code -eq 2 ]] || fail "$name: exit $code, not 2"
  [[ "$err" == *"$reason"* ]] || fail "$name: no '$reason' in the message: $err"
}
mkdir -p "$tmp/t/full"
printf 'keep\n' > "$tmp/t/full/marker"
copy_refused 'a folder outside' "$tmp/outside/copy" 'outside .scratchpads/ and TMPDIR'
[[ ! -e "$tmp/outside" ]] || fail 'a folder outside: the folder was made'
copy_refused 'a folder with ..' "$tmp/t/../outside" 'outside .scratchpads/ and TMPDIR'
copy_refused 'a folder that holds files' "$tmp/t/full" 'holds files'
[[ "$(cat "$tmp/t/full/marker" 2>/dev/null)" == keep ]] || fail 'a folder that holds files: the marker file changed'
[[ ! -e "$tmp/copy.log" ]] || fail 'a refused copy wrote its log'

# grade.py takes each Type from the Scenarios table of docs/workflow/evals.md of its tree, and
# writes scores.tsv in the eval folder that the call names.
mkdir -p "$tmp/g/scripts/eval" "$tmp/g/docs/workflow" "$tmp/g/run"
cp "$eval_dir/grade.py" "$tmp/g/scripts/eval/"
printf '## Scenarios\n\n| ID | Type | Source | Question | Key points | Files | Old | New |\n|---|---|---|---|---|---|---|---|\n| E1 | retention | s | q | (a) k | `a.md` | - | - |\n| E23 | policy | s | q | (a) k | `a.md` | - | - |\n' > "$tmp/g/docs/workflow/evals.md"
printf '## E1\n(a) k\n\n## E23\n(a) k\n' > "$tmp/g/run/keys.md"
printf 'L1\tt\t1\tE1\tnew\t1\nL2\tt\t1\tE23\tnew\t1\n' > "$tmp/g/run/labels.tsv"
printf '[{"label": "L1", "key": "(a)", "result": "PASS"}, {"label": "L2", "key": "(a)", "result": "PASS"}]\n' > "$tmp/g/res.json"
python3 "$tmp/g/scripts/eval/grade.py" score "$tmp/g/run" t "$tmp/g/res.json" > /dev/null || fail "grade.py score: exit $?"
[[ "$(cut -f2,3 "$tmp/g/run/scores.tsv" 2>/dev/null | tail -n 2)" == $'E1\tretention\nE23\tpolicy' ]] \
  || fail "grade.py types: got [$(cat "$tmp/g/run/scores.tsv" 2>/dev/null)]"
[[ ! -e "$tmp/g/scripts/eval/scores.tsv" ]] || fail 'grade.py wrote scores.tsv in the runner folder'
# A tag that scores.tsv or labels.tsv already holds is refused (exit 2), and no file changes: a
# second append would count the answers twice.
before="$(shasum -a 256 "$tmp/g/run/scores.tsv" "$tmp/g/run/labels.tsv")"
err="$(python3 "$tmp/g/scripts/eval/grade.py" score "$tmp/g/run" t "$tmp/g/res.json" 2>&1 >/dev/null)"
code=$?
[[ $code -eq 2 && "$err" == *"tag t"* ]] || fail "grade.py score with a used tag: exit $code: $err"
err="$(python3 "$tmp/g/scripts/eval/grade.py" packets "$tmp/g/run" t 1 1 2>&1 >/dev/null)"
code=$?
[[ $code -eq 2 && "$err" == *"tag t"* ]] || fail "grade.py packets with a used tag: exit $code: $err"
[[ "$(shasum -a 256 "$tmp/g/run/scores.tsv" "$tmp/g/run/labels.tsv")" == "$before" ]] || fail 'grade.py with a used tag changed a file'

[[ $failures -eq 0 ]] && echo "evals-for tests: all passed"
exit $((failures > 0))
