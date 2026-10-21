#!/bin/bash
# Check that land.sh runs the land steps of deliver Phase 9 in order and stops at the first
# failure. Each case uses a temporary repo, a bare remote, and fake make and gh on PATH that log
# their arguments. Cases: the happy path, another worktree that holds main, a red check, a rebase conflict (the rebase is aborted),
# main moved after the check, a run on main or a detached HEAD, an untracked or a changed file, a
# red governance check, `risk: yes` with and with no mutation pass row, a body that pr-terms.sh flags
# (before the fetch), a body that lost a number of logs/pr-draft.md, a pr-terms.sh error, a
# missing body file, and no arguments. The stamp cases: a matching stamp runs no check, a delta
# after the stamp runs the targets of the delta after the load wait, and no usable stamp runs the
# full push check; the governance and the ancestor checks still run. The land reads the stamp
# before its rebase: the delta is the tree diff to the rebased HEAD, with the test target for a
# file that a code line of a Swift test names whole, and a second land of a stopped branch reuses
# the stamp commit. The ratchet case runs the real make check-changed first, so the land runs no
# check after it. A partial stamp is no pass. The tool-author guard of check-commits.sh: a tool
# name in the author, the committer, or a Co-Authored-By trailer refuses the land and the push
# (.githooks/pre-push) for each field and name, and the owner passes; a tool commit below the base
# is out of the range.
# The resume cases (a second land of a branch whose PR exists, after a merge error): an open PR gets
# its text from the body file and one merge call; the kept stamp, the checks, and the governance
# check still run; origin/main past the pushed head stops it before any check; a closed PR, a
# failed lookup, and a reused branch name (the PRs of an earlier run are ignored).
# Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
land="$here/land.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# A git or make value of an outer run (make test-hooks) must not reach the ratchet case.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE MAKE MAKEFLAGS MFLAGS MAKELEVEL BASE FILTER CHECK_RISK
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

bin="$tmp/bin"
mkdir "$bin"
# The fake make logs its arguments and whether origin/main is in HEAD (the rebase came first).
# FAKE_MAKE=red fails the check; FAKE_MAKE=move moves origin/main while the check runs;
# FAKE_MAKE=changed logs the output of the real check-changed.sh origin/main, as the recipe runs it.
cat > "$bin/make" <<'EOF'
#!/bin/bash
echo "make $*" >> "$LAND_LOG"
[[ -z "${CHECK_RISK:-}" ]] || echo "make: risk $CHECK_RISK" >> "$LAND_LOG"
[[ -z "${BASE:-}" ]] || echo "make: base $BASE" >> "$LAND_LOG"
git merge-base --is-ancestor origin/main HEAD && echo "make: rebased" >> "$LAND_LOG"
case "${FAKE_MAKE:-ok}" in
  red) exit 1 ;;
  move) git -C "$FAKE_OTHER" commit -q --allow-empty -m moved && git -C "$FAKE_OTHER" push -q origin main ;;
  changed) "$FAKE_CHANGED" origin/main >> "$LAND_LOG" ;;
esac
exit 0
EOF
# The fake gh logs its arguments: a read (`pr list`, `pr view`) to $LAND_LOG.view, any other call
# to $LAND_LOG. The state file $LAND_LOG.pr has one line per PR, newest first: state, url, head,
# merge commit or -, commit count, separated by tabs. `pr create` fails while a PR is OPEN; else it
# logs whether the branch is on origin (the push came first), adds an OPEN line, and prints its URL
# (the first PR is 7). `pr merge` puts HEAD on origin/main, as a rebase merge does, and sets the
# OPEN line to MERGED. FAKE_GH=move moves origin/main in `pr create`, for a land that runs no make.
# FAKE_MERGE=fail:<n> fails the first n `pr merge` calls (counted in $LAND_LOG.merges) with a 502 text.
# FAKE_LOOKUP=502 fails `pr list`, and FAKE_STATE=502 fails `pr view`, with a GitHub 502 text.
cat > "$bin/gh" <<'EOF'
#!/bin/bash
prs="$LAND_LOG.pr"
bad="HTTP 502: Bad Gateway (https://api.github.com/graphql)"
case "$1 $2" in
  "pr list"|"pr view") echo "gh $*" >> "$LAND_LOG.view" ;;
  *) echo "gh $*" >> "$LAND_LOG" ;;
esac
case "$1 $2" in
  "pr list")
    [[ "${FAKE_LOOKUP:-}" != 502 ]] || { echo "$bad" >&2; exit 1; }
    [[ ! -f "$prs" ]] || cat "$prs" ;;
  "pr view")
    [[ "${FAKE_STATE:-}" != 502 ]] || { echo "$bad" >&2; exit 1; }
    awk -F'\t' -v u="$3" '$2 == u { print $1 }' "$prs" ;;
  "pr create")
    if grep -q '^OPEN' "$prs" 2>/dev/null; then
      echo "a pull request for branch \"$(git branch --show-current)\" into branch \"main\" already exists" >&2
      exit 1
    fi
    git ls-remote --exit-code --heads origin "$(git branch --show-current)" > /dev/null && echo "gh: branch on origin" >> "$LAND_LOG"
    [[ "${FAKE_GH:-}" == move ]] && git -C "$FAKE_OTHER" commit -q --allow-empty -m moved && git -C "$FAKE_OTHER" push -q origin main
    url="https://github.com/o/r/pull/$((7 + $(cat "$prs" 2>/dev/null | grep -c .)))"
    { printf 'OPEN\t%s\t%s\t-\t%s\n' "$url" "$(git rev-parse HEAD)" "$(git rev-list --count origin/main..HEAD)"; cat "$prs" 2>/dev/null; } > "$prs.new"
    mv "$prs.new" "$prs"
    echo "$url" ;;
  "pr merge")
    calls=$(($(cat "$LAND_LOG.merges" 2>/dev/null || echo 0) + 1))
    echo "$calls" > "$LAND_LOG.merges"
    case "${FAKE_MERGE:-}" in fail:*) if ((calls <= ${FAKE_MERGE#fail:})); then echo "$bad" >&2; exit 1; fi ;; esac
    git push -q origin HEAD:main
    awk -F'\t' -v OFS='\t' -v mc="$(git rev-parse HEAD)" '$1 == "OPEN" && !done { $1 = "MERGED"; $4 = mc; done = 1 } { print }' "$prs" > "$prs.new"
    mv "$prs.new" "$prs" ;;
esac
EOF
# The fake sysctl logs its arguments and gives 8 cores and a load of 1.00, for the load wait.
cat > "$bin/sysctl" <<'EOF'
#!/bin/bash
echo "sysctl $*" >> "$LAND_LOG"
case "$2" in hw.ncpu) echo 8 ;; vm.loadavg) echo "{ 1.00 1.00 1.00 }" ;; esac
EOF
# The fake pgrep finds no test of another tree (no output, exit 1, as the real pgrep), so a test
# run of another worktree does not make the load wait go on.
printf '#!/bin/bash\nexit 1\n' > "$bin/pgrep"
chmod +x "$bin/make" "$bin/gh" "$bin/sysctl" "$bin/pgrep"

# A new case: a remote with one commit on main, a clone on the branch feat/x with one commit,
# and one more commit on origin/main after the branch, so the land must rebase.
setup() {
  c="$tmp/case"
  rm -rf "$c"
  mkdir "$c"
  git init -q --bare -b main "$c/origin.git"
  git init -q -b main "$c/other"
  git -C "$c/other" remote add origin "$c/origin.git"
  git -C "$c/other" commit -q --allow-empty -m base
  git -C "$c/other" push -q origin main
  git clone -q "$c/origin.git" "$c/work"
  git -C "$c/work" switch -q -c feat/x
  # A slow run passed today, so the push targets do not add test-slow for the date.
  date +%F > "$c/work/.git/dirigible-slow-date"
  echo x > "$c/work/x.txt"
  git -C "$c/work" add x.txt
  git -C "$c/work" commit -q -m feature
  git -C "$c/other" commit -q --allow-empty -m "main moves"
  git -C "$c/other" push -q origin main
  printf 'body\n' > "$c/pr.md"
  # The run folder is the folder of the body file; check-governance.sh runs check-plan.sh on it.
  printf '## Unknowns\n\n| id | parent | question | resolver | answer | row |\n|---|---|---|---|---|---|\n| U1 | - | q | code | a | 2026-10-01T01:00 |\n' > "$c/analysis.md"
  printf 'Agents: A = S1.\n\n## Slices\n\n### S1 x\n\n- Check: check-docs.\n' > "$c/plan.md"
  : > "$c/log"
}

land_in() {
  (cd "${land_dir:-$c/work}" && PATH="$bin:$PATH" LAND_LOG="$c/log" FAKE_OTHER="$c/other" "$land" "$@") > "$c/out" 2>&1
}

no_side_effects() {
  [[ ! -s "$c/log" ]] || fail "$1: make or gh ran: $(cat "$c/log")"
  ! git -C "$c/origin.git" show-ref -q --verify refs/heads/feat/x || fail "$1: the branch is on origin"
}

# Happy path: rebase, check, push, create, merge, then main is up to date.
setup
old="$(git -C "$c/other" rev-parse HEAD)"
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 0 ]] || fail "happy: exit $code: $(cat "$c/out")"
want="make check-changed BASE=origin/main
make: rebased
gh pr create --base main --head feat/x --title Add x --body-file $c/pr.md
gh: branch on origin
gh pr merge feat/x --rebase --delete-branch"
[[ "$(cat "$c/log")" == "$want" ]] || fail "happy: calls differ: $(cat "$c/log")"
[[ "$(git -C "$c/work" config branch.feat/x.remote)" == origin ]] || fail 'happy: the push did not set the upstream'
[[ "$(git -C "$c/work" branch --show-current)" == main ]] || fail 'happy: not on main at the end'
new="$(git -C "$c/origin.git" rev-parse main)"
[[ "$new" != "$old" && "$(git -C "$c/work" rev-parse HEAD)" == "$new" ]] || fail 'happy: local main is not origin/main'
grep -qx 'pr: https://github.com/o/r/pull/7' "$c/out" || fail "happy: no PR URL: $(cat "$c/out")"
grep -qx "range: $old..$new" "$c/out" || fail "happy: no commit range $old..$new: $(cat "$c/out")"
grep -qx 'stamp: none (no stamp)' "$c/out" || fail "happy: no stamp line: $(cat "$c/out")"
[[ "$(cat "$c/log.view")" == 'gh pr list --head feat/x --state all --json state,url,headRefOid,mergeCommit,commits --jq .[]|[.state,.url,.headRefOid,(.mergeCommit.oid // "-"),(.commits|length)]|@tsv' ]] ||
  fail "happy: the lookup differs: $(cat "$c/log.view")"

