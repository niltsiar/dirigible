#!/bin/bash
# Check that check-plan.sh exits 1 and names the failure for a run folder with no Unknowns table,
# an open Unknowns row, a split row with no child row, a slice with no check line, or a plan with
# no Agents: line, or a review file with an Act on item or a taken Consider nit with no Invariant
# or Siblings field, a run research file with no docs/research route in plan.md, or a bare
# research.md, and exits 0 for a good folder, a routed research file, a user row answered with a
# default, a nit tagged no behavior change, a nit that is not taken, and an old review file.
# Check the ## Plan gate changes section of plan.md: each item has a Criteria: field, and each
# criterion ID of a field has a criterion change row from Phase 4 on.
# Run by `make test-hooks`.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/check-plan.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

run="$tmp/run"
# A good run folder: each Unknowns row is answered with a row time, the split row has a child, a
# cell has an escaped bar, and each slice has a check line.
good() {
  rm -rf "$run"
  mkdir "$run"
  cat > "$run/analysis.md" <<'EOF'
# Analysis: x

## Unknowns

| id | parent | question | resolver | answer | row |
|---|---|---|---|---|---|
| U1 | - | Where does the stamp live? | default | In the git dir. Reverse: say in the tree. | 2026-10-01T17:18 |
| U2 | - | How does the filter read `A\|B`? | split | Two child rows. | 2026-10-01T17:19 |
| U3 | U2 | Does swift take two flags? | probe | Yes (logs/p.log). | 2026-10-01T17:20 |

## Out of scope

- y
EOF
  cat > "$run/plan.md" <<'EOF'
# Plan: x

Agents: B = S1, S2 (serial: one index).

## Slices

### S1 one

- First test: a.
- Check: `targets: check-fast`.

### S2 two

- Check: `targets: check-docs`.

## Gates

### Not a slice

- No check line here.
EOF
}

# pass <name>: exit 0. refuse <name> <reason>: exit 1 and the reason in the output.
pass() {
  local out
  out="$("$script" "$run" 2>&1)" || fail "$1: expected exit 0: $out"
}
refuse() {
  local out code
  out="$("$script" "$run" 2>&1)"
  code=$?
  [[ $code -eq 1 ]] || fail "$1: expected exit 1, got $code: $out"
  [[ "$out" == *"$2"* ]] || fail "$1: no '$2' in: $out"
}

good
pass 'all good'

good
sed -i '' '/^## Unknowns/,/^## Out/{/^|/d;}' "$run/analysis.md"
refuse 'an Unknowns heading with no table' 'no ## Unknowns table'
good
sed -i '' 's/^## Unknowns/## Open questions/' "$run/analysis.md"
refuse 'no Unknowns table' 'no ## Unknowns table'

good
sed -i '' 's/| Yes (logs\/p.log). | 2026-10-01T17:20 |/|  | 2026-10-01T17:20 |/' "$run/analysis.md"
refuse 'a row with no answer' 'open unknown: | U3 | U2 | Does swift take two flags?'
good
sed -i '' 's/| Yes (logs\/p.log). | 2026-10-01T17:20 |/| Yes. | - |/' "$run/analysis.md"
refuse 'a row with no row time' 'open unknown: | U3 |'

good
sed -i '' '/^| U3 /d' "$run/analysis.md"
refuse 'a split row with no child' 'split unknown U2 has no child row'

good
sed -i '' '/^- Check: `targets: check-docs`/d' "$run/plan.md"
refuse 'a slice with no check line' 'slice "### S2 two" has no "- Check:" line'
out="$("$script" "$run" 2>&1)"
[[ "$out" != *'S1 one'* && "$out" != *'Not a slice'* ]] || fail "a slice with no check line: another heading is named: $out"

good
sed -i '' '/^Agents:/d' "$run/plan.md"
refuse 'no Agents: line' 'plan.md has no Agents: line'

good
printf '| U4 | - | Which color? | user | Default: blue, logged. Reverse: say red. | 2026-10-01T17:21 |\n' > "$tmp/u4"
sed -i '' "/^| U3 /r $tmp/u4" "$run/analysis.md"
pass 'a user row answered with a default'

good
rm "$run/plan.md"
refuse 'no plan.md' 'no plan.md'

