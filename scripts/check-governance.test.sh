#!/bin/bash
# Check that check-governance.sh refuses a budget row that goes up with no decisions.tsv time in
# its decision cell, a TOTAL raise that keeps the base cell or cites a time that the run folder lacks, a
# TOTAL change that is not near the sum of the workflow docs, more always-on words (AGENTS.md, CLAUDE.md,
# the files they import, the descriptions of the skills and agents) than the merge base, more skills plus
# agents than the merge base, more than one rules.tsv removal in a docs-only branch of a run with a
# reflect row (in a cut run, a removal row with no class: or found by: instead), a rules.tsv row that changes to delete with a reason that does not start with stale: or no-op:, a run folder that check-plan.sh refuses (an open Unknowns row), a run research
# file with no docs/research copy (a base commit since the run start date also counts), a holdout fail in this run and in the newest done run that ran it, and a
# taken item of the run with status next in the wiki after the reflect row (phase 8), a features.md row
# of the base that the branch loses, a run number that is not the next of its release, a done run number of the base that the branch loses, a run.md `- Lands:` line whose F-ID keeps its features.md state, and a feat,
# fix, or perf run that changes app code with no `- Lands:` line. Each case uses a temporary repo with a base commit on main
# and a branch.
# Run by `make test-hooks`.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/check-governance.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE FILTER SINCE
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# The taken items and the done runs come from the wiki of scripts/wiki.py. DIRIGIBLE_WIKI names a
# temp wiki, so no case reads or writes the real one. The identity of the wiki commits is in the
# environment, because the git config of the machine is not a test input.
wiki_tool="$(dirname "$script")/wiki.py"
export DIRIGIBLE_WIKI="$tmp/wiki"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
new_wiki() { rm -rf "$DIRIGIBLE_WIKI"; "$wiki_tool" init > /dev/null || fail 'wiki init'; }
# put_log: the lines on stdin go to the log of the wiki.
put_log() { cat > "$tmp/put-log.txt"; "$wiki_tool" log --from "$tmp/put-log.txt" || fail 'wiki log'; }
# take_item <status> <run>: add one item with the status, taken by the run. It prints the ID.
take_item() {
  local id
  printf 'an item\nx\n\nbody\n' > "$tmp/take-item.txt"
  id="$("$wiki_tool" add "$1" --from "$tmp/take-item.txt")" || fail "wiki add $1"
  "$wiki_tool" take "$id" "$2" || fail "wiki take $id"
  echo "$id"
}
new_wiki