# Another worktree holds main: the land prints the range before it touches main, skips the
# switch, and stays on the branch (git switch main exits 128 in this state).
setup
old="$(git -C "$c/other" rev-parse HEAD)"
git -C "$c/work" worktree add -q "$c/wt" main
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 0 ]] || fail "main in a worktree: exit $code: $(cat "$c/out")"
new="$(git -C "$c/origin.git" rev-parse main)"
grep -qx "range: $old..$new" "$c/out" || fail "main in a worktree: no commit range $old..$new: $(cat "$c/out")"
grep -q "main is checked out in .*/case/wt; fast-forwarded it" "$c/out" || fail "main in a worktree: no fast-forward line: $(cat "$c/out")"
[[ "$(git -C "$c/work" branch --show-current)" == feat/x ]] || fail 'main in a worktree: not on the branch at the end'
[[ "$(git -C "$c/wt" rev-parse HEAD)" == "$new" ]] || fail 'main in a worktree: the clean worktree is not at origin/main'
# With changes in that worktree, the land prints the command and does not touch the worktree.
setup
git -C "$c/work" worktree add -q "$c/wt" main
before="$(git -C "$c/wt" rev-parse HEAD)"
echo y > "$c/wt/y.txt"
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 0 ]] || fail "main in a changed worktree: exit $code: $(cat "$c/out")"
grep -q 'which has changes; fast-forward it there with git merge --ff-only origin/main' "$c/out" || fail "main in a changed worktree: no command line: $(cat "$c/out")"
[[ "$(git -C "$c/wt" rev-parse HEAD)" == "$before" && -f "$c/wt/y.txt" ]] || fail 'main in a changed worktree: the worktree changed'
# A local main that diverged: the fast-forward fails after the merge, and the land says so.
setup
git -C "$c/work" worktree add -q "$c/wt" main
git -C "$c/wt" commit -q --allow-empty -m local
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 0 ]] || fail "main diverged: exit $code: $(cat "$c/out")"
grep -q 'the merge is done, but the fast-forward of main in .*/case/wt failed' "$c/out" || fail "main diverged: no failure line: $(cat "$c/out")"

# A red check stops before the push.
setup
FAKE_MAKE=red land_in "Add x" "$c/pr.md"
code=$?
[[ $code -ne 0 ]] || fail 'red check: exit 0'
grep -q 'the checks failed' "$c/out" || fail "red check: no reason: $(cat "$c/out")"
! grep -q '^gh ' "$c/log" || fail "red check: gh ran: $(cat "$c/log")"
! git -C "$c/origin.git" show-ref -q --verify refs/heads/feat/x || fail 'red check: the branch is on origin'

# A rebase conflict: the land aborts the rebase, so the branch is as before, and stops.
setup
echo conflict > "$c/other/x.txt"
git -C "$c/other" add x.txt && git -C "$c/other" commit -q -m conflict && git -C "$c/other" push -q origin main
before="$(git -C "$c/work" rev-parse HEAD)"
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -ne 0 ]] || fail 'conflict: exit 0'
grep -q 'the rebase on origin/main stopped on a conflict; the rebase is aborted' "$c/out" || fail "conflict: no reason: $(cat "$c/out")"
[[ ! -d "$c/work/.git/rebase-merge" && ! -d "$c/work/.git/rebase-apply" ]] ||
  fail 'conflict: a rebase is in progress'
[[ "$(git -C "$c/work" branch --show-current)" == feat/x && "$(git -C "$c/work" rev-parse HEAD)" == "$before" ]] ||
  fail 'conflict: the branch is not as before'
no_side_effects 'conflict'

# origin/main moves after the check: the pull request exists, the merge does not run.
setup
FAKE_MAKE=move land_in "Add x" "$c/pr.md"
code=$?
[[ $code -ne 0 ]] || fail 'main moved: exit 0'
grep -q 'origin/main moved' "$c/out" || fail "main moved: no reason: $(cat "$c/out")"
grep -q '^gh pr create ' "$c/log" || fail "main moved: no pr create: $(cat "$c/log")"
! grep -q '^gh pr merge' "$c/log" || fail "main moved: the merge ran: $(cat "$c/log")"
[[ "$(git -C "$c/origin.git" log -1 --format=%s main)" == moved ]] || fail 'main moved: origin/main changed after the move'

# A run on main or on a detached HEAD refuses before any step.
setup
git -C "$c/work" switch -q main
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -ne 0 ]] || fail 'on main: exit 0'
grep -q 'refuses to run on main' "$c/out" || fail "on main: no reason: $(cat "$c/out")"
no_side_effects 'on main'
git -C "$c/work" switch -q --detach feat/x
: > "$c/log"
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -ne 0 ]] || fail 'detached: exit 0'
grep -q 'HEAD is detached' "$c/out" || fail "detached: no reason: $(cat "$c/out")"
no_side_effects 'detached'