# A run research file needs its docs/research route in plan.md (deliver Phase 2, research skill).
good
echo '# Research: x' > "$run/research-x.md"
refuse 'a research file with no route' 'research-x.md: plan.md does not name docs/research/x.md'
echo '- Slice 1 copies it to docs/research/x.md.' >> "$run/plan.md"
pass 'a research file with its route'
good
echo '# Research' > "$run/research.md"
echo '- Slice 1 adds docs/research/y.md.' >> "$run/plan.md"
refuse 'a bare research.md, also with a route' 'research.md: name it research-<name>.md'

# Each warning or critical "Act on" item of a review file has an Invariant and a Siblings field.
review="$run/review-plan-1.md"
good
printf '## Act on\n\n1. (warning, premortem) A fix.\n   Invariant: x\n\n## Dismissed\n\n- Siblings: y\n' > "$review"
refuse 'an Act on item with no Siblings field' 'review-plan-1.md: Act on item 1 has no Siblings field'
refuse 'the hint for an old review file' 'a review file from before the rule: add the fields, or do not edit it'
good
printf '## Act on\n\n1. (nit, x) A nit.\n2. (Critical, x) A fix. Siblings: none, grepped x.\n' > "$review"
refuse 'an Act on item with no Invariant field' 'review-plan-1.md: Act on item 2 has no Invariant field'
good
printf '## Act on\n\n1. (nit, x; no behavior change) A nit.\n2. (critical, x) A fix.\n   - **Invariant (state):** x\n   - **Siblings:** y\n' > "$review"
pass 'a no behavior change nit with no field and a critical item with both fields'
# A taken nit needs both fields too, unless its tag has `no behavior change` (INT-042). A review
# file from before the nit rule keeps the old rule.
good
printf '## Act on\n\n1. (nit, x) A nit.\n' > "$review"
refuse 'an Act on nit with no field' 'review-plan-1.md: Act on item 1 has no Invariant field'
good
printf '## Consider\n\n- (nit, x; taken) A note.\n- (nit, y) Another note.\n' > "$review"
refuse 'a taken Consider nit with no field' 'review-plan-1.md: Consider item 1 has no Siblings field'
good
printf '## Consider\n\n- (nit, x) A note. Taken: a test case.\n' > "$review"
refuse 'a Consider nit with Taken outside the first parenthesis' 'review-plan-1.md: Consider item 1 has no Invariant field'
good
printf '## Consider\n\n- S3 (bash 3.2) is slow. (nit, x; taken) A note.\n' > "$review"
refuse 'a Consider nit whose tag is not the first parenthesis' 'review-plan-1.md: Consider item 1 has no Invariant field'
good
printf '## Consider\n\n- (warning, x) The taken-nit rule names no tag.\n' > "$review"
pass 'a Consider warning that names the taken-nit rule'
good
printf '## Consider\n\n- (nit, x; not taken) A note. Not taken: no case.\n' > "$review"
pass 'a Consider nit with not taken in and outside the parenthesis'
good
printf '## Consider\n\n- (nit, x; taken) A note.\n  - Invariant: x\n  - Siblings: y\n' > "$review"
pass 'a taken Consider nit with both fields'
good
printf '## Consider\n\n- (nit, x; taken, no behavior change) A note.\n' > "$review"
pass 'a taken no behavior change Consider nit with no field'
good
printf '## Consider\n\n- (nit, x) A note.\n' > "$review"
pass 'a Consider nit that is not taken'
good
printf '## Consider\n\n- (nit, x; not taken) A note.\n' > "$review"
pass 'a Consider nit tagged not taken'
good
printf '## Act on\n\n1. (nit, x) A nit.\n\n## Consider\n\n- (nit, x; taken) A note.\n' > "$review"
touch -t 202610080000 "$review"
pass 'a review file from before the nit rule'
good
printf '## Act on\n\n1. A fix with no tag.\n   Invariant: x\n' > "$review"
refuse 'an untagged Act on item with no Siblings field' 'review-plan-1.md: Act on item 1 has no Siblings field'
good
printf '## Act on (all fixed)\n\n1. (warning, x) A fix.\n   Siblings: y\n' > "$review"
refuse 'an Act on heading with more words' 'review-plan-1.md: Act on item 1 has no Invariant field'
good
printf '## Act on\n\n- **A1 (warning, x).** A fix.\n' > "$review"
refuse 'an Act on section with a bullet item' 'review-plan-1.md: ## Act on has no numbered item'
good
printf '## Act on\n\nNone.\n\n## Consider\n\n- A note.\n' > "$review"
pass 'an empty Act on section'
good
printf '## Act on\n\n1. (warning, x) A fix.\n' > "$review"
touch -t 202601010000 "$review"
pass 'a review file older than the field rule'

