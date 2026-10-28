#!/bin/bash
# Check that with-lock.sh holds the shared build lock (<git common dir>/dirigible-build.lock) only
# while its command runs, and removes only a lock that it took. Cases: a free lock, a command that
# fails, a nested call in the command (it runs at once and leaves the lock), a live holder (the
# call waits, also from a second worktree, also with a stale DIRIGIBLE_BUILD_LOCK), a TERM to a
# waiting call (the lock of the holder stays), a release by the holder (the waiting call runs), a
# TERM to a holder (the command stops and the lock goes), a dead holder with a live child (the call
# waits), a dead holder (the lock is taken over), a git dir with no write (exit 2, also with a dead
# holder), a pid write that fails (exit 2, no lock), and the wait log (one line after a wait, none
# with no wait), a lock folder that goes between a failed mkdir and the test for it (the call
# tries again), and the wait limit WITH_LOCK_MAX_WAIT (exit 75, the calls with no limit, the
# default with a fake clock, and the export of run-checks.sh). Each case uses a temporary repo with a worktree, so the lock of an outer
# with-lock.sh call is not touched.
# Run by scripts/bench-pairs.test.sh, which make test-hooks runs.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/with-lock.sh"
failures=0
tmp="$(mktemp -d)"
holder="" child="" waiter="" inner="" other=""
trap 'kill $holder $child $waiter $inner $other 2>/dev/null; chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
# The value of an outer with-lock.sh call names another lock.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE DIRIGIBLE_BUILD_LOCK WITH_LOCK_MAX_WAIT WITH_LOCK_MAX_HOLD BASE MAKEFLAGS SINCE
export WITH_LOCK_RETRY=0.1
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

repo="$tmp/repo" lock="$tmp/repo/.git/dirigible-build.lock" waits="$tmp/repo/.git/dirigible-build-waits.log"
mkdir -p "$repo/scripts"
cp "$script" "$repo/scripts/with-lock.sh"
git -C "$repo" init -q && git -C "$repo" add -A &&
    git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
git -C "$repo" worktree add -q "$tmp/wt" 2>/dev/null
# The tree of a call is the git top level of its working directory.
repo_tree="$(git -C "$repo" rev-parse --show-toplevel)" wt_tree="$(git -C "$tmp/wt" rev-parse --show-toplevel)"
cd "$repo" || exit 2
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
# start time, the wait seconds, the command, the command of the holder, and the tree of the call.
rm -f "$waits" "$tmp/ran"
mkdir "$lock" && echo "$holder" > "$lock/pid" && echo 'make test' > "$lock/command"
cd "$tmp/wt" || exit 2
WITH_LOCK_RETRY=1 "$tmp/wt/scripts/with-lock.sh" touch "$tmp/ran" > "$tmp/wait.out" 2>&1 &
waiter=$!
cd "$repo" || exit 2
until_true 50 grep -q 'held by pid' "$tmp/wait.out" || fail 'wait line: no wait'
sleep 1.5
rm -rf "$lock"
until_true 50 test -e "$tmp/ran" || fail 'wait line: the waiting call did not run'
wait "$waiter"
waiter=""
[[ "$(wc -l < "$waits" 2>/dev/null | tr -d ' ')" == 1 ]] || fail "a call that waited appends one wait line: [$(cat "$waits" 2>/dev/null)]"
started="" seconds=0 command="" held="" wtree=""
IFS=$'\t' read -r started seconds command held wtree < "$waits"
[[ "$started" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T && "$seconds" -ge 1 && "$command" == "touch $tmp/ran" && "$held" == 'make test' && "$wtree" == "$wt_tree" ]] ||
    fail "wait line: [$started] [$seconds] [$command] [$held] [$wtree]"

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

# The wait limit WITH_LOCK_MAX_WAIT (default 120 s): a direct call that waits past it exits 75 and
# leaves the lock of the holder. A release call, a call with the DIRIGIBLE_LOCKED_SCRIPT marker,
# a mutation-pass.sh call, and a call with WITH_LOCK_MAX_WAIT=0 wait with no limit. A nested call
# runs at once. The holder is a live sleep whose lock a timer removes after n seconds.
hold_for() { hold; ( sleep "$1"; rm -rf "$lock" ) > /dev/null 2>&1 & other=$!; }
clear_hold() { kill $holder $other 2>/dev/null; wait $holder $other 2>/dev/null; rm -rf "$lock"; holder="" other=""; }
cp "$fake/make" "$fake/mutation-pass.sh"
rm -f "$tmp/ran" "$tmp/order"
hold_for 6
t0=$(date +%s)
out="$(WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 "$repo/scripts/with-lock.sh" touch "$tmp/ran" 2>&1)"
code=$?
elapsed=$(($(date +%s) - t0))
[[ $code -eq 75 && $elapsed -le 3 && ! -e "$tmp/ran" ]] || fail "limit: exit $code after $elapsed s (want 75 within 3 s): $out"
[[ "$out" == *"held by pid $holder"* && "$out" == *'run the same command again'* ]] || fail "limit: no holder line or rerun text: $out"
[[ "$(cat "$lock/pid" 2>/dev/null)" == "$holder" ]] || fail 'limit: the lock of the holder is gone after exit 75'
clear_hold
# A holder that goes in time: exit 0 (the pass value of the threshold).
hold_for 1
WITH_LOCK_MAX_WAIT=3 WITH_LOCK_RETRY=1 "$repo/scripts/with-lock.sh" touch "$tmp/ran" > "$tmp/wait.out" 2>&1
code=$?
[[ $code -eq 0 && -e "$tmp/ran" ]] || fail "limit, holder of 1 s under 3 s: exit $code: $(cat "$tmp/wait.out")"
clear_hold
# These calls wait past a limit of 2 s for a holder of 3 s.
for kind in release envbase makeflags mark mutation zero; do
  hold_for 3
  rm -f "$tmp/ran" "$tmp/order"
  case "$kind" in
    release) WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 "$repo/scripts/with-lock.sh" "$fake/make" check-changed BASE=origin/main ;;
    envbase) BASE=origin/main WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 "$repo/scripts/with-lock.sh" "$fake/make" check-changed ;;
    makeflags) MAKEFLAGS='w -- BASE=origin/main' WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 "$repo/scripts/with-lock.sh" "$fake/make" check-changed ;;
    mark) DIRIGIBLE_LOCKED_SCRIPT="$fake/make" WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 "$repo/scripts/with-lock.sh" "$fake/make" test ;;
    mutation) WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 "$repo/scripts/with-lock.sh" "$fake/mutation-pass.sh" x ;;
    zero) WITH_LOCK_MAX_WAIT=0 WITH_LOCK_RETRY=1 "$repo/scripts/with-lock.sh" "$fake/make" test ;;
  esac > "$tmp/wait.out" 2>&1
  code=$?
  [[ $code -eq 0 && -s "$tmp/order" ]] || fail "no limit, $kind: exit $code: $(cat "$tmp/wait.out")"
  clear_hold
