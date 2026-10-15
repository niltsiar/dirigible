#!/bin/bash
# Check that with-lock.sh holds the shared build lock (<git common dir>/dirigible-build.lock) only
# while its command runs, and removes only a lock that it took. Cases: a free lock, a command that
# fails, a nested call in the command (it runs at once and leaves the lock), a live holder (the
# call waits, also from a second worktree, also with a stale DIRIGIBLE_BUILD_LOCK), a TERM to a
# waiting call (the lock of the holder stays), a release by the holder (the waiting call runs), a
# TERM to a holder (the command stops and the lock goes), a dead holder with a live child (the call
# waits), a dead holder (the lock is taken over), a git dir with no write (exit 2, also with a dead
# holder), a pid write that fails (exit 2, no lock), and the wait log (one line after a wait, none
# with no wait), and a lock folder that goes between a failed mkdir and the test for it (the call
# tries again). Each case uses a temporary repo with a worktree, so the lock of an outer
# with-lock.sh call is not touched.
# Run by scripts/bench-pairs.test.sh, which make test-hooks runs.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/with-lock.sh"
failures=0
tmp="$(mktemp -d)"
holder="" child="" waiter="" inner="" other=""
trap 'kill $holder $child $waiter $inner $other 2>/dev/null; chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
# The value of an outer with-lock.sh call names another lock.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE DIRIGIBLE_BUILD_LOCK
export WITH_LOCK_RETRY=0.1
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

repo="$tmp/repo" lock="$tmp/repo/.git/dirigible-build.lock" waits="$tmp/repo/.git/dirigible-build-waits.log"
mkdir -p "$repo/scripts"
cp "$script" "$repo/scripts/with-lock.sh"
git -C "$repo" init -q && git -C "$repo" add -A &&
    git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
git -C "$repo" worktree add -q "$tmp/wt" 2>/dev/null
# until_true <limit in tenths of a second> <command...>: 0 when the command passes in the limit.
# At the limit it stops the waiting call, so a regression fails the test and never hangs it.
until_true() {
  local n="$1"
  shift
  while ((n-- > 0)); do "$@" && return 0; sleep 0.1; done
  [[ -z "$waiter" ]] || kill "$waiter" 2>/dev/null
  return 1
}
# A live holder: a sleep whose pid is in the lock.
hold() { sleep 60 & holder=$!; mkdir "$lock" && echo "$holder" > "$lock/pid"; }
dead() { ! kill -0 "$1" 2>/dev/null; }

# A free lock: the command runs with the lock held, and the lock is gone after.
out="$("$repo/scripts/with-lock.sh" bash -c "cat '$lock/pid'" 2>&1)" || fail "free: exit $?: $out"
[[ "$out" =~ ^[0-9]+$ ]] || fail "free: no pid in the lock while the command runs: $out"
[[ ! -e "$lock" ]] || fail 'free: the lock stays after the command'
[[ ! -e "$waits" ]] || fail "free: a call with no wait appended a wait line: $(cat "$waits")"

# The exit status of the command passes through, and the lock is gone after.
"$repo/scripts/with-lock.sh" bash -c 'exit 3' > /dev/null 2>&1
code=$?
[[ $code -eq 3 ]] || fail "failed command: exit $code, not 3"
[[ ! -e "$lock" ]] || fail 'failed command: the lock stays'

# A nested call in the command (make test runs swift-test.sh, which calls with-lock.sh) sees the
# exported value in the pid file: it runs at once, and the lock of the outer call stays after it.
nested="'$repo/scripts/with-lock.sh' touch '$tmp/ran' && { cat '$lock/pid' || echo gone; } > '$tmp/after'"
"$repo/scripts/with-lock.sh" bash -c "$nested; echo \$DIRIGIBLE_BUILD_LOCK > '$tmp/value'" > "$tmp/wait.out" 2>&1 &
waiter=$!
until_true 50 test -s "$tmp/after" || fail "nested: the nested call waited for its own holder: $(cat "$tmp/wait.out")"
wait "$waiter"
waiter=""
[[ -s "$tmp/value" && "$(cat "$tmp/after")" == "$(cat "$tmp/value")" ]] ||
    fail "nested: the pid file after the nested call ($(cat "$tmp/after")) is not the exported value ($(cat "$tmp/value"))"
