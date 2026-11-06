#!/bin/bash
# Check that log-decision.sh appends one row of six tab-separated columns from a five-line file
# (--from), changes a tab in a field to a space, refuses a file with four lines and appends
# nothing, keeps the six-argument form, and refuses a row whose decision or result starts with
# default and whose why has no `Reverse:` (any case), and refuses a phase that is not one digit.
# Check that a criterion change row needs a criterion whose text in analysis.md differs from its text at
# the last row for that ID (criteria-logged.tsv), and the words old and new. Check
# that the first phase 4 row of a run folder with a plan.md needs a passing scripts/check-plan.sh
# (a Criteria: field for each plan gate change, and a criterion change row for each ID).
# Check that a row that claims a test result on the red tree or the old tree needs an existing file
# of the logs/ folder of the run in its evidence.
# Check that a phase 6 row needs a graded eval key for each evals.md row that the branch adds or re-keys.
# Check that new-run.sh reads the wiki: it reports the later count, the size of the next list, the
# upkeep items, and a due architecture audit, opens a run with one log row, refuses a third
# non-feature run in a row with no --blocks-feature reason, and refuses to open a run with no wiki.
# Run by `make test-hooks`.
set -uo pipefail
log="$(cd "$(dirname "$0")" && pwd)/log-decision.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
run="$tmp/run"
mkdir "$run"
: > "$run/decisions.tsv"

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# The last row has six columns, a ts from the clock, and the expected fields.
check_row() {
  local name="$1" want="$2" row
  row="$(tail -n 1 "$run/decisions.tsv")"
  [[ "$(awk -F'\t' '{print NF}' <<< "$row")" == 6 ]] || fail "$name: row has not six columns: $row"
  [[ "$(cut -f1 <<< "$row")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$ ]] || fail "$name: no ts: $row"
  [[ "$(cut -f2- <<< "$row")" == "$want" ]] || fail "$name: fields differ: $row"
}

printf '4\nuse make check && git commit\nwhy\nevidence\ndone\n' > "$tmp/five"
"$log" "$run" --from "$tmp/five" || fail "--from with five lines exits $?"
check_row '--from' $'4\tuse make check && git commit\twhy\tevidence\tdone'
[[ "$(wc -l < "$run/decisions.tsv")" -eq 1 ]] || fail '--from did not append exactly one row'
[[ ! -e "$tmp/five" ]] || fail '--from kept its file after an append that exited 0'

printf '4\na\tb\nwhy\nevidence\ndone\n' > "$tmp/tab"
"$log" "$run" --from "$tmp/tab" || fail "--from with a tab exits $?"
check_row 'a tab in a field' $'4\ta b\twhy\tevidence\tdone'
[[ ! -e "$tmp/tab" ]] || fail '--from kept its file after the row with a tab'

before="$(shasum -a 256 "$run/decisions.tsv")"
printf '4\ndecision\nwhy\nevidence\n' > "$tmp/four"
err="$("$log" "$run" --from "$tmp/four" 2>&1)"
code=$?
[[ $code -eq 2 ]] || fail "four lines: expected exit 2, got $code"
[[ "$err" == *"five lines"* ]] || fail "four lines: no reason in the message: $err"
[[ "$(shasum -a 256 "$run/decisions.tsv")" == "$before" ]] || fail 'four lines: decisions.tsv changed'
[[ -e "$tmp/four" ]] || fail 'four lines: the refused --from file is gone'

"$log" "$run" 2 decision why evidence done || fail "six arguments exit $?"
check_row 'six arguments' $'2\tdecision\twhy\tevidence\tdone'

# A row whose result starts with `default` names the word that reverses it in its why.
for form in from args; do
  before="$(shasum -a 256 "$run/decisions.tsv")"
  if [[ $form == from ]]; then
    printf '2\nuse blue\nno reference app\nevidence\ndefault: blue\n' > "$tmp/default"
    err="$("$log" "$run" --from "$tmp/default" 2>&1)"
  else
    err="$("$log" "$run" 2 'use blue' 'no reference app' evidence 'Default: blue' 2>&1)"
  fi
  code=$?
  [[ $code -eq 2 ]] || fail "a default row with no Reverse: ($form): expected exit 2, got $code"
  [[ "$err" == *'Reverse:'* ]] || fail "a default row with no Reverse: ($form): no reason in the message: $err"
  [[ "$(shasum -a 256 "$run/decisions.tsv")" == "$before" ]] || fail "a default row with no Reverse: ($form): decisions.tsv changed"
  [[ $form != from || -e "$tmp/default" ]] || fail 'a default row with no Reverse: the refused --from file is gone'
done
rows="$(wc -l < "$run/decisions.tsv")"
"$log" "$run" 2 'use blue' 'no reference app. Reverse: say red.' evidence 'default: blue' || fail "a default row with Reverse: exits $?"
check_row 'a default row with Reverse:' $'2\tuse blue\tno reference app. Reverse: say red.\tevidence\tdefault: blue'
[[ "$(wc -l < "$run/decisions.tsv")" -eq $((rows + 1)) ]] || fail 'a default row with Reverse: did not append exactly one row'
"$log" "$run" 2 'use blue' 'the user asked' evidence 'done' || fail "a row with another result exits $?"
[[ "$(wc -l < "$run/decisions.tsv")" -eq $((rows + 2)) ]] || fail 'a row with another result did not append exactly one row'
# The decision column starts with default too; Reverse: matches in any case.
before="$(shasum -a 256 "$run/decisions.tsv")"
err="$("$log" "$run" 2 'Default: blue' 'no reference app' evidence 'done' 2>&1)"
code=$?
[[ $code -eq 2 ]] || fail "a default decision with no Reverse: expected exit 2, got $code"
[[ "$(shasum -a 256 "$run/decisions.tsv")" == "$before" ]] || fail 'a default decision with no Reverse: decisions.tsv changed'
"$log" "$run" 2 'use blue' 'no reference app. reverse: say red.' evidence 'default: blue' || fail "a default row with reverse: exits $?"
[[ "$(wc -l < "$run/decisions.tsv")" -eq $((rows + 3)) ]] || fail 'a default row with reverse: did not append exactly one row'

# The phase is one digit, so land.sh finds the mutation pass row of phase 7.
for phase in '4 implement' implement 10 ''; do
  before="$(shasum -a 256 "$run/decisions.tsv")"
  err="$("$log" "$run" "$phase" decision why evidence done 2>&1)"
  code=$?
  [[ $code -eq 2 ]] || fail "phase '$phase': expected exit 2, got $code"
  [[ "$err" == *'one digit'* ]] || fail "phase '$phase': no reason in the message: $err"
  [[ "$(shasum -a 256 "$run/decisions.tsv")" == "$before" ]] || fail "phase '$phase': decisions.tsv changed"
done
printf '4 implement\ndecision\nwhy\nevidence\ndone\n' > "$tmp/phase"
"$log" "$run" --from "$tmp/phase" 2> /dev/null && fail "--from with the phase '4 implement' exits 0"
"$log" "$run" 0 decision why evidence done || fail "phase 0 exits $?"
"$log" "$run" 9 decision why evidence done || fail "phase 9 exits $?"
check_row 'phase 9' $'9\tdecision\twhy\tevidence\tdone'

# A criterion change row needs a criterion whose text differs from its text at the last row for that
# ID, and the words old and new. The file time of analysis.md decides nothing.
refused() {
  local name="$1" reason="$2" before err code
  shift 2
  before="$(shasum -a 256 "$run/decisions.tsv")"
  err="$("$log" "$run" "$@" 2>&1)"
  code=$?
  [[ $code -eq 2 ]] || fail "$name: expected exit 2, got $code"
  [[ "$err" == *"$reason"* ]] || fail "$name: no '$reason' in the message: $err"
  [[ "$(shasum -a 256 "$run/decisions.tsv")" == "$before" ]] || fail "$name: decisions.tsv changed"
}
change=(4 'Criterion change C1: old 3 s, new 5 s' 'the probe gives 4 s' evidence done)
refused 'a criterion change with no analysis.md' analysis.md "${change[@]}"
printf '# A\n\n## Acceptance criteria\n\n- C1: 3 s.\n' > "$run/analysis.md"
refused 'a criterion change with no old and new' 'old and new' 4 'criterion change C1: 5 s' 'the probe gives 4 s' evidence done
"$log" "$run" "${change[@]}" || fail "a criterion change for a new criterion exits $?"
check_row 'a criterion change for a new criterion' $'4\tCriterion change C1: old 3 s, new 5 s\tthe probe gives 4 s\tevidence\tdone'
refused 'a second criterion change with no change of the criterion' 'differs from its text' "${change[@]}"
touch "$run/analysis.md"
refused 'a criterion change after a touch of analysis.md' 'differs from its text' "${change[@]}"
"$log" "$run" 7 'criterion 4 verified' 'the test passes' evidence done || fail "a criterion verification row exits $?"

# The text of a criterion is its line and its indented lines. cc_row logs a phase 3 row in a folder
# of its own and reads the exit status; a refusal also names its reason.
cc="$tmp/cc"
cc_fresh() { rm -rf "$cc"; mkdir "$cc"; : > "$cc/decisions.tsv"; }
cc_crit() { # <text of C1> ...: analysis.md with C1..Cn, a decoy C9 and an outside I3 below the section
  local i=1 t
  { printf '# A\n\n## Acceptance criteria\n\n'; for t in "$@"; do printf -- '- C%d: %s\n' "$i" "$t"; i=$((i + 1)); done
    printf '\n## Other\n\n- C9: not a criterion.\n- I3: outside the section.\n'; } > "$cc/analysis.md"
}
cc_row() { # <name> <want exit> <decision>
  local name="$1" want="$2" err code
  shift 2
  err="$("$log" "$cc" 3 "$1" why evidence done 2>&1)"
  code=$?
  [[ $code -eq $want ]] || { fail "criterion text, $name: exit $code (want $want): $err"; return; }
  [[ $want -eq 0 || "$err" == *'differs from its text'* || "$err" == *'Acceptance criteria'* ]] || fail "criterion text, $name: no reason in the message: $err"
}
cc_fresh
cc_crit a b c d e
cc_row 'first row for C1 (new ID)' 0 'criterion change C1: old none, new a'
cc_row 'C1 again with no edit' 2 'criterion change C1: old none, new a'
cc_crit a2 b2 c2 d2 e2
for i in 2 3 4 5 1; do cc_row "one edit of five, row for C$i" 0 "criterion change C$i: old x, new y"; done
cc_row 'C3 again with no edit' 2 'criterion change C3: old x, new y'
cc_crit a2 b2 'c3 \d back\slash' d2 e2
cc_row 'C3 edited (backslash text)' 0 'criterion change C3: old x, new y'
cc_crit a2 b2 'c3 \d back\slash2' d2 e2
cc_row 'C3 edited again (one backslash part)' 0 'criterion change C3: old x, new y'
cc_row 'C3 third row with no edit' 2 'criterion change C3: old x, new y'
touch "$cc/analysis.md"
cc_row 'C3 after a touch only' 2 'criterion change C3: old x, new y'
cc_crit a2 b4 c5 d2 e2
cc_row 'two IDs in one row' 0 'criterion change C2 and C3: old x, new y'
cc_row 'both again with no edit' 2 'criterion change C2, C3: old x, new y'
cc_row 'a stray token that is no criterion ID' 2 'criterion change U5 C2: old x, new y'
# A row for an ID of no criteria section is refused, also after an edit of analysis.md. A row with
# no ID needs another hash of analysis.md. A word such as MP3 is no ID.
cc_fresh
cc_crit a b
cc_row 'ID outside the section' 2 'criterion change I3: old x, new y'
cc_row 'C9, which the section does not hold' 2 'criterion change C9: old x, new y'
printf '# A\n\n## Acceptance criteria\n\n- C1: a\n\n## Other\n\n- I3: outside the section, edited\n' > "$cc/analysis.md"
cc_row 'outside ID, analysis.md edited' 2 'criterion change I3: old x, new y'
err="$("$log" "$cc" 3 'criterion change I3: old x, new y' why evidence done 2>&1)"
[[ "$err" == *'Acceptance criteria'*'check-plan.sh'*'name its ID'* ]] || fail "outside ID: the message names no section rule: $err"
cc_crit a2 b
cc_row 'C1 changed plus an outside ID' 0 'criterion change C1 I3: old x, new y'
cc_row 'the outside ID alone after that' 2 'criterion change I3: old x, new y'
[[ "$(wc -l < "$cc/decisions.tsv" | tr -d ' ')" == 1 ]] || fail "outside ID: $(wc -l < "$cc/decisions.tsv") rows, not 1"
cc_fresh
cc_crit a b
cc_row 'no ID, first row' 0 'criterion change: old x, new y'
cc_row 'no ID, no edit' 2 'criterion change: old x, new y'
cc_crit a2 b
cc_row 'no ID, after an edit' 0 'criterion change: old x, new y'
cc_row 'C1, which differs from its line at the last C1 row' 0 'criterion change C1: old a, new a2'
cc_row 'C1 again with no edit' 2 'criterion change C1: old a, new a2'
cc_fresh
cc_crit a b
cc_row 'no ID, codec word' 0 'criterion change: MP3 export, old x, new y'
cc_row 'no ID, codec word, no edit' 2 'criterion change: MP3 export, old x, new y'
cc_crit a2 b
cc_row 'no ID, codec word, after an edit' 0 'criterion change: MP3 export, old x, new y'
cc_row 'C77, which no line holds' 2 'criterion change C77: old x, new y'
cc_crit a3 b
cc_row 'C77 after an edit' 2 'criterion change C77: old x, new y'
# A run with no baseline (no line in criteria-logged.tsv, no analysis-gate.md) reads the file time:
# the first row needs an analysis.md newer than decisions.tsv, with an ID or with none.
cc_fresh
cc_crit a b
touch -t 200001020000 "$cc/decisions.tsv"
touch -t 200001010000 "$cc/analysis.md"
cc_row 'no baseline, unchanged analysis.md, ID row' 2 'criterion change C1: old 10, new 20'
cc_crit a2 b
cc_row 'no baseline, analysis.md edited, ID row' 0 'criterion change C1: old 10, new 20'
cc_fresh
cc_crit a b
touch -t 200001020000 "$cc/decisions.tsv"
touch -t 200001010000 "$cc/analysis.md"
cc_row 'no baseline, unchanged analysis.md, no ID' 2 'criterion change: old 10, new 20'
cc_crit a b
cc_row 'no baseline, analysis.md edited, no ID' 0 'criterion change: old 10, new 20'
# analysis-gate.md is the baseline of an ID with no row, and a removed criterion needs one row.
cc_fresh
cc_crit a b
cp "$cc/analysis.md" "$cc/analysis-gate.md"
cc_row 'C1 unchanged since the gate copy' 2 'criterion change C1: old a, new a'
cc_crit a2 b
cc_row 'C1 changed since the gate copy' 0 'criterion change C1: old a, new a2'
cc_row 'C2 unchanged since the gate copy' 2 'criterion change C2: old b, new b'
printf '# A\n\n## Acceptance criteria\n\n- C1: a2\n' > "$cc/analysis.md"
cc_row 'C2 removed' 0 'criterion change C2: old b, new gone'
cc_row 'C2 removed again' 2 'criterion change C2: old b, new gone'
# The indented lines under a criterion are part of its text; a paragraph after the list is not.
cc_fresh
cc_sub() { # <C1 sub value> <C2 sub value>
  printf '# A\n\n## Acceptance criteria\n\n- C1: main one\n  - proof: %s\n\n  - near miss: x\n- C2: main two\n\t- proof: %s\n\nA paragraph after the list, not part of C2.\n\n## Other\n' "$1" "$2" > "$cc/analysis.md"
}
cc_sub p1 q1
cc_row 'indented, first row C1' 0 'criterion change C1: old none, new main one'
cc_row 'indented, first row C2' 0 'criterion change C2: old none, new main two'
cc_sub p2 q1
cc_row 'only the C1 sub-bullet changed, row for C2' 2 'criterion change C2: old a, new b'
cc_row 'sub-bullet edit of C1' 0 'criterion change C1: old p1, new p2'
cc_row 'C1 again with no edit' 2 'criterion change C1: old p1, new p2'
cc_sub p3 q3
cc_row 'one edit of both sub-bullets, row for C1' 0 'criterion change C1: old p2, new p3'
cc_row 'one edit of both sub-bullets, row for C2' 0 'criterion change C2: old q1, new q3'
printf '# A\n\n## Acceptance criteria\n\n- C1: main one\n  - proof: p3\n\n  - near miss: x\n- C2: main two\n\t- proof: q3\n\nA changed paragraph after the list.\n\n## Other\n' > "$cc/analysis.md"
cc_row 'a changed paragraph after the list' 2 'criterion change C2: old a, new b'
printf '# A\n\n## Acceptance criteria\n\n- C1: main one\n  - proof: p3\n\n  - near miss: x2\n- C2: main two\n\t- proof: q3\n' > "$cc/analysis.md"
cc_row 'sub-bullet after a blank line edited' 0 'criterion change C1: old x, new x2'
# A refused row keeps decisions.tsv, criteria-logged.tsv, and the folder; a later row only appends.
cc_fresh
cc_crit a b c
cc_row 'first row' 0 'criterion change C1: old none, new a'
before="$(shasum -a 256 < "$cc/criteria-logged.tsv")" files_before="$(ls -a "$cc")"
cc_row 'refused: no change' 2 'criterion change C1: old none, new a'
cc_row 'refused: outside ID' 2 'criterion change I3: old x, new y'
"$log" "$cc" 3 'criterion change C1: 5 s' why evidence done 2> /dev/null
[[ "$(shasum -a 256 < "$cc/criteria-logged.tsv")" == "$before" && "$(ls -a "$cc")" == "$files_before" ]] ||
  fail 'criterion text: a refused row changed criteria-logged.tsv or left a file'
head -n "$(wc -l < "$cc/criteria-logged.tsv")" "$cc/criteria-logged.tsv" > "$tmp/logged-prefix"
cc_crit a2 b c
cc_row 'C1 after an edit' 0 'criterion change C1: old a, new a2'
cmp -s "$tmp/logged-prefix" <(head -n "$(wc -l < "$tmp/logged-prefix")" "$cc/criteria-logged.tsv") ||
  fail 'criterion text: a later row changed an earlier line of criteria-logged.tsv'

# A row that claims a test result on the red tree or the old tree names a file of the logs/ folder
# of the run in its evidence. The phrase is read at a word start, in the decision or the why.
mkdir "$run/logs"
: > "$run/review-diff-2.md"
printf 'red output\n' > "$run/logs/s1-red.log"
claim='The item 4 test passed on the red tree'
appended() {
  local name="$1" rows
  shift
  rows="$(wc -l < "$run/decisions.tsv")"
  "$log" "$run" "$@" || fail "$name: exit $?"
  [[ "$(wc -l < "$run/decisions.tsv")" -eq $((rows + 1)) ]] || fail "$name: no row appended"
}
refused 'a red-tree claim with a file outside logs/' 'name the rule INR-030/claim' 6 'item 4 fixed' "$claim" review-diff-2.md done
printf '6\nitem 4 fixed\n%s\nreview-diff-2.md\ndone\n' "$claim" > "$tmp/claim"
refused 'a red-tree claim, --from form' 'logs/' --from "$tmp/claim"
[[ -e "$tmp/claim" ]] || fail 'a refused claim row: the --from file is gone'
refused 'a claim in the decision' 'logs/' 6 'item 4 fails on the old tree' 'the fix is in' review-diff-2.md done
for why in 'the test failed on the red-tree' 'It Passed on the red build' 'the old tree gave exit 0' 'the old-tree run'; do
  refused "the claim phrase '$why'" 'logs/' 6 decision "$why" review-diff-2.md done
done
"$log" "$run" 6 'item 4 fixed' "$claim" 'logs/s1-red.log:3.' done || fail "a red-tree claim with a log exits $?"
check_row 'a red-tree claim with a log' $'6\titem 4 fixed\tThe item 4 test passed on the red tree\tlogs/s1-red.log:3.\tdone'
printf '6\nitem 4 fixed\n%s\nlogs/s1-red.log\ndone\n' "$claim" > "$tmp/claim"
"$log" "$run" --from "$tmp/claim" || fail "a red-tree claim with a log, --from form, exits $?"
# Evidence forms: a word is logs/<file>, or ends in /<run name>/logs/<file>, and the file exists.
appended 'a log in parentheses' 6 d "$claim" 'the red run (logs/s1-red.log)' done
appended 'a log between other files' 6 d "$claim" 'review-diff-2.md, logs/s1-red.log; a.txt' done
appended 'the absolute path of the log' 6 d "$claim" "$run/logs/s1-red.log" done
refused 'a log that does not exist' 'logs/' 6 d "$claim" logs/s9-missing.log done
refused 'a log of another run' 'logs/' 6 d "$claim" /x/other-run/logs/s1-red.log done
refused 'a path out of logs/' 'logs/' 6 d "$claim" logs/../review-diff-2.md done
refused 'the word logs alone' 'logs/' 6 d "$claim" 'review-diff-2.md in logs' done
# Rows with no claim phrase are not read: a word that holds the letters, the rule named by its key,
# and a loop that is red-capable.
appended 'a tree that is no red tree' 6 'the measured tree' 'a scored tree' review-diff-2.md done
appended 'a red-capable loop' 6 d 'no test without a red-capable loop' review-diff-2.md done
appended 'the rule named by its key' 6 'apply the INR-030/claim rule of log-decision.sh' 'the key names the rule' review-diff-2.md done

# Each phase 4 row of a run with a plan.md runs scripts/check-plan.sh on the run folder: a plan
# gate change with no Criteria: field, or a criterion with no criterion change row, refuses the
# row, while a fix can still come before Phase 4. A run with no plan.md is not checked.
gated="$tmp/gated"
mkdir "$gated"
printf '# A\n\n## Unknowns\n\n| id | parent | question | resolver | answer | row |\n|---|---|---|---|---|---|\n| U1 | - | q | code | a | 2026-10-01T10:00 |\n' > "$gated/analysis.md"
printf '# P\n\nAgents: one.\n\n## Slices\n\n### S1\n\n- Check: x\n\n## Plan gate changes\n\n1. S1: a case.\n' > "$gated/plan.md"
: > "$gated/decisions.tsv"
: > "$gated/review-plan-1.md"
"$log" "$gated" 3 'plan gate item 1' why evidence done || fail "a phase 3 row with a plan item with no field exits $?"
before="$(shasum -a 256 "$gated/decisions.tsv")"
err="$("$log" "$gated" 4 'Slice S1 committed' why evidence done 2>&1)"
[[ $? -eq 2 ]] || fail "the first phase 4 row with a plan item with no Criteria field was not refused"
[[ "$err" == *'Criteria: <IDs separated by commas> or Criteria: none'* ]] || fail "the refusal names no format: $err"
[[ "$(shasum -a 256 "$gated/decisions.tsv")" == "$before" ]] || fail "a refused phase 4 row changed decisions.tsv"
printf '# P\n\nAgents: one.\n\n## Slices\n\n### S1\n\n- Check: x\n\n## Plan gate changes\n\n1. S1: a case. Criteria: C8\n' > "$gated/plan.md"
err="$("$log" "$gated" 4 'Slice S1 committed' why evidence done 2>&1)"
[[ $? -eq 2 ]] || fail "the first phase 4 row with no criterion change row for C8 was not refused"
[[ "$err" == *'log-decision.sh'*'criterion change C8: old'* ]] || fail "the refusal gives no fixing command: $err"
printf '# A\n\n## Acceptance criteria\n\n- C8: 5 s.\n\n## Unknowns\n\n| id | parent | question | resolver | answer | row |\n|---|---|---|---|---|---|\n| U1 | - | q | code | a | 2026-10-01T10:00 |\n' > "$gated/analysis.md"
"$log" "$gated" 3 'criterion change C8: old 3 s, new 5 s' why evidence done || fail "the criterion change row for C8 exits $?"
"$log" "$gated" 4 'Slice S1 committed' why evidence done || fail "the first phase 4 row after the C8 row exits $?"
printf '# P\n\nAgents: one.\n\n## Slices\n\n### S1\n\n- Check: x\n\n## Plan gate changes\n\n1. S1: a case.\n' > "$gated/plan.md"
"$log" "$gated" 4 'Slice S2 committed' why evidence done 2>/dev/null
[[ $? -eq 2 ]] || fail "a second phase 4 row with a plan item with no Criteria field was not refused"
# A late plan gate change (C5, after the first phase 4 row) passes once its row is in.
printf '# P\n\nAgents: one.\n\n## Slices\n\n### S1\n\n- Check: x\n\n## Plan gate changes\n\n1. S1: a case. Criteria: C8\n2. S1: a late case. Criteria: C5\n' > "$gated/plan.md"
"$log" "$gated" 4 'Slice S3 committed' why evidence done 2>/dev/null
[[ $? -eq 2 ]] || fail "a phase 4 row with a late C5 and no row was not refused"
printf '# A\n\n## Acceptance criteria\n\n- C8: 5 s.\n- C5: b.\n\n## Unknowns\n\n| id | parent | question | resolver | answer | row |\n|---|---|---|---|---|---|\n| U1 | - | q | code | a | 2026-10-01T10:00 |\n' > "$gated/analysis.md"
"$log" "$gated" 6 'criterion change C5: old a, new b' why evidence done || fail "the criterion change row for C5 exits $?"
"$log" "$gated" 4 'Slice S3 committed' why evidence done || fail "the next phase 4 row after the late C5 row exits $?"

# A phase 6 row runs scripts/check-plan.sh with no CHECK_PLAN_AT_PHASE4 value, the check of the land
# (check-governance.sh): an Act on item with no Siblings field refuses the row and keeps the --from
# file. A phase 2 row after the phase 3 row is no refusal, because only the phase 4 check tests the
# plan gate. The criterion change row of the gated run above is the case that skips the check.
p6="$tmp/p6"
mkdir "$p6"
printf '# A\n\n## Unknowns\n\n| id | parent | question | resolver | answer | row |\n|---|---|---|---|---|---|\n| U1 | - | q | code | a | 2026-10-01T10:00 |\n' > "$p6/analysis.md"
printf '# P\n\nAgents: one.\n\n## Slices\n\n### S1\n\n- Check: x\n' > "$p6/plan.md"
: > "$p6/decisions.tsv"
: > "$p6/review-plan-1.md"
"$log" "$p6" 2 'plan written' why evidence done || fail "p6: the phase 2 row exits $?"
"$log" "$p6" 3 'plan gate closed' why evidence done || fail "p6: the phase 3 row exits $?"
"$log" "$p6" 4 'Slice S1 committed' why evidence done || fail "p6: the phase 4 row exits $?"
printf '# V\n\n## Act on\n\n1. (warning, x, read) A case is missing. Invariant: each case has a test.\n' > "$p6/review-diff-1.md"
printf '6\nfix item 1\nthe case\nevidence\nfixed\n' > "$tmp/p6row"
before="$(shasum -a 256 "$p6/decisions.tsv")"
err="$("$log" "$p6" --from "$tmp/p6row" 2>&1)"
code=$?
[[ $code -eq 2 ]] || fail "p6: an Act on item with no Siblings field: expected exit 2, got $code"
[[ "$err" == *'Siblings'* ]] || fail "p6: the refusal names no Siblings field: $err"
[[ "$(shasum -a 256 "$p6/decisions.tsv")" == "$before" ]] || fail 'p6: the refused phase 6 row changed decisions.tsv'
[[ -e "$tmp/p6row" ]] || fail 'p6: the refused --from file is gone'
printf '# V\n\n## Act on\n\n1. (warning, x, read) A case is missing. Invariant: each case has a test. Siblings: none.\n' > "$p6/review-diff-1.md"
"$log" "$p6" --from "$tmp/p6row" || fail "p6: the phase 6 row with both fields exits $?"
[[ "$(tail -n 1 "$p6/decisions.tsv" | cut -f2-)" == $'6\tfix item 1\tthe case\tevidence\tfixed' ]] || fail 'p6: no phase 6 row after the field came'
[[ ! -e "$tmp/p6row" ]] || fail 'p6: the --from file is still there after the append'
"$log" "$p6" 2 'plan changed late' why evidence done || fail "p6: the late phase 2 row exits $?"
"$log" "$p6" 6 'fix item 2' 'the plan gate has no row after the late phase 2 row' evidence fixed || fail "p6: a phase 6 row after a late phase 2 row exits $?"

# The first phase 7 row of a run with a plan.md needs a line in the ## Fix check of the last
# review-diff-<n>.md for each Act on item of each round (a line that has the whole word <round>.<item>).
# A run with no Act on item, and a run whose first row is older than the rule, need none.
p7_run() { # <name> <first row time>: a run folder with a plan and two review rounds
  local d="$tmp/$1"
  mkdir "$d"
  printf '# A\n\n## Unknowns\n\n| id | parent | question | resolver | answer | row |\n|---|---|---|---|---|---|\n| U1 | - | q | code | a | 2026-10-01T10:00 |\n' > "$d/analysis.md"
  printf '# P\n\nAgents: one.\n\n## Slices\n\n### S1\n\n- Check: x\n' > "$d/plan.md"
  printf '%s\t2\tplan written\twhy\tevidence\tdone\n' "$2" > "$d/decisions.tsv"
  printf '# V\n\n## Act on\n\n1. (warning, x, read) One. Invariant: a. Siblings: none.\n2. (warning, x, read) Two. Invariant: a. Siblings: none.\n3. (warning, x, read) Three. Invariant: a. Siblings: none.\n' > "$d/review-diff-1.md"
  printf '# V\n\n## Act on\n\n1. (warning, x, read) Again. Invariant: a. Siblings: none.\n\n## Fix check\n\n- 1.1 OK: done; new failure: none: x.\n- 1.2 OK: done; new failure: none: x.\n- 2.1 OK: done; new failure: none: x.\n- 11.3 OK: another item; new failure: none: x.\n' > "$d/review-diff-2.md"
}
p7_run p7 "$(date +%FT%R)"
before="$(shasum -a 256 "$tmp/p7/decisions.tsv")"
err="$("$log" "$tmp/p7" 7 'criterion 1 verified' why evidence done 2>&1)"
code=$?
[[ $code -eq 2 && "$err" == *1.3* && "$err" != *1.1* ]] || fail "p7: a Fix check with no line for item 1.3: exit $code: $err"
[[ "$(shasum -a 256 "$tmp/p7/decisions.tsv")" == "$before" ]] || fail 'p7: the refused phase 7 row changed decisions.tsv'
printf -- '- 1.3 OK: done\n' >> "$tmp/p7/review-diff-2.md"
err="$("$log" "$tmp/p7" 7 'criterion 1 verified' why evidence done 2>&1)"
code=$?
[[ $code -eq 2 && "$err" == *1.3* && "$err" == *'new failure:'* && "$err" != *1.1* ]] || fail "p7: a line for 1.3 with no new failure part: exit $code: $err"
[[ "$(shasum -a 256 "$tmp/p7/decisions.tsv")" == "$before" ]] || fail 'p7: the phase 7 row with no new failure part changed decisions.tsv'
sed -i.bak 's/^- 1.3 OK: done$/&; new failure: none: x./' "$tmp/p7/review-diff-2.md" && rm "$tmp/p7/review-diff-2.md.bak"
"$log" "$tmp/p7" 7 'criterion 1 verified' why evidence done || fail "p7: a Fix check with a line for each item exits $?"
# A plan gate line with a deferred control (form b) refuses the first phase 7 row until its file exists.
p7_run p7-ctl "$(date +%FT%R)"
printf -- '- 1.3 OK; new failure: none: x.\n' >> "$tmp/p7-ctl/review-diff-2.md"
printf '# V\n\n## Act on\n\n1. (warning, x, read) One. Invariant: a. Siblings: none.\n\n## Fix check\n\n- 1.1 OK; new failure: none: x; control: logs/c1.log after S1\n' > "$tmp/p7-ctl/review-plan-1.md"
printf '2026-11-02T00:00\t3\tcriterion change C1 (plan gate 1 item 1): old a, new b\twhy\tevidence\tdone\n' >> "$tmp/p7-ctl/decisions.tsv"
before="$(shasum -a 256 "$tmp/p7-ctl/decisions.tsv")"
err="$("$log" "$tmp/p7-ctl" 7 'criterion 1 verified' why evidence done 2>&1)"
code=$?
[[ $code -eq 2 && "$err" == *1.1* && "$err" == *logs/c1.log* ]] || fail "p7: a deferred control with no file: exit $code: $err"
[[ "$(shasum -a 256 "$tmp/p7-ctl/decisions.tsv")" == "$before" ]] || fail 'p7: the phase 7 row with a missing control file changed decisions.tsv'
mkdir "$tmp/p7-ctl/logs"; : > "$tmp/p7-ctl/logs/c1.log"
"$log" "$tmp/p7-ctl" 7 'criterion 1 verified' why evidence done || fail "p7: a deferred control with its file exits $?"
p7_run p7-none "$(date +%FT%R)"
printf '# V\n\n## Consider\n\n- a nit\n' > "$tmp/p7-none/review-diff-1.md"
printf '# V\n\n## Consider\n\n- a nit\n' > "$tmp/p7-none/review-diff-2.md"
"$log" "$tmp/p7-none" 7 'criterion 1 verified' why evidence done || fail "p7: a run with no Act on item exits $?"
p7_run p7-old 2026-10-01T10:00
"$log" "$tmp/p7-old" 7 'criterion 1 verified' why evidence done || fail "p7: a run older than the rule exits $?"

# The first phase 4 row copies analysis.md to analysis-gate.md when that file is absent and the run
# has no phase 4 row. After that, a criterion line of analysis.md that differs from the copy, or
# is gone, needs a criterion change row that names its ID as a whole word, logged after the first
# phase 4 row. A run with phase 4 rows and no copy is older than the rule and needs none.
g10_run() { # <name>: a run folder that is ready for its first phase 4 row
  local d="$tmp/$1"
  mkdir "$d"
  printf '# A\n\n## Unknowns\n\n| id | parent | question | resolver | answer | row |\n|---|---|---|---|---|---|\n| U1 | - | q | code | a | 2026-10-01T10:00 |\n\n## Acceptance criteria\n\n- C1: the meter moves.\n- C12: the file is saved.\n- C2: the file is read.\n\n## Other\n\n- C9: not a criterion.\n' > "$d/analysis.md"
  printf '# P\n\nAgents: one.\n\n## Slices\n\n### S1\n\n- Check: C1 C2 C3 C12\n' > "$d/plan.md"
  : > "$d/decisions.tsv"
  : > "$d/review-plan-1.md"
  "$log" "$d" 2 'plan written' why evidence done || fail "g10: the phase 2 row exits $?"
  "$log" "$d" 3 'plan gate closed' why evidence done || fail "g10: the phase 3 row exits $?"
}
g10_run g10
[[ ! -e "$tmp/g10/analysis-gate.md" ]] || fail 'g10: analysis-gate.md exists before the first phase 4 row'
"$log" "$tmp/g10" 4 'Slice S1 committed' why evidence done || fail "g10: the first phase 4 row exits $?"
cmp -s "$tmp/g10/analysis.md" "$tmp/g10/analysis-gate.md" || fail 'g10: the first phase 4 row did not copy analysis.md to analysis-gate.md'
sed 's/^- C1: the meter moves\./- C1: the meter moves at 24 fps./' "$tmp/g10/analysis-gate.md" > "$tmp/g10/analysis.md"
before="$(shasum -a 256 "$tmp/g10/decisions.tsv")"
err="$("$log" "$tmp/g10" 4 'Slice S3 committed' why evidence done 2>&1)"
code=$?
[[ $code -eq 2 && "$err" == *'criterion C1 '* && "$err" != *'criterion C12 '* && "$err" != *'criterion C2 '* && "$err" == *'a default, a wording pick, a fix'* ]] ||
  fail "g10: a changed C1 with no row: exit $code: $err"
[[ "$(shasum -a 256 "$tmp/g10/decisions.tsv")" == "$before" ]] || fail 'g10: the refused phase 4 row changed decisions.tsv'
"$log" "$tmp/g10" 6 'fix item 1' why evidence fixed 2>/dev/null
[[ $? -eq 2 ]] || fail 'g10: a phase 6 row with a changed C1 and no row was not refused'
"$log" "$tmp/g10" 4 'criterion change C12: old saved, new saved twice' why evidence done 2>/dev/null
[[ $? -eq 2 ]] || fail "g10: a criterion change row for the unedited C12 exits $?"
err="$("$log" "$tmp/g10" 4 'Slice S3 committed' why evidence done 2>&1)"
code=$?
[[ $code -eq 2 && "$err" == *'criterion C1 '* ]] || fail "g10: a row for C12 stood for the changed C1: exit $code: $err"
"$log" "$tmp/g10" 4 'criterion change C1: old the meter moves, new the meter moves at 24 fps' why evidence done ||
  fail "g10: the criterion change row for C1 exits $?"
"$log" "$tmp/g10" 4 'Slice S3 committed' why evidence done || fail "g10: a phase 4 row after the C1 row exits $?"
sed '/^- C2: /d' "$tmp/g10/analysis.md" > "$tmp/g10/analysis.new" && mv "$tmp/g10/analysis.new" "$tmp/g10/analysis.md"
err="$("$log" "$tmp/g10" 4 'Slice S4 committed' why evidence done 2>&1)"
code=$?
[[ $code -eq 2 && "$err" == *'criterion C2 '* && "$err" != *'criterion C1 '* ]] || fail "g10: a removed C2 with no row: exit $code: $err"
"$log" "$tmp/g10" 6 'criterion change C2: old the file is read, new gone' why evidence done || fail "g10: the criterion change row for C2 exits $?"
"$log" "$tmp/g10" 4 'Slice S4 committed' why evidence done || fail "g10: a phase 4 row after the C2 row exits $?"
printf -- '- C3: a new criterion.\n' >> "$tmp/g10/analysis.md"
sed -i.bak 's/^- C9: not a criterion\./- C9: another text./' "$tmp/g10/analysis.md" && rm "$tmp/g10/analysis.md.bak"
"$log" "$tmp/g10" 4 'Slice S5 committed' why evidence done || fail "g10: a new criterion C3 and a changed line outside the section exit $?"
g10_run g10-old
printf '2026-10-01T10:00\t4\tSlice S1 committed\twhy\tevidence\tdone\n' >> "$tmp/g10-old/decisions.tsv"
sed -i.bak 's/^- C1: the meter moves\./- C1: the meter moves at 24 fps./' "$tmp/g10-old/analysis.md" && rm "$tmp/g10-old/analysis.md.bak"
"$log" "$tmp/g10-old" 4 'Slice S2 committed' why evidence done || fail "g10: a run with phase 4 rows and no copy exits $?"
[[ ! -e "$tmp/g10-old/analysis-gate.md" ]] || fail 'g10: a run with phase 4 rows got an analysis-gate.md'

# A phase 6 row of a run whose branch adds an evals.md key with no graded eval folder is refused
# (scripts/check-eval-keys.sh, against origin/main, with the worktree of the last - Branch: line),
# and the --from file stays. A run folder with no run.md is not checked.
ek="$tmp/ek"
eg() { git -C "$ek" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
mkdir -p "$ek/docs/workflow" "$ek/runs/r"
eg init -q -b main
printf '## Scenarios\n\n| ID | Type | Source | Question | Key points | Files | Old | New |\n|---|---|---|---|---|---|---|---|\n' > "$ek/docs/workflow/evals.md"
eg add docs
eg commit -q -m base
eg update-ref refs/remotes/origin/main main
eg worktree add -q -b chore/k "$tmp/ek-wt"
printf '| E4 | policy | s | q | (a) new. | `a.md` | - | - |\n' >> "$tmp/ek-wt/docs/workflow/evals.md"
git -C "$tmp/ek-wt" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -am keys
printf '# Run r\n\n- Branch: chore/k\n' > "$ek/runs/r/run.md"
: > "$ek/runs/r/decisions.tsv"
printf '6\nfix item 1\nthe case\nevidence\nfixed\n' > "$tmp/ekrow"
err="$("$log" "$ek/runs/r" --from "$tmp/ekrow" 2>&1)"
code=$?
[[ $code -eq 2 ]] || fail "ek: a phase 6 row with an ungraded key: expected exit 2, got $code"
[[ "$err" == *E4* ]] || fail "ek: the refusal names no ID: $err"
[[ "$err" == *'the lead runs'* ]] || fail "ek: the refusal names no lead step: $err"
[[ ! -s "$ek/runs/r/decisions.tsv" ]] || fail 'ek: the refused phase 6 row changed decisions.tsv'
[[ -e "$tmp/ekrow" ]] || fail 'ek: the refused --from file is gone'
mv "$ek/runs/r/run.md" "$ek/run.md.off"
"$log" "$ek/runs/r" 6 'fix item 0' 'no run.md' evidence fixed || fail "ek: a phase 6 row with no run.md exits $?"
mv "$ek/run.md.off" "$ek/runs/r/run.md"
mkdir "$ek/runs/r/eval"
printf '## E4\n(a) new.\n\n' > "$ek/runs/r/eval/keys.md"
printf 'p7\tE4\tpolicy\ta\t1\tPASS\t\n' > "$ek/runs/r/eval/scores.tsv"
"$log" "$ek/runs/r" --from "$tmp/ekrow" || fail "ek: a phase 6 row with a graded key exits $?"

# The backlog and the run log are the wiki of scripts/wiki.py. DIRIGIBLE_WIKI names a temp wiki, so
# no case reads or writes the real one. The git config is off in this test, so the identity of the
# wiki commits is in the environment.
new_run="$(dirname "$log")/new-run.sh"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
wiki_tool="$(cd "$(dirname "$log")/../../../.." && pwd)/scripts/wiki.py"
export DIRIGIBLE_WIKI="$tmp/wiki"
new_wiki() { rm -rf "$DIRIGIBLE_WIKI"; "$wiki_tool" init > /dev/null || fail 'wiki init'; }
# put_log: the lines on stdin are appended to the log of the wiki, as new-run.sh does.
put_log() { cat > "$tmp/put-log.txt"; "$wiki_tool" log --from "$tmp/put-log.txt" || fail 'wiki log'; }
# put_item <status> <title> <description>: add one item with the tool.
put_item() {
  printf '%s\n%s\n\nbody\n' "$2" "$3" > "$tmp/put-item.txt"
  "$wiki_tool" add "$1" --from "$tmp/put-item.txt" > /dev/null || fail "wiki add $1 $2"
}
# bulk_next <n>: 142 next items of 21 words in their `list next` line (the ID, 8 title words, and 12
# description words), and one more with 8 title words and <n> description words: 2991 + <n> words in
# all. The pages are written in one commit, because 143 calls of the tool take a minute.
bulk_next() {
  local i n
  mkdir -p "$DIRIGIBLE_WIKI/wiki/items"
  for i in $(seq 143); do
    n=12
    [[ $i -eq 143 ]] && n="$1"
    printf -- '---\ntype: Item\ntitle: "t1 t2 t3 t4 t5 t6 t7 t8"\ndescription: "%s"\nstatus: next\ngenerated: 2026-10-23\n---\n\nbody\n' \
      "$(printf 'd%.0s ' $(seq "$n") | sed 's/ $//')" > "$DIRIGIBLE_WIKI/wiki/items/$(printf '%04d' "$i").md"
  done
  git -C "$DIRIGIBLE_WIKI" add -A && git -C "$DIRIGIBLE_WIKI" commit -q -m 'fixture: next items' || fail 'bulk_next commit'
}
repo="$tmp/repo"
mkdir -p "$repo/.scratchpads/runs/2026-01-01-old"
git -C "$repo" init -q
today="$(date +%Y-%m-%d)"

# With no wiki, new-run.sh exits nonzero, names the path, `init`, and DIRIGIBLE_WIKI, and makes no
# run folder and no wiki.
out="$(cd "$repo" && DIRIGIBLE_WIKI="$tmp/missing" "$new_run" nowiki feat 2>&1)"
code=$?
[[ $code -ne 0 ]] || fail 'no wiki: new-run exits 0'
for w in "$tmp/missing" 'scripts/wiki.py init' DIRIGIBLE_WIKI; do
  [[ "$out" == *"$w"* ]] || fail "no wiki: the message lacks [$w]: $out"
done
[[ ! -e "$repo/.scratchpads/runs/$today-nowiki" && ! -e "$tmp/missing" ]] || fail 'no wiki: new-run made a run folder or a wiki'

# new-run.sh reports the wiki on stderr and keeps stdout to the run folder. It warns when
# `wiki.py list next` has over 3000 words (3000 gives no warning), writes `- Later items: <n>` in
# the new run.md, and prints the later count with the change from the `Later items:` line of the
# last run.md. It makes the logs/ folder, where cost.sh of reflect counts the check and bench logs,
# and it adds one open row to the log: a second call for the open run adds none.
new_wiki; bulk_next 9
(cd "$repo" && "$new_run" limit feat > /dev/null 2> "$tmp/err") || fail "new-run with 3000 next words exits $?"
grep -q 'words' "$tmp/err" && fail "a warning at 3000 next words: $(cat "$tmp/err")"
rm -r "$repo/.scratchpads/runs/$today-limit"
new_wiki; bulk_next 10
for s in a b c; do put_item later "$s" x; done
printf '# Run 2026-01-01-old\n\n- Later items: 1\n' > "$repo/.scratchpads/runs/2026-01-01-old/run.md"
out="$(cd "$repo" && "$new_run" big feat 2> "$tmp/err")" || fail "new-run with a long next list exits $?"
dir="$repo/.scratchpads/runs/$today-big"
[[ "$out" == "$(cd "$repo" && pwd -P)/.scratchpads/runs/$today-big" ]] || fail "new-run stdout is not the run folder: $out"
grep -q 'wiki.py list next has 3001 words, over 3000' "$tmp/err" || fail "no warning that names list next and 3001 words: $(cat "$tmp/err")"
grep -qx -- '- Later items: 3' "$dir/run.md" || fail "run.md has no '- Later items: 3' line"
[[ -d "$dir/logs" ]] || fail 'new-run made no logs/ folder'
grep -q 'later has 3 items (+2 since 2026-01-01-old)' "$tmp/err" || fail "no later count with the change: $(cat "$tmp/err")"
[[ "$("$wiki_tool" runs | grep -cxF "| $today-big | big | open | |")" == 1 ]] || fail "no single open row for the new run: $("$wiki_tool" runs)"
[[ -z "$(ls "$dir/logs")" ]] || fail "the row file stays in logs/: $(ls "$dir/logs")"
[[ -z "$(git -C "$DIRIGIBLE_WIKI" status --porcelain)" ]] || fail 'the wiki tree is not clean after new-run'

# It writes analysis.md and plan.md skeletons, so a subagent fills them with the Edit tool.
# check-plan.sh refuses the skeletons, and a second call for the open run keeps each edited file.
grep -qx '## Unknowns' "$dir/analysis.md" && grep -qx '| id | parent | question | resolver | answer | row |' "$dir/analysis.md" ||
  fail "no analysis.md skeleton with the Unknowns header line: $(cat "$dir/analysis.md" 2>&1)"
grep -qx '## Slices' "$dir/plan.md" || fail "no plan.md skeleton with ## Slices: $(cat "$dir/plan.md" 2>&1)"
out="$("$(cd "$(dirname "$log")/../../../.." && pwd)/scripts/check-plan.sh" "$dir" 2>&1)"
code=$?
[[ $code -eq 1 && "$out" == *'no ## Unknowns table with rows'* ]] || fail "check-plan.sh on the skeletons: exit $code: $out"
# The skeletons exist, and write-guard.sh refuses a Write over them: Phase 1 and Phase 2 of the
# skill name the Edit route.
skill="$(cd "$(dirname "$log")/.." && pwd)/SKILL.md"
for f in analysis plan; do
  grep -qE "^Fill \`$f.md\` with the Edit tool" "$skill" || fail "SKILL.md: the $f.md heading does not name the Edit route: $(grep -n "$f.md\`:" "$skill")"
done
echo '| U1 | - | q | code | a | 2026-01-01T00:00 |' >> "$dir/analysis.md"
echo '### S1' >> "$dir/plan.md"
before="$(cat "$dir/analysis.md" "$dir/plan.md" | shasum)"
(cd "$repo" && "$new_run" big feat > /dev/null 2>&1) || fail "new-run again for the open run exits $?"
[[ "$(cat "$dir/analysis.md" "$dir/plan.md" | shasum)" == "$before" ]] || fail 'a second new-run changed an edited skeleton'

new_wiki; put_item next short x; put_item later a x
rm -r "$dir"
printf '# Run 2026-01-01-old\n' > "$repo/.scratchpads/runs/2026-01-01-old/run.md"
(cd "$repo" && "$new_run" small feat > /dev/null 2> "$tmp/err") || fail "new-run with a short next list exits $?"
grep -q 'words' "$tmp/err" && fail "warning for a short next list: $(cat "$tmp/err")"
grep -qx 'backlog: later has 1 items' "$tmp/err" || fail "no later count without a last count: $(cat "$tmp/err")"
grep -qx 'upkeep items: 0' "$tmp/err" || fail "no upkeep count of 0: $(cat "$tmp/err")"
grep -q 'warning' "$tmp/err" && fail "warning with no upkeep item: $(cat "$tmp/err")"

# It counts the upkeep items of status next only, and warns at 8 or more (reflect rule 6): 7 next
# items and one later item give no warning; 8 next items give one.
new_wiki
for i in $(seq 7); do put_item next "upkeep k$i" x; done
put_item later 'upkeep d' x
(cd "$repo" && "$new_run" upkeep-seven feat > /dev/null 2> "$tmp/err") || fail "new-run with 7 upkeep items exits $?"
grep -qx 'upkeep items: 7' "$tmp/err" || fail "no upkeep count of 7: $(cat "$tmp/err")"
grep -q 'warning' "$tmp/err" && fail "warning at 7 upkeep items: $(cat "$tmp/err")"
put_item next 'upkeep k8' x
(cd "$repo" && "$new_run" upkeep feat > /dev/null 2> "$tmp/err") || fail "new-run with 8 upkeep items exits $?"
grep -qx 'upkeep items: 8' "$tmp/err" || fail "no upkeep count of 8: $(cat "$tmp/err")"
grep -q 'warning:.*upkeep run' "$tmp/err" || fail "no warning at 8 upkeep items: $(cat "$tmp/err")"

# It reminds of an architecture audit at 5 distinct product runs after the last run whose name has
# architecture and a done row. A run has an open and a done row. A product run has a run.md branch
# of type feat, fix, or perf, and a slug with no hardening. The current run does not count.
# ledger_typed <run>:<type> ...: a new wiki with an open row and a later done row of each run in its
# log, and the run.md of each run.
ledger_typed() {
  new_wiki
  local spec r rows=""
  for spec in "$@"; do
    r="${spec%%:*}"
    mkdir -p "$repo/.scratchpads/runs/$r"
    printf '# Run %s\n\n- Branch: %s/x\n' "$r" "${spec##*:}" > "$repo/.scratchpads/runs/$r/run.md"
    rows+="$(printf '| %s | x | open | |\n| %s | x | done | |' "$r" "$r")"$'\n'
  done
  printf '%s' "$rows" | put_log
}
# ledger_rows <run> ...: a run whose name has workflow, upkeep, or docs is of type docs, else feat.
ledger_rows() {
  local r specs=()
  for r in "$@"; do
    case "$r" in *workflow* | *upkeep* | *docs*) specs+=("$r:docs") ;; *) specs+=("$r:feat") ;; esac
  done
  ledger_typed "${specs[@]}"
}
audit() { (cd "$repo" && "$new_run" "$1" feat > /dev/null 2> "$tmp/err") || fail "new-run $1 exits $?"; }
ledger_rows 2026-01-01-architecture-a 2026-01-02-p1 2026-01-03-p2 2026-01-04-p3 2026-01-05-p4
audit audit-four
grep -q 'architecture audit' "$tmp/err" && fail "a reminder at 4 product runs: $(cat "$tmp/err")"
ledger_rows 2026-01-01-architecture-a 2026-01-02-p1 2026-01-03-p2 2026-01-04-p3 2026-01-05-p4 2026-01-06-p5
audit audit-five
grep -q 'architecture audit due: 5 product runs' "$tmp/err" || fail "no reminder at 5 product runs: $(cat "$tmp/err")"
ledger_rows 2026-01-02-p1 2026-01-03-p2 2026-01-04-p3 2026-01-05-p4 2026-01-06-p5
echo '| 2026-01-07-architecture-b | x | open | |' | put_log
audit audit-open
grep -q 'architecture audit due: 5 product runs' "$tmp/err" || fail "an open architecture run reset the count: $(cat "$tmp/err")"
echo '| 2026-01-07-architecture-b | x | done | |' | put_log
audit audit-reset
grep -q 'architecture audit' "$tmp/err" && fail "a reminder after a done architecture run: $(cat "$tmp/err")"
ledger_rows 2026-01-01-architecture-a 2026-01-02-workflow-a 2026-01-03-upkeep-b 2026-01-04-docs-c 2026-01-05-workflow-d 2026-01-06-docs-e
audit audit-docs
grep -q 'architecture audit' "$tmp/err" && fail "a reminder for workflow, upkeep, and docs runs: $(cat "$tmp/err")"

# A run counts by the type of its run.md branch, not by its name: docs, build, and chore runs do not
# count, nor does a run with hardening in its slug. feat, fix, and perf runs do.
ledger_typed 2026-01-01-architecture-a:docs 2026-01-02-p1:feat 2026-01-03-p2:fix 2026-01-04-p3:perf 2026-01-05-p4:feat \
  2026-01-06-cycle:docs 2026-01-07-tool:build 2026-01-08-hardening:fix 2026-01-09-cleanup:chore
audit audit-types
grep -q 'architecture audit' "$tmp/err" && fail "a reminder at 4 product runs among docs, build, chore, and hardening runs: $(cat "$tmp/err")"
ledger_typed 2026-01-01-architecture-a:docs 2026-01-02-p1:feat 2026-01-03-p2:fix 2026-01-04-p3:perf 2026-01-05-p4:feat \
  2026-01-06-cycle:docs 2026-01-07-tool:build 2026-01-08-hardening:fix 2026-01-09-p5:fix
audit audit-types-five
grep -q 'architecture audit due: 5 product runs' "$tmp/err" || fail "no reminder at 5 feat, fix, and perf runs: $(cat "$tmp/err")"

# It prints `consolidation due` when the words of the workflow docs (scripts/workflow-words.sh sum:
# the pin line leaves out its folders) are over the TOTAL row of docs/workflow/budgets.tsv x 1.03, and
# it exits 0 either way (decision 0028, Word budgets). A references file counts.
mkdir -p "$repo/docs/workflow" "$repo/.claude/skills/pin" "$repo/.claude/skills/s/references"
printf 'path\twords\tdecision\nTOTAL\t10000\tx\n' > "$repo/docs/workflow/budgets.tsv"
n_words() { seq "$2" | tr '\n' ' ' > "$repo/$1"; git -C "$repo" add "$1"; }
n_words AGENTS.md 10300
audit total-10300
grep -q 'consolidation due' "$tmp/err" && fail "consolidation due at TOTAL x 1.03: $(cat "$tmp/err")"
n_words AGENTS.md 10301
audit total-10301
grep -q 'consolidation due: the workflow docs have 10301 words, over TOTAL x 1.03 (10000 in docs/workflow/budgets.tsv)' "$tmp/err" \
  || fail "no consolidation due at 10301 words: $(cat "$tmp/err")"
n_words AGENTS.md 10000
n_words .claude/skills/pin/SKILL.md 5000
printf 'Pinned skills: `pin`.\n' > "$repo/.claude/skills/THIRD_PARTY.md"
audit pinned-words
grep -q 'consolidation due' "$tmp/err" && fail "the words of a pinned skill count: $(cat "$tmp/err")"
n_words .claude/skills/s/references/r.md 301
audit references-file
grep -q 'consolidation due: the workflow docs have 10301 words' "$tmp/err" || fail "a references file does not count: $(cat "$tmp/err")"

# It prints `dependency check due` when the first `Last check: YYYY-MM-DD` line of
# docs/workflow/dependency-check.md is 30 or more calendar days old, or when no such line is a real
# date. A date after today and no doc print nothing. Each call exits 0 and prints the run folder.
dep_doc="$repo/docs/workflow/dependency-check.md"
dep_run='; add one dependency check item with status next unless the next list has one (docs/workflow/dependency-check.md)'
dep_case() {
  local out
  out="$(cd "$repo" && "$new_run" "$1" feat 2> "$tmp/err")" || fail "new-run $1 exits $?"
  [[ "$out" == "$(cd "$repo" && pwd -P)/.scratchpads/runs/$today-$1" ]] || fail "new-run $1 stdout is not the run folder: $out"
}
day30="$(date -v-30d +%F)"
printf '# x\n\nLast check: %s\n' "$day30" > "$dep_doc"
dep_case dep-30
grep -qxF "dependency check due: last check $day30, 30 days ago$dep_run" "$tmp/err" || fail "no dependency check due at 30 days: $(cat "$tmp/err")"
for d in "$(date -v-29d +%F)" "$(date +%F)" "$(date -v+1d +%F)"; do
  printf 'Last check: %s\n' "$d" > "$dep_doc"
  dep_case "dep-$d"
  grep -q 'dependency check due' "$tmp/err" && fail "a dependency check due for Last check: $d: $(cat "$tmp/err")"
done
for line in 'Last checked: 2026-11-02' 'Last check: 2026-11-31' 'Last check: 2026-13-45'; do
  printf '# x\n%s\n' "$line" > "$dep_doc"
  dep_case "dep-bad-${line//[^0-9]/}"
  grep -qxF "dependency check due: no valid Last check: line in docs/workflow/dependency-check.md$dep_run" "$tmp/err" \
    || fail "no dependency check due for '$line': $(cat "$tmp/err")"
done
rm "$dep_doc"
dep_case dep-no-doc
grep -q 'dependency check due' "$tmp/err" && fail "a dependency check due with no doc: $(cat "$tmp/err")"
rm -rf "$repo/AGENTS.md" "$repo/.claude" "$repo/docs"

# It refuses a third non-feature run in a row: the two runs of the log with the highest PR numbers
# in their done rows (open rows do not count; a run with two rows counts once, by its last row) have
# a run.md branch type other than feat, and the new type is not feat. The type is
# the text between "- Branch: " and the first slash, as the real run.md lines have it.
# guard_ledger <run> <branch line> ...: a new wiki with done rows with PR numbers 101, 102, ... in argument order.
guard_ledger() {
  new_wiki
  local r t n=100 rows=""
  while [[ $# -gt 0 ]]; do
    r="$1" t="$2" n=$((n + 1)); shift 2
    mkdir -p "$repo/.scratchpads/runs/$r"
    printf '# Run %s\n\n- Status: done\n- Branch: %s\n' "$r" "$t" > "$repo/.scratchpads/runs/$r/run.md"
    rows+="$(printf '| %s | x | done | https://github.com/o/r/pull/%s, a..b: x |' "$r" "$n")"$'\n'
  done
  printf '%s' "$rows" | put_log
}
# done_row <run> <PR number>: one more done row, at the end of the log.
done_row() { printf '| %s | x | done | https://github.com/o/r/pull/%s, a..b: x |\n' "$1" "$2" | put_log; }
guard() { (cd "$repo" && "$new_run" "$@" > "$tmp/out" 2> "$tmp/err"); code=$?; }
gdir() { echo "$repo/.scratchpads/runs/$(date +%Y-%m-%d)-$1"; }
guard_ledger 2026-02-01-f 'feat/f (worktree /x/dirigible-f, from origin/main 1234abcd)' \
  2026-02-02-c 'chore/upkeep-batch-12, cut from origin/main 897b01d3, in the worktree /x/dirigible-upkeep' \
  2026-02-03-r 'refactor/size-split (worktree /x/dirigible-upkeep, from 41bd906c)'
echo '| 2026-02-04-open-feat | x | open | |' | put_log
lines="$("$wiki_tool" runs | wc -l)"
guard speed perf
[[ $code -eq 2 ]] || fail "guard: a third non-feature run exits $code"
grep -qF "new-run: a third non-feature run in a row; give --blocks-feature '<reason>'" "$tmp/err" || fail "guard: no refusal message: $(cat "$tmp/err")"
[[ ! -e "$(gdir speed)" ]] || fail 'guard: the refusal made a run folder'
[[ "$("$wiki_tool" runs | wc -l)" -eq $lines ]] || fail 'guard: the refusal wrote a log row'
guard speed perf --blocks-feature 'R2 needs it'
[[ $code -eq 0 ]] || fail "guard: a run with a reason exits $code: $(cat "$tmp/err")"
awk -F'\t' '$2 == 0 && $3 ~ /third non-feature run/ && $4 == "R2 needs it"' "$(gdir speed)/decisions.tsv" 2>/dev/null | grep -q . || fail "guard: no phase 0 row with the reason: $(cat "$(gdir speed)/decisions.tsv" 2>&1)"
grep -qx -- '- Branch: perf/speed' "$(gdir speed)/run.md" || fail "guard: no Branch line in run.md: $(cat "$(gdir speed)/run.md" 2>&1)"
guard speed perf
[[ $code -eq 0 ]] || fail "guard: a second call for the open run exits $code: $(cat "$tmp/err")"
guard feature feat
[[ $code -eq 0 ]] || fail "guard: a feat run after two non-feature runs exits $code: $(cat "$tmp/err")"
guard_ledger 2026-02-01-c 'chore/a' 2026-02-02-f 'feat/b (worktree /x/y)' 2026-02-03-r 'refactor/c'
guard after-feat fix
[[ $code -eq 0 ]] || fail "guard: a feat run before the last one exits $code: $(cat "$tmp/err")"
# The land order is the PR order, not the log order: a feat run that started first and landed
# last is the newest run. A run with two done rows counts once.
guard_ledger 2026-02-01-f 'feat/f' 2026-02-02-c 'chore/c' 2026-02-03-r 'refactor/r'
new_wiki
echo '| 2026-01-30-old | x | done | no PR |' | put_log
done_row 2026-02-01-f 30; done_row 2026-02-02-c 10; done_row 2026-02-03-r 20
guard land-order fix
[[ $code -eq 0 ]] || fail "guard: a feat run that landed last exits $code: $(cat "$tmp/err")"
new_wiki
done_row 2026-02-02-c 10; done_row 2026-02-01-f 20; done_row 2026-02-03-r 30; done_row 2026-02-03-r 31
guard two-rows fix
[[ $code -eq 0 ]] || fail "guard: a run with two done rows counts twice: exit $code: $(cat "$tmp/err")"
guard bad-type feature
[[ $code -eq 2 ]] || fail "guard: a type that is not a Conventional Commits type exits $code"
[[ ! -e "$(gdir bad-type)" ]] || fail 'guard: a bad type made a run folder'

# The ledger has three done forms: `done` with a pull/<n> URL in the Result cell, `done: PR #<n>, ...`,
# and `done, PR <n>, ...` in the Status cell. The audit counter and the feature guard read all three, and the
# PR number comes from the URL, else from the Status cell. The rows below are not in PR order.
mixed_ledger() { # mixed_ledger <product runs after the architecture run>
  new_wiki
  { printf '| 2026-02-01-p1 | x | done: PR #141, a..b: x | y |\n| 2026-02-02-p2 | x | done | https://x/pull/142, a..b: x |\n'
    printf '| 2026-02-03-p3 | x | done | https://x/pull/130, a..b: x |\n| 2026-02-04-p4 | x | done: PR #131, a..b: x |\n'
    printf '| 2026-02-05-p5 | x | done | https://x/pull/132, a..b: x |\n| 2026-02-06-architecture-x | x | done, PR 143, v0.3.1 | y |\n'
    local i; for i in $(seq "$1"); do printf '| 2026-02-%02d-q%d | x | done, PR %d, v0.3.1 | y |\n' $((6 + i)) "$i" $((143 + i)); done
  } | put_log
  for i in $(seq "$1"); do
    mkdir -p "$repo/.scratchpads/runs/$(printf '2026-02-%02d-q%d' $((6 + i)) "$i")"
    printf '# Run\n\n- Branch: feat/x\n' > "$repo/.scratchpads/runs/$(printf '2026-02-%02d-q%d' $((6 + i)) "$i")/run.md"
  done
}
mixed_ledger 1; audit mixed-one
grep -q 'architecture audit' "$tmp/err" && fail "a reminder after a done, PR 143 architecture row and 1 product run: $(cat "$tmp/err")"
mixed_ledger 5; audit mixed-five
grep -q 'architecture audit due: 5 product runs' "$tmp/err" || fail "no reminder at 5 product runs after a done, PR 143 architecture row: $(cat "$tmp/err")"
grep -q 'scripts/' "$tmp/err" && grep -q '\.githooks' "$tmp/err" || fail "the reminder does not name scripts/ and .githooks: $(cat "$tmp/err")"
# mixed_guard <type of the PR 143 run>: PR 143 (a done, PR row) and PR 142 (a URL row) are the newest lands.
mixed_guard() {
  new_wiki
  printf '| 2026-02-03-g3 | x | done, PR 143, v0.3.1 | y |\n| 2026-02-02-g2 | x | done | https://x/pull/142, a..b: x |\n| 2026-02-01-g1 | x | done: PR #141, a..b: x | y |\n' | put_log
  local r t
  for r in g1:feat g2:docs g3:"$1"; do
    t="${r#*:}" r="2026-02-0${r:1:1}-${r%%:*}"
    mkdir -p "$repo/.scratchpads/runs/$r"
    printf '# Run %s\n\n- Branch: %s/x\n' "$r" "$t" > "$repo/.scratchpads/runs/$r/run.md"
  done
}
mixed_guard docs; guard mixed-docs fix
[[ $code -eq 2 ]] && grep -qF 'a third non-feature run in a row' "$tmp/err" || fail "guard: PR 143 and PR 142 are docs runs, but the exit is $code: $(cat "$tmp/err")"
mixed_guard feat; guard mixed-feat fix
[[ $code -eq 0 ]] || fail "guard: a feat run at PR 143 exits $code: $(cat "$tmp/err")"

# It prints one health line on stderr: the product and the workflow PRs of the runs with a done row
# and a name dated in the last 7 days, the newest test-shards seconds of a done run's push-check.log,
# and the minutes of the hold lines in the last 7 days. A missing source prints none, and the exit is 0.
# Calendar days: a step of 86400 s across a daylight saving change lands on the wrong date near midnight.
days_ago() { date -v-"$1"d +%FT%T; }
new_wiki
old="$(days_ago 8 | cut -c1-10)-ho" prod="$(days_ago 1 | cut -c1-10)-hp" flow="$(days_ago 2 | cut -c1-10)-hw"
printf '| %s | x | open | |\n| %s | x | done | https://x/pull/1 |\n| %s | x | done | https://x/pull/2 |\n| %s | x | done | https://x/pull/3 |\n' \
  "$old" "$old" "$prod" "$flow" | put_log
for r in "$old:feat" "$prod:feat" "$flow:chore"; do
  mkdir -p "$repo/.scratchpads/runs/${r%%:*}/logs"
  printf '# Run\n\n- Branch: %s/x\n' "${r#*:}" > "$repo/.scratchpads/runs/${r%%:*}/run.md"
done
printf 'test-shards: 999 of 999 tests in 999 s\n' > "$repo/.scratchpads/runs/$old/logs/push-check.log"
printf 'test-shards: shard 1 (/x/shard-1.log)\ntest-shards: 512 of 520 tests in 512 s\nlater line\n' > "$repo/.scratchpads/runs/$prod/logs/push-check.log"
holds="$repo/.git/dirigible-build-holds.log"
printf '%s\t600\tmake test\t/t\n%s\t1200\tmake dmg\t/t\tlimit\n%s\t900\tmake test\t/t\n' "$(days_ago 1)" "$(days_ago 2)" "$(days_ago 8)" > "$holds"
(cd "$repo" && "$new_run" health-line feat > /dev/null 2> "$tmp/err") || fail "health: new-run exits $?"
grep -qxF 'health: 7 days: 1 product PRs, 1 workflow PRs; test-shards 512 s; lock held 30 min' "$tmp/err" || fail "health: wrong line: $(cat "$tmp/err")"
rm "$holds" "$repo/.scratchpads/runs/$prod/logs/push-check.log" "$repo/.scratchpads/runs/$old/logs/push-check.log"
(cd "$repo" && "$new_run" health-none feat > /dev/null 2> "$tmp/err") || fail "health: new-run with no source exits $?"
grep -qxF 'health: 7 days: 1 product PRs, 1 workflow PRs; test-shards none; lock held none' "$tmp/err" || fail "health: wrong line with no source: $(cat "$tmp/err")"

[[ $failures -eq 0 ]] && echo "run-files tests: all passed"
exit $((failures > 0))