done
# A nested call runs at once under the held lock, also with a limit.
mkdir "$lock" && echo 4242 > "$lock/pid"
DIRIGIBLE_BUILD_LOCK=4242 WITH_LOCK_MAX_WAIT=1 "$repo/scripts/with-lock.sh" touch "$tmp/ran" > "$tmp/wait.out" 2>&1
code=$?
[[ $code -eq 0 && -e "$tmp/ran" && "$(cat "$lock/pid")" == 4242 ]] || fail "limit, nested call: exit $code: $(cat "$tmp/wait.out")"
rm -rf "$lock"
# The default limit with a fake clock: sleep adds its seconds to the clock and date +%s reads it. A
# holder that stays gives exit 75 at 120 s, and one that goes at 119 s gives exit 0. The wait
# sleeps the seconds that are left, so the retry of 7 s does not pass the limit.
mkdir "$tmp/clockbin"
printf '#!/bin/bash\n[[ "$1" == +%%s ]] && { cat "$FAKE_CLOCK"; exit; }\nexec /bin/date "$@"\n' > "$tmp/clockbin/date"
cat > "$tmp/clockbin/sleep" << EOF
#!/bin/bash
now=\$((\$(cat "\$FAKE_CLOCK") + \${1%.*}))
echo \$now > "\$FAKE_CLOCK"
[[ \$now -lt 1002000 ]] || kill -TERM \$PPID
[[ -z "\${FAKE_RELEASE_AT:-}" || \$now -lt \$FAKE_RELEASE_AT ]] || rm -rf "$lock"
EOF
chmod +x "$tmp/clockbin/date" "$tmp/clockbin/sleep"
hold
echo 1000000 > "$tmp/clock"
out="$(env -u WITH_LOCK_MAX_WAIT PATH="$tmp/clockbin:$PATH" FAKE_CLOCK="$tmp/clock" WITH_LOCK_RETRY=7 "$repo/scripts/with-lock.sh" touch "$tmp/ran" 2>&1)"
code=$?
[[ $code -eq 75 && "$(cat "$tmp/clock")" == 1000120 && "$out" == *'120 s'* ]] || fail "default limit, holder stays: exit $code at $(($(cat "$tmp/clock") - 1000000)) s: $out"
echo 1000000 > "$tmp/clock"
out="$(env -u WITH_LOCK_MAX_WAIT PATH="$tmp/clockbin:$PATH" FAKE_CLOCK="$tmp/clock" FAKE_RELEASE_AT=1000119 WITH_LOCK_RETRY=7 "$repo/scripts/with-lock.sh" touch "$tmp/ran" 2>&1)"
code=$?
[[ $code -eq 0 && "$(cat "$tmp/clock")" -ge 1000119 ]] || fail "default limit, holder goes at 119 s: exit $code at $(($(cat "$tmp/clock") - 1000000)) s: $out"
clear_hold
# run-checks.sh exports WITH_LOCK_MAX_WAIT=0, so a with-lock.sh call of a make recipe (swift-test.sh)
# under a push check waits past the limit of the caller. The fake make calls with-lock.sh as that
# recipe does.
cp "$(dirname "$script")/run-checks.sh" "$repo/scripts/run-checks.sh"
printf '#!/bin/bash\nexit 0\n' > "$repo/scripts/check-changed.sh"
printf '#!/bin/bash\nexec %q touch %q\n' "$repo/scripts/with-lock.sh" "$tmp/ran" > "$fake/rcmake"
chmod +x "$repo/scripts/check-changed.sh" "$fake/rcmake"
hold_for 4
rm -f "$tmp/ran"
out="$(cd "$repo" && env -u BASE MAKE="$fake/rcmake" WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 scripts/run-checks.sh test 2>&1)"
code=$?
[[ $code -eq 0 && -e "$tmp/ran" ]] || fail "run-checks.sh: the recipe call stops at the limit of the caller: exit $code: $out"
clear_hold

# Builders. A release appends one hold line to dirigible-build-holds.log: the start, the hold
# seconds, the command, and the tree. The lock folder keeps $lock/tree while a call holds it, and a
# waiting call keeps the marker dirigible-build-waiting/<pid> with its tree. --builders prints each
# tree with a wait or hold line that ended in the last WITH_LOCK_BUILDERS_MIN minutes (default 60),
# the live holder, and each live waiter. A wait with 2 or more other trees prints the count.
holds="$repo/.git/dirigible-build-holds.log" waiting="$repo/.git/dirigible-build-waiting"
reset_builders() { clear_hold; rm -rf "$lock" "$waits" "$holds" "$waiting" "$first"; }
# A make check-changed call whose targets build no Swift or lock each Swift call themselves
# (check-docs, check-fast, lint, format, none, test, test-filter, or a word with =), and a make
# test-hooks call with a HOOK_TESTS= word, run at once with no lock, no wait line, and no hold line,
# while an ordinary build or test holds the lock. While a release call, a bench, a mutation pass, or
# a flake loop holds the lock, they wait without taking the lock (the cases below). The fake
# check-changed.sh prints $FAKE_TARGETS, logs the FILTER value, prints $FAKE_STDERR on stderr, and
# exits $FAKE_EXIT.
cat > "$repo/scripts/check-changed.sh" << 'EOF'
#!/bin/bash
echo "${FILTER-unset}" >> "$FAKE_FILTER_LOG"
if [[ "${FAKE_EXIT:-0}" != 3 ]]; then # exit 3 is the refusal: no stdout
    echo "classes: tooling"
    echo "targets: $FAKE_TARGETS"
fi
[[ -z "${FAKE_STDERR:-}" ]] || echo "$FAKE_STDERR" >&2
exit "${FAKE_EXIT:-0}"
EOF
chmod +x "$repo/scripts/check-changed.sh"
export FAKE_FILTER_LOG="$tmp/filter.log"
# lockfree <expect> <label> <command...>: with a live holder, the call runs at once (run) or waits
# until the limit of 2 s (wait). It leaves the holder, the wait log, and the hold log as they were.
lockfree() {
    local expect="$1" label="$2"
    shift 2
    reset_builders
    rm -f "$tmp/order" "$FAKE_FILTER_LOG"
    hold
    [[ -z "${HOLDER_COMMAND:-}" ]] || echo "$HOLDER_COMMAND" > "$lock/command"
    out="$(WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 "$repo/scripts/with-lock.sh" "$@" 2>&1)"
    code=$?
    if [[ $expect == run ]]; then
        [[ $code -eq 0 && -s "$tmp/order" && "$out" == *'lock-free targets'* ]] || fail "lock-free, $label: exit $code, order [$(cat "$tmp/order" 2>/dev/null)]: $out"
        [[ ! -e "$waits" && ! -e "$holds" && "$(cat "$lock/pid")" == "$holder" ]] ||
            fail "lock-free, $label: a log line or a change of the lock: $(cat "$waits" "$holds" 2>/dev/null)"
    else
        [[ $code -eq 75 && ! -s "$tmp/order" && "$out" != *'lock-free targets'* ]] || fail "lock-free, $label: exit $code (want 75), order [$(cat "$tmp/order" 2>/dev/null)]: $out"
    fi
}
for targets in "check-fast HOOK_TESTS=a" "check-docs" "none" "check-fast DIRIGIBLE_HOOKS_ALL=1" "lint format" \
    "test" "check-docs test" "check-fast HOOK_TESTS=a test-filter"; do
    FAKE_TARGETS="$targets" lockfree run "targets $targets" "$fake/make" check-changed