# An untracked file or a changed tracked file refuses before the fetch: the checks build the
# working tree, and the push sends only the commits.
for kind in untracked changed; do
  setup
  if [[ $kind == untracked ]]; then echo y > "$c/work/y.txt"; else echo x2 > "$c/work/x.txt"; fi
  land_in "Add x" "$c/pr.md"
  code=$?
  [[ $code -ne 0 ]] || fail "$kind file: exit 0"
  grep -q 'the working tree has changes that the push does not send' "$c/out" || fail "$kind file: no reason: $(cat "$c/out")"
  [[ "$(git -C "$c/work" rev-parse origin/main)" != "$(git -C "$c/origin.git" rev-parse main)" ]] ||
    fail "$kind file: the fetch ran"
  no_side_effects "$kind file"
done

# A budget row that goes up with no decisions.tsv row stops before the checks and the push.
setup
mkdir -p "$c/other/docs/workflow"
printf 'path\twords\tdecision\na.md\t100\tbaseline\n' > "$c/other/docs/workflow/budgets.tsv"
git -C "$c/other" add -A && git -C "$c/other" commit -q -m budgets && git -C "$c/other" push -q origin main
git -C "$c/work" fetch -q && git -C "$c/work" rebase -q origin/main
printf 'path\twords\tdecision\na.md\t120\traised\n' > "$c/work/docs/workflow/budgets.tsv"
git -C "$c/work" commit -q -am raise
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -ne 0 ]] || fail 'governance: exit 0'
grep -q 'the governance check failed' "$c/out" || fail "governance: no reason: $(cat "$c/out")"
no_side_effects 'governance'

# risk: yes (a file under Sources/DirigibleAudio/) needs a mutation pass row (phase 7, a log under
# controls/) in the decisions.tsv of the run folder (the folder of the body file), or a third
# argument that names the row that says why no pass applies. A slice control row (phase 4) or a red
# log row alone is not the pass, and a pass row older than the last Sources/ commit of the branch
# (its author minute) does not cover the tree that lands. Else the land stops before the checks
# and the push.
risk_setup() {
  setup
  mkdir -p "$c/work/Sources/DirigibleAudio"
  echo a > "$c/work/Sources/DirigibleAudio/A.swift"
  git -C "$c/work" add -A && git -C "$c/work" commit -q -m audio
  printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n2026-10-01T01:00\t4\tslice 1\tw\tlogs/s1.log\tdone\n' > "$c/decisions.tsv"
}
risk_refused() {
  [[ $code -ne 0 ]] || fail "$1: exit 0"
  grep -q "$2" "$c/out" || fail "$1: no '$2' in: $(cat "$c/out")"
  no_side_effects "$1"
}
risk_setup
rm "$c/decisions.tsv"
land_in "Add x" "$c/pr.md"
code=$?
risk_refused 'risk with no decisions.tsv' 'risk: yes and no decisions.tsv'
risk_setup
land_in "Add x" "$c/pr.md"
code=$?
risk_refused 'risk with no pass row' 'has no mutation pass row'
risk_setup
land_in "Add x" "$c/pr.md" 2026-10-01T09:99
code=$?
risk_refused 'risk with a missing why row' 'no row 2026-10-01T09:99'
risk_setup
printf '2026-10-01T02:00\t4\ts2 red first\tw\tlogs/s2-red.log\tdone\n' >> "$c/decisions.tsv"
printf '2026-10-01T02:01\t4\tk1 killed\tw\tcontrols/k1.log\tkilled\n' >> "$c/decisions.tsv"
land_in "Add x" "$c/pr.md"
code=$?
risk_refused 'risk with only slice rows' 'has no mutation pass row'
risk_setup
printf '2026-10-01T02:00\t4\ts2 red first\tw\tlogs/s2-red.log\tdone\n' >> "$c/decisions.tsv"
printf '2026-10-01T03:00\t7\tmutation pass: k1 killed\tw\tcontrols/k1.log\tkilled\n' >> "$c/decisions.tsv"
land_in "Add x" "$c/pr.md"
code=$?
risk_refused 'risk with a pass row before the last Sources commit' 'older than the last Sources/ commit'
grep -q 'or pass the time of the phase 7 row that says the fix touches no guard' "$c/out" ||
  fail "risk with a pass row before the last Sources commit: no why-row option in: $(cat "$c/out")"
# Only a row whose decision starts with "mutation pass" is the pass row: a newer phase 7 row with
# a log under controls/ (a pass measure row) does not hide a stale pass.
risk_setup
printf '2026-10-01T03:00\t7\tmutation pass: k1 killed\tw\tcontrols/k1.log\tkilled\n' >> "$c/decisions.tsv"
printf '%s\t7\tpass measure: 1 pick\tw\tcontrols/k1.log\tdone\n' "$(date +%FT%R)" >> "$c/decisions.tsv"
land_in "Add x" "$c/pr.md"
code=$?
risk_refused 'risk with a newer pass measure row after a stale pass' 'older than the last Sources/ commit'
risk_setup
printf '%s\t7\tmutation pass: k1 killed\tw\tcontrols/k1.log\tkilled\n' "$(date +%FT%R)" >> "$c/decisions.tsv"
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 0 ]] || fail "risk with a pass row: exit $code: $(cat "$c/out")"
grep -q '^gh pr merge' "$c/log" || fail "risk with a pass row: no merge: $(cat "$c/log")"
# Only a Sources/ commit makes the pass old: a docs commit 5 min after the pass row lands.
risk_setup
printf '%s\t7\tmutation pass: k1 killed\tw\tcontrols/k1.log\tkilled\n' "$(date +%FT%R)" >> "$c/decisions.tsv"
echo d > "$c/work/notes.md"
git -C "$c/work" add -A && GIT_AUTHOR_DATE="$(date -v+5M +%FT%T)" git -C "$c/work" commit -q -m docs
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 0 ]] || fail "risk with a docs commit after the pass: exit $code: $(cat "$c/out")"
grep -q '^gh pr merge' "$c/log" || fail "risk with a docs commit after the pass: no merge: $(cat "$c/log")"
risk_setup
land_in "Add x" "$c/pr.md" 2026-10-01T01:00
code=$?
[[ $code -eq 0 ]] || fail "risk with a why row: exit $code: $(cat "$c/out")"
grep -q '^gh pr merge' "$c/log" || fail "risk with a why row: no merge: $(cat "$c/log")"

# The stamp cases. stamp_setup puts the branch on origin/main, so the rebase of the land keeps
# the commits. stamp <base> appends a stamp line for HEAD, as a passing check does.
stamp_setup() {
  setup
  git -C "$c/work" fetch -q
  git -C "$c/work" rebase -q origin/main
}
stamp() { (cd "$c/work" && "$here/check-stamp.sh" write "$(git rev-parse HEAD)" clean "$(git rev-parse "$1")" check test-slow) > /dev/null; }
commit_file() {
  mkdir -p "$(dirname "$c/work/$1")"
  echo "$1" > "$c/work/$1"
  git -C "$c/work" add -A && git -C "$c/work" commit -q -m "$1"
}
makes() { grep '^make [^:]' "$c/log"; }
# stamp_case <name> <stamp line> <make calls>: the land merges, prints the stamp line, and runs
# only the make calls (one per line, or none).
stamp_case() {
  land_in "Add x" "$c/pr.md"
  code=$?
  [[ $code -eq 0 ]] || fail "$1: exit $code: $(cat "$c/out")"
  grep -qx "$2" "$c/out" || fail "$1: no '$2' line: $(cat "$c/out")"
  [[ "$(makes)" == "$3" ]] || fail "$1: make calls [$(makes)], want [$3]"
  grep -q '^gh pr merge' "$c/log" || fail "$1: no merge: $(cat "$c/log")"
}

