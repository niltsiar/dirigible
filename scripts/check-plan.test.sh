#!/bin/bash
# Check that check-plan.sh exits 1 and names the failure for a run folder with no Unknowns table,
# an open Unknowns row, a split row with no child row, a slice with no check line, or a plan with
# no Agents: line, or a review file with an Act on item or a taken Consider nit with no Invariant
# or Siblings field, a run research file with no docs/research route in plan.md, or a bare
# research.md, and exits 0 for a good folder, a routed research file, a user row answered with a
# default, a nit tagged no behavior change, a nit that is not taken, and an old review file.
# Check the ## Plan gate changes section of plan.md: each item has a Criteria: field, and each
# criterion ID of a field has a criterion change row from Phase 4 on.
# Check that CHECK_PLAN_AT_PHASE4=1 needs a review-plan-<n>.md file and a phase 3 row after the last
# phase 2 row, and that the land check without it does not.
# Check that with CHECK_PLAN_AT_PHASE4=1 the last round file has a ## Fix check when a round file has an Act on item.
# Check that plan.md names each criterion ID of the ## Acceptance criteria section of analysis.md.
# Run by `make test-hooks`.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/check-plan.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# The decision numbers come from the wiki of scripts/wiki.py. DIRIGIBLE_WIKI names a temp wiki, so
# no case reads or writes the real one. The identity of the wiki commits is in the environment,
# because the git config of the machine is not a test input.
wiki_tool="$(dirname "$script")/wiki.py"
export DIRIGIBLE_WIKI="$tmp/wiki"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
new_wiki() { rm -rf "$DIRIGIBLE_WIKI"; "$wiki_tool" init > /dev/null || fail 'wiki init'; }
new_wiki

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

# A heading with a suffix (`## Slices (serial)`) is a Slices section, as for the landings rule.
good
sed -i '' 's/^## Slices$/## Slices (serial)/' "$run/plan.md"
sed -i '' '/^- Check: `targets: check-docs`/d' "$run/plan.md"
refuse 'a slice with no check line under a suffixed heading' 'slice "### S2 two" has no "- Check:" line'
good
sed -i '' 's/^## Slices$/## Slices (serial)/' "$run/plan.md"
pass 'a suffixed Slices heading and every check line'
good
sed -i '' 's/^## Slices$/## Slicesx/' "$run/plan.md"
sed -i '' '/^- Check: `targets: check-docs`/d' "$run/plan.md"
out="$("$script" "$run" 2>&1)"
[[ "$out" != *'has no "- Check:" line'* ]] || fail "a heading Slicesx is no Slices section: $out"

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
row() { printf '%s\t%s\t%s\twhy\tevidence\tdone\n' "${ROW_AT:-2026-10-01T10:00}" "$1" "$2" >> "$run/decisions.tsv"; }
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
: > "$run/review-plan-1.md"
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

# The plan gate must be closed at the first phase 4 row (CHECK_PLAN_AT_PHASE4=1, which log-decision.sh
# sets): a review-plan-<n>.md file, and a phase 3 row after the last phase 2 row. The land check
# of an old run has no such variable, so a run with phase 4 rows and no review-plan file passes.
good
row 2 'plan written'
CHECK_PLAN_AT_PHASE4=1 refuse 'a phase 4 row with no review-plan file' 'review-plan-<n>.md'
CHECK_PLAN_AT_PHASE4=1 refuse 'the refusal names the plan gate' 'deliver Phase 3'
row 3 'plan gate 1'
CHECK_PLAN_AT_PHASE4=1 refuse 'a phase 3 row with no review-plan file' 'review-plan-<n>.md'
: > "$run/review-plan-1.md"
CHECK_PLAN_AT_PHASE4=1 pass 'a review-plan file and a phase 3 row after the phase 2 row'
row 2 'plan changed after the gate'
CHECK_PLAN_AT_PHASE4=1 refuse 'a phase 2 row after the last phase 3 row' 'phase 2 row'
row 3 'plan gate 2'
CHECK_PLAN_AT_PHASE4=1 pass 'a phase 3 row after the last phase 2 row'
good
: > "$run/review-plan-1.md"
row 2 'plan written'
CHECK_PLAN_AT_PHASE4=1 refuse 'a review-plan file and a phase 2 row with no phase 3 row' 'phase 3 row'
good
row 2 'plan written'
row 4 'Slice S1 committed'
pass 'phase 4 rows and no review-plan file at the land check'

