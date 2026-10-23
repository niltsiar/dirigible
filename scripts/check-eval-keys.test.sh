#!/bin/bash
# Check that check-eval-keys.sh refuses an evals.md row that the branch adds or re-keys when no eval
# folder of the run holds its exact key text and a scores.tsv line of its ID. It passes for a branch
# with no key change, for a rebased branch, for a holdout and a row of type agent, and for a key
# change that only the base made after the branch point. It reads the branch tree, also from the
# main checkout. It exits 2 with the branch name when no worktree holds the run branch, and when
# the branch of the last `- Branch:` line is landed (no commit off the base). With two `- Branch:`
# lines it checks the last one, or the tree that the caller names. The refusal of an ungraded key
# names the lead as the step that grades. It finds keys.md in any folder of the run and takes
# scores.tsv from the same folder. It reads a branch name in backticks.
# Run by `make test-hooks`.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/check-eval-keys.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

main="$tmp/main"
run="$main/.scratchpads/runs/r1"
g() { git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "${@:2}"; }

# evals_md <E1 key> [<extra row>]: a Scenarios table with a graded row E1, a holdout H1, and a row of type agent.
evals_md() {
  printf '# Evals\n\n## Result\n\n| E9 | 0 of 3 | `a.md` |\n\n## Scenarios\n\n| ID | Type | Source | Question | Key points | Files | Old | New |\n|---|---|---|---|---|---|---|---|\n'
  printf '| E1 | policy | s | q | %s | `a.md` | - | - |\n' "$1"
  printf '| H1 | retention | s | q | In the run folder (holdout). | `a.md` | - | - |\n'
  printf '| E3 | agent | s | q | (a) the agent edits. | `a.md` | - | - |\n'
  [[ -z "${2:-}" ]] || printf '%s\n' "$2"
}
row() { printf '| %s | policy | s | q | %s | `a.md` | - | - |' "$1" "$2"; }

# work <worktree>: commit a file that is no evals.md change, so the branch has a commit off main.
work() { printf 'w\n' > "$1/work.txt"; g "$1" add work.txt; g "$1" commit -q -m work; }
# fresh: main holds evals.md with E1 key "(a) base."; the worktree $tmp/wt1 holds branch feat/a, with one commit; run.md names it.
fresh() {
  rm -rf "$tmp/main" "$tmp/wt1" "$tmp/wt2"
  mkdir -p "$main/docs/workflow" "$run"
  g "$main" init -q -b main
  evals_md '(a) base.' > "$main/docs/workflow/evals.md"
  printf 'a\n' > "$main/a.md"
  g "$main" add docs a.md
  g "$main" commit -q -m base
  g "$main" worktree add -q -b feat/a "$tmp/wt1"
  work "$tmp/wt1"
  printf '# Run r1\n\n- Branch: feat/a\n' > "$run/run.md"
}
# branch_evals <worktree> <E1 key> [<extra row>]: commit a new evals.md on the branch of the worktree.
branch_evals() {
  evals_md "$2" "${3:-}" > "$1/docs/workflow/evals.md"
  g "$1" add docs
  g "$1" commit -q -m keys
}
# eval_folder <name> <ID> <key> [noscore]: an eval folder of the run with keys.md and scores.tsv.
eval_folder() {
  mkdir -p "$run/$1"
  printf '## %s\n%s\n\n' "$2" "$3" >> "$run/$1/keys.md"
  [[ "${4:-}" == noscore ]] || printf 'p7\t%s\tpolicy\ta\t1\tPASS\t\n' "$2" >> "$run/$1/scores.tsv"
}
# check <name> <want code> <want text> <args...>: run from the main checkout.
check() {
  local name="$1" want="$2" text="$3" out code
  out="$(cd "$main" && "$script" "${@:4}" 2>&1)"
  code=$?
  [[ $code -eq $want ]] || fail "$name: expected exit $want, got $code: $out"
  [[ -z "$text" || "$out" == *"$text"* ]] || fail "$name: no '$text' in the message: $out"
}

fresh
check 'a branch that changes no key' 0 '' main "$run"

fresh; branch_evals "$tmp/wt1" '(a) base.' "$(row E4 '(a) new.')"
check 'a new row with no eval folder' 1 'E4' main "$run"
check 'the refusal names the lead as the step that grades' 1 'the lead runs' main "$run"
eval_folder eval E4 '(a) other text.'
check 'a folder whose keys.md holds other text' 1 'E4' main "$run"
rm -rf "$run/eval"; eval_folder eval E4 '(a) new.' noscore
check 'a folder with the key text and no scores.tsv line of the ID' 1 'E4' main "$run"
rm -rf "$run/eval"; eval_folder eval E4 '(a) new.'
check 'a folder with the exact key text and a scores.tsv line' 0 '' main "$run"
eval_folder eval-b E7 '(a) other.'
check 'a second folder for another ID' 0 '' main "$run"

