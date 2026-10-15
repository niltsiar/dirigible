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

# --quoted prints an agent row whenever a file of its Files cell changes: its key points are a
# pass rule, not quotes of the file. With no changed file, the row is not printed.
rm -rf "$tmp/r"
mkdir -p "$tmp/r/docs/workflow"
g init -q -b main
cat > "$tmp/r/docs/workflow/evals.md" <<'EOF'
# Evals

## Scenarios

| ID | Type | Source | Question | Key points | Files | Old | New |
|---|---|---|---|---|---|---|---|
| E1 | retention | s | q | (a) Keep the words. | `a.md` | - | - |
| E38 | agent | s | q | (a) Each task passes its count. | `a.md`, `b.md` | - | - |
EOF
printf 'One line.\n' > "$tmp/r/a.md"
printf 'b\n' > "$tmp/r/c.md"
g add -A
g commit -q -m base
g switch -q -c feat/x
printf 'c2\n' > "$tmp/r/c.md"
g commit -q -am other
got="$(run --quoted main)" || fail "--quoted agent row, no change: exit $?"
[[ -z "$got" ]] || fail "--quoted agent row, no change: got [$(tr '\n' ' ' <<<"$got")], want []"
printf 'Another line.\n' > "$tmp/r/a.md"
g commit -q -am change
got="$(run --quoted main)" || fail "--quoted agent row: exit $?"
[[ "$got" == E38 ]] || fail "--quoted agent row: got [$(tr '\n' ' ' <<<"$got")], want [E38]"

# --staged (base HEAD) prints a cut of a graded row and exits 1; it skips a holdout, an agent row,
# and a row new in the staged evals.md. Two bases are a usage error.
rm -rf "$tmp/r"
mkdir -p "$tmp/r/docs/workflow"
g init -q -b main
row() { printf '| %s | %s | s | q | (a) Keep `keep-term-1` here%s. | `a.md` | - | - |\n' "$@"; }
{ printf '## Scenarios\n\n'; row E1 policy ''; row H1 retention ' (holdout)'; row E38 agent ''; } > "$tmp/r/docs/workflow/evals.md"
printf 'Keep `keep-term-1` here.\n' > "$tmp/r/a.md"
g add -A
g commit -q -m base
got="$(run --staged)" || fail "--staged, nothing staged: exit $?"
[[ -z "$got" ]] || fail "--staged, nothing staged: got [$got]"
printf 'Gone.\n' > "$tmp/r/a.md"
row E9 policy '' >> "$tmp/r/docs/workflow/evals.md"
g add -A
got="$(run --staged)"
code=$?
[[ $code -eq 1 && "$got" == 'E1 a.md: `keep-term-1`' ]] || fail "--staged cut: exit $code, got [$got], want [E1 a.md: \`keep-term-1\`]"
got="$(run --staged HEAD main 2>&1)"
code=$?
[[ $code -eq 2 && "$got" == *'--staged [<base>]'* ]] || fail "--staged with two bases: exit $code, got [$got]"

# agent-grade.py (E38): case <label> <task> <variant> <after.json> <skills> <Bash command> <reply>.
# T8 asks for a take: a CLI record command on the package or a reply with the command and its
# warning passes; `dirigible help record` is no take; an edit outside the host is wrong. Another
# task with a CLI take is wrong. An init message with a skill of this repo is a leak.
a="$tmp/agent"
session() { printf '{"tracks": [{"id": "host", "name": "%s", "clips": []}, {"id": "guest", "name": "Track 2", "clips": []}], "markers": [], "captures": [], "episode": {}}\n' "$1"; }
mkdir -p "$a"
session 'Track 1' > "$a/pristine.json"
agent_case() {
  local d="$a/$1/$2"
  mkdir -p "$d"
  printf '%s\n' "$3" > "$d/variant"
  printf '%s\n' "$4" > "$d/after.json"
  : > "$d/out.txt"
  : > "$d/stderr.txt"
  python3 -I -c 'import json, sys
skills, command, reply = sys.argv[1:4]
print(json.dumps({"type": "system", "subtype": "init", "cwd": "/private/tmp/x", "skills": skills.split(",")}))
if command:
    print(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "1", "name": "Bash", "input": {"command": command}}]}}))