# Criterion coverage: plan.md names each ID of the ## Acceptance criteria section of analysis.md,
# in ## Slices or ## Criteria map, as a whole word or inside a range. A run whose decisions.tsv
# starts before the rule (2026-10-20T11:35) is not checked. The good() fixture has no such section.
# criteria <lines>: good() plus an ## Acceptance criteria section. names <text>: the First test line
# of slice S1 becomes <text>.
criteria() { good; printf '\n## Acceptance criteria\n\n%s\n' "$1" >> "$run/analysis.md"; }
names() { sed -i '' "s/^- First test: a\.\$/- First test: $1./" "$run/plan.md"; }
CRIT=$'- **C1.** a\n- C2: b'
criteria "$CRIT"
names 'C1'
refuse 'a criterion that plan.md does not name' 'criterion C2'
refuse 'the refusal names the file and the sections' 'plan.md does not name criterion C2 of analysis.md; name it under ## Slices, ## Criteria map, or ## Plan gate changes (a range such as C2 to C5 counts)'
good
printf '\n## Criteria map\n\nC1 is proven.\n' >> "$run/plan.md"
sed -i '' '1a\
\
- R5 is the release of this run.
' "$run/analysis.md"
printf '\n## Acceptance criteria\n\n- C1: a\n' >> "$run/analysis.md"
pass 'an item above the first heading of analysis.md is no criterion'
criteria "$CRIT"
names 'C1 and C2'
pass 'each criterion named'
criteria $'- **C1.** a\n- C2: b\n- C3: c'
names 'C1 to C3'
pass 'a range with to'
criteria $'- **C1.** a\n- C2: b\n- C3: c'
names 'C1-C3'
pass 'a range with a hyphen'
criteria $'- **C1.** a\n- C2: b\n- C4: c'
names 'C1 to C3'
refuse 'an ID outside the range' 'criterion C4'
SUF=$'- C4a: a\n- C4b: b\n- C4c: c\n- C4d: d'
criteria "$SUF"
names 'C4a to C4d'
pass 'a range of suffixed IDs with to'
criteria "$SUF"
names 'C4a-C4d'
pass 'a range of suffixed IDs with a hyphen'
criteria "$SUF"
names 'C4b-C4c and C4a, C4d'
pass 'a narrow suffixed range and single IDs'
criteria $'- C4a: a\n- C4e: e'
names 'C4a to C4d'
refuse 'a suffix after the end of the range' 'criterion C4e'
criteria $'- C1a: a\n- C1b: b\n- C2: c\n- C3: d'
names 'C1a-C3'
pass 'a range with a suffix at one end only'
criteria $'- C1a: a\n- C1b: b\n- C2: c\n- C3: d\n- C4: e'
names 'C1b to C3'
refuse 'a suffix before the start of the range' 'criterion C1a'
criteria $'- **C1.** a\n- C2: b\n- C3: c'
names 'C1 to D3'
refuse 'a range with two prefixes' 'criterion C2'
criteria '- **C1.** a'
names 'C12'
refuse 'C12 does not name C1' 'criterion C1 of analysis.md'
criteria $'| id | text |\n|---|---|\n| C4 | a |'
refuse 'a table row with no ID in plan.md' 'criterion C4'
names 'C4'
pass 'a table row with its ID in plan.md'
criteria $'1. **C1** a\n   - C9: a nested item\n\n### Sub\n\n- C2: b'
names 'C1 and C2'
pass 'a nested item is no ID and a subheading stays in the section'
criteria "$CRIT"
names 'C1'
printf '\n## Criteria map\n\n| C2 | S1 |\n' >> "$run/plan.md"
pass 'a criterion named in the Criteria map'
criteria "$CRIT"
names 'C1'
printf '\n## Criteria map (round 2)\n\n| C2 | S1 |\n' >> "$run/plan.md"
pass 'a Criteria map heading with a suffix'
criteria "$CRIT"
sed -i '' 's/^## Slices$/## Slices (serial)/' "$run/plan.md"
names 'C1 and C2'
pass 'a Slices heading with a suffix'
criteria "$CRIT"
names 'C1'
printf '\n## Plan gate 2 changes\n\n1. S2: a case.\n   Criteria: none\n   Covers C2.\n' >> "$run/plan.md"
pass 'a criterion named in a Plan gate 2 changes section'
criteria "$CRIT"
names 'C1'
printf '\n## Slicesx\n\nC2 here.\n' >> "$run/plan.md"
refuse 'a heading that only starts with Slices' 'criterion C2'
criteria "$CRIT"
sed -i '' 's/^Agents:/Inputs: criteria C1 to C2.\nAgents:/' "$run/plan.md"
names 'C1'
refuse 'a range above the Slices section' 'criterion C2'
criteria "$CRIT"
names 'C1'
printf '2026-10-01T10:00\t2\tplan written\twhy\tevidence\tdone\n' > "$run/decisions.tsv"
pass 'a run whose first row is older than the rule, with no phase 3 row'
printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n2026-10-01T10:00\t2\tplan written\twhy\tevidence\tdone\n' > "$run/decisions.tsv"
pass 'an old first row after a header row'
printf '2026-10-20T11:35\t2\tplan written\twhy\tevidence\tdone\n' > "$run/decisions.tsv"
refuse 'a run whose first row is at the cutoff' 'criterion C2'
printf '2026-10-21T10:00\t2\tplan written\twhy\tevidence\tdone\n' > "$run/decisions.tsv"
refuse 'a run whose first row is after the cutoff' 'criterion C2'

