#!/bin/bash
# Check that check-stamp.sh appends a stamp line only for a passing check with a base on a clean
# tree whose HEAD did not move, and not when make runs with -n, -t, -i, or -q. Check that the
# reader gives the newest line with the base commit (or an older commit of it) and an ancestor
# commit, or the reason that no line is usable. Run by `make test-hooks`.
set -uo pipefail
stamp_sh="$(cd "$(dirname "$0")" && pwd)/check-stamp.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# A git or make value of an outer run (make test-hooks) must not reach the cases.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE MAKEFLAGS MFLAGS MAKELEVEL BASE FILTER
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

g() { git -C "$tmp/r" "$@"; }
# A repo with a commit on main and one commit on the branch feat/x.
new_repo() {
  rm -rf "$tmp/r"
  mkdir -p "$tmp/r"
  g init -q -b main
  echo a > "$tmp/r/a.txt"
  g add -A && g commit -q -m base
  g switch -q -c feat/x
  echo b > "$tmp/r/b.txt"
  g add -A && g commit -q -m b
  file="$(g rev-parse --path-format=absolute --git-common-dir)/dirigible-check-stamp"
}
st() { (cd "$tmp/r" && "$stamp_sh" "$@"); }
# st_in <dir> <args>: run check-stamp.sh in another worktree.
st_in() { local d="$1"; shift; (cd "$d" && "$stamp_sh" "$@"); }
lines() { if [[ -f "$file" ]]; then wc -l < "$file" | tr -d ' '; else echo 0; fi; }

# Write on a clean tree: one line with the commit, the base commit, and the targets.
new_repo
head="$(g rev-parse HEAD)" main="$(g rev-parse main)"
out="$(st write "$head" clean "$main" check test-slow)" || fail "clean write: exit $?"
want="$head $main check test-slow"
[[ "$(cat "$file" 2>/dev/null)" == "$want" ]] || fail "clean write: got [$(cat "$file" 2>/dev/null)], want [$want]"
[[ "$out" == "check-stamp: wrote $head" ]] || fail "clean write: output [$out]"
got="$(st read main)" || fail "clean read: exit $?"
[[ "$got" == "$head check test-slow" ]] || fail "clean read: got [$got]"

# A dirty tree at the start, a changed file or an untracked file at the end: no line.
new_repo
head="$(g rev-parse HEAD)" main="$(g rev-parse main)"
out="$(st write "$head" dirty "$main" check)" || fail "dirty at the start: exit $?"
[[ "$(lines)" == 0 ]] || fail 'dirty at the start: a line was written'
[[ "$out" == *"no stamp (the tree was dirty)"* ]] || fail "dirty at the start: output [$out]"
echo b2 > "$tmp/r/b.txt"
st write "$head" clean "$main" check > /dev/null || fail "changed file: exit $?"
[[ "$(lines)" == 0 ]] || fail 'changed file: a line was written'
g checkout -q -- b.txt
echo u > "$tmp/r/u.txt"
out="$(st write "$head" clean "$main" check)"
[[ "$(lines)" == 0 ]] || fail 'untracked file: a line was written'
[[ "$out" == *"no stamp (the tree is dirty)"* ]] || fail "untracked file: output [$out]"

# HEAD moved during the check: no line.
new_repo
head="$(g rev-parse HEAD)" main="$(g rev-parse main)"
g commit -q --allow-empty -m moved
out="$(st write "$head" clean "$main" check)" || fail "HEAD moved: exit $?"
[[ "$(lines)" == 0 ]] || fail 'HEAD moved: a line was written'
[[ "$out" == *"no stamp (HEAD moved)"* ]] || fail "HEAD moved: output [$out]"

# No base: no line.
new_repo
out="$(st write "$(g rev-parse HEAD)" clean none check)" || fail "no base: exit $?"
[[ "$(lines)" == 0 ]] || fail 'no base: a line was written'
[[ "$out" == *"no stamp (no base)"* ]] || fail "no base: output [$out]"

# Make with -n, -t, -i, or -q runs the recipe line of $(MAKE) but not the checks: no line. The
# first word of MAKEFLAGS has the short flags; a variable word (BASE=origin/main) has an n too.
new_repo
head="$(g rev-parse HEAD)" main="$(g rev-parse main)"
for flags in 'n -- BASE=main' 't -- BASE=main' 'i -- BASE=main' 'q' 'sn -- BASE=main'; do
  out="$(MAKEFLAGS="$flags" st write "$head" clean "$main" check)" || fail "MAKEFLAGS [$flags]: exit $?"
  [[ "$(lines)" == 0 ]] || fail "MAKEFLAGS [$flags]: a line was written"
  [[ "$out" == *"no stamp (make ran with -n, -t, -i, or -q)"* ]] || fail "MAKEFLAGS [$flags]: output [$out]"
