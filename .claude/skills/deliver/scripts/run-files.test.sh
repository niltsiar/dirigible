#!/bin/bash
# Check that log-decision.sh appends one row of six tab-separated columns from a five-line file
# (--from), changes a tab in a field to a space, refuses a file with four lines and appends
# nothing, keeps the six-argument form, and refuses a row whose decision or result starts with
# default and whose why has no `Reverse:` (any case), and refuses a phase that is not one digit.
# Check that a criterion change row needs a newer analysis.md and the words old and new. Check
# that the first phase 4 row of a run folder with a plan.md needs a passing scripts/check-plan.sh
# (a Criteria: field for each plan gate change, and a criterion change row for each ID).
# Check that new-run.sh reports the backlog sections, the upkeep items, and a due architecture
# audit, and that it refuses a third non-feature run in a row with no --blocks-feature reason.
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

printf '4\na\tb\nwhy\nevidence\ndone\n' > "$tmp/tab"
"$log" "$run" --from "$tmp/tab" || fail "--from with a tab exits $?"
check_row 'a tab in a field' $'4\ta b\twhy\tevidence\tdone'

before="$(shasum -a 256 "$run/decisions.tsv")"
printf '4\ndecision\nwhy\nevidence\n' > "$tmp/four"
err="$("$log" "$run" --from "$tmp/four" 2>&1)"
code=$?
[[ $code -eq 2 ]] || fail "four lines: expected exit 2, got $code"
[[ "$err" == *"five lines"* ]] || fail "four lines: no reason in the message: $err"
[[ "$(shasum -a 256 "$run/decisions.tsv")" == "$before" ]] || fail 'four lines: decisions.tsv changed'

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

# The phase is one digit, so land.sh finds the control rows of phase 2 and 4.
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

# A criterion change row needs an analysis.md that changed after the last row, and the words old
# and new. /bin/bash compares whole seconds, so touch -t puts decisions.tsv in the past.
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
touch -t 200001010000 "$run/analysis.md"
refused 'a criterion change with an old analysis.md' analysis.md "${change[@]}"
touch "$run/analysis.md"
touch -t 200001010000 "$run/decisions.tsv"
refused 'a criterion change with no old and new' 'old and new' 4 'criterion change C1: 5 s' 'the probe gives 4 s' evidence done
"$log" "$run" "${change[@]}" || fail "a criterion change after an analysis.md edit exits $?"
check_row 'a criterion change after an analysis.md edit' $'4\tCriterion change C1: old 3 s, new 5 s\tthe probe gives 4 s\tevidence\tdone'
refused 'a second criterion change with no new analysis.md edit' analysis.md "${change[@]}"
"$log" "$run" 7 'criterion 4 verified' 'the test passes' evidence done || fail "a criterion verification row exits $?"