done
FAKE_TARGETS="check-fast test-filter" lockfree run "test-filter with a FILTER word" "$fake/make" check-changed FILTER=ATests
[[ "$(cat "$FAKE_FILTER_LOG")" == ATests ]] || fail "lock-free: check-changed.sh got FILTER [$(cat "$FAKE_FILTER_LOG")], not ATests"
FAKE_TARGETS="check-fast test-filter test-app" lockfree wait "targets check-fast test-filter test-app" "$fake/make" check-changed
FAKE_TARGETS="check-fast test-filter test-app" lockfree wait "test-app with a FILTER word" "$fake/make" check-changed FILTER=ATests
[[ "$(cat "$FAKE_FILTER_LOG")" == ATests ]] || fail "lock-free: check-changed.sh got FILTER [$(cat "$FAKE_FILTER_LOG")], not ATests"
FAKE_TARGETS="check-fast" lockfree run "a make word with =" "$fake/make" check-changed SINCE=main
FAKE_TARGETS="check-fast" FAKE_EXIT=1 lockfree wait "check-changed.sh exit 1" "$fake/make" check-changed
FAKE_TARGETS="" lockfree wait "no targets" "$fake/make" check-changed
FAKE_TARGETS="check-fast" lockfree wait "another goal" "$fake/make" check-changed test
# A release call keeps its ticket and the lock, also with lock-free targets.
reset_builders
rm -f "$tmp/order"
hold_for 2
FAKE_TARGETS="check-docs" "$repo/scripts/with-lock.sh" "$fake/make" check-changed BASE=origin/main > "$tmp/wait.out" 2>&1
code=$?
[[ $code -eq 0 && -s "$tmp/order" && "$(cat "$tmp/wait.out")" != *'lock-free'* && "$(awk -F'\t' '{ print $3 }' "$holds")" == *'BASE=origin/main' ]] ||
    fail "lock-free, push check: exit $code, hold [$(cat "$holds" 2>/dev/null)]: $(cat "$tmp/wait.out")"
# BASE in the environment or in MAKEFLAGS (make exports a BASE= word of its command line to the
# recipe) is a push check as well: never lock-free, and a release call with no wait limit. An empty
# BASE is no push check.
for envword in BASE=origin/main 'MAKEFLAGS= BASE=origin/main' 'MAKEFLAGS=w -- BASE=origin/main'; do
    reset_builders
    rm -f "$tmp/order"
    hold_for 4
    FAKE_TARGETS="check-docs" WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 env "$envword" "$repo/scripts/with-lock.sh" "$fake/make" check-changed > "$tmp/wait.out" 2>&1
    code=$?
    [[ $code -eq 0 && -s "$tmp/order" && "$(cat "$tmp/wait.out")" != *'lock-free'* && "$(awk -F'\t' '{ print $3 }' "$holds")" == *'check-changed' ]] ||
        fail "lock-free, push check from [$envword]: exit $code, hold [$(cat "$holds" 2>/dev/null)]: $(cat "$tmp/wait.out")"
done
FAKE_TARGETS="check-docs" BASE= lockfree run "an empty BASE in the environment" "$fake/make" check-changed
FAKE_TARGETS="check-docs" MAKEFLAGS='w -- SINCE=main' lockfree run "MAKEFLAGS with no BASE" "$fake/make" check-changed
# A live holder that is a push check by its environment keeps the wait of a lock-free call.
reset_builders
mkdir "$fake/slow"
printf '#!/bin/bash\nsleep 6\n' > "$fake/slow/make"
chmod +x "$fake/slow/make"
BASE=origin/main "$repo/scripts/with-lock.sh" "$fake/slow/make" check-changed > /dev/null 2>&1 &
other=$!
until_true 50 test -s "$lock/child" || fail 'lock-free, push check holder: the holder did not start'
rm -f "$tmp/order"
out="$(FAKE_TARGETS="check-docs" WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 "$repo/scripts/with-lock.sh" "$fake/make" check-changed 2>&1)"
code=$?
[[ $code -eq 75 && ! -s "$tmp/order" && "$out" != *'lock-free targets'* ]] ||
    fail "lock-free, holder with BASE in its environment: exit $code (want 75), order [$(cat "$tmp/order" 2>/dev/null)]: $out"
reset_builders
# make test-hooks: a HOOK_TESTS= word runs at once; the bare goal waits.
lockfree run "test-hooks with HOOK_TESTS" "$fake/make" test-hooks HOOK_TESTS=a,b
lockfree wait "test-hooks with no HOOK_TESTS" "$fake/make" test-hooks
lockfree wait "test-hooks with an empty HOOK_TESTS" "$fake/make" test-hooks HOOK_TESTS=
# A holder that is a release call, a bench, a mutation pass, or a flake loop keeps the wait; an
# ordinary build or test does not.
for holder_command in "make check-changed BASE=origin/main" "$repo/scripts/land.sh x" "make dmg" "$repo/scripts/bench.sh x" "$repo/scripts/bench-pairs.sh x" \
    "$repo/scripts/mutation-pass.sh $repo batch" "$repo/scripts/flake-monitor/loop.sh x" "bash $repo/scripts/flake-monitor/loop.sh x" \
    "make bench FILTER=HeaderDragBenchmark" "make bench FILTER=ATests BTests" "make FILTER=ATests bench" "make DMG_X=1 dmg"; do
    FAKE_TARGETS="check-docs" HOLDER_COMMAND="$holder_command" lockfree wait "holder $holder_command" "$fake/make" check-changed
done
for holder_command in "make test-filter ATests" "make test-filter FILTER=bench" "make benchmark-gate"; do
    FAKE_TARGETS="check-docs" HOLDER_COMMAND="$holder_command" lockfree run "holder $holder_command" "$fake/make" check-changed
done
reset_builders

# A lock-free call that starts behind a long holder waits with no lock (no marker, no ticket, no
# hold line), under the wait limit of an ordinary call, and runs its command with no lock when the
# holder ends and no release call has a live ticket. It writes one wait line with the column nocap.
# The fake make logs whether the lock folder exists, DIRIGIBLE_BUILD_LOCK, and whether the ticket
# pid lives. lf_start runs the call in the background; lf_finish waits for it (<tenths of a second>).
mkdir "$fake/probe"
cat > "$fake/probe/make" << 'EOF'
#!/bin/bash
{ [[ -d "$FAKE_LOCK" ]] && echo lock || echo nolock; echo "${DIRIGIBLE_BUILD_LOCK-unset}"
  if [[ -n "${FAKE_TICKET:-}" ]] && kill -0 "$FAKE_TICKET" 2>/dev/null; then echo ticket-live; else echo ticket-gone; fi; } > "$FAKE_STATE"