# scripts/eval/run.sh writes keys.md in the eval folder that the caller names, at any depth of the run folder.
fresh; branch_evals "$tmp/wt1" '(a) base.' "$(row E4 '(a) new.')"
eval_folder logs/old/deep E4 '(a) new.'
check 'a graded folder nested in the run folder' 0 '' main "$run"
rm -rf "$run/logs"; eval_folder logs/a E4 '(a) new.' noscore; eval_folder logs/b E4 '(a) other.'
check 'keys.md and the scores.tsv line in two folders' 1 'E4' main "$run"

fresh; branch_evals "$tmp/wt1" '(b) re-keyed.'
check 'a re-keyed row with no eval folder' 1 'E1' main "$run"
eval_folder eval E1 '(b) re-keyed.'
check 'a re-keyed row with a graded folder' 0 '' main "$run"

fresh; branch_evals "$tmp/wt1" '(a) base \| and (b) bar.'
eval_folder eval E1 '(a) base | and (b) bar.'
check 'a key with an escaped bar is graded as the runner writes it' 0 '' main "$run"

fresh; branch_evals "$tmp/wt1" '(a) base.' "$(row H2 'In the run folder (holdout).')"$'\n'"$(row E8 '(a) the agent runs.' | sed 's/| policy |/| agent |/')"
check 'a holdout and a row of type agent are skipped' 0 '' main "$run"

# A rebased branch has other commit hashes and the same text.
fresh; branch_evals "$tmp/wt1" '(a) base.' "$(row E4 '(a) new.')"
eval_folder eval E4 '(a) new.'
printf 'b\n' > "$main/b.md"; g "$main" add b.md; g "$main" commit -q -m other
before="$(g "$tmp/wt1" rev-parse HEAD)"
g "$tmp/wt1" rebase -q main
[[ "$(g "$tmp/wt1" rev-parse HEAD)" != "$before" ]] || fail 'the rebase kept the commit hash'
check 'a rebased branch' 0 '' main "$run"

# The base changes a key after the branch point and the branch changes none.
fresh
evals_md '(a) the base moved on.' > "$main/docs/workflow/evals.md"; g "$main" add docs; g "$main" commit -q -m 'base re-keys E1'
check 'a key change that only the base made' 0 '' main "$run"

# The caller is the main checkout, whose own evals.md has no change: the branch tree decides.
fresh; branch_evals "$tmp/wt1" '(a) base.' "$(row E4 '(a) new.')"
[[ "$(grep -c E4 "$main/docs/workflow/evals.md")" -eq 0 ]] || fail 'the main checkout holds the branch row'
check 'a call from the main checkout sees the branch keys' 1 'E4' main "$run"

fresh; sed -i '' 's|feat/a|feat/none|' "$run/run.md"
check 'no worktree holds the run branch' 2 'feat/none' main "$run"
out="$(cd "$main" && "$script" main "$run" 2>&1)"
[[ "$out" != *'give the tree'* ]] || fail "the message offers a tree that log-decision.sh cannot give: $out"

fresh; printf '# Run r1\n\n- Branch: `feat/a`\n' > "$run/run.md"
check 'a branch name in backticks' 0 '' main "$run"

# A landed branch: a rebase merge puts its commits on main under other hashes, so no commit is off the base.
fresh; branch_evals "$tmp/wt1" '(a) base.' "$(row E4 '(a) new.')"
printf 'b\n' > "$main/b.md"; g "$main" add b.md; g "$main" commit -q -m other
g "$main" cherry-pick main..feat/a >/dev/null
[[ "$(g "$main" rev-parse HEAD)" != "$(g "$tmp/wt1" rev-parse HEAD)" ]] || fail 'the landing kept the commit hash'
check 'the last - Branch: line is landed' 2 'add the line of the next landing' main "$run"
check 'a landed branch, with the tree given' 1 'E4' main "$run" "$tmp/wt1"

# Two landings: the last - Branch: line is the default tree, and a tree argument picks another.
fresh; branch_evals "$tmp/wt1" '(a) base.' "$(row E4 '(a) new.')"
g "$main" worktree add -q -b feat/b "$tmp/wt2"; work "$tmp/wt2"
printf '# Run r1\n\n- Branch: feat/a\n- Branch: feat/b\n' > "$run/run.md"
check 'two branches, no tree: the last branch has no key change' 0 '' main "$run"
check 'two branches, the tree of the first branch' 1 'E4' main "$run" "$tmp/wt1"

fresh
check 'one argument' 2 'usage' main
check 'a bad base' 2 'merge base' nope "$run"

[[ $failures -eq 0 ]] && echo "check-eval-keys tests: all passed"
exit $((failures > 0))