# Each phase 4 row of a run with a plan.md runs scripts/check-plan.sh on the run folder: a plan
# gate change with no Criteria: field, or a criterion with no criterion change row, refuses the
# row, while a fix can still come before Phase 4. A run with no plan.md is not checked.
gated="$tmp/gated"
mkdir "$gated"
printf '# A\n\n## Unknowns\n\n| id | parent | question | resolver | answer | row |\n|---|---|---|---|---|---|\n| U1 | - | q | code | a | 2026-10-01T10:00 |\n' > "$gated/analysis.md"
printf '# P\n\nAgents: one.\n\n## Slices\n\n### S1\n\n- Check: x\n\n## Plan gate changes\n\n1. S1: a case.\n' > "$gated/plan.md"
: > "$gated/decisions.tsv"
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
touch "$gated/analysis.md"
touch -t 200001010000 "$gated/decisions.tsv"
"$log" "$gated" 3 'criterion change C8: old 3 s, new 5 s' why evidence done || fail "the criterion change row for C8 exits $?"
"$log" "$gated" 4 'Slice S1 committed' why evidence done || fail "the first phase 4 row after the C8 row exits $?"
printf '# P\n\nAgents: one.\n\n## Slices\n\n### S1\n\n- Check: x\n\n## Plan gate changes\n\n1. S1: a case.\n' > "$gated/plan.md"
"$log" "$gated" 4 'Slice S2 committed' why evidence done 2>/dev/null
[[ $? -eq 2 ]] || fail "a second phase 4 row with a plan item with no Criteria field was not refused"
# A late plan gate change (C5, after the first phase 4 row) passes once its row is in.
printf '# P\n\nAgents: one.\n\n## Slices\n\n### S1\n\n- Check: x\n\n## Plan gate changes\n\n1. S1: a case. Criteria: C8\n2. S1: a late case. Criteria: C5\n' > "$gated/plan.md"
"$log" "$gated" 4 'Slice S3 committed' why evidence done 2>/dev/null
[[ $? -eq 2 ]] || fail "a phase 4 row with a late C5 and no row was not refused"
touch "$gated/analysis.md"
touch -t 200001010000 "$gated/decisions.tsv"
"$log" "$gated" 6 'criterion change C5: old a, new b' why evidence done || fail "the criterion change row for C5 exits $?"
"$log" "$gated" 4 'Slice S3 committed' why evidence done || fail "the next phase 4 row after the late C5 row exits $?"

# new-run.sh reports the backlog sections on stderr and keeps stdout to the run folder. It warns
# when ## Next is over 1000 words, writes `- Later items: <n>` in the new run.md, and prints the
# Later count with the change from the `Later items:` line of the last run.md. It makes the logs/
# folder, where cost.sh of reflect counts the check and bench logs.
new_run="$(dirname "$log")/new-run.sh"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
repo="$tmp/repo"
mkdir -p "$repo/.scratchpads/runs/2026-01-01-old"
git -C "$repo" init -q
words="$(printf 'w%.0s ' $(seq 1000))"
printf '# Backlog\n\n## Next\n\n- %s\n\n## Later\n\n- a\n- b\n\n### From run x\n\n- c\n' "$words" > "$repo/.scratchpads/backlog.md"
printf '# Run 2026-01-01-old\n\n- Later items: 1\n' > "$repo/.scratchpads/runs/2026-01-01-old/run.md"
out="$(cd "$repo" && "$new_run" big feat 2> "$tmp/err")" || fail "new-run with a long ## Next exits $?"
dir="$repo/.scratchpads/runs/$(date +%Y-%m-%d)-big"
[[ "$out" == "$(cd "$repo" && pwd -P)/.scratchpads/runs/$(date +%Y-%m-%d)-big" ]] || fail "new-run stdout is not the run folder: $out"
grep -q '## Next.*1001 words' "$tmp/err" || fail "no warning that names ## Next and 1001 words: $(cat "$tmp/err")"
grep -qx -- '- Later items: 3' "$dir/run.md" || fail "run.md has no '- Later items: 3' line"
[[ -d "$dir/logs" ]] || fail 'new-run made no logs/ folder'
grep -q '## Later has 3 items (+2 since 2026-01-01-old)' "$tmp/err" || fail "no Later count with the change: $(cat "$tmp/err")"

# It writes analysis.md and plan.md skeletons, so a subagent fills them with the Edit tool.
# check-plan.sh refuses the skeletons, and a second call for the open run keeps each edited file.
grep -qx '## Unknowns' "$dir/analysis.md" && grep -qx '| id | parent | question | resolver | answer | row |' "$dir/analysis.md" ||
  fail "no analysis.md skeleton with the Unknowns header line: $(cat "$dir/analysis.md" 2>&1)"