[[ ! -e "$lock" ]] || fail 'nested: the lock stays after the outer command'
rm -f "$tmp/ran"

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

# A stale value (a pid that is not in the pid file) waits as a call with no value does.
DIRIGIBLE_BUILD_LOCK=$$ "$repo/scripts/with-lock.sh" touch "$tmp/ran" > "$tmp/wait.out" 2>&1 &
waiter=$!
until_true 50 grep -q "held by pid $holder" "$tmp/wait.out" || fail "stale value: no wait line: $(cat "$tmp/wait.out")"
[[ ! -e "$tmp/ran" ]] || fail 'stale value: the command ran while another process held the lock'
kill -TERM "$waiter"
wait "$waiter" 2>/dev/null
[[ "$(cat "$lock/pid" 2>/dev/null)" == "$holder" ]] || fail 'stale value: the lock of the holder is gone'

# The holder releases: the waiting call takes the lock and runs.
"$repo/scripts/with-lock.sh" touch "$tmp/ran" > "$tmp/wait.out" 2>&1 &
waiter=$!
until_true 50 grep -q 'held by pid' "$tmp/wait.out" || fail 'release: no wait line'
rm -rf "$lock"
until_true 50 test -e "$tmp/ran" || fail 'release: the waiting call did not run'
wait "$waiter" || fail 'release: the waiting call failed'
[[ ! -e "$lock" ]] || fail 'release: the lock stays after the command'

# A call that waited appends one line to dirigible-build-waits.log of the git common dir: the
# start time, the wait seconds, the command, and the command of the holder.
rm -f "$waits" "$tmp/ran"
mkdir "$lock" && echo "$holder" > "$lock/pid" && echo 'make test' > "$lock/command"
WITH_LOCK_RETRY=1 "$tmp/wt/scripts/with-lock.sh" touch "$tmp/ran" > "$tmp/wait.out" 2>&1 &
waiter=$!
until_true 50 grep -q 'held by pid' "$tmp/wait.out" || fail 'wait line: no wait'
sleep 1.5
rm -rf "$lock"
until_true 50 test -e "$tmp/ran" || fail 'wait line: the waiting call did not run'
wait "$waiter"
waiter=""
[[ "$(wc -l < "$waits" 2>/dev/null | tr -d ' ')" == 1 ]] || fail "a call that waited appends one wait line: [$(cat "$waits" 2>/dev/null)]"
started="" seconds=0 command="" held=""
IFS=$'\t' read -r started seconds command held < "$waits"
[[ "$started" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T && "$seconds" -ge 1 && "$command" == "touch $tmp/ran" && "$held" == 'make test' ]] ||
    fail "wait line: [$started] [$seconds] [$command] [$held]"

