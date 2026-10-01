#!/bin/bash
# Check that check-governance.sh refuses a budget row that goes up with no decisions.tsv time in
# its decision cell, and more than one rules.tsv removal in a docs-only branch of a run with a
# reflect row. Each case uses a temporary repo with a base commit on main and a branch.
# Run by `make test-hooks`.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/check-governance.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
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

[[ $failures -eq 0 ]] && echo "check-governance tests: all passed"
exit $((failures > 0))