# A matching stamp: no check runs. A later line with a base that is not on main (the reflect
# check) does not hide it.
stamp_setup
head="$(git -C "$c/work" rev-parse HEAD)"
stamp origin/main
stamp HEAD
stamp_case 'matching stamp' "stamp: reuse $head" ''

# A docs commit after the stamp: only check-docs. A Sources commit: check.
stamp_setup
stamp origin/main
commit_file docs/a.md
stamp_case 'docs delta' 'stamp: delta check-docs' 'make -k check-docs'
grep -qx 'make: risk no' "$c/log" || fail "docs delta: run-checks.sh did not get CHECK_RISK=no: $(cat "$c/log")"
grep -qx 'make: base origin/main' "$c/log" || fail "docs delta: run-checks.sh did not get BASE, so it does not mark the tree: $(cat "$c/log")"
! grep -q '^sysctl' "$c/log" || fail "docs delta: the load wait read the load: $(cat "$c/log")"
stamp_setup
stamp origin/main
commit_file Sources/DirigibleApp/X.swift
stamp_case 'sources delta' 'stamp: delta check' 'make -k check'
# The delta runs Swift tests, so the load wait reads the load before make.
[[ "$(grep -E '^(sysctl -n vm.loadavg|make -k check)$' "$c/log")" == $'sysctl -n vm.loadavg\nmake -k check' ]] ||
  fail "sources delta: no load wait before make check: $(cat "$c/log")"
grep -q 'check-changed: load 1.00, under 8' "$c/out" || fail "sources delta: no load line: $(cat "$c/out")"

# A move of a bundle file after the stamp: --no-renames keeps the old path, so the delta is bundle.
stamp_setup
commit_file Support/x.plist
stamp origin/main
mkdir -p "$c/work/docs"
git -C "$c/work" mv Support/x.plist docs/x.plist
git -C "$c/work" commit -q -m move
stamp_case 'renamed bundle path' 'stamp: delta check test-dmg' 'make -k check test-dmg'

# A delta with risk: yes against origin/main gives run-checks.sh CHECK_RISK=yes (1 rerun at most).
stamp_setup
commit_file Sources/DirigibleAudio/A.swift
printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n%s\t7\tmutation pass: k1 killed\tw\tcontrols/k1.log\tkilled\n' "$(date +%FT%R)" > "$c/decisions.tsv"
stamp origin/main
commit_file docs/a.md
stamp_case 'risk delta' 'stamp: delta check-docs' 'make -k check-docs'
grep -qx 'make: risk yes' "$c/log" || fail "risk delta: run-checks.sh did not get CHECK_RISK=yes: $(cat "$c/log")"

# A stamp of an older commit of main (another run landed since the check) gives the delta. A stamp
# with a base that is a branch commit is no pass: the full push check, with the reason.
stamp_setup
stamp origin/main~1
commit_file docs/a.md
stamp_case 'base moved on main' 'stamp: delta check-docs' 'make -k check-docs'
stamp_setup
stamp HEAD
stamp_case 'base off main' 'stamp: none (base moved)' 'make check-changed BASE=origin/main'
# main_commit <path> [<text>]: origin/main gets a commit of one file, as another run that landed.
main_commit() {
  mkdir -p "$(dirname "$c/other/$1")"
  echo "${2:-$1}" > "$c/other/$1"
  git -C "$c/other" add -A && git -C "$c/other" commit -q -m "$1" && git -C "$c/other" push -q origin main
}
# The land reads the stamp before its rebase, and runs the targets of the tree diff from the
# stamped commit to the rebased HEAD. In each case, origin/main moves and is fetched first, then
# the stamp has origin/main as its base, as the land has.
setup
git -C "$c/work" fetch -q
stamp origin/main
stamp_case 'rebase with an empty main delta' "stamp: reuse $(git -C "$c/work" rev-parse HEAD)" ''
setup
main_commit docs/a.md
git -C "$c/work" fetch -q
stamp origin/main
stamp_case 'rebase delta docs' 'stamp: delta check-docs' 'make -k check-docs'
setup
main_commit docs/a.md
main_commit scripts/a.sh
git -C "$c/work" fetch -q
stamp origin/main
stamp_case 'rebase delta tooling' 'stamp: delta check-fast' 'make -k check-fast'
setup
main_commit Sources/DirigibleApp/X.swift
git -C "$c/work" fetch -q
stamp origin/main
stamp_case 'rebase delta sources' 'stamp: delta check' 'make -k check'
[[ "$(grep -E '^(sysctl -n vm.loadavg|make -k check)$' "$c/log")" == $'sysctl -n vm.loadavg\nmake -k check' ]] ||
  fail "rebase delta sources: no load wait before make check: $(cat "$c/log")"
# A branch commit after the stamp counts, not only the main delta.
setup
main_commit docs/a.md
git -C "$c/work" fetch -q
stamp origin/main
commit_file Tests/T.swift
stamp_case 'rebase delta with a later branch commit' 'stamp: delta check' 'make -k check'
# A floor path on main adds test-slow-push, and the risk stays that of the branch.
setup
main_commit Sources/DirigibleAudio/A.swift
git -C "$c/work" fetch -q
stamp origin/main
stamp_case 'rebase delta with a floor path on main' 'stamp: delta check test-slow-push' 'make -k check test-slow-push'
grep -qx 'make: risk no' "$c/log" || fail "rebase delta with a floor path on main: run-checks.sh did not get CHECK_RISK=no: $(cat "$c/log")"
# A conflict stops the land before any stamp line, any check, and any push.
setup
main_commit x.txt conflict
git -C "$c/work" fetch -q
stamp origin/main
before="$(git -C "$c/work" rev-parse HEAD)"
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -ne 0 ]] || fail 'conflict with a stamp: exit 0'
grep -q 'the rebase on origin/main stopped on a conflict' "$c/out" || fail "conflict with a stamp: no reason: $(cat "$c/out")"
! grep -q '^stamp:' "$c/out" || fail "conflict with a stamp: a stamp line: $(cat "$c/out")"
[[ "$(git -C "$c/work" rev-parse HEAD)" == "$before" ]] || fail 'conflict with a stamp: the branch is not as before'
no_side_effects 'conflict with a stamp'
# A stamp of a commit that is not in HEAD before the rebase (a side branch) is no pass.
setup
git -C "$c/work" fetch -q
git -C "$c/work" switch -q -c side
git -C "$c/work" commit -q --allow-empty -m side
stamp origin/main
git -C "$c/work" switch -q feat/x
stamp_case 'not an ancestor before the rebase' 'stamp: none (not an ancestor)' 'make check-changed BASE=origin/main'
# A delta path that a Swift test reads adds a test target. reads_case <name> <test file> <test
# text> <main file> <targets>: the stamped tree and HEAD both hold the test file, then
# origin/main gets the main file.
reads_case() {
  setup
  main_commit "$2" "$3"
  git -C "$c/work" fetch -q && git -C "$c/work" rebase -q origin/main
  main_commit "$4"
  git -C "$c/work" fetch -q
  stamp origin/main
  stamp_case "$1" "stamp: delta $5" "make -k $5"
}
reads_case 'rebase delta of a file that a test reads' Tests/G.swift 'let p = "../../docs/guide.md"' docs/guide.md 'check-docs test'
reads_case 'rebase delta of a doc that no test reads' Tests/G.swift 'let p = "../../docs/guide.md"' docs/a.md check-docs
# Only a path that a code line names whole counts: a comment, a longer name, and a name that is
# part of a longer path do not.
reads_case 'rebase delta of a file that a test names in a comment' Tests/G.swift '/// reads "scripts/a.sh"' scripts/a.sh check-fast
reads_case 'rebase delta of a file that a test names in part' Tests/G.swift $'let a = "xscripts/a.sh"\nlet b = "scripts/a.sh.txt"' scripts/a.sh check-fast
reads_case 'rebase delta of a script that a test reads' Tests/G.swift 'let p = "scripts/a.sh"' scripts/a.sh 'check-fast test'
# make test skips AppBundleTests and DiskImageTests: a read in them adds the target that runs them.
reads_case 'rebase delta of a script that AppBundleTests reads' Tests/DirigibleTests/AppBundleTests.swift 'let p = "scripts/a.sh"' scripts/a.sh 'check-fast test-app'
reads_case 'rebase delta of a script that DiskImageTests reads' Tests/DirigibleTests/DiskImageTests.swift 'let p = "scripts/a.sh"' scripts/a.sh 'check-fast test-dmg'
# A land that stops after its rebase (here: a slice with no Check line) keeps the rebased branch.
# The second land of the branch finds the stamp commit in the land stamp file of the common git dir.
setup
main_commit docs/a.md
git -C "$c/work" fetch -q
stamp origin/main
cp "$c/plan.md" "$c/plan-ok.md"
printf 'Agents: A = S1.\n\n## Slices\n\n### S1 x\n\n' > "$c/plan.md"
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -ne 0 ]] || fail 'second land: the first land exit 0'
grep -q 'the governance check failed' "$c/out" || fail "second land: the first land has no governance stop: $(cat "$c/out")"
no_side_effects 'second land, first land'
cp "$c/plan-ok.md" "$c/plan.md"
stamp_case 'second land after a stop after the rebase' 'stamp: delta check-docs' 'make -k check-docs'
[[ -z "$(ls "$c"/work/.git/dirigible-land-stamp-* 2>/dev/null)" ]] || fail "second land: a land stamp file stays: $(ls "$c"/work/.git)"
# The land stamp file is in the common git dir, like the other state files of the land, so a land
# from any worktree of the clone finds it.
setup
main_commit docs/a.md
git -C "$c/work" fetch -q
stamp origin/main
git -C "$c/work" switch -q main
git -C "$c/work" worktree add -q "$c/wt" feat/x
cp "$c/plan.md" "$c/plan-ok.md"
printf 'Agents: A = S1.\n\n## Slices\n\n### S1 x\n\n' > "$c/plan.md"
land_dir="$c/wt" land_in "Add x" "$c/pr.md"
[[ -f "$c/work/.git/dirigible-land-stamp-feat-x" ]] || fail "land stamp file: not in the common git dir: $(ls "$c"/work/.git "$c"/work/.git/worktrees/wt)"
cp "$c/plan-ok.md" "$c/plan.md"
land_dir="$c/wt" stamp_case 'second land from a linked worktree' 'stamp: delta check-docs' 'make -k check-docs'
unset land_dir