# The decision number of a record that the plan makes. A fixture repo holds a copy of the script and
# of wiki.py, and docs/decisions/0042-old.md on origin/main. The temp wiki holds the numbers.
repo="$tmp/repo"
mkdir -p "$repo/scripts" "$repo/docs/decisions" "$repo/.scratchpads/runs"
cp "$script" "$wiki_tool" "$repo/scripts/"
echo old > "$repo/docs/decisions/0042-old.md"
git -C "$repo" init -q && git -C "$repo" add docs \
  && git -C "$repo" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q -m one \
  && git -C "$repo" update-ref refs/remotes/origin/main HEAD
rm "$repo/docs/decisions/0042-old.md" # only origin/main has it now
saved_script="$script" saved_run="$run"
script="$repo/scripts/check-plan.sh" run="$repo/.scratchpads/runs/2026-10-14-new-thing"
# reserve <entries>: the register page holds the line of the old files, as the import copies it. A
# note after the run folder is not an entry that `wiki.py reserve` takes, so the page is written.
reserve() {
  new_wiki
  printf -- '---\ntype: Register\n---\n\nDecision numbers taken or reserved (reserve at Phase 2): 0042 old (run 2026-10-01-old, landed), %s\n' "$1" > "$DIRIGIBLE_WIKI/wiki/decision-numbers.md"
  git -C "$DIRIGIBLE_WIKI" commit -q -a -m fixture || fail 'wiki fixture commit'
}
makes() { good && printf -- '\n- Modules: `%s` (the new record).\n' "$1" >> "$run/plan.md"; }

reserve '0043 other-title (run 2026-10-13-other)'
makes docs/decisions/0044-new-thing.md
refuse 'a new record with no entry' 'reserve 0044 with scripts/wiki.py reserve --from <file>'
reserve '0044 new-thing (run 2026-10-13-other)'
makes docs/decisions/0044-new-thing.md
refuse 'a number that another run holds' 'reserved for another run: 0044 new-thing (run 2026-10-13-other)'
reserve '0044 y (run 2026-10-13-other), 0044 new-thing (run 2026-10-14-new-thing)'
makes docs/decisions/0044-new-thing.md
refuse 'a second entry for a number that another run holds' 'reserved for another run: 0044 y (run 2026-10-13-other)'
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
refuse 'the own record in the worktree with no reservation' 'reserve 0045 with scripts/wiki.py reserve --from <file>'
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
# An entry that wiki.py reserve writes counts: the file holds the line, the tool removes it.
new_wiki
makes docs/decisions/0044-new-thing.md
printf '0044 new-thing (run 2026-10-14-new-thing)\n' > "$tmp/entry.txt"
"$wiki_tool" reserve --from "$tmp/entry.txt" || fail 'wiki reserve'
pass 'a number that wiki.py reserve wrote for this run'
export DIRIGIBLE_WIKI="$tmp/missing"
for w in "$tmp/missing" 'scripts/wiki.py init' DIRIGIBLE_WIKI; do refuse "no wiki, a record: [$w]" "$w"; done
good
pass 'no wiki, a plan that makes no record'
export DIRIGIBLE_WIKI="$tmp/wiki"
makes docs/decisions/0044-new-thing.md
row 3 'plan gate round 1'
pass 'a run whose plan gate came before the rule'
script="$saved_script" run="$saved_run"

