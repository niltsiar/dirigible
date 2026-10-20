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

# --quoted omits a holdout of the void list of evals.md (the line `- Void list: <IDs>.`).
rm -rf "$tmp/r"
mkdir -p "$tmp/r/docs/workflow"
g init -q -b main
{
  printf '## How the eval runs\n\n- Void list: H1, H13. They fail on both sets.\n\n## Scenarios\n\n'
  for h in H1 H3 H13; do printf '| %s | retention | s | q | (a) k (holdout). | `a.md` | - | - |\n' "$h"; done
} > "$tmp/r/docs/workflow/evals.md"
printf 'One line.\n' > "$tmp/r/a.md"
g add -A
g commit -q -m base
g switch -q -c feat/x
printf 'Another line.\n' > "$tmp/r/a.md"
g commit -q -am change
got="$(run --quoted main)" || fail "--quoted void list: exit $?"
[[ "$got" == H3 ]] || fail "--quoted void list: got [$(tr '\n' ' ' <<<"$got")], want [H3]"

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
# A 5-word run is one of a single key point: text inserted between the words of two key points,
# which each stay whole, is no cut.
g reset -q --hard
printf '## Scenarios\n\n| E2 | policy | s | q | (a) Read the run files. (b) Start no build or test. | `b.md` | - | - |\n' > "$tmp/r/docs/workflow/evals.md"
printf 'Read the run files. Start no build or test.\n' > "$tmp/r/b.md"
g add -A
g commit -q -m points
printf 'Read the run files and the built files. Start a fix later. Start no build or test.\n' > "$tmp/r/b.md"
g add -A
got="$(run --staged)" || fail "--staged, an insertion between two key points: exit $?, got [$got]"
printf 'Read the run files. Start a build or test.\n' > "$tmp/r/b.md"
g add -A
got="$(run --staged)" && fail "--staged, a cut inside one key point: exit 0"
[[ "$got" == 'E2 b.md: start no build or test' ]] || fail "--staged, a cut inside one key point: got [$got]"

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
for f in build-copy.sh quote-check.py pointed-missing.py grade.py run.sh; do
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
# A verdict with no holdout fail leaves an empty holdout-fails.txt: check-governance.sh reads it as "this run ran the verdict".
[[ -f "$tmp/v/retention-pass/holdout-fails.txt" && ! -s "$tmp/v/retention-pass/holdout-fails.txt" ]] || fail 'verdict retention-pass: holdout-fails.txt is missing or not empty'
# The retention sum fails only when old minus new is over 2 x sqrt(sum of k x p x (1 - p)), k the
# runs of both sets and p the pooled pass rate. five <new passes of E1 to E5>: old 6/6 each.
five() { local i=0 n; for n in "$@"; do i=$((i + 1)); sc t "E$i" retention old 6 6; sc t "E$i" retention new "$n" 6; done > "$tmp/rows"; }
five 6 6 5 5 5; verdict_case retention-in-bound 0 'retention: old 30, new 27, bound 3.3: PASS' 'verdict: PASS'
five 4 4 4 4 4; verdict_case retention-past-bound 1 'retention: old 30, new 20, bound 5.8: FAIL' 'verdict: FAIL'
five 4 5 6 6 6; verdict_case retention-one-below 1 'retention: old 30, new 27, bound 3.2: PASS' 'below E1: old 6/6, new 4/6: FAIL' 'verdict: FAIL'
# A fail of holdouts only (a below line, or a retention sum that passes with no holdout) prints one
# holdout fail line for each such H and does not fail the verdict. An E fail still fails. The verdict
# writes the same lines to holdout-fails.txt in the eval folder (check-governance.sh reads it).
{ sc t E1 retention old 6 6; sc t E1 retention new 6 6; sc t H6 retention old 6 6; sc t H6 retention new 4 6; } > "$tmp/rows"
verdict_case holdout-below 0 'below H6: old 6/6, new 4/6: FAIL' 'holdout fail H6: no changed text' 'verdict: PASS'
[[ "$(cat "$tmp/v/holdout-below/holdout-fails.txt" 2>&1)" == 'holdout fail H6: no changed text' ]] ||
  fail "verdict holdout-below: holdout-fails.txt does not hold the fail line: [$(cat "$tmp/v/holdout-below/holdout-fails.txt" 2>&1)]"
{ sc t E1 retention old 6 6; sc t E1 retention new 6 6; sc t H6 retention old 6 6; sc t H6 retention new 0 6; } > "$tmp/rows"
verdict_case holdout-sum 0 'retention: old 12, new 6, bound 3.5: FAIL' 'holdout fail H6: no changed text' 'verdict: PASS'
[[ "$(cat "$tmp/v/holdout-sum/holdout-fails.txt" 2>&1)" == 'holdout fail H6: no changed text' ]] ||
  fail "verdict holdout-sum: holdout-fails.txt does not hold one fail line: [$(cat "$tmp/v/holdout-sum/holdout-fails.txt" 2>&1)]"
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
# run.sh runs a whole doc eval with a fake claude first on PATH. The fake copies the probed
# behavior of the real call: exit 1 with text on stdout for a failing call, exit 0 with no file for
# a model that did not write, and one JSON object with --output-format json. It appends one JSON
# line to $FAKE_LOG for each call. FAKE_MODE is exit1:<s-r>, nofile:<s-r>, or badjson:<s-r> for
# the answer session of one set and run, or agent_error. FAKE_GRADE=FAIL makes the grader fail each
# key point. FAKE_SLEEP=<seconds> makes each other call sleep.
run_sh="$eval_dir/run.sh"
fake="$tmp/fakebin"
mkdir -p "$fake"
cat > "$fake/claude" <<'EOF'
#!/usr/bin/env python3
import json, os, re, sys, time
args = sys.argv[1:]
prompt = args[args.index("-p") + 1]
mode = os.environ.get("FAKE_MODE", "")
kind = "agent" if "--output-format" in args else "grader" if "blind grader" in prompt else "answer"
entry = {"kind": kind, "cwd": os.path.realpath(os.getcwd()), "argv": ["<prompt>" if a == prompt else a for a in args],
         "claude_tmp": os.environ.get("CLAUDE_CODE_TMPDIR", ""), "tmp": os.environ.get("TMPDIR", "")}