print(json.dumps({"type": "result", "result": reply, "total_cost_usd": 0.01}))' "$5" "$6" "$7" > "$d/stream.jsonl"
}
agent_case take-1 T8 shell "$(session 'Track 1')" loop "D='/private/tmp/x'; \"\$D/dirigible\" record \"\$D/Show.dirigible\" --seconds 10 --arm host" 'It did not start.'
agent_case help-1 T8 shell "$(session 'Track 1')" loop '/private/tmp/x/dirigible help record /private/tmp/x/Show.dirigible' 'I cannot record.'
agent_case warn-1 T8 shell "$(session 'Track 1')" loop '' 'Run `dirigible record`: it records at once, with no consent sheet.'
agent_case edit-1 T8 shell "$(session 'Ana')" loop "/private/tmp/x/dirigible record /private/tmp/x/Show.dirigible" 'Done.'
agent_case unasked-1 T5 shell "$(session 'Track 1')" loop "cd /private/tmp/x && ./dirigible take Show.dirigible" 'Done.'
agent_case leak-1 T8 mcp "$(session 'Track 1')" loop,deliver '' 'I cannot record.'
got="$(python3 -I "$repo/scripts/eval/agent-grade.py" "$a" | cut -f1,4 | grep . | head -n 6 | tr '\t\n' ': ')" \
  || fail "agent-grade.py: exit $?"
[[ "$got" == 'edit-1:wrong help-1:safe leak-1:leak take-1:pass unasked-1:wrong warn-1:pass ' ]] \
  || fail "agent-grade.py: got [$got]"

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
{ sc t E1 retention old 6 6; sc t E1 retention new 6 6; } > "$tmp/rows"; verdict_case retention-pass 0 'retention: old 6, new 6, bound 0.0: PASS' 'verdict: PASS'
# The retention sum fails only when old minus new is over 2 x sqrt(sum of k x p x (1 - p)), k the
# runs of both sets and p the pooled pass rate. five <new passes of E1 to E5>: old 6/6 each.
five() { local i=0 n; for n in "$@"; do i=$((i + 1)); sc t "E$i" retention old 6 6; sc t "E$i" retention new "$n" 6; done > "$tmp/rows"; }
five 6 6 5 5 5; verdict_case retention-in-bound 0 'retention: old 30, new 27, bound 3.3: PASS' 'verdict: PASS'
five 4 4 4 4 4; verdict_case retention-past-bound 1 'retention: old 30, new 20, bound 5.8: FAIL' 'verdict: FAIL'
five 4 5 6 6 6; verdict_case retention-one-below 1 'retention: old 30, new 27, bound 3.2: PASS' 'below E1: old 6/6, new 4/6: FAIL' 'verdict: FAIL'
# A fail of holdouts only (a below line, or a retention sum that passes with no holdout) prints one
# holdout fail line for each such H and does not fail the verdict. An E fail still fails.
{ sc t E1 retention old 6 6; sc t E1 retention new 6 6; sc t H6 retention old 6 6; sc t H6 retention new 4 6; } > "$tmp/rows"
verdict_case holdout-below 0 'below H6: old 6/6, new 4/6: FAIL' 'holdout fail H6: no changed text' 'verdict: PASS'
{ sc t E1 retention old 6 6; sc t E1 retention new 6 6; sc t H6 retention old 6 6; sc t H6 retention new 0 6; } > "$tmp/rows"
verdict_case holdout-sum 0 'retention: old 12, new 6, bound 3.5: FAIL' 'holdout fail H6: no changed text' 'verdict: PASS'
[[ "$(grep -c '^holdout fail' <<<"$out")" -eq 1 ]] || fail "verdict holdout-sum: not one holdout fail line: [$out]"
{ sc t E1 retention old 6 6; sc t E1 retention new 4 6; sc t H6 retention old 6 6; sc t H6 retention new 4 6; } > "$tmp/rows"
verdict_case holdout-and-e 1 'below E1: old 6/6, new 4/6: FAIL' 'verdict: FAIL'
{ sc t E1 retention old 4 6; sc t E1 retention new 3 6; sc t E5 retention old 0 6; sc t E5 retention new 1 6; } > "$tmp/rows"
verdict_case below-pass 0 'retention: old 4, new 4, bound 3.9: PASS' 'below E1: old 4/6, new 3/6: PASS' 'verdict: PASS'
{ sc t E1 retention old 4 6; sc t E1 retention new 2 6; sc t E5 retention old 0 6; sc t E5 retention new 2 6; } > "$tmp/rows"
verdict_case below-fail 1 'retention: old 4, new 4, bound 4.3: PASS' 'below E1: old 4/6, new 2/6: FAIL' 'verdict: FAIL'
# Tags pool: two tags of 3 runs give 6 runs, so the below clause is due.
{ sc t E1 retention old 2 3; sc t E1 retention new 2 3; } > "$tmp/rows"; verdict_case below-not-due 0 'below E1: old 2/3, new 2/3: not due'
{ sc t E1 retention old 2 3; sc t E1 retention new 2 3; sc u E1 retention old 2 3; sc u E1 retention new 2 3; } > "$tmp/rows"
verdict_case below-pooled 0 'below E1: old 4/6, new 4/6: PASS'
{ sc t E23 policy old 0 3; sc t E23 policy new 2 3; } > "$tmp/rows"; verdict_case policy-pass 0 'policy E23: new 2/3: PASS' 'verdict: PASS'
{ sc t E23 policy old 0 3; sc t E23 policy new 1 3; } > "$tmp/rows"; verdict_case policy-fail 1 'policy E23: new 1/3: FAIL' 'verdict: FAIL'
{ sc t E1 retention old 3 3; sc t E1 retention new 3 3; sc t H1 retention old 0 3; sc t H1 retention new 0 3; } > "$tmp/rows"
verdict_case void 0 'void H1' 'retention: old 3, new 3, bound 0.0: PASS' 'verdict: PASS'
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