# A release call (make check-changed BASE=<ref>, scripts/land.sh, make dmg) holds a ticket folder
# dirigible-build-first/<pid> in the git common dir while it waits; an ordinary call does not take
# the lock while a live ticket is there. The fake make and land.sh log their arguments.
first="$repo/.git/dirigible-build-first" fake="$tmp/fake"
mkdir -p "$fake"
printf '#!/bin/bash\necho "$*" >> "%s"\nsleep 0.3\n' "$tmp/order" > "$fake/make"
cp "$fake/make" "$fake/land.sh"
chmod +x "$fake/make" "$fake/land.sh"
# The ordinary waiter starts first and retries more often; the release waiter still runs first.
rm -f "$tmp/order"
mkdir "$lock" && echo "$holder" > "$lock/pid"
WITH_LOCK_RETRY=0.02 "$repo/scripts/with-lock.sh" "$fake/make" test-filter ATests > "$tmp/w1.out" 2>&1 &
other=$!
until_true 50 grep -q 'held by pid' "$tmp/w1.out" || fail 'release first: the ordinary call did not wait'
WITH_LOCK_RETRY=2 "$tmp/wt/scripts/with-lock.sh" "$fake/make" check-changed BASE=x > "$tmp/wait.out" 2>&1 &
waiter=$!
until_true 50 grep -q 'held by pid' "$tmp/wait.out" || fail 'release first: the release call did not wait'
rm -rf "$lock"
wait "$waiter" "$other"
waiter="" other=""
[[ "$(paste -sd'|' - < "$tmp/order")" == 'check-changed BASE=x|test-filter ATests' ]] ||
    fail "a release waiter that starts second runs first: order [$(paste -sd'|' - < "$tmp/order")]"
[[ -z "$(ls "$first" 2>/dev/null)" ]] || fail "release first: a ticket stays: $(ls "$first")"
# The ticket of a dead release call does not block an ordinary call.
/usr/bin/true &
dead_pid=$!
wait "$dead_pid"
mkdir -p "$first/$dead_pid"
rm -f "$tmp/ran"
"$repo/scripts/with-lock.sh" touch "$tmp/ran" > "$tmp/wait.out" 2>&1 &
waiter=$!
until_true 50 test -e "$tmp/ran" || fail "a dead ticket blocks an ordinary call: $(cat "$tmp/wait.out")"
wait "$waiter"
waiter=""
# scripts/land.sh and make dmg take a ticket while they wait; make test does not. A TERM removes it.
mkdir "$lock" && echo "$holder" > "$lock/pid"
for words in "$fake/land.sh" "$fake/make dmg" "$fake/make check-changed BASE=origin/main" "$fake/make test" "$fake/make check-changed"; do
  "$repo/scripts/with-lock.sh" $words > "$tmp/wait.out" 2>&1 &
  waiter=$!
  until_true 50 grep -q 'held by pid' "$tmp/wait.out" || fail "ticket of $words: no wait"
  case "$words" in
    *test | *check-changed) [[ ! -e "$first/$waiter" ]] || fail "an ordinary call has a ticket: $words" ;;
    *) [[ -d "$first/$waiter" ]] || fail "a release call has no ticket: $words" ;;
  esac
  kill -TERM "$waiter"
  wait "$waiter" 2>/dev/null
  [[ ! -e "$first/$waiter" ]] || fail "a TERM leaves the ticket of $words"
done
waiter=""
rm -rf "$lock"

# A TERM to a holder stops its command, also a process that the command started (make sends
# TERM only to its recipe shell), and removes the lock.
"$repo/scripts/with-lock.sh" bash -c "sleep 60 & echo \$! > '$tmp/inner'; wait" > /dev/null 2>&1 &
waiter=$!
until_true 50 test -s "$tmp/inner" || fail 'TERM to a holder: the command did not start'
child="$(cat "$lock/child" 2>/dev/null)" inner="$(cat "$tmp/inner" 2>/dev/null)"
kill -TERM "$waiter"
wait "$waiter"
code=$?
[[ $code -eq 143 ]] || fail "TERM to a holder: exit $code, not 143"
until_true 50 dead "$child" || fail 'TERM to a holder: the command still runs'
until_true 50 dead "$inner" || fail 'TERM to a holder: a process of the command still runs'
[[ ! -e "$lock" ]] || fail 'TERM to a holder: the lock stays'
waiter=""

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
rm -rf "$lock" "$lock.reap"
chmod a-w "$repo/.git"
out="$("$repo/scripts/with-lock.sh" true 2>&1)"
code=$?
chmod u+w "$repo/.git"
[[ $code -eq 2 && "$out" == *'cannot make'* ]] || fail "no write: exit $code: $out"