done
for flags in 'BASE=main FILTER=x' 's -- BASE=main' ' --no-print-directory -- BASE=main'; do
  rm -f "$file"
  MAKEFLAGS="$flags" st write "$head" clean "$main" check > /dev/null || fail "MAKEFLAGS [$flags]: exit $?"
  [[ "$(lines)" == 1 ]] || fail "MAKEFLAGS [$flags]: no line was written"
done
# The real recipe under make -n: a stub check-changed.sh gives the target stub-ok.
new_repo
mkdir -p "$tmp/r/scripts"
cp "$(dirname "$stamp_sh")/../Makefile" "$tmp/r/Makefile"
printf '\nstub-ok:\n\t@echo stub-ok ran\n' >> "$tmp/r/Makefile"
printf '#!/bin/bash\nprintf "classes: docs\\ntargets: stub-ok\\nrisk: no\\n"\n' > "$tmp/r/scripts/check-changed.sh"
cp "$stamp_sh" "$tmp/r/scripts/check-stamp.sh"
cp "$(dirname "$stamp_sh")/run-checks.sh" "$(dirname "$stamp_sh")/check-commits.sh" "$tmp/r/scripts/"
chmod +x "$tmp/r/scripts/check-changed.sh"
g add -A && g commit -q -m make
(cd "$tmp/r" && make -n check-changed BASE=main) > "$tmp/make.out" 2>&1 || fail "make -n check-changed: exit $?: $(cat "$tmp/make.out")"
[[ "$(lines)" == 0 ]] || fail "make -n check-changed: a line was written: $(cat "$tmp/make.out")"
(cd "$tmp/r" && make -s check-changed BASE=main) > "$tmp/make.out" 2>&1 || fail "make check-changed: exit $?: $(cat "$tmp/make.out")"
[[ "$(lines)" == 1 ]] || fail "make check-changed: no line was written: $(cat "$tmp/make.out")"

# Two lines: a later line with another base (the reflect check) does not hide the usable line,
# and the file keeps both lines (append-only).
new_repo
first="$(g rev-parse HEAD)" main="$(g rev-parse main)"
st write "$first" clean "$main" check test-slow > /dev/null
echo c > "$tmp/r/c.txt"
g add -A && g commit -q -m reflect
second="$(g rev-parse HEAD)"
st write "$second" clean "$first" check-docs > /dev/null
[[ "$(lines)" == 2 ]] || fail "two lines: the file has $(lines) lines"
got="$(st read main)" || fail "two lines: exit $?"
[[ "$got" == "$first check test-slow" ]] || fail "two lines: got [$got]"
# The newest line with the base wins.
st write "$second" clean "$main" check > /dev/null
got="$(st read main)" || fail "newest line: exit $?"
[[ "$got" == "$second check" ]] || fail "newest line: got [$got]"

# A stamp written in a linked worktree survives `git worktree remove`: the main checkout reads it.
new_repo
g worktree add -q -b wt1 "$tmp/wt" feat/x
head="$(g rev-parse HEAD)" main="$(g rev-parse main)"
st_in "$tmp/wt" write "$head" clean "$main" check > /dev/null || fail "worktree write: exit $?"
g worktree remove "$tmp/wt"
got="$(st read main)" || fail "read after worktree remove: exit $?"
[[ "$got" == "$head check" ]] || fail "read after worktree remove: got [$got]"

# A stamp of the main checkout is read in a linked worktree whose HEAD descends from it.
new_repo
head="$(g rev-parse HEAD)" main="$(g rev-parse main)"
st write "$head" clean "$main" check > /dev/null
g worktree add -q -b wt2 "$tmp/wt" feat/x
git -C "$tmp/wt" commit -q --allow-empty -m later
got="$(st_in "$tmp/wt" read main)" || fail "read in a linked worktree: exit $?"
[[ "$got" == "$head check" ]] || fail "read in a linked worktree: got [$got]"
g worktree remove --force "$tmp/wt"