# With CHECK_PLAN_AT_PHASE4=1, the last round file review-plan-<n>.md has a Fix check when any round file
# has a numbered Act on item (lead-judgment.md, Fix check). A per-lens file is no round file.
# closed: a good folder with a closed plan gate. round <n> <Act on text> [<tail>]: review-plan-<n>.md.
closed() { good; row 2 'plan written'; row 3 'plan gate'; }
round() { printf '## Act on\n\n%s\n\n## Consider\n\n- none\n%s' "$2" "${3:-}" > "$run/review-plan-$1.md"; }
ACT=$'1. (warning, x) A fix.\n   Invariant: i. Siblings: s.'
FIX=$'\n## Fix check\n\nDone.\n'
# The rule reads the start of decisions.tsv, as the other rules do: ROW_AT dates the rows of this part.
export CHECK_PLAN_AT_PHASE4=1 ROW_AT=2026-10-24T11:00
closed; round 1 "$ACT"
refuse 'the last round file has an Act on item and no Fix check' 'review-plan-1.md has no ## Fix check'
unset CHECK_PLAN_AT_PHASE4
pass 'the same run at the land check'
export CHECK_PLAN_AT_PHASE4=1
closed; round 1 "$ACT" "$FIX"; round 2 'None.'
refuse 'round 1 has the Fix check, round 2 is the last round file and has none' 'review-plan-2.md has no ## Fix check'
closed; round 1 "$ACT"; round 2 'None.' $'\n## Fix check result\n\nDone.\n'
pass 'a Fix check result in the last round file'
closed; round 2 "$ACT"; round 10 'None.' "$FIX"; round 9 "$ACT"
pass 'rounds 9 and 10: the last round file by number has the Fix check'
closed; round 1 'None.'
printf '## Act on\n\n%s\n' "$ACT" > "$run/review-plan-1-premortem.md"
printf '## Act on\n\n%s\n' "$ACT" > "$run/review-plan-harness-1.md"
printf '## Act on\n\n%s\n' "$ACT" > "$run/review-plan-panel-1.md"
pass 'a per-lens file with an Act on item is no round file'
ROW_AT=2026-10-01T10:00 closed; round 1 "$ACT"
pass 'a run that started before the rule, with a round file that a later note changed'
unset CHECK_PLAN_AT_PHASE4 ROW_AT