EOF
chmod +x "$fake/probe/make"
export FAKE_LOCK="$lock" FAKE_STATE="$tmp/state"
lf_start() {
    rm -f "$tmp/state" "$tmp/wait.out"
    t0=$(date +%s)
    FAKE_TARGETS=check-docs "$@" "$repo/scripts/with-lock.sh" "$fake/probe/make" check-changed > "$tmp/wait.out" 2>&1 &
    waiter=$!
}
lf_finish() {
    until_true "$1" dead "$waiter" || true
    { wait "$waiter"; } 2>/dev/null
    code=$?
    elapsed=$(($(date +%s) - t0))
    waiter=""
    out="$(cat "$tmp/wait.out")"
}
# lf_holder <command of the holder> [seconds until the lock folder goes]
lf_holder() {
    reset_builders
    if [[ -n "${2:-}" ]]; then hold_for "$2"; else hold; fi
    echo "$1" > "$lock/command"
}
# (1) The holder ends during the wait: the command runs with no lock, and the wait leaves one line.
lf_holder 'make dmg' 1
lf_start env WITH_LOCK_MAX_WAIT=10 WITH_LOCK_RETRY=0.1
until_true 50 grep -q 'held by pid' "$tmp/wait.out" || fail "lock-free wait: no holder line: $(cat "$tmp/wait.out")"
sleep 0.3
[[ -z "$(ls -A "$waiting" 2>/dev/null)" ]] || fail "lock-free wait: a marker while it waits: $(ls "$waiting")"
lf_finish 80
[[ $code -eq 0 && $elapsed -le 4 && "$(cat "$tmp/state" 2>/dev/null)" == $'nolock\nunset\nticket-gone' ]] ||
    fail "lock-free wait: exit $code after $elapsed s, state [$(cat "$tmp/state" 2>/dev/null | paste -sd, -)]: $out"
[[ "$out" == *'lock-free targets'* && "$(grep -c 'held by pid' <<<"$out")" == 1 ]] || fail "lock-free wait: stderr: $out"
[[ ! -e "$holds" ]] || fail "lock-free wait: a hold line: $(cat "$holds")"
[[ "$(wc -l < "$waits" 2>/dev/null | tr -d ' ')" == 1 && "$(awk -F'\t' '{ print NF, $4, $NF }' "$waits")" == '6 make dmg lockfree' ]] ||
    fail "lock-free wait: the wait line: [$(cat "$waits" 2>/dev/null)]"
# The wait line is no sign of a building tree: --builders lists no tree after it.
[[ -z "$("$repo/scripts/with-lock.sh" --builders 2>&1)" ]] || fail "lock-free wait: --builders lists [$("$repo/scripts/with-lock.sh" --builders 2>&1)]"
# (2) A holder that stays: exit 75 at the limit, no command, no log line, and the holder as it was.
lf_holder 'make dmg'
lf_start env WITH_LOCK_MAX_WAIT=2
lf_finish 80
[[ $code -eq 75 && ! -e "$tmp/state" && "$out" == *'still waiting after 2 s (WITH_LOCK_MAX_WAIT); run the same command again'* && "$out" != *'lock-free targets'* ]] ||
    fail "lock-free limit: exit $code after $elapsed s: $out"
[[ ! -e "$waits" && ! -e "$holds" && "$(cat "$lock/pid")" == "$holder" && "$(cat "$lock/command")" == 'make dmg' ]] ||
    fail "lock-free limit: a log line or a change of the holder: $(cat "$waits" "$holds" 2>/dev/null)"
# (3) No limit: WITH_LOCK_MAX_WAIT=0 waits for a holder that ends after 3 s.
lf_holder 'make dmg' 3
lf_start env WITH_LOCK_MAX_WAIT=0
lf_finish 80
[[ $code -eq 0 && -s "$tmp/state" && $elapsed -ge 2 ]] || fail "lock-free no limit: exit $code after $elapsed s: $out"
# (4) A limit that is not whole seconds, behind a long holder: exit 2 and no command.
lf_holder 'make dmg'
lf_start env WITH_LOCK_MAX_WAIT=abc
lf_finish 80
[[ $code -eq 2 && ! -e "$tmp/state" && "$out" == *"WITH_LOCK_MAX_WAIT is 'abc'"* ]] || fail "lock-free bad limit: exit $code: $out"
# (5) The holder is replaced by an ordinary build or test: the call runs at the next poll, with no lock.
lf_holder 'make dmg'
( sleep 1; echo 'make test' > "$lock/command" ) > /dev/null 2>&1 & inner=$!
lf_start env WITH_LOCK_MAX_WAIT=10 WITH_LOCK_RETRY=0.1
lf_finish 80
wait "$inner" 2>/dev/null
inner=""
[[ $code -eq 0 && $elapsed -le 4 && "$(sed -n 1p "$tmp/state" 2>/dev/null)" == lock && "$(sed -n 2p "$tmp/state" 2>/dev/null)" == unset && "$(cat "$lock/pid")" == "$holder" ]] ||
    fail "lock-free replaced holder: exit $code after $elapsed s, state [$(paste -sd, - < "$tmp/state" 2>/dev/null)]: $out"
# (6) The holder dies and leaves its lock folder: the call runs, and the dead lock stays.
lf_holder 'make dmg'
( sleep 1; kill -9 "$holder" ) > /dev/null 2>&1 & inner=$!
lf_start env WITH_LOCK_MAX_WAIT=10 WITH_LOCK_RETRY=0.1
lf_finish 80
wait "$inner" 2>/dev/null
inner=""
{ wait "$holder"; } 2>/dev/null
[[ $code -eq 0 && $elapsed -le 4 && -d "$lock" && "$(cat "$lock/pid")" == "$holder" && "$out" != *'took over'* && ! -e "$holds" ]] ||
    fail "lock-free dead holder: exit $code after $elapsed s, lock [$(ls "$lock" 2>/dev/null | paste -sd, -)]: $out"
# (7) TERM to the waiting call: the lock, the pid file, and the command of the holder stay.
lf_holder 'make dmg'
lf_start env WITH_LOCK_MAX_WAIT=10 WITH_LOCK_RETRY=0.1
until_true 50 grep -q 'held by pid' "$tmp/wait.out" || fail "lock-free TERM: no holder line: $(cat "$tmp/wait.out")"
kill -TERM "$waiter"
lf_finish 20
[[ $code -eq 143 && ! -e "$tmp/state" && "$(cat "$lock/pid")" == "$holder" && "$(cat "$lock/command")" == 'make dmg' && ! -e "$holds" ]] ||
    fail "lock-free TERM: exit $code: $out"
# (8) The holder ends while a release call has a live ticket: the call keeps waiting, under the limit.
lf_holder 'make dmg' 1
sleep 60 & inner=$!
mkdir -p "$first/$inner"
lf_start env WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=0.1
lf_finish 80
[[ $code -eq 75 && ! -e "$tmp/state" && -d "$first/$inner" ]] || fail "lock-free ticket, stays: exit $code after $elapsed s, ticket [$(ls "$first" 2>/dev/null)]: $out"
kill "$inner" 2>/dev/null
wait "$inner" 2>/dev/null
inner=""
# (9) The ticket goes after 2 s: the call runs after it, with no lock.
lf_holder 'make dmg' 1
sleep 2 & inner=$!
mkdir -p "$first/$inner"
FAKE_TICKET="$inner" lf_start env WITH_LOCK_MAX_WAIT=10 WITH_LOCK_RETRY=0.1
lf_finish 100
wait "$inner" 2>/dev/null
[[ $code -eq 0 && "$(cat "$tmp/state" 2>/dev/null)" == $'nolock\nunset\nticket-gone' ]] ||
    fail "lock-free ticket, goes: exit $code after $elapsed s, state [$(paste -sd, - < "$tmp/state" 2>/dev/null)]: $out"