# A matching stamp does not skip the governance check or the ancestor check.
stamp_setup
mkdir -p "$c/other/docs/workflow"
printf 'path\twords\tdecision\na.md\t100\tbaseline\n' > "$c/other/docs/workflow/budgets.tsv"
git -C "$c/other" add -A && git -C "$c/other" commit -q -m budgets && git -C "$c/other" push -q origin main
git -C "$c/work" fetch -q && git -C "$c/work" rebase -q origin/main
printf 'path\twords\tdecision\na.md\t120\traised\n' > "$c/work/docs/workflow/budgets.tsv"
git -C "$c/work" commit -q -am raise
stamp origin/main
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -ne 0 ]] || fail 'stamp and governance: exit 0'
grep -q 'the governance check failed' "$c/out" || fail "stamp and governance: no reason: $(cat "$c/out")"
no_side_effects 'stamp and governance'
stamp_setup
stamp origin/main
FAKE_GH=move land_in "Add x" "$c/pr.md"
code=$?
[[ $code -ne 0 ]] || fail 'stamp and main moved: exit 0'
grep -q 'origin/main moved' "$c/out" || fail "stamp and main moved: no reason: $(cat "$c/out")"
! grep -q '^gh pr merge' "$c/log" || fail "stamp and main moved: the merge ran: $(cat "$c/log")"

# The ratchet: the real make check-changed passes and writes the stamp, then the land runs no
# check on the same clean tree. A stub script gives the target stub-ok of the copied Makefile.
stamp_setup
mkdir -p "$c/work/scripts"
cp "$here/../Makefile" "$c/work/Makefile"
printf '\nstub-ok:\n\t@echo stub-ok ran\n' >> "$c/work/Makefile"
printf '#!/bin/bash\nprintf "classes: docs\\ntargets: stub-ok\\nrisk: no\\n"\n' > "$c/work/scripts/check-changed.sh"
cp "$here/check-stamp.sh" "$here/run-checks.sh" "$here/check-commits.sh" "$c/work/scripts/"
chmod +x "$c/work/scripts/check-changed.sh"
git -C "$c/work" add -A && git -C "$c/work" commit -q -m ratchet
(cd "$c/work" && make -s check-changed BASE=origin/main) > "$c/make.out" 2>&1 || fail "ratchet: make check-changed failed: $(cat "$c/make.out")"
grep -qx 'stub-ok ran' "$c/make.out" || fail "ratchet: the check ran no target: $(cat "$c/make.out")"
stamp_case 'ratchet' "stamp: reuse $(git -C "$c/work" rev-parse HEAD)" ''

# A second land of a branch whose PR exists (the first land stopped at the merge). resume_start:
# the first land makes the PR and its merge fails, so the PR stays open; the logs and the merge
# count restart for the second land.
resume_start() {
  FAKE_MERGE=fail:3 land_in "Add x" "$c/pr.md"
  code=$?
  [[ $code -ne 0 ]] || fail "resume: the first land exit 0"
  grep -q '^gh pr create ' "$c/log" || fail "resume: the first land made no PR: $(cat "$c/log")"
  : > "$c/log"
  rm -f "$c/log.view" "$c/log.merges"
}
# resume_refused <name> <reason>: the second land stopped, with the reason, before it made or
# merged a PR.
resume_refused() {
  [[ $code -ne 0 ]] || fail "$1: exit 0"
  grep -q "$2" "$c/out" || fail "$1: no '$2' in: $(cat "$c/out")"
  ! grep -qE '^gh pr (create|merge)' "$c/log" || fail "$1: gh made or merged a PR: $(cat "$c/log")"
}

# The PR is open: no second gh pr create, the PR text is the checked file, one merge call.
setup
old="$(git -C "$c/other" rev-parse HEAD)"
resume_start
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 0 ]] || fail "open PR resumes: exit $code: $(cat "$c/out")"
[[ "$(grep -E '^gh pr (create|edit|merge)' "$c/log")" == "gh pr edit feat/x --title Add x --body-file $c/pr.md
gh pr merge feat/x --rebase --delete-branch" ]] || fail "open PR resumes: calls differ: $(cat "$c/log")"
new="$(git -C "$c/origin.git" rev-parse main)"
grep -qx 'pr: https://github.com/o/r/pull/7' "$c/out" || fail "open PR resumes: no PR URL: $(cat "$c/out")"
grep -qx "range: $old..$new" "$c/out" || fail "open PR resumes: no commit range $old..$new: $(cat "$c/out")"
[[ "$(git -C "$c/work" branch --show-current)" == main && "$(git -C "$c/work" rev-parse HEAD)" == "$new" ]] ||
  fail 'open PR resumes: local main is not origin/main'

# The stamp commit of the first land stays in the land stamp file, so the second land reuses it.
setup
git -C "$c/work" fetch -q
stamp origin/main
kept="$(git -C "$c/work" rev-parse HEAD)"
resume_start
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 0 ]] || fail "resume reuses the stamp: exit $code: $(cat "$c/out")"
grep -qx "stamp: reuse $kept" "$c/out" || fail "resume reuses the stamp: no stamp line: $(cat "$c/out")"
[[ -z "$(makes)" ]] || fail "resume reuses the stamp: make ran: $(makes)"