# A feat/ Landings row with Lands none and a Sources/ path in the Check line of one of its slices
# is refused: scripts/tag-release.sh needs an F-ID (DLV-196). The columns come from the header names.
# landings <header> <row>...: a table and three slices: L1-S1 with a Support/ check, L1-S2 with a Tests/
# check, and L2-S3 with the real Check line of run 2026-10-23-read-by-time, one Sources/ path moved after
# a Tests/ path.
cat > "$tmp/l2s3-check" <<'EOF'
- Check: `scripts/check-changed.sh --paths <<<$'Sources/DirigibleCore/Backup.swift\nSources/DirigibleMCP/AgentManual.swift\nSources/DirigibleMCP/MCPToolTable.swift\nTests/DirigibleCLITests/AgentManualTests.swift\nSources/DirigibleCLI/BackupCommands.swift\nTests/DirigibleCLITests/BackupCommandTests.swift\ndocs/decisions/0051-agent-manual.md'`
EOF
landings() {
  good
  {
    printf '# Plan: x\n\nAgents: B = L1-S1 to L2-S3.\n\n## Landings\n\n%s\n|---|---|---|---|---|\n' "$1"
    shift
    printf '%s\n' "$@"
    printf '\n%s\n\n### L1-S1%s one\n\n- Check: `scripts/check-changed.sh --paths <<<$'"'"'Support/Info.plist\\nTests/A.swift'"'"'`\n' "${SLICES_H:-## Slices}" "${SEP:-}"
    printf '\n### L1-S2%s two\n\n- Check: `scripts/check-changed.sh --paths <<<$'"'"'Tests/A.swift'"'"'`\n' "${SEP:-}"
    printf '\n### L2-S3%s three\n\n' "${SEP:-}"
    cat "$tmp/l2s3-check"
  } > "$run/plan.md"
}
HEAD6='| Landing | Slices | Branch | risk | Code gate | Lands |'
reason='scripts/tag-release.sh needs a done row in features.md'
landings "$HEAD6" '| L2 tester small items | L2-S1 to L2-S3 | `feat/tester-small-items` | no | 1 round | none |'
refuse 'a feat/ row with Lands none whose slice has a Sources/ path after a Tests/ path' "$reason"
refuse 'the refusal counts the Sources/ paths, also the one after a Tests/ path' 'change 4 Sources/ paths, for example Sources/DirigibleCore/Backup.swift'
landings "$HEAD6" '| L1 one | L1-S1 to L1-S2 | `feat/a` | no | 1 round | none |' '| L2 two | L2-S3 | `feat/b` | no | 1 round | F9 |'
pass 'a feat/ row with Lands none whose slices change only Support/ and Tests/, and a feat/ row with an F-ID'
landings "$HEAD6" '| L2 tester small items | L2-S1 to L2-S3 | `fix/tester-small-items` | no | 1 round | none |'
pass 'a fix/ row with Lands none and a Sources/ path'
landings "$HEAD6" '| L2 tester small items | L2-S1 to L2-S3 | `feat/tester-small-items` | no | 1 round | F9, F10 |'
pass 'a feat/ row with an F-ID and a Sources/ path'
landings '| Landing | Items | Criteria | Lands | Branch and worktree |' '| L1 | one | C1 | F122 | `feat/agent-pack`, from origin/main |'
pass 'a table with a Branch and worktree header and an F-ID'
landings '| Landing | Items | Criteria | Lands | Branch and worktree |' '| L1 | one | C1 | none | `feat/agent-pack`, from origin/main |'
refuse 'a Branch and worktree header with Lands none and no Slices column' "$reason"
# A colon after the slice ID of a heading, backticks in the Slices cell, and a suffix of the Slices
# heading do not change which slices a row names.
ONE='| L1 one | L1-S1 to L1-S2 | `feat/a` | no | 1 round | none |'
SEP=: landings "$HEAD6" "$ONE"
pass 'a feat/ row of Support/ and Tests/ slices, with a colon after each slice ID of the headings'
landings "$HEAD6" '| L1 one | `L1-S1` to `L1-S2` | `feat/a` | no | 1 round | none |'
pass 'a feat/ row of Support/ and Tests/ slices, with backticks in the Slices cell'
SLICES_H='## Slices (serial)' landings "$HEAD6" '| L2 tester small items | L2-S1 to L2-S3 | `feat/tester-small-items` | no | 1 round | none |'
refuse 'a Slices heading with a suffix, a feat/ row with Lands none, and a Sources/ path' "$reason"
# A run that started before the rule (2026-10-24T10:00) is not checked.
landings "$HEAD6" '| L2 tester small items | L2-S1 to L2-S3 | `feat/tester-small-items` | no | 1 round | none |'
printf '2026-10-01T10:00\t1\tstart\twhy\tevidence\tdone\n' > "$run/decisions.tsv"
pass 'a run that started before the Landings rule'

# A slice whose Check line names a Swift file near the size limit needs a Split line, before the first
# phase 4 row (AGT-097). A fixture repo holds the script, check-sizes.sh, and Swift files of known
# length on origin/main. The cutoff pair takes its dates from the size_cutoff line of the script,
# because a lead step moves that line before the land.
repo="$tmp/size-repo"
mkdir -p "$repo/scripts" "$repo/Sources/A" "$repo/.scratchpads/runs"
cp "$script" "$(dirname "$script")/check-sizes.sh" "$repo/scripts/"
lines() { seq 1 "$2" > "$repo/Sources/A/$1.swift"; }
lines Big 380; lines Edge 379; lines Mid 280; lines Full 400; lines Allowed 400
printf '# list\nSources/A/Allowed.swift\tone type holds the whole format\n' > "$repo/scripts/check-sizes.allow"
git -C "$repo" init -q && git -C "$repo" add . \
  && git -C "$repo" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q -m one \
  && git -C "$repo" update-ref refs/remotes/origin/main HEAD