# The fixture item comes from the one owner of the format: the Act on line of the interrogate
# ## Output format. A change of that line that this test cannot parse, or that check-plan.sh
# does not read, fails here.
format="$(dirname "$script")/../.claude/skills/interrogate/SKILL.md"
act_on="$(awk '/^## /{ s = $0; next } s == "## Output format" && /^- \*\*Act on:\*\*/' "$format")"
tag="$(grep -oE '`\([^`]*\)`' <<<"$act_on" | head -n 1 | tr -d '`')"
fields=()
while IFS= read -r f; do fields+=("$f"); done < <(sed -n 's/.*, then \(.*\)\.$/\1/p' <<<"$act_on" | grep -oE '\b[A-Z][a-z]+\b')
if [[ "$tag" != *"<severity>"* || ${#fields[@]} -ne 2 ]]; then
  fail "the Act on line of $format: no tag with <severity>, or not two field names: $act_on"
else
  item="${tag/<severity>/warning}"
  item="${item/<lenses>/premortem}"
  good
  printf '## Act on\n\n1. %s A fix.\n' "$item" > "$review"
  refuse 'an item of the Act on format with no fields' "review-plan-1.md: Act on item 1 has no ${fields[0]} field"
  refuse 'an item of the Act on format with no fields' "review-plan-1.md: Act on item 1 has no ${fields[1]} field"
  good
  printf '## Act on\n\n1. %s A fix.\n   - %s: x\n   - %s: y\n' "$item" "${fields[0]}" "${fields[1]}" > "$review"
  pass 'an item of the Act on format with both fields'
fi

# gate <items>: a good folder whose plan.md ends with a ## Plan gate changes section.
gate() {
  good
  printf '\n## Plan gate changes (review-plan-1.md)\n\n%s\n\n## After\n\n- not an item\n' "$1" >> "$run/plan.md"
}
# row <phase> <decision>: append a decisions.tsv row.
row() { printf '2026-10-01T10:00\t%s\t%s\twhy\tevidence\tdone\n' "$1" "$2" >> "$run/decisions.tsv"; }
gate $'1. S2: a new case.\n   Criteria: none'
pass 'a plan gate change with Criteria: none'
gate $'1. S2: a new case.'
refuse 'a numbered plan gate change with no Criteria field' 'Plan gate changes item 1 has no Criteria: field'
refuse 'the refusal names the format' 'Criteria: <IDs separated by commas> or Criteria: none'
gate $'- Slice 1: a new case.\n  - a nested bullet of the item'
refuse 'a bullet plan gate change with no Criteria field' 'Plan gate changes item 1 has no Criteria: field'
gate $'- Slice 1: a new case.\n  - Criteria: none\n- Slice 2: another case.'
refuse 'the second item with no Criteria field' 'Plan gate changes item 2 has no Criteria: field'
good
printf '\n## Plan gate 2 changes\n\n1. S2: a round 2 case.\n' >> "$run/plan.md"
refuse 'a numbered Plan gate 2 changes section' 'Plan gate changes item 1 has no Criteria: field'
# Before Phase 4 a missing row can still come, so only a phase 4 row, or CHECK_PLAN_AT_PHASE4=1
# (log-decision.sh before the first phase 4 row), makes a missing row a failure.
gate $'1. S2: a new case. Criteria: C8, C3b'
pass 'a Criteria field with no decisions.tsv yet'
row 3 'criterion change C8: old 3 s, new 5 s'
pass 'a missing criterion change row before Phase 4'
export CHECK_PLAN_AT_PHASE4=1
refuse 'a criterion with no criterion change row' 'criterion C3b of a plan gate change has no criterion change row'
refuse 'the refusal says to edit analysis.md first' 'edit analysis.md first'
refuse 'with no phase 4 row, the refusal says before Phase 4' 'criterion change row before Phase 4;'
row 3 'Criterion change C3: old a, new b'
refuse 'a row for C3 does not count for C3b' 'criterion C3b of a plan gate change has no criterion change row'
row 3 'criterion change C3b: old a, new b'
pass 'each criterion has a row at the start of Phase 4'
unset CHECK_PLAN_AT_PHASE4
row 4 'Slice S1 committed'
pass 'each criterion has a row before the first phase 4 row'
gate $'1. S2: a new case. Criteria: C1'
row 4 'Slice S1 committed'
refuse 'after a phase 4 row, the refusal does not say before Phase 4' 'criterion C1 of a plan gate change has no criterion change row; edit'
# A change of the code gate adds an item after Phase 4 starts. log-decision.sh refused the first
# phase 4 row while an earlier item had no row, so a row at any position counts here.
row 3 'criterion change C1: old a, new b'
pass 'a late item with its criterion change row after the first phase 4 row'
gate $'1. S2: a new case. Criteria: C1'
row 3 'criterion change C12: old a, new b'
row 4 'Slice S1 committed'
refuse 'a row for C12 does not count for C1' 'criterion C1 of a plan gate change'
good
printf '\n## Not the section\n\n1. An item with no field.\n' >> "$run/plan.md"
pass 'a numbered item outside the Plan gate changes section'

# The decision number of a record that the plan makes. A fixture repo holds a copy of the script,
# docs/decisions/0042-old.md on origin/main, and .scratchpads/ledger.md beside runs/.
repo="$tmp/repo"
mkdir -p "$repo/scripts" "$repo/docs/decisions" "$repo/.scratchpads/runs"
cp "$script" "$repo/scripts/"
echo old > "$repo/docs/decisions/0042-old.md"
git -C "$repo" init -q && git -C "$repo" add docs \
  && git -C "$repo" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q -m one \
  && git -C "$repo" update-ref refs/remotes/origin/main HEAD
rm "$repo/docs/decisions/0042-old.md" # only origin/main has it now
saved_script="$script" saved_run="$run"
script="$repo/scripts/check-plan.sh" run="$repo/.scratchpads/runs/2026-10-14-new-thing"
ledger="$repo/.scratchpads/ledger.md"
reserve() { printf '# Run ledger\n\nDecision numbers taken or reserved (reserve at Phase 2): 0042 old (run 2026-10-01-old, landed), %s\n' "$1" > "$ledger"; }
makes() { good && printf -- '\n- Modules: `%s` (the new record).\n' "$1" >> "$run/plan.md"; }

reserve '0043 other-title (run 2026-10-13-other)'
makes docs/decisions/0044-new-thing.md
refuse 'a new record with no ledger entry' 'reserve 0044 on the Decision numbers line'
reserve '0044 new-thing (run 2026-10-13-other)'
makes docs/decisions/0044-new-thing.md
refuse 'a number that another run holds' 'reserve 0044 on the Decision numbers line'
reserve '0044 new-thing (run 2026-10-14-new-thing)'
makes docs/decisions/0044-new-thing.md
pass 'a number reserved for this run'
reserve '0044 new-thing (run 2026-10-14-new-thing, landed)'
pass 'a reserved entry with a note after the run folder'
makes docs/decisions/0042-old.md
pass 'a record on origin/main'
makes docs/decisions/0042-mine.md
refuse 'another record with the number on origin/main' 'docs/decisions/0042-old.md has the number 0042'
makes docs/decisions/0045-local.md
echo local > "$repo/docs/decisions/0045-local.md"
refuse 'the own record in the worktree with no reservation' 'reserve 0045 on the Decision numbers line'
reserve '0045 local (run 2026-10-14-new-thing)'
pass 'the own record in the worktree with its reservation'
rm "$repo/docs/decisions/0045-local.md"
reserve '0042 mine (run 2026-10-14-new-thing)'
makes docs/decisions/0042-mine.md
echo mine > "$repo/docs/decisions/0042-mine.md"
refuse 'the own record in the worktree and another record with the number on origin/main' 'docs/decisions/0042-old.md has the number 0042'
rm "$repo/docs/decisions/0042-mine.md"
reserve '0044 new-thing (run 2026-10-14-new-thing)'
makes docs/decisions/0044-new-thing.md
printf '\nIt amends decision 0046, cites 0047 (run 10), and has 2048 characters.\n' >> "$run/plan.md"
pass 'cited numbers with no record file path'
rm "$ledger"
makes docs/decisions/0044-new-thing.md
refuse 'no ledger' 'no ledger.md'
makes docs/decisions/0044-new-thing.md
row 3 'plan gate round 1'
pass 'a run whose plan gate came before the rule'
script="$saved_script" run="$saved_run"

out="$("$script" 2>&1)"
code=$?
[[ $code -eq 2 && "$out" == usage:* ]] || fail "no argument: exit $code: $out"

[[ $failures -eq 0 ]] && echo "check-plan tests: all passed"
exit $((failures > 0))
