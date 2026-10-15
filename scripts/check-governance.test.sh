#!/bin/bash
# Check that check-governance.sh refuses a budget row that goes up with no decisions.tsv time in
# its decision cell, more than one rules.tsv removal in a docs-only branch of a run with a
# reflect row, a run folder that check-plan.sh refuses (an open Unknowns row), a run research
# file with no docs/research copy, a holdout fail in this run and in the newest done run that ran it, and a
# taken item of the run in ## Next of the backlog after the reflect row (phase 8), a features.md row
# of the base that the branch loses, a run.md `- Lands:` line whose F-ID keeps its features.md state, and a feat
# run that changes app code with no `- Lands:` line. Each case uses a temporary repo with a base commit on main
# and a branch.
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
# A branch raises TOTAL by at most 50 words, unless its QUOTA row holds a value at or above the new
# TOTAL (a consolidation run). A lower QUOTA or a deleted QUOTA row does not lift the cap.
totals() { printf 'path\twords\tdecision\na.md\t100\tbaseline\nb.md\t100\tbaseline\nTOTAL\t%s\tdecisions.tsv 2026-10-01T02:43\n%s' "$1" "$2" > "$budgets"; }
base_quota() { g switch -q main; printf 'QUOTA\t200\tbaseline\n' >> "$budgets"; g commit -qam quota; g switch -q -C feat/x; }
new_repo; totals 250 ''; commit
pass 'a TOTAL raise of 50 words'
new_repo; totals 251 ''; commit
refuse 'a TOTAL raise of 51 words with no QUOTA change' 'TOTAL goes up by 51 words'
out="$(cd "$tmp/r" && "$script" main 2>&1)"
[[ "$out" != *'change the QUOTA row'* ]] || fail "the cap message tells the agent to change the QUOTA row: $out"
new_repo; totals 251 $'QUOTA\t251\tdecisions.tsv 2026-10-01T02:43\n'; commit
pass 'a TOTAL raise of 51 words with a new QUOTA row at the new TOTAL'
new_repo; base_quota; totals 251 $'QUOTA\t251\tdecisions.tsv 2026-10-01T02:43\n'; commit
pass 'a TOTAL raise of 51 words with a QUOTA row raised to the new TOTAL'
new_repo; base_quota; totals 251 $'QUOTA\t199\tdecisions.tsv 2026-10-01T02:43\n'; commit
refuse 'a TOTAL raise of 51 words with a lower QUOTA' 'TOTAL goes up by 51 words'
new_repo; base_quota; totals 251 $'QUOTA\t201\tdecisions.tsv 2026-10-01T02:43\n'; commit
refuse 'a TOTAL raise of 51 words with a raised QUOTA below the new TOTAL' 'TOTAL goes up by 51 words'
new_repo; base_quota; totals 251 ''; commit
refuse 'a TOTAL raise of 51 words with the QUOTA row deleted' 'TOTAL goes up by 51 words'
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

# features.md keeps each row of the base: the ID and Feature cells of an `| F<n> |` row must stay.
# A drop sets Dropped (<reason>); a new idea gets a new ID. A base with no features.md has no rows to keep.
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
refuse 'a deleted features.md row' 'features.md lost the row of F02; keep it and set Dropped (<reason>)'
feat_repo; sed -i '' 's/| Two |/| Too |/' "$features"; commit
refuse 'a features.md row with another Feature cell' 'features.md lost the row of F02; keep it and set Dropped (<reason>)'
feat_repo; g rm -q docs/requirements/features.md; commit
refuse 'a branch with no features.md' 'features.md lost the row of F01'
feat_repo; sed -i '' 's/| Release 4 |/| Dropped (not used) |/' "$features"; commit
pass 'a features.md row set to Dropped'
feat_repo; printf '| F03 | Three | Logic | Later | R3 |\n' >> "$features"; commit
pass 'a features.md row added'
new_repo; mkdir -p "$tmp/r/docs/requirements"; printf '| F01 | One | Logic | Later | R1 |\n' > "$tmp/r/docs/requirements/features.md"; commit
pass 'a base with no features.md'

