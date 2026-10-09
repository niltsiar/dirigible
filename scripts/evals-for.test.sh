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

# grade.py packets labels only the scenarios that the reports of the tag hold (the union of their
# kept maps), one label for each run. A run with no answer to an asked scenario gets a label with
# no quotes. stderr names each kept ID that keys.md does not have (then dropped), and each
# scenario of keys.md that no report has.
packets_case() {
  local dir="$tmp/p/$1"
  shift
  mkdir -p "$dir"
  printf '## E1\n(a) k\n\n## H1\n(a) k\n' > "$dir/keys.md"
  local specs=() n=0 report
  for report in "$@"; do
    n=$((n + 1))
    printf '%s\n' "$report" > "$dir/r$n.json"
    specs+=("new:$n:$dir/r$n.json")
  done
  err="$(python3 "$tmp/g/scripts/eval/grade.py" packets "$dir" t 1 1 "${specs[@]}" 2>&1 >/dev/null)"
  code=$?
  rows="$(cut -f4,5,6 "$dir/labels.tsv" 2>/dev/null | sort | paste -sd' ' -)"
}
packets_case only-h1 '{"kept": {"H1": [{"quote": "q1"}]}}' '{"kept": {"H1": [{"quote": "q2"}]}}'
[[ $code -eq 0 && "$rows" == $'H1\tnew\t1 H1\tnew\t2' ]] || fail "packets of two H1 reports: exit $code, rows [$rows]"
[[ "$err" == *E1* ]] || fail "packets of two H1 reports: no warning names E1: [$err]"
packets_case one-empty '{"kept": {"H1": [{"quote": "q1"}]}}' '{"kept": {}}'
[[ $code -eq 0 && "$rows" == $'H1\tnew\t1 H1\tnew\t2' ]] || fail "packets with an empty report: exit $code, rows [$rows]"
grep -qF -- '- (no quotes)' "$tmp/p/one-empty/grade/packet-t-1.md" 2>/dev/null || fail 'packets with an empty report: no answer with no quotes'
packets_case unknown-id '{"kept": {"H1": [{"quote": "q1"}], "E99": [{"quote": "q9"}]}}'
[[ $code -eq 0 && "$rows" == $'H1\tnew\t1' ]] || fail "packets with a kept E99: exit $code, rows [$rows]"
grep -q 'E99' <<<"$err" || fail "packets with a kept E99: no warning names E99: [$err]"

# grade.py verdict <eval> <old set> <new set> prints one line per pass-rule clause of evals.md and
# a last verdict line, and exits 0 on PASS, 1 on FAIL, and 2 for a tag whose old and new sets hold
# different scenarios. sc <tag> <scenario> <type> <set> <passes> <runs> prints scores.tsv rows, and
# verdict_case reads them from $tmp/rows (no pipe: a subshell would lose the failure count).
sc() {
  local i
  for ((i = 1; i <= $6; i++)); do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t\n' "$1" "$2" "$3" "$4" "$i" "$( ((i <= $5)) && echo PASS || echo FAIL)"
  done
}
verdict_case() {
  local name="$1" want="$2"
  shift 2
  mkdir -p "$tmp/v/$name"
  { printf 'tag\tscenario\ttype\tset\trun\tresult\tmissing\n'; cat "$tmp/rows"; } > "$tmp/v/$name/scores.tsv"
  out="$(python3 "$tmp/g/scripts/eval/grade.py" verdict "$tmp/v/$name" old new 2>&1)"
  code=$?
  [[ $code -eq $want ]] || fail "verdict $name: exit $code, want $want: [$out]"
  local line
  for line in "$@"; do grep -qxF -- "$line" <<<"$out" || fail "verdict $name: no line [$line]: [$out]"; done
}
{ sc t E1 retention old 6 6; sc t E1 retention new 6 6; } > "$tmp/rows"; verdict_case retention-pass 0 'retention: old 6, new 6: PASS' 'verdict: PASS'
{ sc t E1 retention old 6 6; sc t E1 retention new 5 6; } > "$tmp/rows"; verdict_case retention-fail 1 'retention: old 6, new 5: FAIL' 'verdict: FAIL'
{ sc t E1 retention old 4 6; sc t E1 retention new 3 6; sc t E5 retention old 0 6; sc t E5 retention new 1 6; } > "$tmp/rows"
verdict_case below-pass 0 'retention: old 4, new 4: PASS' 'below E1: old 4/6, new 3/6: PASS' 'verdict: PASS'
{ sc t E1 retention old 4 6; sc t E1 retention new 2 6; sc t E5 retention old 0 6; sc t E5 retention new 2 6; } > "$tmp/rows"
verdict_case below-fail 1 'retention: old 4, new 4: PASS' 'below E1: old 4/6, new 2/6: FAIL' 'verdict: FAIL'
# Tags pool: two tags of 3 runs give 6 runs, so the below clause is due.
{ sc t E1 retention old 2 3; sc t E1 retention new 2 3; } > "$tmp/rows"; verdict_case below-not-due 0 'below E1: old 2/3, new 2/3: not due'
{ sc t E1 retention old 2 3; sc t E1 retention new 2 3; sc u E1 retention old 2 3; sc u E1 retention new 2 3; } > "$tmp/rows"
verdict_case below-pooled 0 'below E1: old 4/6, new 4/6: PASS'
{ sc t E23 policy old 0 3; sc t E23 policy new 2 3; } > "$tmp/rows"; verdict_case policy-pass 0 'policy E23: new 2/3: PASS' 'verdict: PASS'
{ sc t E23 policy old 0 3; sc t E23 policy new 1 3; } > "$tmp/rows"; verdict_case policy-fail 1 'policy E23: new 1/3: FAIL' 'verdict: FAIL'
{ sc t E1 retention old 3 3; sc t E1 retention new 3 3; sc t H1 retention old 0 3; sc t H1 retention new 0 3; } > "$tmp/rows"
verdict_case void 0 'void H1' 'retention: old 3, new 3: PASS' 'verdict: PASS'
grep -q 'H1:' <<<"$out" && fail "verdict void: a clause line names the void H1: [$out]"
{ sc t E1 retention old 3 3; sc t E1 retention new 3 3; sc t E5 retention new 3 3; } > "$tmp/rows"; verdict_case refused 2
[[ "$out" == *'tag t'* ]] || fail "verdict refused: the message names no tag: [$out]"
# A set with no row (a typo of a set name, an empty scores.tsv) exits 2: else the clauses check
# nothing and print PASS. A policy scenario with no new-set run exits 2 too: its tag holds it only
# in the old set.
{ sc t E1 retention old 3 3; sc t E1 retention neu 3 3; } > "$tmp/rows"; verdict_case no-new-set 2
[[ "$out" == *'set new'* && "$out" != *'verdict: PASS'* ]] || fail "verdict no-new-set: [$out]"
: > "$tmp/rows"; verdict_case empty 2
[[ "$out" == *'set old'* && "$out" != *'verdict: PASS'* ]] || fail "verdict empty: [$out]"
{ sc t E23 policy old 0 3; sc t E1 retention old 3 3; sc t E1 retention new 3 3; } > "$tmp/rows"
verdict_case policy-no-new-run 2
[[ "$out" != *'verdict: PASS'* ]] || fail "verdict policy-no-new-run: [$out]"

[[ $failures -eq 0 ]] && echo "evals-for tests: all passed"
exit $((failures > 0))