# The reader gives the reason when no line is usable, with exit 1.
read_refused() {
  local name="$1" reason="$2" got code
  got="$(st read main)"
  code=$?
  [[ $code -eq 1 ]] || fail "$name: expected exit 1, got $code"
  [[ "$got" == "$reason" ]] || fail "$name: got [$got], want [$reason]"
}
new_repo
read_refused 'no stamp' 'no stamp'
st write "$(g rev-parse HEAD)" clean "$(g rev-parse HEAD)" check > /dev/null
read_refused 'base moved' 'base moved'
# A stamp of a commit that is not in HEAD (the commit before a rebase).
new_repo
g switch -q -c side
g commit -q --allow-empty -m side
st write "$(g rev-parse HEAD)" clean "$(g rev-parse main)" check > /dev/null
g switch -q feat/x
read_refused 'not an ancestor' 'not an ancestor'

# A line whose base is an older commit of main (another run landed since the check) is usable.
# main_moves puts one more commit on main.
main_moves() { g switch -q main && g commit -q --allow-empty -m moved && g switch -q feat/x; }
new_repo
head="$(g rev-parse HEAD)"
st write "$head" clean "$(g rev-parse main)" check test-slow > /dev/null
main_moves
got="$(st read main)" || fail "older main base: exit $?"
[[ "$got" == "$head check test-slow" ]] || fail "older main base: got [$got]"
# A base that is a branch commit stays refused (the case base moved above).

# A base that is a well-formed hash of no commit (pruned): the line is skipped with no git error.
new_repo
echo "$(g rev-parse HEAD) $(printf 'a%.0s' {1..40}) check" >> "$file"
read_refused 'a pruned base' 'base moved'
err="$(st read main 2>&1 > /dev/null)"
[[ -z "$err" ]] || fail "a pruned base: stderr [$err]"

# The git calls of one read follow the lines of this branch, not the lines of the file: 50 newer
# lines of commits that are not in HEAD cost no merge-base call. A git wrapper logs each call.
new_repo
head="$(g rev-parse HEAD)"
st write "$head" clean "$(g rev-parse main)" check > /dev/null
g switch -q -c side
for i in $(seq 50); do
  g commit -q --allow-empty -m "side $i"
  echo "$(g rev-parse HEAD) $(g rev-parse main) check" >> "$file"
done
g switch -q feat/x
main_moves
mkdir "$tmp/wrap"
printf '#!/bin/bash\n[[ "$1" != merge-base ]] || echo call >> "%s"\nexec %s "$@"\n' "$tmp/calls" "$(command -v git)" > "$tmp/wrap/git"
chmod +x "$tmp/wrap/git"
got="$(PATH="$tmp/wrap:$PATH" st read main)" || fail "a long file: exit $?"
[[ "$got" == "$head check" ]] || fail "a long file: got [$got]"
calls="$(grep -c call "$tmp/calls" 2> /dev/null)"
[[ "${calls:-0}" -le 2 ]] || fail "a long file: $calls merge-base calls, want 2 at most"

# read <base> <commit>: the newest line of that commit with the base commit, with no ancestry
# test, so land.sh finds the stamp of a branch that an earlier land rebased.
new_repo
g switch -q -c side
g commit -q --allow-empty -m side
side="$(g rev-parse HEAD)" main="$(g rev-parse main)"
st write "$side" clean "$main" check test-slow > /dev/null
g switch -q feat/x
got="$(st read main "$side")" || fail "read of a named commit: exit $?"
[[ "$got" == "$side check test-slow" ]] || fail "read of a named commit: got [$got]"
st read main > /dev/null && fail 'read of a named commit: the plain read took a commit that is not in HEAD'
# A line with a branch-commit base, or a commit with no line, gives no line.
head="$(g rev-parse HEAD)"
rm "$file"
g switch -q side
st write "$side" clean "$head" check > /dev/null
g switch -q feat/x
[[ "$(lines)" == 1 ]] || fail 'read of a named commit: the line with a branch-commit base was not written'
st read main "$side" > /dev/null && fail 'read of a named commit: a branch-commit base was taken'
st read main "$head" > /dev/null && fail 'read of a named commit: a commit with no line was taken'

# A bad base or a bad mode exits nonzero.
new_repo
st read does-not-exist > /dev/null 2>&1 && fail 'read with a bad base exits 0'
st other > /dev/null 2>&1 && fail 'a bad mode exits 0'

[[ $failures -eq 0 ]] && echo "check-stamp tests: all passed"
exit $((failures > 0))