g() { git -C "$tmp/r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
budgets="$tmp/r/docs/workflow/budgets.tsv"
words_sh="$(dirname "$script")/workflow-words.sh"
rules="$tmp/r/docs/workflow/rules.tsv"
head_rules=$'id\tfile\tverdict\ttarget\treason\tsource\tkey\tsummary'

# wl <n>: n words. agents_with <n>: AGENTS.md with n words and the line that imports docs/i.md.
wl() { seq "$1" | sed 's/^/w/' | tr '\n' ' '; }
agents_with() { { wl "$1"; echo; echo '@docs/i.md'; } > "$tmp/r/AGENTS.md"; }
tsum() { (cd "$tmp/r" && "$words_sh" sum); }

# A repo with budgets.tsv, rules.tsv, and the always-on files on main (AGENTS.md of 60 words with an
# import of docs/i.md, CLAUDE.md, an agent, a skill, and a references file), on the branch feat/x, and a run folder.
# The TOTAL row of main is the sum of its workflow docs, kept in $sum0.
new_repo() {
  rm -rf "$tmp/r" "$tmp/run"
  mkdir -p "$tmp/r/docs/workflow" "$tmp/r/docs" "$tmp/r/.claude/agents" "$tmp/r/.claude/skills/s/references" "$tmp/run"
  g init -q -b main
  agents_with 59
  printf '@AGENTS.md\n' > "$tmp/r/CLAUDE.md"
  printf 'i1 i2\n' > "$tmp/r/docs/i.md"
  printf -- '---\nname: a\ndescription: one two three\n---\nbody\n' > "$tmp/r/.claude/agents/a.md"
  printf -- '---\nname: s\ndescription: four five six\n---\nbody\n' > "$tmp/r/.claude/skills/s/SKILL.md"
  printf 'ref words here\n' > "$tmp/r/.claude/skills/s/references/r.md"
  g add -A
  sum0="$(tsum)"
  printf 'path\twords\tdecision\na.md\t100\tbaseline\nb.md\t100\tbaseline\nTOTAL\t%s\tbaseline\n' "$sum0" > "$budgets"
  printf '%s\nA-1\ta.md\tkeep\ta.md\tr\ts\t\tx\nA-2\ta.md\tkeep\ta.md\tr\ts\t\tx\nA-3\ta.md\tkeep\ta.md\tr\ts\t\tx\n' "$head_rules" > "$rules"
  g add -A
  g commit -q -m base
  g switch -q -c feat/x
  printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n' > "$tmp/run/decisions.tsv"
  printf '## Unknowns\n\n| id | parent | question | resolver | answer | row |\n|---|---|---|---|---|---|\n| U1 | - | q | code | a | 2026-10-01T01:00 |\n' > "$tmp/run/analysis.md"
  printf 'Agents: A = S1.\n\n## Slices\n\n### S1 x\n\n- Check: check-docs.\n' > "$tmp/run/plan.md"
}
commit() { g add -A && g commit -q -m change; }
row() { printf 'path\twords\tdecision\na.md\t%s\t%s\nb.md\t100\tbaseline\nTOTAL\t%s\tbaseline\n' "$1" "$2" "$sum0" > "$budgets"; }
why() { if [[ "$1" == delete ]]; then echo 'stale: r'; else echo r; fi; }
verdicts() { printf '%s\nA-1\ta.md\t%s\ta.md\t%s\ts\t\tx\nA-2\ta.md\t%s\tA-1\t%s\ts\t\tx\nA-3\ta.md\tkeep\ta.md\tr\ts\t\tx\n' "$head_rules" "$1" "$(why "$1")" "$2" "$(why "$2")" > "$rules"; }

# pass <name> [args]: exit 0. refuse <name> <reason> [args]: a nonzero exit and the reason.
pass() {
  local name="$1" out
  shift
  out="$(cd "$tmp/r" && "$script" main "$@" 2>&1)" || fail "$name: expected exit 0: $out"
}
refuse() {
  local name="$1" reason="$2" out
  shift 2
  out="$(cd "$tmp/r" && "$script" main "$@" 2>&1)" && fail "$name: expected a nonzero exit"
  [[ "$out" == *"$reason"* ]] || fail "$name: no '$reason' in: $out"
}

new_repo; row 120 'raised'; commit
refuse 'a raised row with free text' 'the row for a.md goes up from 100 to 120'
new_repo; row 120 'run x (decisions.tsv 2026-10-01T02:43: row = wc -w x 1.1)'; commit
pass 'a raised row that cites a decisions.tsv time'
new_repo; row 80 'lowered'; commit
pass 'a lowered row with free text'
new_repo; printf 'c.md\t50\tnew file\n' >> "$budgets"; commit
pass 'a new row with free text'
new_repo; g switch -q main; g rm -q docs/workflow/budgets.tsv; g commit -q -m rm; g switch -q -C feat/x
row 120 'raised'; commit
pass 'no budgets.tsv in the base'
# A raised TOTAL row cites a row of its own run: not the cell of the base, and (with a run folder) a
# time that decisions.tsv of the run has. A changed TOTAL stays within 3 % of the sum of the workflow docs.
cite=$'decisions.tsv 2026-10-01T02:43'
run_row() { printf '2026-10-01T02:43\t3\tx\tw\te\tr\n' >> "$tmp/run/decisions.tsv"; }
total() { sed -i '' "s|^TOTAL	.*|TOTAL	$1	$2|" "$budgets"; }
more_refs() { wl "$1" >> "$tmp/r/.claude/skills/s/references/r.md"; }
new_repo; more_refs 51; run_row; total "$(tsum)" "$cite"; commit
pass 'a TOTAL raise of 51 words that cites a decisions.tsv row' "$tmp/run"
new_repo; more_refs 51; total "$(tsum)" "$cite"; commit
pass 'a TOTAL raise that cites a time, with no run folder'
new_repo; more_refs 51; total "$(tsum)" "$cite"; commit
refuse 'a TOTAL raise that cites a time with no row in the run decisions.tsv' 'has no row with that time' "$tmp/run"
new_repo; more_refs 51; total "$(tsum)" 'free text'; commit
refuse 'a TOTAL raise with free text' 'the row for TOTAL goes up'
new_repo; g switch -q main; total "$sum0" "$cite"; g commit -qam cite; g switch -q -C feat/x
more_refs 51; total "$(tsum)" "$cite"; commit
refuse 'a TOTAL raise that keeps the base citation' 'names a decisions.tsv row of its own'
new_repo; more_refs 50; run_row; total "$(( sum0 + 20 ))" "$cite"; commit
refuse 'a TOTAL change that is not near the sum' 'is not the sum of the workflow docs' "$tmp/run"
new_repo; more_refs 500; run_row; total "$(( $(tsum) + 10 ))" "$cite"; commit
refuse 'a TOTAL raised 2 % over the sum' 'is not the sum of the workflow docs' "$tmp/run"
new_repo; more_refs 500; run_row; total "$(( $(tsum) + 1 ))" "$cite"; commit
refuse 'a TOTAL raised to sum + 1 with a valid citation' 'is not the sum of the workflow docs' "$tmp/run"
new_repo; g switch -q main; more_refs 500; total "$(tsum)" baseline; g commit -qam 'more docs'; g switch -q feat/x
printf 'x y\n' > "$tmp/r/.claude/skills/s/references/r.md"; total "$(( $(tsum) + 2 ))" cut; commit
pass 'a TOTAL lowered to 2.5 % over the sum'
new_repo; g switch -q main; more_refs 500; total "$(tsum)" baseline; g commit -qam 'more docs'; g switch -q feat/x
printf 'x y\n' > "$tmp/r/.claude/skills/s/references/r.md"; total "$(( $(tsum) + 10 ))" cut; commit
refuse 'a TOTAL lowered to 12 % over the sum' 'is not the sum of the workflow docs'
new_repo; more_refs 500; run_row; total "$(( $(tsum) - 10 ))" "$cite"; commit
pass 'a TOTAL change 2 % under the sum' "$tmp/run"
new_repo; more_refs 30; total "$(tsum)" "$cite"; commit
pass 'a TOTAL change that stays at the sum after a docs change'
new_repo; printf 'x y\n' > "$tmp/r/.claude/skills/s/references/r.md"; total "$(tsum)" cut; commit
pass 'a TOTAL cut to the sum needs no citation'
new_repo; printf 'x y\n' > "$tmp/r/.claude/skills/s/references/r.md"; commit
pass 'a docs cut with TOTAL unchanged'
new_repo; more_refs 4000; commit
pass 'docs over TOTAL x 1.03 are no governance fault (new-run.sh warns)'

# The always-on words (AGENTS.md, CLAUDE.md, the files they import, the description of each skill and
# agent) stay at or below the merge base. The merge base is not the tip of main.
new_repo; echo extra >> "$tmp/r/AGENTS.md"; commit
refuse 'AGENTS.md gets 1 more word' 'always-on words go from'
out="$(cd "$tmp/r" && "$script" main 2>&1)"
[[ "$out" == *'move a whole part to a references file'* ]] || fail "the cap refusal does not name the way out: $out"
[[ "$out" != *'cut text'* ]] || fail "the cap refusal asks for a word trim: $out"
new_repo; { wl 59; echo; echo '@docs/i.md'; } | sed 's/w\([0-9]\)/v\1/g' > "$tmp/r/AGENTS.md"; commit
pass 'equal always-on words'
new_repo; { wl 9; echo; echo '@docs/i.md'; } > "$tmp/r/AGENTS.md"; more_refs 50; commit
pass '50 words moved from AGENTS.md to a references file'
new_repo; sed -i '' 's/three/three four/' "$tmp/r/.claude/agents/a.md"; commit
refuse 'a description gets 1 more word' 'always-on words go from'
new_repo; printf -- '---\nname: s\ndescription: >\n  four five\n  six seven\n---\nbody\n' > "$tmp/r/.claude/skills/s/SKILL.md"; commit
refuse 'a folded description gets 1 more word' 'always-on words go from'
new_repo; printf -- '---\nname: s\ndescription: >\n  four five\n  six\n---\nbody\n' > "$tmp/r/.claude/skills/s/SKILL.md"; commit
pass 'a folded description with the same words'
new_repo; echo extra >> "$tmp/r/CLAUDE.md"; commit
refuse 'CLAUDE.md gets 1 more word' 'always-on words go from'
new_repo; echo i3 >> "$tmp/r/docs/i.md"; commit
refuse 'a file that AGENTS.md imports gets 1 more word' 'always-on words go from'
new_repo; g switch -q main; { wl 49; echo; echo '@docs/i.md'; } > "$tmp/r/AGENTS.md"; g commit -qam 'cut 10 words'; g switch -q feat/x
pass 'main cut 10 words of AGENTS.md after the branch start'

# The count of skills plus agents stays at or below the merge base: a new one deletes one.
new_repo; printf -- '---\nname: b\n---\nbody\n' > "$tmp/r/.claude/agents/b.md"; commit
refuse 'an agent added and none deleted' 'skills and agents'
new_repo; mkdir -p "$tmp/r/.claude/skills/t"; printf -- '---\nname: t\n---\nbody\n' > "$tmp/r/.claude/skills/t/SKILL.md"; commit
refuse 'a skill folder added and none deleted' 'skills and agents'
new_repo; mkdir -p "$tmp/r/.claude/skills/t"; printf -- '---\nname: t\ndescription: x y\n---\nbody\n' > "$tmp/r/.claude/skills/t/SKILL.md"; rm "$tmp/r/.claude/agents/a.md"; commit
pass 'a skill added and an agent deleted'
new_repo; g mv .claude/skills/s .claude/skills/s2; commit
pass 'a skill folder renamed'

# A base with no AGENTS.md and no .claude: the fixture of land.test.sh. The check does not stop.
no_workflow_repo() {
  rm -rf "$tmp/r" "$tmp/run"
  mkdir -p "$tmp/r/docs/workflow" "$tmp/run"
  g init -q -b main
  printf 'path\twords\tdecision\na.md\t100\tbaseline\n' > "$budgets"
  g add -A
  g commit -q -m base
  g switch -q -c feat/x
}
no_workflow_repo; echo x > "$tmp/r/x.md"; commit
pass 'a base with no AGENTS.md and no .claude'
no_workflow_repo; printf 'path\twords\tdecision\na.md\t120\traised\n' > "$budgets"; commit
refuse 'a raised row in a repo with no workflow file' 'the row for a.md goes up from 100 to 120'
new_repo; row 120 'raised'; commit
out="$(cd "$tmp/r" && "$script" does-not-exist 2>&1)" && fail 'a bad base exits 0'
[[ "$out" == *does-not-exist* ]] || fail "a bad base: no reason: $out"

# Removals: a docs-only branch, with a reflect row (phase 8) in the run decisions.tsv.
reflect_row() { printf '2026-10-01T01:00\t8\treflect\tw\te\tr\n' >> "$tmp/run/decisions.tsv"; }
new_repo; reflect_row; verdicts delete merge; commit
refuse 'two removals in a reflect docs branch' 'rules.tsv: 2 rows change to delete or merge' "$tmp/run"
new_repo; reflect_row; verdicts keep merge; commit
pass 'one removal in a reflect docs branch' "$tmp/run"
new_repo; verdicts delete merge; commit
pass 'two removals with no reflect row' "$tmp/run"
new_repo; reflect_row; verdicts delete merge; mkdir -p "$tmp/r/scripts"; echo x > "$tmp/r/scripts/x.sh"; commit
pass 'two removals in a branch with a script change' "$tmp/run"
new_repo; reflect_row; verdicts delete merge; commit
pass 'two removals with no run folder'
# check-changed.sh refuses a rerun after a partial stamp on a risk: yes branch with no Sources/ or
# Tests/ change since the stamp: a flaky test must not read as a governance fault.
new_repo; reflect_row; mkdir -p "$tmp/r/Sources/DirigibleAudio"; echo x > "$tmp/r/Sources/DirigibleAudio/A.swift"; commit
printf '%s %s failed fast:SomeTest slow:\n' "$(g rev-parse HEAD)" "$(g rev-parse main)" > "$(g rev-parse --path-format=absolute --git-common-dir)/dirigible-check-partial"
refusal="$(cd "$tmp/r" && "$(dirname "$script")/check-changed.sh" main 2>&1 >/dev/null)" && fail 'a refused rerun: check-changed.sh did not refuse'
[[ "$refusal" == *'fix the test first'* ]] || fail "a refused rerun: not the rerun refusal: $refusal"
pass 'a rerun that check-changed.sh refuses' "$tmp/run"
three() { printf '%s\nA-1\ta.md\tdelete\t\tstale: r\ts\t\tx\nA-2\ta.md\tmerge\tA-1\tr\ts\t\tx\nA-3\ta.md\tdelete\t\tstale: r\ts\t\tx\n' "$head_rules" > "$rules"; }
new_repo; reflect_row; three; commit
refuse 'three removals with no user decision row' 'rules.tsv: 3 rows change to delete or merge' "$tmp/run"
# A cut run (`- Cut run: <item id>` in run.md) has no one-removal cap; each removal row needs class: and found by:.
fields='stale: x; class: a rule that no check needed; found by: check-x'
three_cut() { printf '%s\nA-1\ta.md\tdelete\t\t%s\ts\t\tx\nA-2\ta.md\tmerge\tA-1\t%s\ts\t\tx\nA-3\ta.md\tdelete\t\t%s\ts\t\tx\n' "$head_rules" "$1" "$1" "${2:-$1}" > "$rules"; }
cut_run() { printf -- '- Status: open\n- Cut run: 1234\n' > "$tmp/run/run.md"; }
new_repo; reflect_row; cut_run; three_cut "$fields"; commit
pass 'three removals with fields in a cut run' "$tmp/run"
new_repo; reflect_row; cut_run; three_cut "$fields" 'stale: x; class: a rule that no check needed'; commit
refuse 'a removal with no found by in a cut run' 'A-3 changes to delete or merge in a cut run' "$tmp/run"
new_repo; reflect_row; cut_run; three_cut "$fields" 'stale: x; found by: check-x'; commit
refuse 'a removal with no class in a cut run' 'A-3 changes to delete or merge in a cut run' "$tmp/run"
new_repo; reflect_row; printf -- '- Status: open\n' > "$tmp/run/run.md"; three_cut "$fields"; commit
refuse 'three removals with fields and no cut run line' 'rules.tsv: 3 rows change to delete or merge' "$tmp/run"

# A row that changes to delete has a reason that starts with stale: or no-op: and gives the evidence
# (reflect rule 7), on any branch. A merge row and a row that was delete at the base are free.
row1() { printf '%s\nA-1\ta.md\t%s\ta.md\t%s\ts\t\tx\nA-2\ta.md\tkeep\ta.md\tr\ts\t\tx\nA-3\ta.md\tkeep\ta.md\tr\ts\t\tx\n' "$head_rules" "$1" "$2" > "$rules"; }
bad='A-1 changes to delete; its reason must start with stale: or no-op:'
new_repo; reflect_row; row1 delete 'no eval scenario names it'; commit
refuse 'a delete with a reason that names no cause' "$bad" "$tmp/run"
new_repo; row1 delete 'no eval scenario names it'; commit
refuse 'a delete with no run folder' "$bad"
new_repo; reflect_row; mkdir -p "$tmp/r/scripts"; echo x > "$tmp/r/scripts/x.sh"; row1 delete unused; commit
refuse 'a delete in a docs tooling branch with the reason unused' "$bad" "$tmp/run"
new_repo; row1 delete 'stale:'; commit
refuse 'a delete with an empty stale reason' "$bad"
new_repo; row1 delete 'no-op:   '; commit
refuse 'a delete with an empty no-op reason' "$bad"
new_repo; reflect_row; row1 delete 'stale: step 3 no longer exists'; commit
pass 'a delete with a stale reason' "$tmp/run"
new_repo; row1 delete 'no-op: the model does this by default'; commit
pass 'a delete with a no-op reason'
new_repo; row1 merge 'duplicate of A-2'; commit
pass 'a merge with any reason'
new_repo; g switch -q main; row1 delete 'old reason'; g commit -qam 'delete at base'; g switch -q -C feat/x
row1 delete 'another reason'; commit
pass 'a row that is delete at the merge base with another reason'

# The plan check of the run folder (check-plan.sh) runs with the other checks.
new_repo
pass 'a good run folder' "$tmp/run"
sed -i '' 's/| a | 2026-10-01T01:00 |/|  | 2026-10-01T01:00 |/' "$tmp/run/analysis.md"
refuse 'an open Unknowns row' 'open unknown: | U1 |' "$tmp/run"

# A research file of the run folder has its copy in docs/research.
new_repo; echo x > "$tmp/run/research-topic.md"; echo '- S1 copies it to docs/research/topic.md.' >> "$tmp/run/plan.md"
refuse 'a run research file with no docs/research copy' 'research-topic.md has no docs/research/topic.md' "$tmp/run"
mkdir -p "$tmp/r/docs/research"; echo x > "$tmp/r/docs/research/topic.md"; commit
pass 'a run research file with its docs/research copy' "$tmp/run"
new_repo; mkdir -p "$tmp/r/docs/research"; echo x > "$tmp/r/docs/research/topic.md"; g add -A; g commit -q -m old
g switch -q main; g merge -q --ff-only feat/x; g switch -q feat/x; echo x > "$tmp/run/research-topic.md"
echo '- S1 copies it to docs/research/topic.md.' >> "$tmp/run/plan.md"
refuse 'a run research file whose copy the branch does not change' 'research-topic.md has no docs/research/topic.md that this branch adds or changes' "$tmp/run"

# A run that lands in steps copied its research in an earlier landing: a base commit dated on or after
# the run start date (the date prefix of the run folder name) also counts. An older copy does not.
later_landing() {
  new_repo; mkdir -p "$tmp/r/docs/research"; echo x > "$tmp/r/docs/research/topic.md"; g add -A
  GIT_COMMITTER_DATE="$1" g commit -q -m copy
  g switch -q main; g merge -q --ff-only feat/x; g switch -q feat/x
  run3="$tmp/2026-10-18-topic"; rm -rf "$run3"; cp -R "$tmp/run" "$run3"; echo x > "$run3/research-topic.md"
  echo '- S1 copies it to docs/research/topic.md.' >> "$run3/plan.md"
}
later_landing '2026-10-18T00:00:30'
pass 'a run research file whose copy a base commit changed on the run date' "$run3"
later_landing '2026-10-17T23:59:30'
refuse 'a run research file whose copy a base commit changed before the run date' 'research-topic.md has no docs/research/topic.md that this branch adds or changes' "$run3"

# A run moves its own taken items out of the next list of the wiki before the land, so the list
# stays short (each run reads it at Phase 0). A next item taken by another run, a later item taken
# by the run, and a next item of a run whose name starts with this run name pass. The wiki is the
# same from a worktree. With no wiki the check fails, and the message names the path, init, and
# DIRIGIBLE_WIKI.
# The check runs only after the reflect row (phase 8): Phase 7 runs it before Phase 8 moves the
# taken items out, and land.sh runs it after Phase 8.
new_repo; echo x > "$tmp/r/x.md"; commit
run2="$tmp/2026-01-01-x"; rm -rf "$run2"; cp -R "$tmp/run" "$run2"
new_wiki; id="$(take_item next 2026-01-01-x)"
pass 'a taken item of the run with no reflect row' "$run2"
out="$(cd "$tmp/r" && GOVERNANCE_LAND=1 "$script" main "$run2" 2>&1)" && fail 'a taken item at the land with no reflect row: expected a nonzero exit'
[[ "$out" == *"wiki item $id is next and taken by 2026-01-01-x"* ]] || fail "a taken item at the land with no reflect row: $out"
printf '2026-10-01T01:00\t8\treflect\tw\te\tr\n' >> "$run2/decisions.tsv"
refuse 'a taken item of the run with a reflect row' "wiki item $id is next and taken by 2026-01-01-x" "$run2"
out="$(cd "$tmp/r" && DIRIGIBLE_WIKI="$tmp/missing" "$script" main "$run2" 2>&1)" && fail 'no wiki: expected a nonzero exit'
for w in "$tmp/missing" 'scripts/wiki.py init' DIRIGIBLE_WIKI; do
  [[ "$out" == *"$w"* ]] || fail "no wiki: the message lacks [$w]: $out"
done
[[ ! -e "$tmp/missing" ]] || fail 'no wiki: the check made the wiki'
g worktree add -q "$tmp/wt" -b feat/wt 2>/dev/null
out="$(cd "$tmp/wt" && "$script" main "$run2" 2>&1)" && fail 'a taken item of the run in a worktree: expected a nonzero exit'
[[ "$out" == *"wiki item $id is next and taken by 2026-01-01-x"* ]] || fail "a taken item of the run in a worktree: $out"
"$wiki_tool" move "$id" done || fail 'wiki move'
pass 'a taken item of the run that is done' "$run2"
new_wiki; take_item next 2026-01-01-z > /dev/null; take_item later 2026-01-01-x > /dev/null
pass 'a next item of another run, and a later item of the run' "$run2"
# The run name is the whole value of the taken field, so a run x-2 is another run.
new_wiki; take_item next 2026-01-01-x-2 > /dev/null
pass 'a taken item of a run whose name starts with the run name' "$run2"

# features.md keeps each row of the base: the ID, Feature, and Req cells of an `| F<n> |` row must stay.
# A drop sets Dropped (<reason>); a new idea gets a new ID. The Req cell stays too. A base with no features.md has no rows to keep.
# feat_repo [<F02 Feature cell>]: main holds a features.md with F01 and F02; feat/x branches from it.
feat_repo() {
  new_repo
  g switch -q main
  mkdir -p "$tmp/r/docs/requirements"
  printf '# Features\n\n| ID | Feature | From | State | Req |\n|---|---|---|---|---|\n| F01 | One | Logic | Later | R1 |\n| F02 | Two | Logic | Release 4 | R2 |\n' > "$features"
  g add -A && g commit -q -m features
  g switch -q -C feat/x
}
features="$tmp/r/docs/requirements/features.md"
feat_repo; sed -i '' '/^| F02 /d' "$features"; commit
refuse 'a deleted features.md row' 'features.md lost or changed the row of F02; keep its ID, Feature, and Req cells'
feat_repo; sed -i '' 's/| Two |/| Too |/' "$features"; commit
refuse 'a features.md row with another Feature cell' 'features.md lost or changed the row of F02; keep its ID, Feature, and Req cells'
feat_repo; g rm -q docs/requirements/features.md; commit
refuse 'a branch with no features.md' 'features.md lost or changed the row of F01'
feat_repo; sed -i '' 's/| R2 |/| R9 |/' "$features"; commit
refuse 'a features.md row with another Req cell' 'features.md lost or changed the row of F02; keep its ID, Feature, and Req cells'
feat_repo; sed -i '' 's/| Release 4 |/| Dropped (not used) |/' "$features"; commit
pass 'a features.md row set to Dropped'
feat_repo; printf '| F03 | Three | Logic | Later | R3 |\n' >> "$features"; commit
pass 'a features.md row added'
new_repo; mkdir -p "$tmp/r/docs/requirements"; printf '| F01 | One | Logic | Later | R1 |\n' > "$tmp/r/docs/requirements/features.md"; commit
pass 'a base with no features.md'

# A run.md with a `- Lands:` line names the F-IDs of this land, on any branch type: each one gets a done
# state that the base lacks, or the line says `none`. A feat, fix, or perf run that changes app code
# (Sources/, Package.swift, Package.resolved, Support/) must have the line. A docs-only branch needs none.
# lands_repo <run.md text> [<app path>]: main holds F35, F77, and F89 at Release 4; the branch changes the path.
lands_repo() {
  feat_repo
  g switch -q main
  printf '# Features\n\n| ID | Feature | From | State | Req |\n|---|---|---|---|---|\n| F35 | Noise | Logic | Release 4 | R8 |\n| F77 | Hum | Logic | Release 4 | R8 |\n| F89 | Render | Logic | Release 4 | R8 |\n' > "$features"
  g add -A && g commit -q -m features
  g switch -q -C feat/x
  printf '%b' "$1" > "$tmp/run/run.md"
  mkdir -p "$tmp/r/$(dirname "${2:-Sources/A.swift}")"; echo x > "$tmp/r/${2:-Sources/A.swift}"
  # HEAD sits on the first `- Branch:` line, the branch that lands.
  g switch -q -C "$(sed -n 's/^- Branch: *`\{0,1\}\([^ ,`]*\).*/\1/p' "$tmp/run/run.md" | head -n 1)"
}
set_done() { sed -i '' "s/^\(| $1 | [^|]*| [^|]*| \)[^|]*|/\1done, Release 4 run ${2:-1} |/" "$features"; }
lands_repo '# Run\n\n- Branch: feat/x, from origin/main\n- Lands: F35, F89\n'; commit
refuse 'a feat run that changes Sources/ and keeps its states' 'run.md lands F35, but features.md keeps its state Release 4' "$tmp/run"
lands_repo '# Run\n\n- Branch: feat/x\n- Lands: F35, F89\n'; set_done F35; set_done F89; commit
pass 'a feat run that sets its states done' "$tmp/run"
lands_repo '# Run\n\n- Branch: feat/x\n- Requirements: F35, F89\n'; rm "$tmp/r/Sources/A.swift"; echo x > "$tmp/r/B.md"; commit
pass 'a feat run that changes only docs' "$tmp/run"
lands_repo '# Run\n\n- Branch: fix/x\n- Requirements: F35, F89\n'; commit
refuse 'a fix run that changes Sources/ with no Lands line' 'name the F-IDs of this land in - Lands: of run.md, or write - Lands: none' "$tmp/run"
lands_repo '# Run\n\n- Branch: perf/x\n- Requirements: F35, F89\n'; commit
refuse 'a perf run that changes Sources/ with no Lands line' 'name the F-IDs of this land in - Lands: of run.md, or write - Lands: none' "$tmp/run"
lands_repo '# Run\n\n- Branch: chore/x\n- Requirements: F35, F89\n'; commit
pass 'a chore run that changes Sources/ with no Lands line' "$tmp/run"
lands_repo '# Run\n\n- Branch: fix/x\n- Lands: none\n'; commit
pass 'a fix run that changes Sources/ and writes Lands: none' "$tmp/run"
lands_repo '# Run\n\n- Branch: feat/x\n- Requirements: F35, F77\n- Lands: F35\n'; set_done F35; commit
pass 'a feat run that lands F35 and keeps F77 open' "$tmp/run"
lands_repo '# Run\n\n- Branch: feat/x\n- Requirements: F35, F77\n- Lands: F35\n'; commit
refuse 'a feat run that lands F35 and keeps its state' 'run.md lands F35, but features.md keeps its state Release 4' "$tmp/run"
# The Requirements line is no fallback: a feat run that changes Sources/ with no Lands line is refused.
lands_repo '# Run\n\n- Branch: feat/x\n- Requirements: F35, F77\n'; set_done F35; commit
refuse 'a feat run that changes Sources/ with no Lands line' 'name the F-IDs of this land in - Lands: of run.md, or write - Lands: none' "$tmp/run"
for app in Support/Info.plist Package.swift Package.resolved; do
  lands_repo '# Run\n\n- Branch: feat/x\n- Requirements: F35\n' "$app"; commit
  refuse "a feat run that changes only $app with no Lands line" 'name the F-IDs of this land in - Lands: of run.md' "$tmp/run"
done
lands_repo '# Run\n\n- Branch: feat/x\n- Lands: none\n' Support/Info.plist; commit
pass 'a feat run that changes only Support/ and writes Lands: none' "$tmp/run"
lands_repo '# Run\n\n- Branch: feat/x\n- Lands: none\n'; commit
refuse 'a feat run that changes Sources/ and writes Lands: none' 'scripts/tag-release.sh' "$tmp/run"
# The branch that lands decides: HEAD of the tree under check. A run of several landings may write its later
# `- Branch:` lines ahead. The last `- Branch:` line decides only on a detached HEAD.
lands_repo '# Run\n\n- Branch: feat/x\n- Branch: fix/y\n- Lands: none\n'; commit
refuse 'a feat/ Branch line, then a fix/ line written ahead, HEAD on feat/x, with Lands: none and a Sources/ change' 'scripts/tag-release.sh' "$tmp/run"
lands_repo '# Run\n\n- Branch: fix/y\n- Branch: feat/x\n- Lands: none\n'; g switch -q -C feat/x; commit
refuse 'a fix/ Branch line, then a feat/ line, HEAD on feat/x, with Lands: none and a Sources/ change' 'scripts/tag-release.sh' "$tmp/run"
lands_repo '# Run\n\n- Branch: fix/y\n- Branch: feat/x\n- Lands: none\n'; commit
pass 'a feat/ line written last, HEAD on fix/y, with Lands: none and a Sources/ change' "$tmp/run"
lands_repo '# Run\n\n- Branch: feat/x\n- Branch: fix/y\n- Lands: none\n'; commit; g switch -q --detach
pass 'a detached HEAD, the last Branch line fix/y, with Lands: none and a Sources/ change' "$tmp/run"
lands_repo '# Run\n\n- Branch: fix/y\n- Branch: feat/x\n- Lands: none\n'; commit; g switch -q --detach
refuse 'a detached HEAD, the last Branch line feat/x, with Lands: none and a Sources/ change' 'scripts/tag-release.sh' "$tmp/run"
lands_repo '# Run\n\n- Branch: `feat/x`\n- Lands: none\n'; commit; g switch -q --detach
refuse 'a detached HEAD, a backtick Branch line with Lands: none and a Sources/ change' 'scripts/tag-release.sh' "$tmp/run"
lands_repo '# Run\n\n- Branch: `feat/x`\n- Requirements: F35\n'; commit; g switch -q --detach
refuse 'a detached HEAD, a backtick feat/ Branch line with no Lands line and a Sources/ change' 'name the F-IDs of this land in - Lands: of run.md' "$tmp/run"
lands_repo '# Run\n\n- Branch: feat/x\n- Lands: F77\n' Support/Info.plist; set_done F77; commit
pass 'a feat run that changes only Support/ and sets its Lands state' "$tmp/run"
lands_repo '# Run\n\n- Branch: fix/x\n- Lands: F35\n'; commit
refuse 'a fix run with a Lands line and no state change' 'run.md lands F35, but features.md keeps its state Release 4' "$tmp/run"
lands_repo '# Run\n\n- Branch: fix/x\n- Lands: F35\n'; set_done F35; commit
pass 'a fix run with a Lands line and its state done' "$tmp/run"
lands_repo '# Run\n\n- Branch: docs/x\n- Lands: F35\n'; rm "$tmp/r/Sources/A.swift"; echo x > "$tmp/r/B.md"; commit
refuse 'a docs run with a Lands line and no state change' 'run.md lands F35, but features.md keeps its state Release 4' "$tmp/run"
# The Lands value is none or a comma list of F-IDs: a note goes on its own line.
# lands_docs <value> [<ID to set done>...]: a docs run with that Lands value.
lands_docs() {
  lands_repo "# Run\n\n- Branch: docs/x\n- Lands: $1\n"; rm "$tmp/r/Sources/A.swift"; echo x > "$tmp/r/B.md"
  local id; for id in "${@:2}"; do set_done "$id"; done
  commit
}
for value in 'none (F102 is another feature)' 'F89 (F35 stays open)' 'F35 and F89 (Release 4 run 6)' 'F35, F89. Heal stays for L2'; do
  lands_docs "$value" F35 F89
  refuse "a Lands value with a note: $value" 'put a note on its own line after - Lands:' "$tmp/run"
done
lands_docs none
pass 'a docs run with Lands: none' "$tmp/run"
lands_docs F89 F89
pass 'a Lands value of one F-ID' "$tmp/run"
lands_docs 'F35, F89' F35 F89
pass 'a Lands value of two F-IDs' "$tmp/run"
lands_docs 'F89 ' F89
pass 'a Lands value with a trailing space' "$tmp/run"
lands_repo '# Run\n\n- Branch: feat/x\n- Lands:\n'; commit
refuse 'a feat run with an empty Lands line' 'run.md has a - Lands: line with no F-ID; name the F-IDs of this land, or write - Lands: none' "$tmp/run"
lands_repo '# Run\n\n- Branch: fix/x\n- Lands:   \n'; commit
refuse 'a fix run with a blank Lands line' 'run.md has a - Lands: line with no F-ID' "$tmp/run"
# A run that lands in steps replaces the line before each land, but a second line still counts: the newest line decides.
lands_repo '# Run\n\n- Branch: feat/x\n- Lands: F35\n- Lands: F77\n'; set_done F77; commit
pass 'a run with two Lands lines whose last line is set done' "$tmp/run"
lands_repo '# Run\n\n- Branch: feat/x\n- Lands: F35\n- Lands: F77\n'; set_done F35; commit
refuse 'a run with two Lands lines whose last line keeps its state' 'run.md lands F77, but features.md keeps its state Release 4' "$tmp/run"

# A new run number of a done state is 1 + the highest run number of that release at the base, and all
# new parts of one land share it. A part of the base is not new. A base with no features.md has no number.
# runs_repo: main holds F01 done in Release 4 run 1, F35 and F77 at Release 4, and F89 at Release 5.
runs_repo() {
  new_repo
  g switch -q main
  mkdir -p "$tmp/r/docs/requirements"
  printf '# Features\n\n| ID | Feature | From | State | Req |\n|---|---|---|---|---|\n| F01 | One | Logic | done, Release 4 run 1 (v0.4.1); Later: a part | R1 |\n| F35 | Noise | Logic | Release 4 | R8 |\n| F77 | Hum | Logic | Release 4 | R8 |\n| F89 | Render | Logic | Release 5 | R8 |\n' > "$features"
  g add -A && g commit -q -m features
  g switch -q -C feat/x
}
runs_repo; set_done F35 2; set_done F77 2; commit
pass 'two features that land with the next run number'
runs_repo; set_done F35 1; commit
refuse 'a duplicate run number' 'F35 has Release 4 run 1, but the next run number of Release 4 is 2'
runs_repo; set_done F35 3; commit
refuse 'a skipped run number' 'F35 has Release 4 run 3, but the next run number of Release 4 is 2'
runs_repo; set_done F35 2; set_done F77 3; commit
refuse 'two features of one land with another number' 'F77 has Release 4 run 3, but the next run number of Release 4 is 2'
runs_repo; set_done F35 11; commit
refuse 'an item number as the run number' 'F35 has Release 4 run 11, but the next run number of Release 4 is 2'
runs_repo; set_done F35 2a; commit
refuse 'a run number with a letter' 'F35 has Release 4 run 2a, but the next run number of Release 4 is 2'
runs_repo; sed -i '' 's/^\(| F89 | [^|]*| [^|]*| \)[^|]*|/\1done, Release 4 run 2 (moved from Release 5) |/' "$features"; commit
pass 'a feature of a later release that lands early in the next run of Release 4'
runs_repo; sed -i '' 's/done, Release 4 run 1 (v0.4.1)/done, Release 4 runs 1 and 2 (v0.4.1)/' "$features"; commit
pass 'a second run that extends the done state of a row'
runs_repo; sed -i '' 's/done, Release 4 run 1/done, Release 4 run 1/; s/a part/another part/' "$features"; commit
pass 'a done row whose run numbers stay'
runs_repo; sed -i '' 's/^\(| F35 | [^|]*| [^|]*| \)[^|]*|/\1done, Release 5 run 1 |/' "$features"; commit
pass 'the first run number of a release with no done run at the base'
runs_repo; sed -i '' 's/^\(| F35 | [^|]*| [^|]*| \)[^|]*|/\1done, Release 5 run 2 |/' "$features"; commit
refuse 'a first run number of a release that is not 1' 'F35 has Release 5 run 2, but the next run number of Release 5 is 1'
new_repo; mkdir -p "$tmp/r/docs/requirements"; printf '| F01 | One | Logic | done, Release 4 run 5 | R1 |\n' > "$features"; commit
pass 'a base with no features.md and any run number'

# A done part of the base stays: a shipped run number is not removed, and a done row does not go back.
runs_repo; sed -i '' 's/^\(| F01 | [^|]*| [^|]*| \)[^|]*|/\1Later |/' "$features"; commit
refuse 'a done row set back to Later' 'features.md lost or changed the done part Release 4 run 1 of F01'
runs_repo; sed -i '' 's/^\(| F01 | [^|]*| [^|]*| \)[^|]*|/\1Dropped (not used) |/' "$features"; commit
refuse 'a done row set to Dropped' 'features.md lost or changed the done part Release 4 run 1 of F01'
runs_repo; sed -i '' 's/Release 4 run 1/Release 5 run 1/' "$features"; commit
refuse 'a done part that moves to another release' 'features.md lost or changed the done part Release 4 run 1 of F01'
runs_repo; sed -i '' 's/; Later: a part//' "$features"; commit
pass 'a done row that drops its Later part'

# A branch that is behind its base is read at the merge base: what the base changed after the branch
# point is not a loss of the branch. The top run number of a release still reads the base tip.
# behind_repo: F01 is done in Release 4 run 21 and F02 is open at the branch point; main then marks F02
# done in run 22, adds the row F03, and cuts TOTAL with the same decision cell; the branch adds a file.
behind_repo() {
  new_repo
  g switch -q main
  mkdir -p "$tmp/r/docs/requirements"
  printf '# Features\n\n| ID | Feature | From | State | Req |\n|---|---|---|---|---|\n| F01 | One | Logic | done, Release 4 run 21 | R1 |\n| F02 | Two | Logic | Release 4 | R2 |\n' > "$features"
  g add -A && g commit -q -m features
  g switch -q -C feat/x
  echo x > "$tmp/r/other.txt"; commit
  g switch -q main
  sed -i '' 's/| Release 4 | R2 |/| done, Release 4 run 22 | R2 |/' "$features"
  printf '| F03 | Three | Logic | Later | R3 |\n' >> "$features"
  total "$((sum0 - 1))" baseline
  commit
  g switch -q feat/x
}
# gov_out [args]: run the script against main, and set out and code.
gov_out() { out="$(cd "$tmp/r" && "$script" main "$@" 2>&1)" && code=0 || code=$?; }
behind_repo
pass 'a branch behind a base that marked a feature done, added a row, and cut TOTAL'
behind_repo; sed -i '' 's/| done, Release 4 run 21 | R1 |/| done, Release 4 runs 21 and 22 | R1 |/' "$features"; commit
gov_out
[[ $code -ne 0 && "$out" == *'features.md: F01 has Release 4 run 22, but the next run number of Release 4 is 23'* ]] \
  || fail "a run number that the base tip has: expected the refusal for run 23: $out"
[[ "$out" != *'lost or changed the done part'* ]] || fail "a run number that the base tip has: the refusal names a done part of the base tip: $out"
behind_repo; sed -i '' 's/| done, Release 4 run 21 | R1 |/| done, Release 4 runs 21 and 23 | R1 |/' "$features"; commit
pass 'a run number that is the next of the base tip'
behind_repo; sed -i '' 's/| done, Release 4 run 21 | R1 |/| Later | R1 |/' "$features"; commit
refuse 'a branch behind its base that drops a done part of the merge base' 'features.md lost or changed the done part Release 4 run 21 of F01'
behind_repo; total "$((sum0 + 1))" baseline; commit
refuse 'a branch behind its base that raises TOTAL and keeps the cell of the merge base' 'its decision cell is the cell of the base'

# Two holdout fails in a row stop the land. grade.py verdict writes its fail lines to
# eval/holdout-fails.txt of the run, so no hand row is needed. The run to compare is the newest done
# run of the ledger beside runs/ whose eval/scores.tsv has a row of the holdout: a run that did not
# run the holdout is skipped. One run alone, or an older done run behind a newer one, passes.
new_repo
s="$tmp/s"
rm -rf "$s" && mkdir -p "$s/runs/2026-01-01-a" "$s/runs/2026-01-02-b"
cp -R "$tmp/run" "$s/runs/2026-01-03-me"
new_wiki
printf '| 2026-01-01-a | a | done | x |\n| 2026-01-02-b | b | done: PR #2 | x |\n| 2026-01-03-me | me | open | |\n' | put_log
# ran <run> <holdout>: the eval of the run scored the holdout. hold <run> <holdout>: its verdict failed it.
ran() { mkdir -p "$s/runs/$1/eval"; printf 'tag\tscenario\ttype\tset\trun\tresult\tmissing\nt\t%s\tretention\told\t1\tPASS\t\n' "$2" >> "$s/runs/$1/eval/scores.tsv"; }
hold() { ran "$1" "$2"; printf 'holdout fail %s: no changed text\n' "$2" >> "$s/runs/$1/eval/holdout-fails.txt"; }
me="$s/runs/2026-01-03-me"
hold 2026-01-03-me H6
pass 'a holdout fail in this run only' "$me"
hold 2026-01-01-a H6
ran 2026-01-02-b E1
refuse 'a holdout fail in this run and an older done run, with a newer run that did not run it' 'H6 failed in this run and in 2026-01-01-a' "$me"
ran 2026-01-02-b H6
pass 'a holdout fail in this run, an older done run, and a newer run that passed it' "$me"
hold 2026-01-02-b H6
refuse 'a holdout fail in this run and the newest done run' 'H6 failed in this run and in 2026-01-02-b' "$me"
rm -rf "$s/runs/2026-01-02-b/eval"
hold 2026-01-02-b H1
ran 2026-01-02-b H6
pass 'a fail of another holdout in the newest done run' "$me"
# A hand row "holdout fail" in decisions.tsv is not a verdict file: no run ran H6 with a fail file.
rm -rf "$s/runs/2026-01-01-a/eval" "$s/runs/2026-01-02-b/eval"
printf '2026-01-01T01:00\t7\tholdout fail H6: no changed text\tw\te\tr\n' >> "$s/runs/2026-01-02-b/decisions.tsv"
pass 'a hand row of the newest done run with no verdict file' "$me"
# A log status of the form `done, PR <n>, ...` is a done run too. A later row of a run replaces its
# earlier rows: a run that a later row opens again is not done, so the compare goes to the run before it.
echo '| 2026-01-02-b | b | done, PR 2, x | x |' | put_log
rm -rf "$s/runs/2026-01-02-b/eval"
hold 2026-01-02-b H6
refuse 'a holdout fail in this run and the newest run with the status done, PR 2' 'H6 failed in this run and in 2026-01-02-b' "$me"
echo '| 2026-01-02-b | b | open | |' | put_log
hold 2026-01-01-a H6
refuse 'a holdout fail in this run, a run that a later row opened again, and an older done run' 'H6 failed in this run and in 2026-01-01-a' "$me"
out="$(cd "$tmp/r" && DIRIGIBLE_WIKI="$tmp/missing" "$script" main "$me" 2>&1)" && fail 'a holdout fail with no wiki: expected a nonzero exit'
[[ "$out" == *'scripts/wiki.py init'* ]] || fail "a holdout fail with no wiki: no init hint: $out"

# A branch that adds an evals.md key needs a graded eval folder in the run folder (check-eval-keys.sh).
new_repo
printf '## Scenarios\n\n| ID | Type | Source | Question | Key points | Files | Old | New |\n|---|---|---|---|---|---|---|---|\n| E4 | policy | s | q | (a) new. | `a.md` | - | - |\n' > "$tmp/r/docs/workflow/evals.md"; commit
refuse 'an evals.md key with no graded eval folder' 'E4 has a new or changed key' "$tmp/run"
mkdir "$tmp/run/eval"; printf '## E4\n(a) new.\n\n' > "$tmp/run/eval/keys.md"; printf 'p7\tE4\tpolicy\ta\t1\tPASS\t\n' > "$tmp/run/eval/scores.tsv"
pass 'an evals.md key with a graded eval folder' "$tmp/run"

# The script that counts the words has its own test; this test runs it, so make test-hooks covers it.
ww_out="$(bash "$(dirname "$script")/workflow-words.test.sh" 2>&1)" || fail "workflow-words.test.sh: $ww_out"

[[ $failures -eq 0 ]] && echo "check-governance tests: all passed"
exit $((failures > 0))
