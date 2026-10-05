#!/bin/bash
# Check that land.sh runs the land steps of deliver Phase 9 in order and stops at the first
# failure. Each case uses a temporary repo, a bare remote, and fake make and gh on PATH that log
# their arguments. Cases: the happy path, a red check, a rebase conflict (the rebase is aborted),
# main moved after the check, a run on main or a detached HEAD, an untracked or a changed file, a
# red governance check, `risk: yes` with and with no control row, a body that pr-terms.sh flags
# (before the fetch), a body that lost a number of logs/pr-draft.md, a pr-terms.sh error, a
# missing body file, and no arguments. The stamp cases: a matching stamp runs no check, a delta
# after the stamp runs the targets of the delta after the load wait, and no usable stamp runs the
# full push check; the governance and the ancestor checks still run. The ratchet case runs the
# real make check-changed first, so the land runs no check after it. Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
land="$here/land.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# A git or make value of an outer run (make test-hooks) must not reach the ratchet case.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE MAKEFLAGS MFLAGS MAKELEVEL BASE FILTER
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

bin="$tmp/bin"
mkdir "$bin"
# The fake make logs its arguments and whether origin/main is in HEAD (the rebase came first).
# FAKE_MAKE=red fails the check; FAKE_MAKE=move moves origin/main while the check runs.
cat > "$bin/make" <<'EOF'
#!/bin/bash
echo "make $*" >> "$LAND_LOG"
git merge-base --is-ancestor origin/main HEAD && echo "make: rebased" >> "$LAND_LOG"
case "${FAKE_MAKE:-ok}" in
  red) exit 1 ;;
  move) git -C "$FAKE_OTHER" commit -q --allow-empty -m moved && git -C "$FAKE_OTHER" push -q origin main ;;
esac
exit 0
EOF
# The fake gh logs its arguments. `pr create` also logs whether the branch is on origin (the push
# came first) and prints a URL. `pr merge` puts HEAD on origin/main, as a rebase merge does.
# FAKE_GH=move moves origin/main in `pr create`, for a land that runs no make.
cat > "$bin/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$LAND_LOG"
case "$1 $2" in
  "pr create")
    git ls-remote --exit-code --heads origin "$(git branch --show-current)" > /dev/null && echo "gh: branch on origin" >> "$LAND_LOG"
    [[ "${FAKE_GH:-}" == move ]] && git -C "$FAKE_OTHER" commit -q --allow-empty -m moved && git -C "$FAKE_OTHER" push -q origin main
    echo "https://github.com/o/r/pull/7" ;;
  "pr merge") git push -q origin HEAD:main ;;
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
  (cd "$c/work" && PATH="$bin:$PATH" LAND_LOG="$c/log" FAKE_OTHER="$c/other" "$land" "$@") > "$c/out" 2>&1
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

# risk: yes (a file under Sources/DirigibleAudio/) needs a control row in the decisions.tsv of
# the run folder (the folder of the body file), or a third argument that names the row that says
# why no control applies. Else the land stops before the checks and the push.
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
risk_refused 'risk with no control row' 'has no control row'
risk_setup
land_in "Add x" "$c/pr.md" 2026-10-01T09:99
code=$?
risk_refused 'risk with a missing why row' 'no row 2026-10-01T09:99'
risk_setup
printf '2026-10-01T02:00\t4\tk1 killed\tw\tcontrols/k1.log\tkilled\n' >> "$c/decisions.tsv"
land_in "Add x" "$c/pr.md"
code=$?
[[ $code -eq 0 ]] || fail "risk with a control row: exit $code: $(cat "$c/out")"
grep -q '^gh pr merge' "$c/log" || fail "risk with a control row: no merge: $(cat "$c/log")"
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

# A matching stamp: no check runs. A later line with another base (the reflect check) does not
# hide it.
stamp_setup
head="$(git -C "$c/work" rev-parse HEAD)"
stamp origin/main
stamp origin/main~1
stamp_case 'matching stamp' "stamp: reuse $head" ''

# A docs commit after the stamp: only check-docs. A Sources commit: check.
stamp_setup
stamp origin/main
commit_file docs/a.md
stamp_case 'docs delta' 'stamp: delta check-docs' 'make check-docs'
! grep -q '^sysctl' "$c/log" || fail "docs delta: the load wait read the load: $(cat "$c/log")"
stamp_setup
stamp origin/main
commit_file Sources/DirigibleApp/X.swift
stamp_case 'sources delta' 'stamp: delta check' 'make check'
# The delta runs Swift tests, so the load wait reads the load before make.
[[ "$(grep -E '^(sysctl -n vm.loadavg|make check)$' "$c/log")" == $'sysctl -n vm.loadavg\nmake check' ]] ||
  fail "sources delta: no load wait before make check: $(cat "$c/log")"
grep -q 'check-changed: load 1.00, under 8' "$c/out" || fail "sources delta: no load line: $(cat "$c/out")"

# A move of a bundle file after the stamp: --no-renames keeps the old path, so the delta is bundle.
stamp_setup
commit_file Support/x.plist
stamp origin/main
mkdir -p "$c/work/docs"
git -C "$c/work" mv Support/x.plist docs/x.plist
git -C "$c/work" commit -q -m move
stamp_case 'renamed bundle path' 'stamp: delta check test-dmg' 'make check test-dmg'

# No usable stamp: the full push check, with the reason.
stamp_setup
stamp origin/main~1
stamp_case 'base moved' 'stamp: none (base moved)' 'make check-changed BASE=origin/main'
setup
git -C "$c/work" fetch -q
stamp origin/main
stamp_case 'not an ancestor' 'stamp: none (not an ancestor)' 'make check-changed BASE=origin/main'

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
cp "$here/check-stamp.sh" "$c/work/scripts/check-stamp.sh"
chmod +x "$c/work/scripts/check-changed.sh"
git -C "$c/work" add -A && git -C "$c/work" commit -q -m ratchet
(cd "$c/work" && make -s check-changed BASE=origin/main) > "$c/make.out" 2>&1 || fail "ratchet: make check-changed failed: $(cat "$c/make.out")"
grep -qx 'stub-ok ran' "$c/make.out" || fail "ratchet: the check ran no target: $(cat "$c/make.out")"
stamp_case 'ratchet' "stamp: reuse $(git -C "$c/work" rev-parse HEAD)" ''

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

[[ $failures -eq 0 ]] && echo "land tests: all passed"
exit $((failures > 0))