# A run.md with a `- Lands:` line names the F-IDs of this land, on any branch type: each one gets a done
# state that the base lacks, or the line says `none`. A feat run that changes app code (Sources/,
# Package.swift, Package.resolved, Support/) must have the line. A docs-only branch needs none.
# lands_repo <run.md text> [<app path>]: main holds F35, F77, and F89 at Release 4; the branch changes the path.
lands_repo() {
  feat_repo
  g switch -q main
  printf '# Features\n\n| ID | Feature | From | State | Req |\n|---|---|---|---|---|\n| F35 | Noise | Logic | Release 4 | R8 |\n| F77 | Hum | Logic | Release 4 | R8 |\n| F89 | Render | Logic | Release 4 | R8 |\n' > "$features"
  g add -A && g commit -q -m features
  g switch -q -C feat/x
  printf '%b' "$1" > "$tmp/run/run.md"
  mkdir -p "$tmp/r/$(dirname "${2:-Sources/A.swift}")"; echo x > "$tmp/r/${2:-Sources/A.swift}"
}
set_done() { sed -i '' "s/^\(| $1 | [^|]*| [^|]*| \)[^|]*|/\1done, Release 4 run ${2:-1} |/" "$features"; }
lands_repo '# Run\n\n- Branch: feat/x, from origin/main\n- Lands: F35, F89\n'; commit
refuse 'a feat run that changes Sources/ and keeps its states' 'run.md lands F35, but features.md keeps its state Release 4' "$tmp/run"
lands_repo '# Run\n\n- Branch: feat/x\n- Lands: F35, F89\n'; set_done F35; set_done F89; commit
pass 'a feat run that sets its states done' "$tmp/run"
lands_repo '# Run\n\n- Branch: feat/x\n- Requirements: F35, F89\n'; rm "$tmp/r/Sources/A.swift"; echo x > "$tmp/r/B.md"; commit
pass 'a feat run that changes only docs' "$tmp/run"
lands_repo '# Run\n\n- Branch: fix/x\n- Requirements: F35, F89\n'; commit
pass 'a run that is not feat, with no Lands line' "$tmp/run"
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
pass 'a feat run that changes Sources/ and writes Lands: none' "$tmp/run"
lands_repo '# Run\n\n- Branch: feat/x\n- Lands: F77\n' Support/Info.plist; set_done F77; commit
pass 'a feat run that changes only Support/ and sets its Lands state' "$tmp/run"
lands_repo '# Run\n\n- Branch: fix/x\n- Lands: F35\n'; commit
refuse 'a fix run with a Lands line and no state change' 'run.md lands F35, but features.md keeps its state Release 4' "$tmp/run"
lands_repo '# Run\n\n- Branch: fix/x\n- Lands: F35\n'; set_done F35; commit
pass 'a fix run with a Lands line and its state done' "$tmp/run"
lands_repo '# Run\n\n- Branch: docs/x\n- Lands: F35\n'; rm "$tmp/r/Sources/A.swift"; echo x > "$tmp/r/B.md"; commit
refuse 'a docs run with a Lands line and no state change' 'run.md lands F35, but features.md keeps its state Release 4' "$tmp/run"
lands_repo '# Run\n\n- Branch: feat/x\n- Lands:\n'; commit
refuse 'a feat run with an empty Lands line' 'run.md has a - Lands: line with no F-ID; name the F-IDs of this land, or write - Lands: none' "$tmp/run"
lands_repo '# Run\n\n- Branch: fix/x\n- Lands:   \n'; commit
refuse 'a fix run with a blank Lands line' 'run.md has a - Lands: line with no F-ID' "$tmp/run"

# Two holdout fails in a row stop the land. grade.py verdict writes its fail lines to
# eval/holdout-fails.txt of the run, so no hand row is needed. The run to compare is the newest done
# run of the ledger beside runs/ whose eval/scores.tsv has a row of the holdout: a run that did not
# run the holdout is skipped. One run alone, or an older done run behind a newer one, passes.
new_repo
s="$tmp/s"
rm -rf "$s" && mkdir -p "$s/runs/2026-01-01-a" "$s/runs/2026-01-02-b"
cp -R "$tmp/run" "$s/runs/2026-01-03-me"
printf '# Run ledger\n\n| Run | Goal | Status | Result |\n|---|---|---|---|\n| 2026-01-01-a | a | done | x |\n| 2026-01-02-b | b | done: PR #2 | x |\n| 2026-01-03-me | me | open | |\n' > "$s/ledger.md"
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
# A ledger status of the form `done, PR <n>, ...` is a done run too.
sed -i '' 's/| done: PR #2 |/| done, PR 2, x |/' "$s/ledger.md"
rm -rf "$s/runs/2026-01-02-b/eval"
hold 2026-01-02-b H6
refuse 'a holdout fail in this run and the newest run with the status done, PR 2' 'H6 failed in this run and in 2026-01-02-b' "$me"

[[ $failures -eq 0 ]] && echo "check-governance tests: all passed"
exit $((failures > 0))