if kind == "agent":
    entry["prompt"] = prompt
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(json.dumps(entry) + "\n")
target = ""
if kind == "answer":
    out = re.search(r"Write your answer file to: (\S+)", prompt).group(1)
    target = re.search(r"run-(\w-\d)\.json", out).group(1)
hit = target != "" and mode.partition(":")[2] == target
if os.environ.get("FAKE_SLEEP") and not hit and mode != "agent_error":
    time.sleep(float(os.environ["FAKE_SLEEP"]))
if kind == "answer":
    if hit and mode.startswith("exit1"):
        print("Error: fake failure")
        sys.exit(1)
    if hit and mode.startswith("nofile"):
        print("done")
        sys.exit(0)
    if hit and mode.startswith("badjson"):
        open(out, "w").write("{not json")
        print("done")
        sys.exit(0)
    docs = re.search(r"read only files under it\): (\S+)", prompt).group(1)
    questions = open(re.search(r"Questions: (\S+)", prompt).group(1)).read()
    quote = open(docs + "/AGENTS.md").readline().strip()
    chain = [{"path": "AGENTS.md", "from": None, "pointer": None},
             {"path": ".claude/skills/deliver/SKILL.md", "from": None, "pointer": None}]
    ids = re.findall(r"^([EH]\d+): ", questions, re.M)
    json.dump({"chain": chain, "answers": [{"id": i, "steps": [{"quote": quote, "path": "AGENTS.md"}]} for i in ids]}, open(out, "w"))
    print("2 files, %d answers" % len(ids))
elif kind == "grader":
    packet = re.search(r"Read only this file: (\S+)", prompt).group(1)
    result = re.search(r"Write one JSON file to (\S+),", prompt).group(1)
    word = os.environ.get("FAKE_GRADE", "PASS")
    rows, keys = [], []
    for line in open(packet):
        if line.startswith("## Scenario"):
            keys = []
        m = re.match(r"- \(([a-z])\) ", line)
        if m:
            keys.append(m.group(1))
        m = re.match(r"### Answer (\w+)", line)
        if m:
            rows += [{"label": m.group(1), "key": "(%s)" % k, "result": word, "reason": "fake"} for k in keys]
    json.dump(rows, open(result, "w"))
    print(len(rows))