inner=""
rm -rf "$first"
# (10) With no long holder, a bad limit is not read: the call runs at once.
lf_holder 'make test'
lf_start env WITH_LOCK_MAX_WAIT=abc
lf_finish 80
[[ $code -eq 0 && "$(sed -n 1p "$tmp/state" 2>/dev/null)" == lock && ! -e "$waits" ]] || fail "lock-free bad limit, no long holder: exit $code: $out"
# (11) DIRIGIBLE_LOCKED_SCRIPT has no limit, also for a lock-free call.
lf_holder 'make dmg' 3
lf_start env WITH_LOCK_MAX_WAIT=2 DIRIGIBLE_LOCKED_SCRIPT=1
lf_finish 80
[[ $code -eq 0 && -s "$tmp/state" ]] || fail "lock-free DIRIGIBLE_LOCKED_SCRIPT: exit $code after $elapsed s: $out"
reset_builders

# The refusal of check-changed.sh for a clean tree with commits past origin/main (exit 3, one line)
# passes through at once: no lock, no wait, no ticket, no log line, no command, also behind a long
# holder. Any other failure, also an exit 1 with the same words, keeps the wait and prints nothing.
refusal='check-changed: no changed path, and HEAD has commits past the merge base abc of origin/main (count: 2): give SINCE=abc or BASE=<ref>'
for holder_command in none 'make dmg'; do
    lf_holder "$holder_command"
    [[ $holder_command != none ]] || rm -rf "$lock"
    lf_start env FAKE_EXIT=3 FAKE_STDERR="$refusal" WITH_LOCK_MAX_WAIT=10 WITH_LOCK_RETRY=0.1
    lf_finish 80
    [[ $code -eq 3 && $elapsed -le 4 && "$out" == "$refusal" && ! -e "$tmp/state" ]] || fail "refusal, holder [$holder_command]: exit $code after $elapsed s: $out"
    [[ ! -e "$waits" && ! -e "$holds" && -z "$(ls -A "$waiting" 2>/dev/null)$(ls -A "$first" 2>/dev/null)" ]] || fail "refusal, holder [$holder_command]: a log line, marker, or ticket"
    [[ $holder_command == none || "$(cat "$lock/pid")" == "$holder" ]] || fail "refusal, holder [$holder_command]: the holder changed"
done
for status in 1 2; do
    lf_holder 'make dmg'
    lf_start env FAKE_EXIT=$status FAKE_STDERR="$refusal" WITH_LOCK_MAX_WAIT=2
    lf_finish 80
    [[ $code -eq 75 && ! -e "$tmp/state" && "$out" != *"$refusal"* ]] || fail "exit $status with the words of the refusal: exit $code: $out"
done
reset_builders
# The real check-changed.sh and with-lock.sh as a pair, in a repo whose HEAD is a commit past
# origin/main: the call exits 3 with the one line, also behind a long holder, and logs nothing.
pair="$tmp/pair"
mkdir -p "$pair/scripts"
cp "$script" "$(dirname "$script")/check-changed.sh" "$pair/scripts/"
git -C "$pair" init -q && git -C "$pair" add -A &&
    git -C "$pair" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base &&
    git -C "$pair" update-ref refs/remotes/origin/main HEAD &&
    git -C "$pair" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m ahead
plock="$pair/.git/dirigible-build.lock"
for holder_command in none 'make dmg'; do
    rm -rf "$plock" "$pair/.git/dirigible-build-waits.log"
    if [[ $holder_command != none ]]; then
        sleep 60 & inner=$!
        mkdir "$plock" && echo "$inner" > "$plock/pid" && echo "$holder_command" > "$plock/command"
    fi
    t0=$(date +%s)
    out="$(cd "$pair" && WITH_LOCK_MAX_WAIT=10 WITH_LOCK_RETRY=0.1 scripts/with-lock.sh "$fake/make" check-changed 2>&1)"
    code=$?
    elapsed=$(($(date +%s) - t0))
    [[ $code -eq 3 && $elapsed -le 4 && "$out" == 'check-changed: no changed path, and HEAD has commits past the merge base '*'give SINCE='* && "$(wc -l <<<"$out" | tr -d ' ')" == 1 ]] ||
        fail "real pair, holder [$holder_command]: exit $code after $elapsed s: $out"
    [[ ! -e "$pair/.git/dirigible-build-waits.log" && ! -e "$pair/.git/dirigible-build-holds.log" ]] || fail "real pair, holder [$holder_command]: a log line"
    [[ -z "$inner" ]] || { kill "$inner" 2>/dev/null; wait "$inner" 2>/dev/null; inner=""; }
done
reset_builders

# ago <minutes>: the ISO time of that many minutes ago, as the logs write it.
ago() { date -r $(($(date +%s) - $1 * 60)) +%FT%T; }
/usr/bin/true &
dead_pid=$!
wait "$dead_pid"
reset_builders
"$repo/scripts/with-lock.sh" bash -c 'sleep 1.2' > /dev/null 2>&1
code=$?
started="" seconds=0 command="" htree=""
IFS=$'\t' read -r started seconds command htree < "$holds"
[[ $code -eq 0 && "$(wc -l < "$holds" | tr -d ' ')" == 1 && "$started" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T && "$seconds" -ge 1 && "$command" == "bash -c sleep 1.2" && "$htree" == "$repo_tree" ]] ||
    fail "hold line: exit $code [$started] [$seconds] [$command] [$htree]: $(cat "$holds" 2>/dev/null)"
# The take writes the tree of the call, also after the takeover of a dead lock.
reset_builders
out="$(cd "$tmp/wt" && "$repo/scripts/with-lock.sh" bash -c "cat '$lock/tree'" 2>&1)"
[[ "$out" == "$wt_tree" ]] || fail "take: the lock tree is [$out], not [$wt_tree]"
mkdir "$lock" && echo "$dead_pid" > "$lock/pid" && echo /old/tree > "$lock/tree"
out="$(cd "$tmp/wt" && "$repo/scripts/with-lock.sh" bash -c "cat '$lock/tree'" 2>&1)"
[[ "$out" == *"$wt_tree" && "$out" != *'/old/tree'* ]] || fail "takeover: the lock tree is [$out], not [$wt_tree]"
# A mutation pass counts for the tree that it builds (its first argument), not for the tree of the
# caller: the lock tree, the hold line, and the wait line name that tree. Another command, and a
# first argument that is not a git tree, keep the tree of the caller.
mtree="$tmp/mtree" plain="$tmp/plain"
git init -q "$mtree" && mkdir -p "$plain"
mtree="$(git -C "$mtree" rev-parse --show-toplevel)"
mkdir -p "$fake/x"
printf '#!/bin/bash\ncat "%s/tree" > "%s"\nsleep 0.5\n' "$lock" "$tmp/mp.tree" > "$fake/x/mutation-pass.sh"
cp "$fake/x/mutation-pass.sh" "$fake/x/other-pass.sh"
chmod +x "$fake/x/mutation-pass.sh" "$fake/x/other-pass.sh"
reset_builders
"$repo/scripts/with-lock.sh" "$fake/x/mutation-pass.sh" "$mtree" batch > /dev/null 2>&1
[[ "$(cat "$tmp/mp.tree")" == "$mtree" ]] || fail "mutation pass: the lock tree is [$(cat "$tmp/mp.tree")], not [$mtree]"
[[ "$(awk -F'\t' '{ print $4 }' "$holds")" == "$mtree" ]] || fail "mutation pass: the hold line tree is [$(awk -F'\t' '{ print $4 }' "$holds")], not [$mtree]"
reset_builders
hold
"$repo/scripts/with-lock.sh" "$fake/x/mutation-pass.sh" "$mtree" batch > "$tmp/wait.out" 2>&1 &
waiter=$!
until_true 50 grep -q 'held by pid' "$tmp/wait.out" || fail "mutation pass: no wait line: $(cat "$tmp/wait.out")"
rm -rf "$lock"
wait "$waiter"
waiter=""
[[ "$(awk -F'\t' '{ print $5 }' "$waits")" == "$mtree" ]] || fail "mutation pass: the wait line tree is [$(awk -F'\t' '{ print $5 }' "$waits")], not [$mtree]"
for words in "$fake/x/other-pass.sh $mtree batch" "$fake/x/mutation-pass.sh $plain batch"; do
    reset_builders
    # shellcheck disable=SC2086
    "$repo/scripts/with-lock.sh" $words > /dev/null 2>&1
    [[ "$(cat "$tmp/mp.tree")" == "$repo_tree" ]] || fail "the tree of [$words] is [$(cat "$tmp/mp.tree")], not the caller tree [$repo_tree]"