# A dead holder in a git dir with no write (the sandbox of scripts/probe.sh refuses the reap
# folder): exit 2 with a reason, not a wait without end.
mkdir "$lock" && echo "$holder" > "$lock/pid"
chmod a-w "$repo/.git"
"$repo/scripts/with-lock.sh" true > "$tmp/wait.out" 2>&1 &
waiter=$!
until_true 50 dead "$waiter" || fail "dead holder, no write: the call waits: $(cat "$tmp/wait.out")"
wait "$waiter"
code=$?
waiter=""
chmod u+w "$repo/.git"
[[ $code -eq 2 && "$(cat "$tmp/wait.out")" == *'outside scripts/probe.sh'* ]] ||
    fail "dead holder, no write: exit $code: $(cat "$tmp/wait.out")"
[[ "$(cat "$lock/pid" 2>/dev/null)" == "$holder" ]] || fail 'dead holder, no write: the lock changed'
rm -rf "$lock"

# A pid write that fails (a full disk after the mkdir): exit 2, and the call removes its lock, so
# later calls do not wait on a lock with no pid. A wrapper of mkdir makes the folder with no write.
mkdir "$tmp/bin"
printf '#!/bin/bash\n/bin/mkdir "$@" && chmod a-w "${@: -1}"\n' > "$tmp/bin/mkdir"
chmod +x "$tmp/bin/mkdir"
out="$(PATH="$tmp/bin:$PATH" "$repo/scripts/with-lock.sh" touch "$tmp/ran2" 2>&1)"
code=$?
chmod -R u+w "$lock" 2>/dev/null
[[ $code -eq 2 && "$out" == *'cannot write the pid'* ]] || fail "pid write: exit $code: $out"
[[ ! -e "$lock" && ! -e "$tmp/ran2" ]] || fail 'pid write: the lock stays or the command ran'

# The holder removes the lock between a failed mkdir and the test for the folder: a healthy call
# tries again and runs, for an ordinary call and for a release call. A wrapper of mkdir fails the
# first tries on the lock and leaves no folder, as that window does. When all tries fail with no
# folder (the no-write case above), the call still exits 2.
cat > "$tmp/bin/mkdir" << EOF
#!/bin/bash
if [[ "\${@: -1}" == *dirigible-build.lock ]]; then
  n=\$(cat "$tmp/tries" 2>/dev/null || echo 0)
  echo \$((n + 1)) > "$tmp/tries"
  [[ \$n -ge \$FAIL_TRIES ]] || exit 1
fi
exec /bin/mkdir "\$@"
EOF
for words in "touch $tmp/ran3" "$fake/make check-changed BASE=x"; do
  rm -f "$tmp/tries" "$tmp/ran3" "$tmp/order"
  out="$(FAIL_TRIES=2 PATH="$tmp/bin:$PATH" "$repo/scripts/with-lock.sh" $words 2>&1)"
  code=$?
  [[ $code -eq 0 && "$out" != *'cannot make'* ]] || fail "lock removed after a failed mkdir, $words: exit $code: $out"
  [[ "$(cat "$tmp/tries" 2>/dev/null)" -ge 3 ]] || fail "lock removed after a failed mkdir, $words: no later try"
  [[ ! -e "$lock" ]] || fail "lock removed after a failed mkdir, $words: the lock stays"
done
rm -f "$tmp/tries"
FAIL_TRIES=99 PATH="$tmp/bin:$PATH" "$repo/scripts/with-lock.sh" true > "$tmp/wait.out" 2>&1
code=$?
[[ $code -eq 2 && "$(cat "$tmp/wait.out")" == *'cannot make'* ]] || fail "mkdir fails with no folder: exit $code: $(cat "$tmp/wait.out")"

[[ $failures -eq 0 ]] && echo "with-lock tests: all passed"
exit $((failures > 0))