else:
    here = os.path.realpath(os.getcwd())
    if not os.path.exists("AGENTS.md") or not os.path.exists("scripts/eval/concurrency-review-snippet.txt"):
        print(json.dumps({"is_error": True, "result": "the run folder holds no copy of the docs"}))
        sys.exit(1)
    if not os.path.realpath(os.environ.get("CLAUDE_CODE_TMPDIR", "/")).startswith(here + "/") \
            or not os.path.realpath(os.environ.get("TMPDIR", "/")).startswith(here + "/"):
        print(json.dumps({"is_error": True, "result": "the temp folders are not inside the run folder"}))
        sys.exit(1)
    if mode == "agent_error":
        print(json.dumps({"type": "result", "is_error": True, "result": "fake failure"}))
        sys.exit(1)
    print(json.dumps({"type": "result", "is_error": False, "result": "The review flags the F_FULLFSYNC call.\nIt is file I/O on the main actor."}))
EOF
chmod +x "$fake/claude"
head_commit="$(git -C "$repo" rev-parse HEAD)"
# eval_env <name>: a new eval folder with two small doc sets and finished builds, keyed to HEAD.
eval_env() {
  local d="$tmp/e/$1" s
  mkdir -p "$d/logs"
  for s in a b; do
    mkdir -p "$d/docs-$s/.claude/skills/deliver" "$d/docs-$s/scripts/eval"
    printf 'Fake AGENTS.md of set %s.\nSecond line.\n' "$s" > "$d/docs-$s/AGENTS.md"
    printf 'The deliver skill.\n' > "$d/docs-$s/.claude/skills/deliver/SKILL.md"
    cp "$eval_dir/concurrency-review-snippet.txt" "$d/docs-$s/scripts/eval/"
    printf 'byte check end\n' > "$d/logs/build-$s.log"
    printf '%s\n' "$head_commit" > "$d/logs/build-$s.commit"
  done
  printf '%s\n' "$d"
}
# runner <args>: run.sh with the fake claude; sets out and code.
runner() {
  : > "$tmp/fake.log"
  out="$(PATH="$fake:$PATH" FAKE_LOG="$tmp/fake.log" "$run_sh" "$@" 2>&1)"
  code=$?
}
calls() { grep -c -- "$1" "$tmp/fake.log"; }
no_fake_left() { ! pgrep -f "$fake/claude" > /dev/null; }
if [[ ! -x "$run_sh" ]]; then
  fail 'scripts/eval/run.sh is missing'