grep -qx '## Slices' "$dir/plan.md" || fail "no plan.md skeleton with ## Slices: $(cat "$dir/plan.md" 2>&1)"
out="$("$(cd "$(dirname "$log")/../../../.." && pwd)/scripts/check-plan.sh" "$dir" 2>&1)"
code=$?
[[ $code -eq 1 && "$out" == *'no ## Unknowns table with rows'* ]] || fail "check-plan.sh on the skeletons: exit $code: $out"
echo '| U1 | - | q | code | a | 2026-01-01T00:00 |' >> "$dir/analysis.md"
echo '### S1' >> "$dir/plan.md"
before="$(cat "$dir/analysis.md" "$dir/plan.md" | shasum)"
(cd "$repo" && "$new_run" big feat > /dev/null 2>&1) || fail "new-run again for the open run exits $?"
[[ "$(cat "$dir/analysis.md" "$dir/plan.md" | shasum)" == "$before" ]] || fail 'a second new-run changed an edited skeleton'

printf '# Backlog\n\n## Next\n\n- short\n\n## Later\n\n- a\n' > "$repo/.scratchpads/backlog.md"
rm -r "$dir"
printf '# Run 2026-01-01-old\n' > "$repo/.scratchpads/runs/2026-01-01-old/run.md"
(cd "$repo" && "$new_run" small feat > /dev/null 2> "$tmp/err") || fail "new-run with a short ## Next exits $?"
grep -q 'Next' "$tmp/err" && fail "warning for a short ## Next: $(cat "$tmp/err")"
grep -qx 'backlog: ## Later has 1 items' "$tmp/err" || fail "no Later count without a last count: $(cat "$tmp/err")"
grep -qx 'upkeep items: 0' "$tmp/err" || fail "no upkeep count of 0: $(cat "$tmp/err")"
grep -q 'warning' "$tmp/err" && fail "warning with no upkeep item: $(cat "$tmp/err")"

# It counts the upkeep items of ## Next only, and warns at 8 or more (reflect rule 6): 7 items in
# ## Next and one in ## Later give no warning; 8 items in ## Next give one.
items() { for i in $(seq "$1"); do printf -- '- upkeep k%d: x\n' "$i"; done; }
printf '# Backlog\n\n## Next\n\n%s\n\n## Later\n\n- upkeep d: x\n' "$(items 7)" > "$repo/.scratchpads/backlog.md"
(cd "$repo" && "$new_run" upkeep-seven feat > /dev/null 2> "$tmp/err") || fail "new-run with 7 upkeep items exits $?"
grep -qx 'upkeep items: 7' "$tmp/err" || fail "no upkeep count of 7: $(cat "$tmp/err")"
grep -q 'warning' "$tmp/err" && fail "warning at 7 upkeep items: $(cat "$tmp/err")"
printf '# Backlog\n\n## Next\n\n%s\n\n## Later\n\n- upkeep d: x\n' "$(items 8)" > "$repo/.scratchpads/backlog.md"
(cd "$repo" && "$new_run" upkeep feat > /dev/null 2> "$tmp/err") || fail "new-run with 8 upkeep items exits $?"
grep -qx 'upkeep items: 8' "$tmp/err" || fail "no upkeep count of 8: $(cat "$tmp/err")"
grep -q 'warning:.*upkeep run' "$tmp/err" || fail "no warning at 8 upkeep items: $(cat "$tmp/err")"