saved_script="$script" saved_run="$run"
script="$repo/scripts/check-plan.sh" run="$repo/.scratchpads/runs/2026-10-31-size"
size_cut="$(sed -n 's/^ *size_cutoff=\(.*\)$/\1/p' "$script")"
[[ -n "$size_cut" ]] || { fail 'check-plan.sh has no size_cutoff= line'; size_cut=2026-10-30T15:30; }
AFTER="$(date -j -v+1d -f %Y-%m-%dT%H:%M "$size_cut" +%Y-%m-%dT%H:%M)"
BEFORE="$(date -j -v-1d -f %Y-%m-%dT%H:%M "$size_cut" +%Y-%m-%dT%H:%M)"
# sized <paths> [<line before the Check line of S2>]: slice S2 checks the paths (separated by a literal
# \n). S1_PATH and S1_SPLIT set the Check path and an extra line of slice S1.
sized() {
  good
  {
    printf '# Plan: x\n\nAgents: B = S1, S2.\n\n## Slices\n\n### S1 one\n\n'
    [[ -z "${S1_SPLIT:-}" ]] || printf '%s\n\n' "$S1_SPLIT"
    printf -- '- Check: `scripts/check-changed.sh --paths <<<$'"'"'%s'"'"'`.\n\n### S2 two\n\n' "${S1_PATH:-docs/x.md}"
    [[ -z "${2:-}" ]] || printf '%s\n\n' "$2"
    printf -- '- Check: `scripts/check-changed.sh --paths <<<$'"'"'%s'"'"'`.\n' "$1"
  } > "$run/plan.md"
  ROW_AT="$AFTER" row 2 'plan written'
}
BIG='Sources/A/Big.swift'
sized "$BIG"
refuse 'a slice that names a file of 380 lines, with no Split line' 'Sources/A/Big.swift'
refuse 'the refusal names the line count' '380 lines'
refuse 'the refusal names the limit' 'limit 400'
refuse 'the refusal names the Split choice' '- Split:'
refuse 'the refusal names the allow list choice' 'scripts/check-sizes.allow'
sized 'Sources/A/Edge.swift'
pass 'a file of 379 lines'
sized 'Sources/A/Mid.swift'
pass 'a file of 280 lines under the limit of 400'
sed -i '' 's/^limit=400$/limit=300/' "$repo/scripts/check-sizes.sh"
refuse 'a file of 280 lines under limit=300 in check-sizes.sh' 'Sources/A/Mid.swift'
sed -i '' 's/^limit=300$/limit=400/' "$repo/scripts/check-sizes.sh"
sized "$BIG" '- Split: Big.swift moves the parser to BigParser.swift.'
pass 'a Split line with the file name and a target .swift file'
sized "$BIG" '- Split: Other.swift moves the parser to OtherParser.swift.'
refuse 'a Split line that names another file' 'Sources/A/Big.swift'
sized "$BIG" '- Split: NotBig.swift moves the parser to NotBigParser.swift.'
refuse 'a Split line that names a file with a longer name' 'Sources/A/Big.swift'
sized "$BIG" '- Split: Big.swift, later.'
refuse 'a Split line with the file name and no target' 'Sources/A/Big.swift'
sized "$BIG" '- Split: Big.swift gets an entry in scripts/check-sizes.allow: one parser type holds the whole format.'
pass 'a Split line with the file name, the allow list, and a reason'
sized "$BIG" '- Split: Big.swift in scripts/check-sizes.allow'
refuse 'a Split line with the file name and the allow list, with no reason' 'Sources/A/Big.swift'
sized "$BIG" 'The file can go in scripts/check-sizes.allow.'
refuse 'a slice that names the allow list only in other text' 'Sources/A/Big.swift'
sized 'Sources/A/Allowed.swift'
pass 'a file of 400 lines that the allow list at origin/main names'
sized 'Sources/A/Full.swift'
refuse 'a file of 400 lines that the allow list at origin/main does not name' 'Sources/A/Full.swift'
sized 'Sources/A/New.swift'
pass 'a path that is not on origin/main'
S1_PATH=Sources/A/Full.swift S1_SPLIT='- Split: Full.swift moves the parser to FullParser.swift.' sized 'Sources/A/Edge.swift'
pass 'a file of 400 lines in another slice, with its own Split line'
S1_PATH=Sources/A/Edge.swift sized "$BIG"
out="$("$script" "$run" 2>&1)"
[[ "$out" == *'slice S2'* && "$out" != *'slice S1'* ]] || fail "the size refusal names slice S2 only: $out"
# Start states: the rule runs before the first phase 4 row, with or without CHECK_PLAN_AT_PHASE4.
export CHECK_PLAN_AT_PHASE4=1
sized "$BIG"; ROW_AT="$AFTER" row 3 'plan gate'; round 1 'None.'
refuse 'CHECK_PLAN_AT_PHASE4=1 with no phase 4 row' 'Sources/A/Big.swift'
ROW_AT="$AFTER" row 4 'implement'
pass 'CHECK_PLAN_AT_PHASE4=1 with a phase 4 row'
unset CHECK_PLAN_AT_PHASE4
pass 'a phase 4 row at the land check'
# The cutoff pair on one plan: a run that started before the rule date is not checked.
sized "$BIG"; rm "$run/decisions.tsv"; ROW_AT="$BEFORE" row 2 'plan written'
pass 'a first row one day before the size_cutoff line'
rm "$run/decisions.tsv"; ROW_AT="$AFTER" row 2 'plan written'
refuse 'a first row one day after the size_cutoff line' 'Sources/A/Big.swift'
script="$saved_script" run="$saved_run"