done
reset_builders
# The window: a hold that ended 59 min ago counts, one that ended 61 min ago does not. A wait line
# counts as a hold line, and the old wait line of 4 columns has no tree.
reset_builders
printf '%s\t30\tmake test\t/t/in\n%s\t30\tmake test\t/t/out\n' "$(ago 60)" "$(ago 62)" > "$holds"
printf '%s\t30\ttouch x\tmake test\t/t/wait-in\n%s\t30\ttouch x\tmake test\t/t/wait-out\n%s\t30\ttouch x\tmake test\n' "$(ago 60)" "$(ago 62)" "$(ago 5)" > "$waits"
out="$("$repo/scripts/with-lock.sh" --builders 2>&1)"
[[ "$out" == "$(printf '/t/in\n/t/wait-in')" ]] || fail "--builders window: [$out]"
out="$(WITH_LOCK_BUILDERS_MIN=90 "$repo/scripts/with-lock.sh" --builders 2>&1)"
[[ "$out" == *'/t/out'* && "$out" == *'/t/wait-out'* ]] || fail "--builders, 90 min: [$out]"
# A live holder with no log line counts, and a dead holder does not. A live waiter counts, and a
# marker of a dead pid does not and goes.
reset_builders
hold
echo /t/holder > "$lock/tree"
mkdir -p "$waiting"
sleep 60 & other=$!
echo /t/waiter > "$waiting/$other"
echo /t/gone > "$waiting/$dead_pid"
out="$("$repo/scripts/with-lock.sh" --builders 2>&1 | sed '/^holder:/d')"
[[ "$out" == "$(printf '/t/holder\n/t/waiter')" && ! -e "$waiting/$dead_pid" ]] || fail "--builders, live holder and waiter: [$out]"
# A wait behind them, with no log line, counts both: 2 other trees.
cd "$tmp/wt" || exit 2
"$repo/scripts/with-lock.sh" touch "$tmp/ran" > "$tmp/wait.out" 2>&1 &
waiter=$!
cd "$repo" || exit 2
until_true 50 grep -q 'the cap is 2' "$tmp/wait.out" || fail "builders line: none for 2 other trees: $(cat "$tmp/wait.out")"
grep -qF 'builders in the last 60 min: 2 (/t/holder, /t/waiter); the cap is 2 (long-runs.md)' "$tmp/wait.out" || fail "builders line: $(cat "$tmp/wait.out")"
[[ "$(cat "$waiting/$waiter" 2>/dev/null)" == "$wt_tree" ]] || fail 'wait marker: no marker with the tree of the waiting call'
wpid=$waiter
kill -TERM "$waiter"
wait "$waiter" 2>/dev/null
waiter=""
[[ ! -e "$waiting/$wpid" ]] || fail "a TERM leaves a wait marker: $(ls "$waiting")"
# One other tree prints no line, and the tree of the caller is never an other tree.
reset_builders
hold
echo /t/holder > "$lock/tree"
printf '%s\t30\tmake test\t%s\n' "$(ago 5)" "$wt_tree" > "$holds"
cd "$tmp/wt" || exit 2
"$repo/scripts/with-lock.sh" touch "$tmp/ran" > "$tmp/wait.out" 2>&1 &
waiter=$!
cd "$repo" || exit 2
until_true 50 grep -q 'held by pid' "$tmp/wait.out" || fail 'builders line: no wait'
sleep 0.5
kill -TERM "$waiter"
wait "$waiter" 2>/dev/null
waiter=""
! grep -q 'builders in the last' "$tmp/wait.out" || fail "builders line for 1 other tree: $(cat "$tmp/wait.out")"
# A call that waits behind a live release ticket and a free lock leaves a marker that --builders counts.
reset_builders
sleep 60 & other=$!
mkdir -p "$first/$other"
cd "$tmp/wt" || exit 2
"$repo/scripts/with-lock.sh" touch "$tmp/ran" > "$tmp/wait.out" 2>&1 &
waiter=$!
cd "$repo" || exit 2
until_true 50 grep -q 'takes .* first' "$tmp/wait.out" || fail "ticket wait: no wait line: $(cat "$tmp/wait.out")"
out="$("$repo/scripts/with-lock.sh" --builders 2>&1)"
[[ "$out" == "$wt_tree" ]] || fail "ticket wait: --builders lists [$out], not the waiting tree"
kill -TERM "$waiter"
wait "$waiter" 2>/dev/null
waiter=""
# A call that ends in exit 75, and a call that takes the lock, leave no marker.
reset_builders
hold
WITH_LOCK_MAX_WAIT=1 WITH_LOCK_RETRY=0.3 "$repo/scripts/with-lock.sh" touch "$tmp/ran" > "$tmp/wait.out" 2>&1
code=$?
[[ $code -eq 75 && -z "$(ls "$waiting" 2>/dev/null)" ]] || fail "exit 75: code $code, markers [$(ls "$waiting" 2>/dev/null)]"
clear_hold
hold_for 1
WITH_LOCK_RETRY=0.3 "$repo/scripts/with-lock.sh" touch "$tmp/ran" > "$tmp/wait.out" 2>&1
[[ -z "$(ls "$waiting" 2>/dev/null)" ]] || fail "a take leaves a marker: $(ls "$waiting")"
reset_builders