# It reminds of an architecture audit at 5 distinct product runs after the last run whose name has
# architecture and a done row. A run has an open and a done row. The current run, and a run whose name has
# workflow, upkeep, or docs, do not count.
ledger_rows() {
  printf '# Run ledger\n\n| Run | Goal | Status | Result |\n|---|---|---|---|\n' > "$repo/.scratchpads/ledger.md"
  local r
  for r in "$@"; do printf '| %s | x | open | |\n| %s | x | done | |\n' "$r" "$r" >> "$repo/.scratchpads/ledger.md"; done
}
audit() { (cd "$repo" && "$new_run" "$1" feat > /dev/null 2> "$tmp/err") || fail "new-run $1 exits $?"; }
ledger_rows 2026-01-01-architecture-a 2026-01-02-p1 2026-01-03-p2 2026-01-04-p3 2026-01-05-p4
audit audit-four
grep -q 'architecture audit' "$tmp/err" && fail "a reminder at 4 product runs: $(cat "$tmp/err")"
ledger_rows 2026-01-01-architecture-a 2026-01-02-p1 2026-01-03-p2 2026-01-04-p3 2026-01-05-p4 2026-01-06-p5
audit audit-five
grep -q 'architecture audit due: 5 product runs' "$tmp/err" || fail "no reminder at 5 product runs: $(cat "$tmp/err")"
ledger_rows 2026-01-02-p1 2026-01-03-p2 2026-01-04-p3 2026-01-05-p4 2026-01-06-p5
printf '| 2026-01-07-architecture-b | x | open | |\n' >> "$repo/.scratchpads/ledger.md"
audit audit-open
grep -q 'architecture audit due: 5 product runs' "$tmp/err" || fail "an open architecture run reset the count: $(cat "$tmp/err")"
printf '| 2026-01-07-architecture-b | x | done | |\n' >> "$repo/.scratchpads/ledger.md"
audit audit-reset
grep -q 'architecture audit' "$tmp/err" && fail "a reminder after a done architecture run: $(cat "$tmp/err")"
ledger_rows 2026-01-01-architecture-a 2026-01-02-workflow-a 2026-01-03-upkeep-b 2026-01-04-docs-c 2026-01-05-workflow-d 2026-01-06-docs-e
audit audit-docs
grep -q 'architecture audit' "$tmp/err" && fail "a reminder for workflow, upkeep, and docs runs: $(cat "$tmp/err")"

# It refuses a third non-feature run in a row: the two newest done rows of the ledger (open rows do
# not count) have a run.md branch type other than feat, and the new type is not feat. The type is
# the text between "- Branch: " and the first slash, as the real run.md lines have it.
guard_ledger() {
  printf '# Run ledger\n\n| Run | Goal | Status | Result |\n|---|---|---|---|\n' > "$repo/.scratchpads/ledger.md"
  local r t
  while [[ $# -gt 0 ]]; do
    r="$1" t="$2"; shift 2
    mkdir -p "$repo/.scratchpads/runs/$r"
    printf '# Run %s\n\n- Status: done\n- Branch: %s\n' "$r" "$t" > "$repo/.scratchpads/runs/$r/run.md"
    printf '| %s | x | done | |\n' "$r" >> "$repo/.scratchpads/ledger.md"
  done
}
guard() { (cd "$repo" && "$new_run" "$@" > "$tmp/out" 2> "$tmp/err"); code=$?; }
gdir() { echo "$repo/.scratchpads/runs/$(date +%Y-%m-%d)-$1"; }
guard_ledger 2026-02-01-f 'feat/f (worktree /x/dirigible-f, from origin/main 1234abcd)' \
  2026-02-02-c 'chore/upkeep-batch-12, cut from origin/main 897b01d3, in the worktree /x/dirigible-upkeep' \
  2026-02-03-r 'refactor/size-split (worktree /x/dirigible-upkeep, from 41bd906c)'
printf '| 2026-02-04-open-feat | x | open | |\n' >> "$repo/.scratchpads/ledger.md"
lines="$(wc -l < "$repo/.scratchpads/ledger.md")"
guard speed perf
[[ $code -eq 2 ]] || fail "guard: a third non-feature run exits $code"
grep -qF "new-run: a third non-feature run in a row; give --blocks-feature '<reason>'" "$tmp/err" || fail "guard: no refusal message: $(cat "$tmp/err")"
[[ ! -e "$(gdir speed)" ]] || fail 'guard: the refusal made a run folder'
[[ "$(wc -l < "$repo/.scratchpads/ledger.md")" -eq $lines ]] || fail 'guard: the refusal wrote a ledger line'
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
guard bad-type feature
[[ $code -eq 2 ]] || fail "guard: a type that is not a Conventional Commits type exits $code"
[[ ! -e "$(gdir bad-type)" ]] || fail 'guard: a bad type made a run folder'

[[ $failures -eq 0 ]] && echo "run-files tests: all passed"
exit $((failures > 0))