# The second land runs the checks again: a red check, a moved origin/main, and a red governance
# check each stop it before the merge.
setup
resume_start
FAKE_MAKE=red land_in "Add x" "$c/pr.md"
code=$?
resume_refused 'resume runs the checks' 'the checks failed'
setup
resume_start
FAKE_MAKE=move land_in "Add x" "$c/pr.md"
code=$?
resume_refused 'resume checks origin/main ancestry' 'origin/main moved'
grep -q '^make ' "$c/log" || fail "resume checks origin/main ancestry: no check ran: $(cat "$c/log")"
setup
resume_start
printf 'Agents: A = S1.\n\n## Slices\n\n### S1 x\n\n' > "$c/plan.md"
land_in "Add x" "$c/pr.md"
code=$?
resume_refused 'resume runs governance' 'the governance check failed'

# origin/main moved past the pushed head since the first land: the second land stops before the
# rebase, the checks, and the push.
setup
resume_start
main_commit docs/b.md
head="$(git -C "$c/work" rev-parse HEAD)"
pushed="$(git -C "$c/origin.git" rev-parse feat/x)"
land_in "Add x" "$c/pr.md"
code=$?
resume_refused 'resume after main moved' 'origin/main moved'
[[ -z "$(makes)" ]] || fail "resume after main moved: make ran: $(makes)"
[[ "$(git -C "$c/work" rev-parse HEAD)" == "$head" && "$(git -C "$c/origin.git" rev-parse feat/x)" == "$pushed" ]] ||
  fail 'resume after main moved: the branch changed'

# A closed PR of this push stops the land.
setup
resume_start
awk -F'\t' -v OFS='\t' '{ $1 = "CLOSED" } 1' "$c/log.pr" > "$c/log.pr.new" && mv "$c/log.pr.new" "$c/log.pr"
land_in "Add x" "$c/pr.md"
code=$?
resume_refused 'closed PR' 'is closed, not merged'
[[ -z "$(makes)" ]] || fail "closed PR: make ran: $(makes)"

# The PRs of an earlier run with the same branch name (merged with a head that is not an ancestor,
# closed with a head the clone lacks) are not this land: the land makes a new PR and merges it.
setup
git -C "$c/work" switch -q -c side
git -C "$c/work" commit -q --allow-empty -m side
side="$(git -C "$c/work" rev-parse HEAD)"
git -C "$c/work" switch -q feat/x
printf 'CLOSED\thttps://github.com/o/r/pull/6\t%s\t-\t1\nMERGED\thttps://github.com/o/r/pull/5\t%s\t%s\t1\n' \
  1111111111111111111111111111111111111111 "$side" "$side" > "$c/log.pr"
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 0 ]] || fail "reused branch name: exit $code: $(cat "$c/out")"
[[ "$(grep -cE '^gh pr (create|merge)' "$c/log")" == 2 ]] || fail "reused branch name: calls differ: $(cat "$c/log")"
grep -qx 'pr: https://github.com/o/r/pull/9' "$c/out" || fail "reused branch name: no new PR URL: $(cat "$c/out")"

# A lookup error is no "no PR": the land stops before it makes a PR.
setup
FAKE_LOOKUP=502 land_in "Add x" "$c/pr.md"
code=$?
[[ $code -ne 0 ]] || fail 'view error: exit 0'
grep -q 'HTTP 502' "$c/out" || fail "view error: no gh text: $(cat "$c/out")"
no_side_effects 'view error'

# The flake rows: before the push, each dirigible-flakes line of a commit of the branch (an
# ancestor of HEAD before or after the rebase) gives one flake row in the decisions.tsv of the run
# and leaves the file. A line of another commit stays.
setup
printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n' > "$c/decisions.tsv"
git -C "$c/work" switch -q -c side
git -C "$c/work" commit -q --allow-empty -m side
side="$(git -C "$c/work" rev-parse HEAD)"
git -C "$c/work" switch -q feat/x
printf '%s aFlake load 7.50\n%s other load 1.00\n' "$(git -C "$c/work" rev-parse HEAD)" "$side" > "$c/work/.git/dirigible-flakes"
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 0 ]] || fail "flake rows: exit $code: $(cat "$c/out")"
rows="$(tail -n +2 "$c/decisions.tsv")"
[[ "$(grep -c . <<<"$rows")" == 1 ]] || fail "flake rows: rows [$rows]"
# run-checks.sh reads the load after make -k ends, so the row names that time, not the failure.
[[ "$(cut -f2 <<<"$rows")" == 7 && "$(cut -f3 <<<"$rows")" == *aFlake*'load 7.50 at the end of the check'* && "$(cut -f6 <<<"$rows")" == flake* ]] ||
  fail "flake rows: row [$rows]"
[[ "$(cat "$c/work/.git/dirigible-flakes")" == "$side other load 1.00" ]] || fail "flake rows: flakes [$(cat "$c/work/.git/dirigible-flakes")]"

