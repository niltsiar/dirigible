#!/bin/bash
# Check that with-lock.sh holds the shared build lock (<git common dir>/dirigible-build.lock) only
# while its command runs, and removes only a lock that it took. Cases: a free lock, a command that
# fails, a live holder (the call waits, also from a second worktree), a TERM to a waiting call (the
# lock of the holder stays), a release by the holder (the waiting call runs), a TERM to a holder
# (the command stops and the lock goes), a dead holder with a live child (the call waits), a dead
# holder (the lock is taken over), and a git dir with no write (exit 2). Each case uses a temporary
# repo with a worktree, so the lock of an outer with-lock.sh call is not touched.
# Run by scripts/bench-pairs.test.sh, which make test-hooks runs.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/with-lock.sh"
failures=0
tmp="$(mktemp -d)"
holder="" child=""
trap 'kill $holder $child 2>/dev/null; chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
export WITH_LOCK_RETRY=0.1
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

repo="$tmp/repo" lock="$tmp/repo/.git/dirigible-build.lock"
mkdir -p "$repo/scripts"
cp "$script" "$repo/scripts/with-lock.sh"
git -C "$repo" init -q && git -C "$repo" add -A &&
    git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
git -C "$repo" worktree add -q "$tmp/wt" 2>/dev/null
# until_true <limit in tenths of a second> <command...>: 0 when the command passes in the limit.
until_true() {
  local n="$1"
  shift
  while ((n-- > 0)); do "$@" && return 0; sleep 0.1; done
  return 1
}
# A live holder: a sleep whose pid is in the lock.
hold() { sleep 60 & holder=$!; mkdir "$lock" && echo "$holder" > "$lock/pid"; }
dead() { ! kill -0 "$1" 2>/dev/null; }

# A free lock: the command runs with the lock held, and the lock is gone after.
out="$("$repo/scripts/with-lock.sh" bash -c "cat '$lock/pid'" 2>&1)" || fail "free: exit $?: $out"
[[ "$out" =~ ^[0-9]+$ ]] || fail "free: no pid in the lock while the command runs: $out"
[[ ! -e "$lock" ]] || fail 'free: the lock stays after the command'

# The exit status of the command passes through, and the lock is gone after.
"$repo/scripts/with-lock.sh" bash -c 'exit 3' > /dev/null 2>&1
code=$?
[[ $code -eq 3 ]] || fail "failed command: exit $code, not 3"
[[ ! -e "$lock" ]] || fail 'failed command: the lock stays'

# A live holder: a call from the second worktree waits. A TERM to the waiting call leaves the
# lock of the holder in place (a release trap set before the take removes it).
hold
"$tmp/wt/scripts/with-lock.sh" touch "$tmp/ran" > "$tmp/wait.out" 2>&1 &
waiter=$!
until_true 50 grep -q "held by pid $holder" "$tmp/wait.out" || fail "live holder: no wait line that names the holder: $(cat "$tmp/wait.out")"
[[ ! -e "$tmp/ran" ]] || fail 'live holder: the command ran while another process held the lock'
kill -TERM "$waiter"
wait "$waiter" 2>/dev/null
[[ "$(cat "$lock/pid" 2>/dev/null)" == "$holder" ]] || fail 'TERM while waiting: the lock of the holder is gone'
[[ ! -e "$tmp/ran" ]] || fail 'TERM while waiting: the command ran'

# The holder releases: the waiting call takes the lock and runs.
"$repo/scripts/with-lock.sh" touch "$tmp/ran" > "$tmp/wait.out" 2>&1 &
waiter=$!
until_true 50 grep -q 'held by pid' "$tmp/wait.out" || fail 'release: no wait line'
rm -rf "$lock"
until_true 50 test -e "$tmp/ran" || fail 'release: the waiting call did not run'
wait "$waiter" || fail 'release: the waiting call failed'
[[ ! -e "$lock" ]] || fail 'release: the lock stays after the command'

# A TERM to a holder stops its command and removes the lock.
"$repo/scripts/with-lock.sh" sleep 60 > /dev/null 2>&1 &
waiter=$!
until_true 50 test -s "$lock/child" || fail 'TERM to a holder: no child pid in the lock'
child="$(cat "$lock/child" 2>/dev/null)"
kill -TERM "$waiter"
wait "$waiter"
code=$?
[[ $code -eq 143 ]] || fail "TERM to a holder: exit $code, not 143"
until_true 50 dead "$child" || fail 'TERM to a holder: the command still runs'
[[ ! -e "$lock" ]] || fail 'TERM to a holder: the lock stays'

# A dead holder whose child still runs (a kill -9 of the call): the call waits.
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
sleep 60 & child=$!
mkdir "$lock" && echo "$holder" > "$lock/pid" && echo "$child" > "$lock/child"
rm -f "$tmp/ran"
"$repo/scripts/with-lock.sh" touch "$tmp/ran" > "$tmp/wait.out" 2>&1 &
waiter=$!
until_true 50 grep -q "held by pid $holder" "$tmp/wait.out" || fail "dead holder, live child: no wait line: $(cat "$tmp/wait.out")"
[[ ! -e "$tmp/ran" ]] || fail 'dead holder, live child: the command ran'

# The child ends too: the lock is taken over.
kill "$child" 2>/dev/null
wait "$child" 2>/dev/null
until_true 50 test -e "$tmp/ran" || fail 'dead holder: the lock was not taken over'
wait "$waiter" 2>/dev/null
[[ ! -e "$lock" && ! -e "$lock.reap" ]] || fail 'dead holder: the lock or the reap folder stays'

# A git dir with no write (a sandbox): exit 2 with a reason, not a wait.
chmod a-w "$repo/.git"
out="$("$repo/scripts/with-lock.sh" true 2>&1)"
code=$?
chmod u+w "$repo/.git"
[[ $code -eq 2 && "$out" == *'cannot make'* ]] || fail "no write: exit $code: $out"

[[ $failures -eq 0 ]] && echo "with-lock tests: all passed"
exit $((failures > 0))