# The cap of 2 building trees. An ordinary call does not take a free lock while 2 other trees
# build: the live holder and the trees of the hold lines in the window, never a waiting marker, a
# line of the calling tree, a line with the last column nocap, or a tree path that does not exist.
# It waits as for a held lock (exit 75 at the wait limit) and prints the cap line once. A release
# call, a nested call, and a marker call run at the cap; so does a call with WITH_LOCK_NO_CAP=1,
# which writes its wait and hold lines with the last column nocap. The trees are real folders, as
# the cap skips a path that does not exist.
ta="$tmp/ta" tb="$tmp/tb" tc="$tmp/tc"
mkdir -p "$ta" "$tb" "$tc"
git -C "$repo" worktree add -q "$tmp/wt2" 2>/dev/null
# capcall <tree dir> <command...>: an ordinary call from that tree; out and code hold the result.
capcall() {
  local dir="$1"
  shift
  out="$(cd "$dir" && WITH_LOCK_MAX_WAIT="${WITH_LOCK_MAX_WAIT:-2}" WITH_LOCK_RETRY=1 "$repo/scripts/with-lock.sh" "$@" 2>&1)"
  code=$?
}
# holdline <minutes ago> <tree>: a hold line of 30 s that started that long ago.
holdline() { printf '%s\t30\tmake test\t%s\n' "$(ago "$1")" "$2" >> "$holds"; }
cap_text='the cap is 2 building trees'
reset_builders
holdline 5 "$ta"
holdline 3 "$tb"
rm -f "$tmp/ran"
capcall "$repo" touch "$tmp/ran"
[[ $code -eq 75 && ! -e "$tmp/ran" ]] || fail "cap: exit $code, ran [$(ls "$tmp/ran" 2>&1)] (want 75, no run): $out"
[[ "$out" == *"$cap_text: $ta, $tb; 56 min until $ta ages out"* ]] || fail "cap: no cap line with both trees and the minutes: $out"
[[ "$(grep -c "$cap_text" <<<"$out")" -eq 1 ]] || fail "cap: the cap line is not printed once: $out"
# One other tree, and the calling tree with one other tree: the command runs.
reset_builders
holdline 5 "$ta"
rm -f "$tmp/ran"
capcall "$repo" touch "$tmp/ran"
[[ $code -eq 0 && -e "$tmp/ran" ]] || fail "cap, one other tree: exit $code: $out"
reset_builders
holdline 5 "$repo_tree"
holdline 4 "$ta"
rm -f "$tmp/ran"
capcall "$repo" touch "$tmp/ran"
[[ $code -eq 0 && -e "$tmp/ran" ]] || fail "cap, the calling tree and one other: exit $code: $out"
# With 2 other trees: a release call, a nested call, and a marker call run.
reset_builders
holdline 5 "$ta"
holdline 3 "$tb"
rm -f "$tmp/order" "$tmp/ran"
capcall "$repo" "$fake/make" check-changed BASE=x
[[ $code -eq 0 && -s "$tmp/order" ]] || fail "cap, release call: exit $code: $out"
mkdir "$lock" && echo 4242 > "$lock/pid"
DIRIGIBLE_BUILD_LOCK=4242 capcall "$repo" touch "$tmp/ran"
[[ $code -eq 0 && -e "$tmp/ran" ]] || fail "cap, nested call: exit $code: $out"
rm -rf "$lock"
rm -f "$tmp/order"
DIRIGIBLE_LOCKED_SCRIPT="$fake/make" capcall "$repo" "$fake/make" test
[[ $code -eq 0 && -s "$tmp/order" ]] || fail "cap, marker call: exit $code: $out"
# A release call fills no slot: a make dmg hold line of a third tree and one other builder leave
# the cap open, so an ordinary call takes the lock.
reset_builders
rm -f "$tmp/order" "$tmp/ran"
capcall "$tc" "$fake/make" dmg
[[ $code -eq 0 && "$(tail -n 1 "$holds" | awk -F'\t' '{ print $6 }')" == nocap ]] || fail "cap, make dmg hold line: exit $code [$(tail -n 1 "$holds")]: $out"
holdline 5 "$ta"
capcall "$repo" touch "$tmp/ran"
[[ $code -eq 0 && -e "$tmp/ran" ]] || fail "cap, make dmg hold line and one other tree: exit $code: $out"
# A line ages out after the call starts to wait: the call takes the lock.
reset_builders
printf '%s\t0\tmake test\t%s\n' "$(date -r $(($(date +%s) - 30)) +%FT%T)" "$ta" >> "$holds"
printf '%s\t0\tmake test\t%s\n' "$(date -r $(($(date +%s) - 58)) +%FT%T)" "$tb" >> "$holds"
rm -f "$tmp/ran"
WITH_LOCK_BUILDERS_MIN=1 WITH_LOCK_MAX_WAIT=8 capcall "$repo" touch "$tmp/ran"
[[ $code -eq 0 && -e "$tmp/ran" && "$out" == *"$cap_text"* ]] || fail "cap, a line ages out: exit $code (want 0 after the cap line): $out"
# Waiters do not count: 2 live waiting markers of other trees and one fresh hold line, free lock.
reset_builders
sleep 60 & other=$!
sleep 60 & inner=$!
mkdir -p "$waiting"
echo "$ta" > "$waiting/$other"
echo "$tb" > "$waiting/$inner"
holdline 5 "$tc"
rm -f "$tmp/ran"
capcall "$repo" touch "$tmp/ran"
[[ $code -eq 0 && -e "$tmp/ran" ]] || fail "cap, two waiters and one hold line: exit $code: $out"
kill $other $inner 2>/dev/null
other="" inner=""
# Three calls from three trees: two run, the third waits at the cap.
reset_builders
for dir in "$repo" "$tmp/wt" "$tmp/wt2"; do
  rm -f "$tmp/ran"
  capcall "$dir" touch "$tmp/ran"
  [[ $code -eq 0 && -e "$tmp/ran" ]] || break
done
[[ "$dir" == "$tmp/wt2" && $code -eq 75 && ! -e "$tmp/ran" && "$out" == *"$cap_text: "* && "$out" == *"$repo_tree"* && "$out" == *"$wt_tree"* ]] ||
  fail "cap, three trees: the call of [$dir] has exit $code (want 75 for wt2 after two runs): $out"
# A hold line whose tree path does not exist does not count.
reset_builders
holdline 5 "$ta"
holdline 4 /t/gone-1
holdline 3 /t/gone-2
rm -f "$tmp/ran"
capcall "$repo" touch "$tmp/ran"
[[ $code -eq 0 && -e "$tmp/ran" ]] || fail "cap, trees that do not exist: exit $code: $out"
# A live holder counts, and a live holder of a call with WITH_LOCK_NO_CAP=1 does not. The lock is
# held, so the call waits either way: the cap line tells which.
reset_builders
hold
echo "$ta" > "$lock/tree"
holdline 5 "$tb"
WITH_LOCK_MAX_WAIT=1 capcall "$repo" touch "$tmp/ran"
[[ $code -eq 75 && "$out" == *"$cap_text: $ta, $tb;"* ]] || fail "cap, live holder and one hold line: exit $code, no cap line: $out"
touch "$lock/nocap"
WITH_LOCK_MAX_WAIT=1 capcall "$repo" touch "$tmp/ran"
[[ $code -eq 75 && "$out" != *"$cap_text"* ]] || fail "cap, live nocap holder and one hold line: exit $code, a cap line: $out"
# WITH_LOCK_NO_CAP=1 with 2 other trees: the command runs, and its hold line ends in nocap after an
# empty fifth column. A later ordinary call from a third tree with that line and one other tree runs.
reset_builders
holdline 5 "$ta"
holdline 3 "$tb"
rm -f "$tmp/ran"
WITH_LOCK_NO_CAP=1 capcall "$repo" touch "$tmp/ran"
[[ $code -eq 0 && -e "$tmp/ran" ]] || fail "cap, WITH_LOCK_NO_CAP=1 with 2 other trees: exit $code: $out"
[[ "$(tail -n 1 "$holds" | awk -F'\t' -v t="$repo_tree" '{ print NF, ($4 == t), ($5 == ""), $6 }')" == '6 1 1 nocap' ]] ||
  fail "cap, nocap hold line: [$(tail -n 1 "$holds")]"
