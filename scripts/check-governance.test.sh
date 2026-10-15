#!/bin/bash
# Check that check-governance.sh refuses a budget row that goes up with no decisions.tsv time in
# its decision cell, more than one rules.tsv removal in a docs-only branch of a run with a
# reflect row, a run folder that check-plan.sh refuses (an open Unknowns row), a run research
# file with no docs/research copy, a holdout fail in this run and in the newest done run, and a
# taken item of the run in ## Next of the backlog after the reflect row (phase 8). Each case uses
# a temporary repo with a base commit on main and a branch.
# Run by `make test-hooks`.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/check-governance.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE FILTER
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

g() { git -C "$tmp/r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
budgets="$tmp/r/docs/workflow/budgets.tsv"
rules="$tmp/r/docs/workflow/rules.tsv"
head_rules=$'id\tfile\tverdict\ttarget\treason\tsource\tkey\tsummary'

# A repo with budgets.tsv and rules.tsv on main, on the branch feat/x, and a run folder.
new_repo() {
  rm -rf "$tmp/r" "$tmp/run"
  mkdir -p "$tmp/r/docs/workflow" "$tmp/run"
  g init -q -b main
  printf 'path\twords\tdecision\na.md\t100\tbaseline\nb.md\t100\tbaseline\nTOTAL\t200\tbaseline\n' > "$budgets"
  printf '%s\nA-1\ta.md\tkeep\ta.md\tr\ts\t\tx\nA-2\ta.md\tkeep\ta.md\tr\ts\t\tx\nA-3\ta.md\tkeep\ta.md\tr\ts\t\tx\n' "$head_rules" > "$rules"
  g add -A
  g commit -q -m base
  g switch -q -c feat/x
  printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n' > "$tmp/run/decisions.tsv"
  printf '## Unknowns\n\n| id | parent | question | resolver | answer | row |\n|---|---|---|---|---|---|\n| U1 | - | q | code | a | 2026-10-01T01:00 |\n' > "$tmp/run/analysis.md"
  printf 'Agents: A = S1.\n\n## Slices\n\n### S1 x\n\n- Check: check-docs.\n' > "$tmp/run/plan.md"
}
commit() { g add -A && g commit -q -m change; }
row() { printf 'path\twords\tdecision\na.md\t%s\t%s\nb.md\t100\tbaseline\nTOTAL\t200\tbaseline\n' "$1" "$2" > "$budgets"; }
verdicts() { printf '%s\nA-1\ta.md\t%s\ta.md\tr\ts\t\tx\nA-2\ta.md\t%s\tA-1\tr\ts\t\tx\nA-3\ta.md\tkeep\ta.md\tr\ts\t\tx\n' "$head_rules" "$1" "$2" > "$rules"; }

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
three() { printf '%s\nA-1\ta.md\tdelete\t\tr\ts\t\tx\nA-2\ta.md\tmerge\tA-1\tr\ts\t\tx\nA-3\ta.md\tdelete\t\tr\ts\t\tx\n' "$head_rules" > "$rules"; }
new_repo; reflect_row; three; commit
refuse 'three removals with no user decision row' 'rules.tsv: 3 rows change to delete or merge' "$tmp/run"

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

# A run moves its own taken items out of ## Next of the main-checkout backlog before the land, so
# ## Next stays short (each run reads it at Phase 0). A taken item of another run, a taken item in
# ## Later, and no backlog file pass. In a worktree, the backlog of the main checkout counts.
# The check runs only after the reflect row (phase 8): Phase 7 runs it before Phase 8 moves the
# taken items out, and land.sh runs it after Phase 8.
new_repo; echo x > "$tmp/r/x.md"; commit
run2="$tmp/2026-01-01-x"; rm -rf "$run2"; cp -R "$tmp/run" "$run2"; mkdir -p "$tmp/r/.scratchpads"
printf '# Backlog\n\n## Next\n\n- (taken: run 2026-01-01-x) an item\n' > "$tmp/r/.scratchpads/backlog.md"
pass 'a taken item of the run with no reflect row' "$run2"
out="$(cd "$tmp/r" && GOVERNANCE_LAND=1 "$script" main "$run2" 2>&1)" && fail 'a taken item at the land with no reflect row: expected a nonzero exit'
[[ "$out" == *'## Next has a taken item of 2026-01-01-x'* ]] || fail "a taken item at the land with no reflect row: $out"
printf '2026-10-01T01:00\t8\treflect\tw\te\tr\n' >> "$run2/decisions.tsv"
refuse 'a taken item of the run with a reflect row' '## Next has a taken item of 2026-01-01-x' "$run2"
rm "$tmp/r/.scratchpads/backlog.md"
pass 'no backlog file' "$run2"
printf '# Backlog\n\n## Next\n\n- (taken: run 2026-01-01-x) an item\n\n## Later\n\n- b\n' > "$tmp/r/.scratchpads/backlog.md"
refuse 'a taken item of the run in ## Next' '## Next has a taken item of 2026-01-01-x' "$run2"
g worktree add -q "$tmp/wt" -b feat/wt 2>/dev/null
out="$(cd "$tmp/wt" && "$script" main "$run2" 2>&1)" && fail 'a taken item of the run in a worktree: expected a nonzero exit'
[[ "$out" == *'## Next has a taken item of 2026-01-01-x'* ]] || fail "a taken item of the run in a worktree: $out"
printf '# Backlog\n\n## Next\n\n- (taken: run 2026-01-01-z) an item\n\n## Later\n\n- (taken: run 2026-01-01-x) b\n' > "$tmp/r/.scratchpads/backlog.md"
pass 'a taken item of another run, and one in ## Later' "$run2"
# The run name ends at a space, a comma, or a parenthesis, so a run x-2 is another run. A backlog
# with no ## Next heading fails closed (code gate item C).
printf '# Backlog\n\n## Next\n\n- (taken: run 2026-01-01-x-2) an item\n' > "$tmp/r/.scratchpads/backlog.md"
pass 'a taken item of a run whose name starts with the run name' "$run2"
printf '# Backlog\n\n## Next (short)\n\n- (taken: run 2026-01-01-x, S3) an item\n' > "$tmp/r/.scratchpads/backlog.md"
refuse 'a taken item of the run with a slice' '## Next has a taken item of 2026-01-01-x' "$run2"
printf '# Backlog\n\n## Now\n\n- (taken: run 2026-01-01-x) an item\n' > "$tmp/r/.scratchpads/backlog.md"
refuse 'a backlog with no ## Next heading' 'backlog.md has no line that starts with ## Next' "$run2"

# A holdout fail (a phase 7 row "holdout fail <H>") in this run and in the newest done run of the
# ledger beside runs/ stops the land. One run alone, or an older done run, passes.
new_repo
s="$tmp/s"
rm -rf "$s" && mkdir -p "$s/runs/2026-01-01-a" "$s/runs/2026-01-02-b"
cp -R "$tmp/run" "$s/runs/2026-01-03-me"
printf '# Run ledger\n\n| Run | Goal | Status | Result |\n|---|---|---|---|\n| 2026-01-01-a | a | done | x |\n| 2026-01-02-b | b | done: PR #2 | x |\n| 2026-01-03-me | me | open | |\n' > "$s/ledger.md"
hold() { printf '2026-01-01T01:00\t7\tholdout fail %s: no changed text\tw\te\tr\n' "$2" >> "$s/runs/$1/decisions.tsv"; }
hold 2026-01-03-me H6
pass 'a holdout fail in this run only' "$s/runs/2026-01-03-me"
hold 2026-01-01-a H6
pass 'a holdout fail in this run and an older done run' "$s/runs/2026-01-03-me"
hold 2026-01-02-b H1
pass 'a fail of another holdout in the newest done run' "$s/runs/2026-01-03-me"
hold 2026-01-02-b H6
refuse 'a holdout fail in this run and the newest done run' 'H6 failed in this run and in 2026-01-02-b' "$s/runs/2026-01-03-me"

[[ $failures -eq 0 ]] && echo "check-governance tests: all passed"
exit $((failures > 0))