# stub_land <fake log-decision.sh body>: runs a copy of land.sh beside the real scripts, with a
# fake log-decision.sh, on a branch whose flakes file has the lines of $c/flakes; sets code.
# flakes_now prints the sorted lines of the flakes file; copies prints the count of renamed copies.
stub_land() {
  setup
  mkdir -p "$c/stub" "$c/.claude/skills/deliver/scripts"
  cp "$here"/*.sh "$c/stub/"
  cp "$here/../Makefile" "$c/Makefile"
  printf '#!/bin/bash\n%s\n' "$1" > "$c/.claude/skills/deliver/scripts/log-decision.sh"
  chmod +x "$c/.claude/skills/deliver/scripts/log-decision.sh"
  printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n' > "$c/decisions.tsv"
  printf '%s aFlake load 7.50\n%s bFlake load 7.50\n' "$(git -C "$c/work" rev-parse HEAD)" "$(git -C "$c/work" rev-parse HEAD)" > "$c/flakes"
  cp "$c/flakes" "$c/work/.git/dirigible-flakes"
  (cd "$c/work" && PATH="$bin:$PATH" LAND_LOG="$c/log" FAKE_OTHER="$c/other" "$c/stub/land.sh" "Add x" "$c/pr.md") > "$c/out" 2>&1
  code=$?
}
flakes_now() { sort "$c/work/.git/dirigible-flakes" 2>/dev/null; }
copies() { ls "$c/work/.git" | grep -c '^dirigible-flakes\.'; }
row='printf "x\t7\t%s\n" "$(sed -n 2p "$3")" >> "$1/decisions.tsv"'

# A line that another worktree appends while land.sh writes the rows stays in the file. The fake
# log-decision.sh appends such a line once.
stub_land "$row"'
[[ -e "$1/appended" ]] && exit 0
touch "$1/appended"
echo "$(git rev-parse HEAD) late load 3.00" >> "$(git rev-parse --path-format=absolute --git-common-dir)/dirigible-flakes"'
[[ $code -eq 0 ]] || fail "a line appended during the rows: exit $code: $(cat "$c/out")"
[[ "$(cut -f3 "$c/decisions.tsv" | grep -c Flake)" == 2 ]] || fail "a line appended during the rows: rows [$(cat "$c/decisions.tsv")]"
[[ "$(flakes_now)" == *' late load 3.00' ]] || fail "a line appended during the rows: lost: [$(flakes_now)]"
[[ "$(flakes_now | grep -c Flake)" == 0 ]] || fail "a line appended during the rows: a written line stays: [$(flakes_now)]"

# A failed row stops the land before the push, and the flakes file holds each original line.
stub_land 'exit 1'
[[ $code -eq 1 ]] || fail "a failed row: exit $code: $(cat "$c/out")"
grep -q 'no flake row' "$c/out" || fail "a failed row: no reason: $(cat "$c/out")"
[[ "$(flakes_now)" == "$(sort "$c/flakes")" && "$(copies)" == 0 ]] || fail "a failed row: flakes [$(flakes_now)], $(copies) copies"
no_side_effects_push() { ! git -C "$c/origin.git" show-ref -q --verify refs/heads/feat/x || fail "$1: the branch is on origin"; }
no_side_effects_push 'a failed row'

# A TERM during the row loop: the trap of land.sh puts each original line back, and nothing is
# pushed.
stub_land "$row"'
kill -TERM $PPID
sleep 1'
[[ $code -ne 0 ]] || fail "a TERM in the rows: exit 0"
[[ "$(flakes_now)" == "$(sort "$c/flakes")" && "$(copies)" == 0 ]] || fail "a TERM in the rows: flakes [$(flakes_now)], $(copies) copies"
no_side_effects_push 'a TERM in the rows'

# A body with a run-internal ID refuses before any step, also before the fetch, and names the
# writing-for-humans skill. The remote main moved after the clone, so a fetch would show.
setup
printf 'Fixed U3.\n' > "$c/pr.md"
before="$(git -C "$c/work" rev-parse origin/main)"
[[ "$(git -C "$c/origin.git" rev-parse main)" != "$before" ]] || fail 'flagged body: the remote main did not move'
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 1 ]] || fail "flagged body: exit $code: $(cat "$c/out")"
grep -q 'U3: run-internal ID' "$c/out" || fail "flagged body: U3 is not named: $(cat "$c/out")"
grep -q 'writing-for-humans' "$c/out" || fail "flagged body: the skill is not named: $(cat "$c/out")"
[[ "$(git -C "$c/work" rev-parse origin/main)" == "$before" ]] || fail 'flagged body: the fetch ran'
no_side_effects 'flagged body'

# A revision that lost a number of logs/pr-draft.md (the copy before the writing-for-humans
# skill) refuses before the fetch.
setup
mkdir "$c/logs"
printf 'The row is 31335.\n' > "$c/logs/pr-draft.md"
printf 'The row is the real sum.\n' > "$c/pr.md"
before="$(git -C "$c/work" rev-parse origin/main)"
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 1 ]] || fail "lost number: exit $code: $(cat "$c/out")"
grep -q 'lost number: 31335' "$c/out" || fail "lost number: 31335 is not named: $(cat "$c/out")"
grep -q 'restore' "$c/out" || fail "lost number: no reason: $(cat "$c/out")"
[[ "$(git -C "$c/work" rev-parse origin/main)" == "$before" ]] || fail 'lost number: the fetch ran'
no_side_effects 'lost number'

# A pr-terms.sh error (exit 2) is a script failure, not a body to revise: a copy of land.sh
# beside a stub pr-terms.sh.
setup
mkdir "$c/stub"
cp "$land" "$c/stub/land.sh"
printf '#!/bin/bash\necho "pr-terms: broken" >&2\nexit 2\n' > "$c/stub/pr-terms.sh"
chmod +x "$c/stub/pr-terms.sh"
(cd "$c/work" && PATH="$bin:$PATH" LAND_LOG="$c/log" "$c/stub/land.sh" "Add x" "$c/pr.md") > "$c/out" 2>&1
code=$?
[[ $code -eq 1 ]] || fail "pr-terms error: exit $code: $(cat "$c/out")"
grep -q 'pr-terms.sh failed (exit 2)' "$c/out" || fail "pr-terms error: no reason: $(cat "$c/out")"
! grep -q 'writing-for-humans' "$c/out" || fail "pr-terms error: the skill is named: $(cat "$c/out")"
no_side_effects 'pr-terms error'

# A missing body file refuses before any step.
setup
land_in "Add x" "$c/missing.md"
code=$?
[[ $code -ne 0 ]] || fail 'missing body: exit 0'
grep -q 'no body file' "$c/out" || fail "missing body: no reason: $(cat "$c/out")"
no_side_effects 'missing body'

# No arguments prints the usage and exits 2.
setup
land_in
code=$?
[[ $code -eq 2 ]] || fail "no arguments: expected exit 2, got $code"
grep -q '^usage: scripts/land.sh <title> <body-file>' "$c/out" || fail "no arguments: no usage: $(cat "$c/out")"
no_side_effects 'no arguments'

# A partial stamp is no pass: with a partial line for HEAD and no pass line, the land runs the
# push check, and the real check-changed.sh origin/main gives the RERUN word, not targets: none.
stamp_setup
mkdir -p "$c/work/Tests/DirigibleCoreTests"
printf 'func aFast() {}\n' > "$c/work/Tests/DirigibleCoreTests/A.swift"
git -C "$c/work" add -A && git -C "$c/work" commit -q -m tests
head="$(git -C "$c/work" rev-parse HEAD)"
echo "$head $(git -C "$c/work" rev-parse origin/main) failed fast:aFast slow:" >> "$c/work/.git/dirigible-check-partial"
FAKE_MAKE=changed FAKE_CHANGED="$here/check-changed.sh" land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 0 ]] || fail "a partial stamp: exit $code: $(cat "$c/out")"
! grep -q '^stamp: reuse' "$c/out" || fail "a partial stamp: the land reused it: $(cat "$c/out")"
grep -qx "targets: RERUN=$head:fast:aFast+slow:" "$c/log" || fail "a partial stamp: no RERUN word: $(cat "$c/log")"

# The tool-author guard (check-commits.sh --authors, run by land.sh and .githooks/pre-push).
# ident_commit <author name> <author email> <committer name> <committer email> <message> adds an
# empty commit to the work branch. guard <args> runs check-commits.sh in the work clone.
ident_commit() {
  GIT_AUTHOR_NAME="$1" GIT_AUTHOR_EMAIL="$2" GIT_COMMITTER_NAME="$3" GIT_COMMITTER_EMAIL="$4" \
    git -C "$c/work" commit -q --allow-empty -m "$5"
}
guard() { (cd "$c/work" && "$here/check-commits.sh" "$@") > "$c/out" 2>&1; code=$?; }
# authors_case <name> <pass|fail> <author name> <author email> <committer name> <committer email> <message>
authors_case() {
  setup
  ident_commit "$3" "$4" "$5" "$6" "$7"
  guard origin/main
  if [[ $2 == pass ]]; then
    [[ $code -eq 0 ]] || fail "authors $1: exit $code: $(cat "$c/out")"
  else
    [[ $code -eq 1 ]] || fail "authors $1: exit $code: $(cat "$c/out")"
    grep -q 'names a tool' "$c/out" || fail "authors $1: no reason: $(cat "$c/out")"
  fi
}
for tool in Claude Copilot Codex "T3 Code" opencode Cursor Gemini; do
  authors_case "author $tool" fail "$tool" t@t t t@t m
done
authors_case 'author address t3code' fail x t3code@users.noreply.github.com t t@t m
authors_case 'author bot' fail 'dependabot[bot]' 49699333+dependabot[bot]@users.noreply.github.com t t@t m
authors_case 'author anthropic address' fail x noreply@anthropic.com t t@t m
authors_case 'author openai address' fail x noreply@openai.com t t@t m
authors_case 'committer bot' fail t t@t 'github-actions[bot]' 41898282+github-actions[bot]@users.noreply.github.com m
authors_case 'committer Copilot' fail t t@t Copilot t@t m
authors_case 'trailer Claude' fail t t@t t t@t $'m\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>'
authors_case 'trailer in lower case' fail t t@t t t@t $'m\n\nCo-authored-by: Copilot <copilot@github.com>'
authors_case 'owner' pass 'Borja Quevedo' borjota@gmail.com 'Borja Quevedo' borjota@gmail.com $'m\n\nCo-Authored-By: Jane Doe <jane@example.org>'
# The whole range counts, not only the tip.
setup
ident_commit Claude t@t t t@t first
ident_commit t t@t t t@t second
guard origin/main
[[ $code -eq 1 ]] || fail "authors in the middle of the range: exit $code: $(cat "$c/out")"
# A tool commit that origin/main already holds is outside the range.
setup
GIT_AUTHOR_NAME=Claude git -C "$c/other" commit -q --allow-empty -m old
git -C "$c/other" push -q origin main
git -C "$c/work" fetch -q
guard origin/main
[[ $code -eq 0 ]] || fail "a tool commit below the base: exit $code: $(cat "$c/out")"
guard nosuchbase
[[ $code -eq 1 ]] && grep -q 'nosuchbase is not a commit' "$c/out" || fail "a base that is no commit: exit $code: $(cat "$c/out")"
# land.sh stops before the check and the push.
setup
ident_commit 'T3 Code' t3code@users.noreply.github.com t t@t m
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 1 ]] || fail "land with a tool commit: exit $code: $(cat "$c/out")"
grep -q 'names a tool' "$c/out" || fail "land with a tool commit: no reason: $(cat "$c/out")"
grep -q 'nothing is pushed' "$c/out" || fail "land with a tool commit: no stop text: $(cat "$c/out")"
no_side_effects 'land with a tool commit'

# The pre-push hook checks the range of each pushed ref. hook <remote sha> <local sha> feeds the
# line that git gives it; <local sha> zero is a delete.
zero=0000000000000000000000000000000000000000
hook() {
  (cd "$c/work" && "$here/../.githooks/pre-push" origin "$c/origin.git" <<<"refs/heads/feat/x $2 refs/heads/feat/x $1") > "$c/out" 2>&1
  code=$?
}
hook_case() { # <name> <expected exit> <remote sha> <local sha>
  hook "$3" "$4"
  [[ $code -eq $2 ]] || fail "pre-push $1: exit $code, expected $2: $(cat "$c/out")"
}
setup
clean="$(git -C "$c/work" rev-parse HEAD)"
hook_case 'new branch, clean' 0 "$zero" "$clean"
ident_commit Claude t@t t t@t tool
tool="$(git -C "$c/work" rev-parse HEAD)"
ident_commit t t@t t t@t after
tip="$(git -C "$c/work" rev-parse HEAD)"
hook_case 'new branch, tool commit' 1 "$zero" "$tip"
grep -q 'names a tool' "$c/out" || fail "pre-push new branch: no reason: $(cat "$c/out")"
hook_case 'update, tool commit' 1 "$clean" "$tip"
hook_case 'update, tool commit already on the remote' 0 "$tool" "$tip"
hook_case 'remote sha unknown here, tool commit' 1 1111111111111111111111111111111111111111 "$tip"
hook_case 'delete' 0 "$clean" "$zero"

# The secret scan (check-commits.sh, gitleaks on <base>..HEAD). The fake token is joined here, so
# this file holds no token for the scan of the commits that add it. leak_commit adds a commit
# with the token in a file; a clean range passes in the cases above.
tok="g""hp_R8sT2vXy9LmQ4wPz7KdN1bC5fG3hJ6aEuYoI"
leak_commit() {
  printf 'token = "%s"\n' "$tok" > "$c/work/${1:-secret.txt}"
  git -C "$c/work" add -A && git -C "$c/work" commit -q -m leak
}
setup
leak_commit
guard origin/main
[[ $code -eq 1 ]] || fail "secret: exit $code: $(cat "$c/out")"
grep -q 'github-pat' "$c/out" && grep -q 'secret.txt' "$c/out" && grep -q 'found a secret' "$c/out" || fail "secret: no finding named: $(cat "$c/out")"
grep -q "\"Fingerprint\": \"$(git -C "$c/work" rev-parse HEAD):secret.txt:github-pat:1\"" "$c/out" && grep -q '"StartLine": 1' "$c/out" ||
  fail "secret: no line or fingerprint: $(cat "$c/out")"
grep -q '.gitleaksignore' "$c/out" || fail "secret: no allow route: $(cat "$c/out")"
! grep -q "$tok" "$c/out" || fail "secret: the output holds the token"
# The scan reads the commits, not the tree: a token removed in a later commit is still found.
git -C "$c/work" rm -q secret.txt && git -C "$c/work" commit -q -m remove
guard origin/main
[[ $code -eq 1 ]] || fail "a removed secret: exit $code: $(cat "$c/out")"
# --secrets alone, and a token that origin/main holds is outside the range.
guard --secrets origin/main
[[ $code -eq 1 ]] || fail "--secrets: exit $code: $(cat "$c/out")"
setup
printf 'token = "%s"\n' "$tok" > "$c/other/old.txt"
git -C "$c/other" add -A && git -C "$c/other" commit -q -m old
git -C "$c/other" push -q origin main
git -C "$c/work" fetch -q
guard origin/main
[[ $code -eq 0 ]] || fail "a secret below the base: exit $code: $(cat "$c/out")"
guard --secrets nosuchbase
[[ $code -eq 1 ]] && grep -q 'nosuchbase is not a commit' "$c/out" || fail "--secrets with a base that is no commit: exit $code: $(cat "$c/out")"
# With no gitleaks, the scan fails and names the tool and the install command; --authors needs none.
# nogl prints a PATH whose folders that hold gitleaks have links to their other files only.
nogl() {
  local d f dirs out=""
  mkdir -p "$c/nobin"
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    if [[ -x "$d/gitleaks" ]]; then
      for f in "$d"/*; do [[ ${f##*/} == gitleaks ]] || ln -sf "$f" "$c/nobin/" 2>/dev/null; done
      d="$c/nobin"
    fi
    out+="$d:"
  done
  echo "${out%:}"
}
setup
nopath="$(nogl)"
(cd "$c/work" && PATH="$nopath" "$here/check-commits.sh" origin/main) > "$c/out" 2>&1
code=$?
[[ $code -eq 1 ]] || fail "no gitleaks: exit $code: $(cat "$c/out")"
grep -q 'gitleaks is not installed' "$c/out" && grep -q 'brew install gitleaks' "$c/out" || fail "no gitleaks: no install hint: $(cat "$c/out")"
(cd "$c/work" && PATH="$nopath" "$here/check-commits.sh" --authors origin/main..HEAD) > "$c/out" 2>&1
code=$?
[[ $code -eq 0 ]] || fail "no gitleaks, --authors: exit $code: $(cat "$c/out")"
# A gitleaks that fails with a tool error is no clean scan.
mkdir -p "$c/badbin"
printf '#!/bin/bash\necho "fatal" >&2\nexit 1\n' > "$c/badbin/gitleaks"
chmod +x "$c/badbin/gitleaks"
(cd "$c/work" && PATH="$c/badbin:$PATH" "$here/check-commits.sh" origin/main) > "$c/out" 2>&1
code=$?
[[ $code -eq 1 ]] && grep -q 'gitleaks failed (exit 1)' "$c/out" || fail "a gitleaks error: exit $code: $(cat "$c/out")"
# land.sh stops before the check and the push.
setup
leak_commit
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 1 ]] || fail "land with a secret: exit $code: $(cat "$c/out")"
grep -q 'found a secret' "$c/out" && grep -q 'nothing is pushed' "$c/out" || fail "land with a secret: no reason: $(cat "$c/out")"
no_side_effects 'land with a secret'

[[ $failures -eq 0 ]] && echo "land tests: all passed"
exit $((failures > 0))