reset_builders
holdline 5 "$ta"
WITH_LOCK_NO_CAP=1 capcall "$repo" touch "$tmp/ran"
rm -f "$tmp/ran"
capcall "$tmp/wt" touch "$tmp/ran"
[[ $code -eq 0 && -e "$tmp/ran" ]] || fail "cap, a nocap line and one other tree: exit $code: $out"
# A NO_CAP call that waited writes a wait line with the last column nocap.
reset_builders
hold_for 1
WITH_LOCK_NO_CAP=1 WITH_LOCK_MAX_WAIT=5 capcall "$repo" touch "$tmp/ran"
[[ $code -eq 0 && "$(tail -n 1 "$waits" | awk -F'\t' '{ print NF, $6 }')" == '6 nocap' ]] || fail "cap, nocap wait line: exit $code [$(tail -n 1 "$waits" 2>&1)]: $out"
reset_builders

# The hold limit WITH_LOCK_MAX_HOLD: a command that runs past it gets TERM on its process group,
# then KILL after WITH_LOCK_HOLD_GRACE seconds; the lock goes, the hold line gets the fifth column
# limit, and the call exits 124. A command that ends in time keeps its status, and 0 turns the
# limit off. The default is in $lock/maxhold while the lock is held: 30 min, and for a call with no
# wait limit (a release call, WITH_LOCK_MAX_WAIT=0) 2 times the newest push-check hold in the log,
# at least 60 min.
reset_builders
rm -f "$tmp/inner"
printf '#!/bin/bash\necho $$ > "%s"\ntrap "" TERM\nwhile :; do sleep 0.2; done\n' "$tmp/inner" > "$fake/stubborn"
chmod +x "$fake/stubborn"
t0=$(date +%s)
WITH_LOCK_MAX_HOLD=2 WITH_LOCK_HOLD_GRACE=1 "$repo/scripts/with-lock.sh" "$fake/stubborn" > "$tmp/wait.out" 2>&1 &
waiter=$!
until_true 80 dead "$waiter" || { fail 'hold limit: the call runs past the limit'; kill -KILL "$(cat "$tmp/inner" 2>/dev/null)" "$waiter" 2>/dev/null; }
wait "$waiter" 2>/dev/null
code=$?
waiter=""
elapsed=$(($(date +%s) - t0))
[[ $code -eq 124 && $elapsed -ge 2 && $elapsed -le 6 ]] || fail "hold limit: exit $code after $elapsed s (want 124 in 2 to 6 s): $(cat "$tmp/wait.out")"
[[ ! -e "$lock" ]] || fail 'hold limit: the lock stays'
inner="$(cat "$tmp/inner" 2>/dev/null)"
dead "$inner" || fail 'hold limit: the command still runs'
started="" seconds=0 command="" htree="" word=""
IFS=$'\t' read -r started seconds command htree word < "$holds"
[[ "$word" == limit && "$command" == "$fake/stubborn" && "$seconds" -ge 2 ]] || fail "hold limit: the hold line is [$started] [$seconds] [$command] [$htree] [$word]"
inner=""
# A command that ends in time keeps its status and its four-column hold line; 0 turns the limit off.
reset_builders
WITH_LOCK_MAX_HOLD=5 "$repo/scripts/with-lock.sh" bash -c 'exit 3' > /dev/null 2>&1
code=$?
[[ $code -eq 3 && "$(awk -F'\t' '{ print NF }' "$holds")" == 4 ]] || fail "hold in time: exit $code, hold line [$(cat "$holds" 2>/dev/null)]"
WITH_LOCK_MAX_HOLD=0 "$repo/scripts/with-lock.sh" bash -c 'sleep 2' > /dev/null 2>&1
code=$?
[[ $code -eq 0 ]] || fail "WITH_LOCK_MAX_HOLD=0: exit $code"
# The default limit: 30 min for an ordinary call, 60 min for a release call with no push check in
# the log, and 2 times the newest push-check hold when that is over 30 min. A killed push check
# does not count.
mkdir -p "$tmp/relbin"
printf '#!/bin/bash\ncat "%s/maxhold"\n' "$lock" > "$tmp/relbin/make"
chmod +x "$tmp/relbin/make"
reset_builders
out="$("$repo/scripts/with-lock.sh" bash -c "cat '$lock/maxhold'" 2>&1)"
[[ "$out" == 1800 ]] || fail "default hold limit, ordinary call: [$out]"
out="$(WITH_LOCK_MAX_WAIT=0 "$repo/scripts/with-lock.sh" bash -c "cat '$lock/maxhold'" 2>&1)"
[[ "$out" == 3600 ]] || fail "default hold limit, WITH_LOCK_MAX_WAIT=0, no history: [$out]"
out="$("$repo/scripts/with-lock.sh" "$tmp/relbin/make" check-changed BASE=origin/main 2>&1)"
[[ "$out" == 3600 ]] || fail "default hold limit, release call, no history: [$out]"
printf '%s\t6000\tmake check-changed BASE=origin/main\t/t/a\n%s\t9000\tmake check-changed BASE=origin/main\t/t/a\tlimit\n%s\t100\tmake test\t/t/a\n' "$(ago 300)" "$(ago 200)" "$(ago 100)" > "$holds"
out="$(WITH_LOCK_MAX_WAIT=0 "$repo/scripts/with-lock.sh" bash -c "cat '$lock/maxhold'" 2>&1)"
[[ "$out" == 12000 ]] || fail "default hold limit, WITH_LOCK_MAX_WAIT=0, newest push check 6000 s: [$out]"
out="$("$repo/scripts/with-lock.sh" "$tmp/relbin/make" check-changed BASE=origin/main 2>&1)"
[[ "$out" == 12000 ]] || fail "default hold limit, release call, newest push check 6000 s: [$out]"
out="$(WITH_LOCK_MAX_HOLD=77 "$repo/scripts/with-lock.sh" bash -c "cat '$lock/maxhold'" 2>&1)"
[[ "$out" == 77 ]] || fail "WITH_LOCK_MAX_HOLD=77: [$out]"
# --builders prints the hold seconds of the live holder, and its limit when the lock folder has one.
reset_builders
hold
echo /t/holder > "$lock/tree"
echo 1800 > "$lock/maxhold"
touch -t "$(date -r $(($(date +%s) - 100)) +%Y%m%d%H%M.%S)" "$lock/pid"
out="$("$repo/scripts/with-lock.sh" --builders 2>&1)"
[[ "$out" =~ holder:\ /t/holder\ held\ (99|100|101|102)\ s\ of\ 1800\ s ]] || fail "--builders, hold seconds: [$out]"
reset_builders

[[ $failures -eq 0 ]] && echo "with-lock tests: all passed"
exit $((failures > 0))