else
  e="$(eval_env e2e)"
  runner "$e" HEAD HEAD E2,E5 t1
  [[ $code -eq 0 && "$out" == *'verdict: PASS'* ]] || fail "run.sh end to end: exit $code: $out"
  [[ "$(ls "$e"/answer-t1/run-*.json 2>/dev/null | wc -l)" -eq 6 && "$(ls "$e"/answer-t1/kept-*.json 2>/dev/null | wc -l)" -eq 6 ]] \
    || fail 'run.sh end to end: not 6 answer files and 6 kept files'
  [[ "$(wc -l < "$e/labels.tsv")" -eq 12 && "$(tail -n +2 "$e/scores.tsv" | wc -l)" -eq 12 ]] || fail 'run.sh end to end: not 12 labels and 12 scores'
  [[ -f "$e/holdout-fails.txt" && ! -s "$e/holdout-fails.txt" ]] || fail 'run.sh end to end: holdout-fails.txt is missing or not empty'
  # Every call has Read and Write only, no Bash; answers use sonnet, graders opus (min(4, 2) packets).
  [[ "$(calls '"kind": "answer"')" -eq 6 && "$(calls '"kind": "grader"')" -eq 2 ]] || fail "run.sh calls: $(cat "$tmp/fake.log")"
  [[ "$(calls '"--tools", "Read,Write", "--allowedTools", "Read", "Write"')" -eq 8 ]] || fail 'run.sh: a call has other tools than Read and Write'
  [[ "$(calls Bash)" -eq 0 ]] || fail 'run.sh: a call names Bash'
  [[ "$(calls '"kind": "answer".*"--model", "sonnet"')" -eq 6 && "$(calls '"kind": "grader".*"--model", "opus"')" -eq 2 ]] || fail 'run.sh: wrong models'
  # Each session starts in a folder outside the checkout and the eval folder (the CLAUDE.md of a
  # checkout would load), and the folder is gone at the end.
  while IFS= read -r wd; do
    case "$wd" in "$repo"/* | "$e"/*) fail "run.sh: a session started in $wd" ;; esac
    [[ "$(basename "$wd")" == dirigible-eval-* && ! -e "$wd" ]] || fail "run.sh: working folder $wd is not a temporary folder that is removed"
  done < <(python3 -I -c 'import json, sys; [print(json.loads(l)["cwd"]) for l in open(sys.argv[1])]' "$tmp/fake.log")
  # A failing grader fails the policy scenario.
  e="$(eval_env e2e-fail)"
  FAKE_GRADE=FAIL runner "$e" HEAD HEAD E2,E5 t1
  [[ $code -eq 1 && "$out" == *'verdict: FAIL'* && "$out" == *'policy E2: new 0/3: FAIL'* ]] || fail "run.sh with a failing grader: exit $code: $out"
  # ANSWER_MODEL changes the answer calls only.
  e="$(eval_env model)"
  RUNS=1 ANSWER_MODEL=haiku runner "$e" HEAD HEAD E2 t1
  [[ $code -eq 0 && "$(calls '"kind": "answer".*"--model", "haiku"')" -eq 2 && "$(calls '"kind": "grader".*"--model", "opus"')" -eq 1 ]] \
    || fail "run.sh with ANSWER_MODEL=haiku: exit $code: $(cat "$tmp/fake.log")"

  # keys.md holds each Key points cell of the table, which this test reads on its own.
  e="$(eval_env keys)"
  printf '## E99\nstale\n' > "$e/keys.md"
  runner "$e" HEAD HEAD E2,E5 t1
  for id in E2 E5; do
    want="$(awk -F'|' -v id=" $id " '$2 == id && NF > 8 { gsub(/^ +| +$/, "", $6); print $6 }' "$repo/docs/workflow/evals.md")"
    got="$(awk -v id="## $id" '$0 == id { getline; print }' "$e/keys.md")"
    [[ -n "$want" && "$got" == "$want" ]] || fail "run.sh keys.md: $id is [$got], want [$want]"
  done
  [[ "$(grep -c '^## ' "$e/keys.md")" -eq 2 ]] || fail 'run.sh keys.md: a stale section stays'
  [[ "$(cat "$e/answer-t1/prompt-a-1.md")" != *'Shell note'* ]] || fail 'prompt has a shell note'

  # A failed session or check stops the run before grading.
  for spec in "exit1:b-2|prompt-b-2|exit 1" "nofile:b-2|run-b-2.json|run-b-2.json" "badjson:b-2|quote check|run-b-2.json"; do
    mode="${spec%%|*}"
    rest="${spec#*|}"
    e="$(eval_env "fail-${mode%%:*}")"
    FAKE_MODE="$mode" runner "$e" HEAD HEAD E2,E5 t1
    [[ $code -eq 3 && "$out" == *"${rest%%|*}"* && "$out" == *"${rest#*|}"* ]] || fail "run.sh $mode: exit $code, want 3 with [${rest%%|*}] and [${rest#*|}]: $out"
    [[ ! -e "$e/scores.tsv" && "$(calls '"kind": "grader"')" -eq 0 ]] || fail "run.sh $mode: grading started"
  done
  # An answer folder that holds a file is refused before any session.
  e="$(eval_env stale)"
  mkdir -p "$e/answer-t1"
  printf '{}\n' > "$e/answer-t1/run-b-2.json"
  FAKE_MODE=nofile:b-2 runner "$e" HEAD HEAD E2,E5 t1
  [[ $code -eq 2 && "$out" == *answer-t1* && ! -s "$tmp/fake.log" ]] || fail "run.sh with an answer file: exit $code: $out"
  # No claude on PATH: exit 2 and the message names the command.
  if PATH=/usr/bin:/bin command -v claude > /dev/null; then
    echo 'skip: claude is in /usr/bin or /bin'
  else
    e="$(eval_env noclaude)"
    out="$(PATH=/usr/bin:/bin "$run_sh" "$e" HEAD HEAD E2 t1 2>&1)"
    code=$?
    [[ $code -eq 2 && "$out" == *claude* ]] || fail "run.sh with no claude: exit $code: $out"
  fi
  # A failed session stops the sessions that still run, and a TERM stops them all.
  e="$(eval_env killfail)"
  SECONDS=0
  FAKE_SLEEP=60 FAKE_MODE=exit1:b-2 runner "$e" HEAD HEAD E2 t1
  [[ $code -eq 3 && $SECONDS -lt 40 ]] || fail "run.sh with a failed session: exit $code after $SECONDS s"
  no_fake_left || { pkill -f "$fake/claude"; fail 'run.sh with a failed session: a session still runs'; }
  e="$(eval_env killterm)"
  : > "$tmp/fake.log"
  PATH="$fake:$PATH" FAKE_LOG="$tmp/fake.log" FAKE_SLEEP=60 "$run_sh" "$e" HEAD HEAD E2 t1 > /dev/null 2>&1 &
  pid=$!
  for _ in $(seq 100); do [[ "$(calls '"kind": "answer"')" -eq 6 ]] && break; sleep 0.2; done
  kill -TERM "$pid"
  wait "$pid"
  no_fake_left || { pkill -f "$fake/claude"; fail 'run.sh after TERM: a session still runs'; }

  # A holdout key comes from a --holdout-keys file (the table holds none). Without the file, the
  # run exits 2 before any session. A second file fills an ID that the first lacks.
  printf '## E2\n(a) not used\n\n## H5\n(a) x.\n' > "$tmp/hold1.md"
  printf '## H6\n(a) Hold one. (b) Hold two. (c) Hold three.\n' > "$tmp/hold2.md"
  e="$(eval_env holdout)"
  runner "$e" HEAD HEAD E2,H6 t2 --holdout-keys "$tmp/hold1.md" --holdout-keys "$tmp/hold2.md"
  [[ $code -eq 0 && -f "$e/holdout-fails.txt" ]] || fail "run.sh holdout: exit $code: $out"
  [[ "$(awk '$0 == "## H6" { getline; print }' "$e/keys.md")" == '(a) Hold one. (b) Hold two. (c) Hold three.' ]] || fail "run.sh holdout: keys.md has no H6 line of the file: $(cat "$e/keys.md")"
  [[ "$(awk '$0 == "## E2" { getline; print }' "$e/keys.md")" != '(a) not used' ]] || fail 'run.sh holdout: E2 got its key from the holdout file'
  [[ "$(awk '/^## Scenario H6/ { on = 1 } /^### Answer/ { on = 0 } on && /^- \([a-z]\) /' "$e"/grade/packet-t2-*.md | wc -l)" -eq 3 ]] || fail 'run.sh holdout: the packet of H6 does not list 3 key points'
  e="$(eval_env holdout-none)"
  runner "$e" HEAD HEAD E2,H6 t2
  [[ $code -eq 2 && "$out" == *H6* && ! -s "$tmp/fake.log" ]] || fail "run.sh holdout with no file: exit $code: $out"
  runner "$e" HEAD HEAD E2,H6 t2 --holdout-keys "$tmp/hold1.md"
  [[ $code -eq 2 && "$out" == *H6* && ! -s "$tmp/fake.log" ]] || fail "run.sh holdout with a file that lacks H6: exit $code: $out"

  # An agent row with a quoted prompt and no task in agent-tasks.sh (E41) runs RUNS sessions in a
  # copy of set b, inside probe.sh, with the temp folders in the run folder, and is scored in
  # agent/ only. E38 has no prompt: it runs through agent-tasks.sh.
  e="$(eval_env agent)"
  runner "$e" HEAD HEAD E41 t3
  want="$(awk -F'|' '$2 == " E41 " && NF > 8 { print $5 }' "$repo/docs/workflow/evals.md" | sed -n 's/.*with the prompt: "\([^"]*\)".*/\1/p')"
  [[ $code -eq 0 && "$(calls '"kind": "agent"')" -eq 3 && "$(calls '"kind": "answer"')" -eq 0 ]] || fail "run.sh agent row: exit $code: $out"
  [[ -n "$want" && "$(python3 -I -c 'import json, sys
want = sys.argv[1]
for line in open(sys.argv[2]):
    e = json.loads(line)
    if e["kind"] != "agent":
        continue
    a = e["argv"]
    ok = e["prompt"] == want and a[a.index("--tools") + 1:a.index("--tools") + 2] == ["Skill,Read"] \
        and a[a.index("--allowedTools") + 1:a.index("--allowedTools") + 3] == ["Skill", "Read"] \
        and a[a.index("--output-format") + 1] == "json" and a[a.index("--model") + 1] == "sonnet" \
        and e["claude_tmp"].startswith(e["cwd"] + "/") and e["tmp"].startswith(e["cwd"] + "/") \
        and e["cwd"].split("/")[-1].startswith("dirigible-eval-agent-")
    print("ok" if ok else "bad " + line)' "$want" "$tmp/fake.log" | sort | uniq -c)" == '   3 ok' ]] || fail "run.sh agent row: a call has other arguments than the row says: $(cat "$tmp/fake.log")"
  [[ "$(tail -n +2 "$e/agent/scores.tsv" 2>/dev/null | cut -f2 | uniq -c)" == '   3 E41' && "$(grep -c '^t3	E41' <<<"$out")" -eq 3 ]] || fail "run.sh agent row: not 3 score rows of E41: $out"
  [[ ! -e "$e/scores.tsv" ]] || fail 'run.sh agent row: the doc scores.tsv exists'
  ! grep -qE 'of [0-9]+ runs|In each run' "$e/agent/keys.md" || fail "run.sh agent row: agent/keys.md holds a run count: $(cat "$e/agent/keys.md")"
  while IFS= read -r wd; do [[ ! -e "$wd" ]] || fail "run.sh agent row: run folder $wd is not removed"; done < <(python3 -I -c 'import json, sys; [print(json.loads(l)["cwd"]) for l in open(sys.argv[1])]' "$tmp/fake.log")
  e="$(eval_env agent-error)"
  FAKE_MODE=agent_error runner "$e" HEAD HEAD E41 t3
  [[ $code -eq 3 && "$out" == *E41-* ]] || fail "run.sh agent row with is_error: exit $code: $out"
  e="$(eval_env agent-e38)"
  runner "$e" HEAD HEAD E38 t3
  [[ $code -eq 2 && "$out" == *agent-tasks.sh* && ! -s "$tmp/fake.log" ]] || fail "run.sh E38: exit $code: $out"

  # The build branch for real: a stamp keys each docs copy to its commit, and a second commit into
  # the same folder is refused (the copies would be those of the first commit).
  mkdir -p "$tmp/t/real"
  e="$tmp/t/real/eval"
  TMPDIR="$tmp/t" runner "$e" HEAD HEAD E2 t1
  [[ $code -eq 0 && "$(cat "$e/logs/build-a.commit" "$e/logs/build-b.commit" 2>/dev/null | sort -u)" == "$head_commit" ]] \
    || fail "run.sh build: exit $code, stamp [$(cat "$e"/logs/build-*.commit 2>/dev/null)]: $out"
  other="$(git -C "$repo" rev-parse HEAD~1 2>/dev/null || true)"
  if [[ -n "$other" ]]; then
    TMPDIR="$tmp/t" runner "$e" HEAD~1 HEAD~1 E2 t2
    [[ $code -eq 2 && "$out" == *"$e/docs-a"* && "$out" == *"$other"* ]] || fail "run.sh build with another commit: exit $code: $out"
  fi
fi
# prompt-template.md offers no shell: no mv and no shell note, and a line names the tools.
[[ "$(grep -cw -e mv -e 'Shell note' "$eval_dir/prompt-template.md")" -eq 0 ]] || fail 'prompt-template.md offers a shell'
grep -qF 'Your tools are Read and Write. You have no shell.' "$eval_dir/prompt-template.md" || fail 'prompt-template.md does not name the tools'
# No local path in the runner or in this test (the patterns are split so this file does not hold them).
[[ "$(grep -cE -e '/Use''rs/' -e '\.scratchpads/ru''ns' "$run_sh" "$repo/scripts/evals-for.test.sh" 2>/dev/null | awk -F: '{ n += $2 } END { print n + 0 }')" -eq 0 ]] \
  || fail 'the runner or its test holds a local path'

[[ $failures -eq 0 ]] && echo "evals-for tests: all passed"
exit $((failures > 0))
