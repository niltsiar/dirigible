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
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE DIRIGIBLE_BUILD_LOCK WITH_LOCK_MAX_WAIT WITH_LOCK_MAX_HOLD
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
for kind in release mark mutation zero; do
  hold_for 3
  rm -f "$tmp/ran" "$tmp/order"
  case "$kind" in
    release) WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 "$repo/scripts/with-lock.sh" "$fake/make" check-changed BASE=origin/main ;;
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
out="$(cd "$repo" && MAKE="$fake/rcmake" WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 scripts/run-checks.sh test 2>&1)"
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
