#!/bin/bash
# Check that land.sh runs the land steps of deliver Phase 9 in order and stops at the first
# failure. Each case uses a temporary repo, a bare remote, and fake make and gh on PATH that log
# their arguments. Cases: the happy path, a red check, main moved after the check, a run on main
# or a detached HEAD, an untracked or a changed file, a red governance check, `risk: yes` with
# and with no control row, a missing body file, and no arguments. Run by `make test-hooks`.
set -uo pipefail
land="$(cd "$(dirname "$0")" && pwd)/land.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

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
cat > "$bin/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$LAND_LOG"
case "$1 $2" in
  "pr create")
    git ls-remote --exit-code --heads origin "$(git branch --show-current)" > /dev/null && echo "gh: branch on origin" >> "$LAND_LOG"
    echo "https://github.com/o/r/pull/7" ;;
  "pr merge") git push -q origin HEAD:main ;;
esac
EOF
chmod +x "$bin/make" "$bin/gh"

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
  echo x > "$c/work/x.txt"
  git -C "$c/work" add x.txt
  git -C "$c/work" commit -q -m feature
  git -C "$c/other" commit -q --allow-empty -m "main moves"
  git -C "$c/other" push -q origin main
  printf 'body\n' > "$c/pr.md"
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

# A red check stops before the push.
setup
FAKE_MAKE=red land_in "Add x" "$c/pr.md"
code=$?
[[ $code -ne 0 ]] || fail 'red check: exit 0'
grep -q 'the checks failed' "$c/out" || fail "red check: no reason: $(cat "$c/out")"
! grep -q '^gh ' "$c/log" || fail "red check: gh ran: $(cat "$c/log")"
! git -C "$c/origin.git" show-ref -q --verify refs/heads/feat/x || fail 'red check: the branch is on origin'

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