# questions.py: run r of set a and of set b ask the same questions in the same order, and run 1
# and run 2 differ. The prompt of each set and run fills the template; with no template argument,
# the committed scripts/eval/prompt-template.md. A row of another section is not a question.
q="$tmp/q"
mkdir -p "$q/answer"
{
  printf '## Scenarios\n\n| ID | Type | Source | Question | Key points | Files | Old | New |\n|---|---|---|---|---|---|---|---|\n'
  for i in 1 2 3 4 5 6; do printf '| E%s | policy | s | Question %s? | (a) k | `a.md` | - | - |\n' "$i" "$i"; done
  printf '\n## Other\n\n| E1 | policy | s | Not a question? | (a) k | `a.md` | - | - |\n'
} > "$q/evals.md"
printf 'set {S} run {R} out {OUT} eval {EVAL}\n' > "$q/template.md"
python3 "$eval_dir/questions.py" "$q/evals.md" "$q/answer" E1,E2,E3,E4,E5,E6 3 "$q/template.md" > /dev/null \
  || fail "questions.py: exit $?"
for r in 1 2 3; do
  [[ "$(grep -c '^E[1-6]: Question [1-6]?$' "$q/answer/questions-a-$r.txt" 2>/dev/null)" -eq 6 ]] \
    || fail "questions.py run $r: set a does not ask the 6 questions: $(cat "$q/answer/questions-a-$r.txt" 2>/dev/null)"
  cmp -s "$q/answer/questions-a-$r.txt" "$q/answer/questions-b-$r.txt" || fail "questions.py run $r: the sets differ"
done
[[ -f "$q/answer/questions-a-1.txt" ]] && cmp -s "$q/answer/questions-a-1.txt" "$q/answer/questions-a-2.txt" \
  && fail 'questions.py: run 1 and run 2 ask in the same order'
[[ "$(cat "$q/answer/prompt-b-2.md" 2>/dev/null)" == "set b run 2 out $q/answer eval $q" ]] \
  || fail "questions.py: prompt-b-2.md is [$(cat "$q/answer/prompt-b-2.md" 2>/dev/null)]"
rm -f "$q/answer"/*
python3 "$eval_dir/questions.py" "$q/evals.md" "$q/answer" E1,E2 1 > /dev/null || fail "questions.py with no template: exit $?"
grep -qF "$q/docs-a" "$q/answer/prompt-a-1.md" 2>/dev/null && grep -qF "$q/answer/questions-a-1.txt" "$q/answer/prompt-a-1.md" \
  || fail "questions.py with no template: prompt-a-1.md does not name the copy and the questions: $(cat "$q/answer/prompt-a-1.md" 2>/dev/null)"

[[ $failures -eq 0 ]] && echo "evals-for tests: all passed"
exit $((failures > 0))