# A round file review-plan-<n>.md or review-diff-<n>.md writes each finding as a numbered item under
# ## Act on (INT-043): an item-ID heading refuses, also next to ## Act on, and so does a ## Fix check
# with no ## Act on. A per-lens file and a file from before the round_cutoff line are none.
# roundfile <name> <text>: a good folder with the one review file <name>; \n in <text> is a newline.
roundfile() { good; printf '%b' "$2" > "$run/$1"; }
roundfile review-diff-1.md '# Code gate 1\n\n## G1: the hand-over waits for a writer (architecture warning)\n\nFixed in abc123.\n\n## Fix check\n\n- 1.1 OK\n'
refuse 'a round file with an item heading and no Act on' 'review-diff-1.md: '
refuse 'the refusal names the item heading' '## G1:'
refuse 'the refusal names Act on' '## Act on'
roundfile review-diff-1.md '# Code gate 1\n\n## Fix check\n\n- none\n'
refuse 'a round file with a Fix check and no Act on' 'review-diff-1.md: '
roundfile review-plan-1.md '## Act on\n\nNone.\n\n## N9: a nit\n\nText.\n'
refuse 'an item heading N9 next to Act on' '## N9:'
roundfile review-plan-1.md '## 3. a numbered heading\n\nText.\n'
refuse 'a numbered item heading' '## 3.'
roundfile review-plan-1.md '## R2 (warning) a finding\n\nText.\n'
refuse 'an item heading R2 with a parenthesis' '## R2 ('
roundfile review-diff-2.md '# Code gate 2\n\n## Act on\n\nNone.\n\n## G1: the hand-over waits for a writer (architecture warning)\n\nFixed in abc123.\n'
refuse 'an item heading next to an empty Act on' 'review-diff-2.md: '
roundfile review-diff-1.md '## Act on\n\nNone.\n\n## Fix check\n\n- none\n'
pass 'an empty Act on and a Fix check'
roundfile review-diff-1.md '## Notes\n\n- x\n'
pass 'a round file with a Notes heading only'
roundfile review-diff-1.md ''
pass 'an empty round file'
roundfile review-diff-1-code-review.md '## 1. warning\n\nText.\n'
pass 'a per-lens file with a numbered heading'
roundfile review-diff-1.md '## G1: a finding\n\n## Fix check\n\n- none\n'
touch -t 202610290000 "$run/review-diff-1.md"
pass 'a round file older than the round_cutoff line'

out="$("$script" 2>&1)"
code=$?
[[ $code -eq 2 && "$out" == usage:* ]] || fail "no argument: exit $code: $out"

[[ $failures -eq 0 ]] && echo "check-plan tests: all passed"
exit $((failures > 0))
