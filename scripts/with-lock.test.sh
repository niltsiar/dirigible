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
# default with a fake clock, run-checks.sh: no limit only for a push check, and a lock-free make check-changed FILTER call, which exits 75 with the real make, also with a test-app whose app step exits 75), scripts/bundle.sh
# (it takes the lock itself after its path check, and keeps the wait limit and the cap), and --release-holder (a live
# release holder or ticket gives exit 0, any other state exit 1, also inside a locked process tree), --long-holder (the same, plus a
# bench, mutation-pass, or flake-loop holder and a live bench marker, but no bench-pairs.sh --compare or --lines holder), and the hold limit
# (exit 124; a command that creates <lock>/shard-limit gets the column limit and keeps its exit), and --bench-mark (a marker in
# dirigible-bench-marks/ blocks each lock-free call, a lock-free call keeps a file in dirigible-lock-free/ while it runs and the
# marked call waits for it, a file of a reused pid, two marked calls that start together, the load wait, and the refusal of a
# lock-class command). Each case uses a temporary repo with a worktree, so the lock of an outer
# with-lock.sh call is not touched.
# Run by scripts/bench-pairs.test.sh, which make test-hooks runs.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/with-lock.sh"
failures=0
tmp="$(mktemp -d)"
holder="" child="" waiter="" inner="" other=""
trap 'kill $holder $child $waiter $inner $other 2>/dev/null; chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
# The value of an outer with-lock.sh call names another lock.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE DIRIGIBLE_BUILD_LOCK DIRIGIBLE_BENCH_MARK WITH_LOCK_MAX_WAIT WITH_LOCK_MAX_HOLD WITH_LOCK_BUILDERS_MIN WITH_LOCK_BUILDERS_FLOOR WITH_LOCK_RUN_ONLY BASE MAKEFLAGS SINCE
export WITH_LOCK_RETRY=0.1
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
# A pid variable can outlive its child, and the kernel can give the number to a process of another
# tree. kill below signals a pid only when it descends from this shell (kill -0 stays a plain probe).
mine() {
  local p n=0
  p="$(ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ')"
  while [[ "$p" =~ ^[0-9]+$ && $p -gt 1 && $((n++)) -lt 8 ]]; do
    [[ "$p" == "$$" ]] && return 0
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  return 1
}
kill() {
  local sig=-TERM arg pid sent=1
  local -a pids=()
  for arg in "$@"; do
    case "$arg" in
      --) ;;
      -*) sig="$arg" ;;
      *) pids+=("$arg") ;;
    esac
  done
  if [[ "$sig" == -0 ]]; then builtin kill -0 ${pids[@]+"${pids[@]}"}; return; fi
  for pid in ${pids[@]+"${pids[@]}"}; do
    mine "$pid" && builtin kill "$sig" "$pid" 2>/dev/null && sent=0
  done
  return $sent
}

repo="$tmp/repo" lock="$tmp/repo/.git/dirigible-build.lock" waits="$tmp/repo/.git/dirigible-build-waits.log"
mkdir -p "$repo/scripts"
cp "$script" "$repo/scripts/with-lock.sh" && cp "${script%/*}/lock-words.sh" "$repo/scripts/lock-words.sh"
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
# Each exit 75 appends a wait line whose sixth column is exit75. A call whose command and tree have
# an exit75 line that ended under 10 min before the call started also prints the hand-back route
# after the first line. x75 <tree> <command...>: one call from <tree> behind the live holder, with
# a limit of 1 s.
x75() {
  local t="$1"
  shift
  out="$(cd "$t" && WITH_LOCK_MAX_WAIT=1 "$t/scripts/with-lock.sh" "$@" 2>&1)"
  code=$?
}
again='still waiting after 1 s (WITH_LOCK_MAX_WAIT); run the same command again'
route='remaining locked steps as one bash file in the run folder'
rm -f "$waits" "$tmp/ran"
hold
echo 'make test' > "$lock/command"
x75 "$repo" touch "$tmp/ran"
[[ $code -eq 75 && "$(sed -n 1p <<<"$out")" == *"held by pid $holder"* && "$out" == *"$again" && "$out" != *'second exit 75'* && "$out" != *"$route"* ]] ||
    fail "first exit 75: exit $code, a route line or no rerun line: $out"
started="" seconds=0 command="" held="" wtree="" kind=""
IFS=$'\t' read -r started seconds command held wtree kind < "$waits"
[[ "$(wc -l < "$waits" | tr -d ' ')" == 1 && "$started" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T && "$seconds" -ge 1 && "$command" == "touch $tmp/ran" && "$held" == 'make test' && "$wtree" == "$repo_tree" && "$kind" == exit75 ]] ||
    fail "first exit 75: the wait line [$(cat "$waits" 2>/dev/null)]"
x75 "$repo" touch "$tmp/ran"
[[ $code -eq 75 && ! -e "$tmp/ran" && "$out" == *"$again"$'\n'"with-lock: second exit 75 of this command in this tree since $started"* ]] ||
    fail "second exit 75: exit $code, no second-exit line after the rerun line: $out"
[[ "$out" == *"$route"* && "$out" == *'set -euo pipefail and a cd to the worktree'* && "$out" == *'no DIRIGIBLE_LOCKED_SCRIPT line'* && "$out" == *'the lead runs that file as WITH_LOCK_MAX_WAIT=0 bash <file>, and its own command as WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh <command>, with run_in_background'* ]] ||
    fail "second exit 75: no hand-back route: $out"
[[ "$(awk -F'\t' '$6 == "exit75"' "$waits" | wc -l | tr -d ' ')" == 2 && "$(cat "$lock/pid")" == "$holder" ]] ||
    fail "second exit 75: the wait lines [$(cat "$waits" 2>/dev/null)] or the holder"
route_err="$(cd "$repo" && WITH_LOCK_MAX_WAIT=1 "$repo/scripts/with-lock.sh" touch "$tmp/ran" 2>/dev/null)"
[[ -z "$route_err" ]] || fail "second exit 75: the route is on stdout: $route_err"
# Near cases with no route: another command, the same command from another tree, a line that ended
# 11 min before. The age is that of the end of the earlier call (start plus wait), so a limit of
# 300 s still finds the first exit 75 (start 610 s before, end 310 s before).
x75 "$repo" touch "$tmp/ran2"
[[ $code -eq 75 && "$out" != *'second exit 75'* ]] || fail "exit 75 of another command: exit $code, a route line: $out"
x75 "$tmp/wt" touch "$tmp/ran"
[[ $code -eq 75 && "$out" != *'second exit 75'* ]] || fail "exit 75 from another tree: exit $code, a route line: $out"
for age in 780:120 660:120 610:300; do
  rm -f "$waits"
  printf '%s\t%s\ttouch %s\tmake test\t%s\texit75\n' "$(date -r $(($(date +%s) - ${age%:*})) +%FT%T)" "${age#*:}" "$tmp/ran" "$repo_tree" > "$waits"
  x75 "$repo" touch "$tmp/ran"
  case "$age" in
    780:120) [[ $code -eq 75 && "$out" != *'second exit 75'* ]] || fail "exit 75 after a line that ended 11 min before: exit $code, a route line: $out" ;;
    *) [[ $code -eq 75 && "$out" == *'second exit 75'* ]] || fail "exit 75 after a line $age (start:wait) that ended under 10 min before: exit $code, no route line: $out" ;;
  esac
done
# The 10 min count ends at the start of this call, not at its end, so the wait limit of this call
# does not shrink it: a line that ended 597 s before a call with a limit of 3 s gets the route.
rm -f "$waits"
printf '%s\t300\ttouch %s\tmake test\t%s\texit75\n' "$(date -r $(($(date +%s) - 897)) +%FT%T)" "$tmp/ran" "$repo_tree" > "$waits"
out="$(cd "$repo" && WITH_LOCK_MAX_WAIT=3 "$repo/scripts/with-lock.sh" touch "$tmp/ran" 2>&1)"
code=$?
[[ $code -eq 75 && "$out" == *'second exit 75'* && "$out" == *"$route"* ]] || fail "exit 75 at a limit of 3 s after a line that ended 597 s before this call: exit $code, no route: $out"
# With no waits log to write, the call cannot count its exit 75, so it prints the route each time.
rm -f "$waits"
mkdir "$waits"
x75 "$repo" touch "$tmp/ran"
[[ $code -eq 75 && "$out" == *'cannot be written'* && "$out" == *'prints the route at each exit 75; take the route below only after a second exit 75 of this command'* && "$out" == *"$route"* ]] ||
  fail "exit 75 with no waits log: exit $code, no route or no line that says when to take it: $out"
rmdir "$waits"
clear_hold
rm -f "$waits"
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
# run-checks.sh exports WITH_LOCK_MAX_WAIT=0 only for a push check (BASE set), so the recipe call of
# a slice test keeps the wait limit and run-checks.sh ends in exit 75. The fake make calls
# with-lock.sh as the recipe does, and prints the make error line of a failed recipe.
cp "$(dirname "$script")/run-checks.sh" "$repo/scripts/run-checks.sh"
printf '#!/bin/bash\nexit 0\n' > "$repo/scripts/check-changed.sh"
printf '#!/bin/bash\nexit 0\n' > "$repo/scripts/check-commits.sh"
printf '#!/bin/bash\n%q touch %q || { c=$?; echo "make: *** [test] Error $c" >&2; exit 2; }\n' "$repo/scripts/with-lock.sh" "$tmp/ran" > "$fake/rcmake"
chmod +x "$repo/scripts/check-changed.sh" "$repo/scripts/check-commits.sh" "$fake/rcmake"
hold
rm -f "$tmp/ran"
out="$(cd "$repo" && env -u BASE MAKE="$fake/rcmake" WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 scripts/run-checks.sh test 2>&1)"
code=$?
[[ $code -eq 75 && ! -e "$tmp/ran" && "$out" == *'still waiting after 2 s'* ]] || fail "run-checks.sh, no BASE: the recipe call keeps the wait limit: exit $code (want 75): $out"
clear_hold
hold_for 4
rm -f "$tmp/ran"
out="$(cd "$repo" && BASE=HEAD MAKE="$fake/rcmake" WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 scripts/run-checks.sh test 2>&1)"
code=$?
[[ $code -eq 0 && -e "$tmp/ran" ]] || fail "run-checks.sh, BASE set: the recipe call stops at the limit of the caller: exit $code: $out"
clear_hold

# Builders. A release appends one hold line to dirigible-build-holds.log: the start, the hold
# seconds, the command, and the tree. The lock folder keeps $lock/tree while a call holds it, and a
# waiting call keeps the marker dirigible-build-waiting/<pid> with its tree. --builders prints each
# existing tree whose hold lines ended in the last WITH_LOCK_BUILDERS_MIN minutes (default 20) and
# add up to WITH_LOCK_BUILDERS_FLOOR seconds or more (default 10), the live holder, and each live
# waiter. A wait with 2 or more other trees prints the count.
holds="$repo/.git/dirigible-build-holds.log" waiting="$repo/.git/dirigible-build-waiting"
reset_builders() { clear_hold; rm -rf "$lock" "$waits" "$holds" "$waiting" "$first"; }
# A make check-changed call whose targets build no Swift or lock each Swift call themselves
# (check-docs, check-fast, static, test-app, lint, format, none, test, test-filter, or a word with =), and a make
# test-hooks call with a HOOK_TESTS= word, run at once with no lock, no wait line, and no hold line,
# while an ordinary build or test holds the lock. While a release call, a bench, a mutation pass, or
# a flake loop holds the lock, they wait without taking the lock (the cases below). The fake
# check-changed.sh prints $FAKE_TARGETS, logs the FILTER value, prints $FAKE_STDERR on stderr, and
# exits $FAKE_EXIT.
cat > "$repo/scripts/check-changed.sh" << 'EOF'
#!/bin/bash
if [[ "${1:-}" == --wait-load && -n "${BM_LOG:-}" ]]; then # the load wait of a bench marker: logs, blocks while $BM_GATE exists
    echo "wait-load $*" >> "$BM_LOG"
    while [[ -e "${BM_GATE:-/nonexistent}" ]]; do sleep 0.1; done
    [[ -z "${BM_LOAD_STOP:-}" ]] || echo "$BM_LOAD_STOP"
    exit "${BM_LOAD_EXIT:-0}"
fi
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
# until the limit of 2 s (wait, or freewait for a lock-free call, which prints its line first). It leaves the holder, the wait log, and the hold log as they were.
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
    elif [[ $expect == freewait ]]; then
        [[ $code -eq 75 && ! -s "$tmp/order" && "$out" == *'no lock; it waits while'* ]] || fail "lock-free, $label: exit $code (want 75), order [$(cat "$tmp/order" 2>/dev/null)]: $out"
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
FAKE_TARGETS="check-fast test-filter test-app" lockfree run "targets check-fast test-filter test-app" "$fake/make" check-changed
FAKE_TARGETS="check-fast test-filter test-app" lockfree run "test-app with a FILTER word" "$fake/make" check-changed FILTER=ATests
[[ "$(cat "$FAKE_FILTER_LOG")" == ATests ]] || fail "lock-free: check-changed.sh got FILTER [$(cat "$FAKE_FILTER_LOG")], not ATests"
FAKE_TARGETS="static test-filter test-app" lockfree run "targets static test-filter test-app with a FILTER word" "$fake/make" check-changed FILTER=ATests
FAKE_TARGETS="static" lockfree run "targets static" "$fake/make" check-changed
FAKE_TARGETS="check" lockfree wait "targets check" "$fake/make" check-changed
FAKE_TARGETS="test-dmg" lockfree wait "targets test-dmg" "$fake/make" check-changed
FAKE_TARGETS="check-fast test-filter test-app bench" lockfree wait "targets check-fast test-filter test-app bench" "$fake/make" check-changed
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
[[ $code -eq 75 && ! -s "$tmp/order" && "$out" == *'no lock; it waits while'* ]] ||
    fail "lock-free, holder with BASE in its environment: exit $code (want 75), order [$(cat "$tmp/order" 2>/dev/null)]: $out"
reset_builders
# make test-hooks: a HOOK_TESTS= word runs at once; the bare goal waits.
lockfree run "test-hooks with HOOK_TESTS" "$fake/make" test-hooks HOOK_TESTS=a,b
lockfree wait "test-hooks with no HOOK_TESTS" "$fake/make" test-hooks
lockfree wait "test-hooks with an empty HOOK_TESTS" "$fake/make" test-hooks HOOK_TESTS=
lockfree wait "test-hooks, the goal twice" "$fake/make" test-hooks test-hooks HOOK_TESTS=a
lockfree wait "test-hooks, env before make" env "$fake/make" test-hooks HOOK_TESTS=a
lockfree wait "test-hooks, a make flag" "$fake/make" -s test-hooks HOOK_TESTS=a
# A copy of with-lock.sh with no lock-words.sh beside it fails closed: it runs nothing and names the file.
mkdir -p "$tmp/nolw/scripts"
git -C "$tmp/nolw" init -q
cp "$script" "$tmp/nolw/scripts/with-lock.sh"
out="$("$tmp/nolw/scripts/with-lock.sh" touch "$tmp/nolw/ran" 2>&1)"
code=$?
[[ $code -eq 2 && ! -e "$tmp/nolw/ran" && "$out" == *scripts/lock-words.sh* ]] ||
    fail "no lock-words.sh: exit $code (want 2), ran [$(ls "$tmp/nolw/ran" 2>/dev/null)]: $out"
# The slice call of an agent, make check-changed FILTER=x, is lock-free. A recipe that exits 75 gives
# the make line "Error 75" and make exits 2, so the call turns that line back into exit 75. The
# case runs the real make, the check-changed recipe of the Makefile, and run-checks.sh; the test-filter
# recipe is a with-lock.sh call (as swift-test.sh is) that waits behind a live holder. A recipe that
# fails for another reason keeps exit 2.
reset_builders
{ printf 'FILTER ?=\nBASE ?=\nRECIPE ?= %s touch %s\n' "$repo/scripts/with-lock.sh" "$tmp/ran"
  awk '/^check-changed:/ { p = 1 } p { print } p && /^$/ { exit }' "$(dirname "$script")/../Makefile"
  printf 'test-filter:\n\t@$(RECIPE)\n'
  printf 'test-app: app\n\t@touch %s\napp:\n\t@exit 75\n' "$tmp/appran"; } > "$repo/Makefile"
hold
rm -f "$tmp/ran"
out="$(cd "$repo" && FAKE_TARGETS=test-filter WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 scripts/with-lock.sh make check-changed FILTER=x 2>&1)"
code=$?
[[ $code -eq 75 && ! -e "$tmp/ran" && "$out" == *'lock-free targets (test-filter)'* && "$out" == *'still waiting after 2 s'* ]] ||
    fail "lock-free, check-changed FILTER with a lock wait in the recipe: exit $code (want 75): $out"
out="$(cd "$repo" && FAKE_TARGETS=test-filter scripts/with-lock.sh make check-changed FILTER=x 'RECIPE=exit 1' 2>&1)"
code=$?
[[ $code -eq 2 && "$out" == *'lock-free targets (test-filter)'* ]] ||
    fail "lock-free, check-changed FILTER with a red recipe: exit $code (want 2): $out"
# The app step of test-app (scripts/bundle.sh takes the lock itself) exits 75 at its limit: the
# lock-free call exits 75 and AppBundleTests do not run.
rm -f "$tmp/appran"
out="$(cd "$repo" && FAKE_TARGETS=test-app scripts/with-lock.sh make check-changed FILTER=x 2>&1)"
code=$?
[[ $code -eq 75 && ! -e "$tmp/appran" && "$out" == *'lock-free targets (test-app)'* ]] ||
    fail "lock-free, check-changed FILTER with a test-app whose app step exits 75: exit $code (want 75): $out"
clear_hold
rm -f "$repo/Makefile"
# A TERM to a lock-free call stops the command and its children, which the call runs as a child.
printf '#!/bin/bash\nsleep 30 &\necho "$$ $!" > "%s"\nwait\n' "$tmp/freepid" > "$fake/slow/make"
rm -f "$tmp/freepid"
FAKE_TARGETS=check-docs "$repo/scripts/with-lock.sh" "$fake/slow/make" check-changed > "$tmp/wait.out" 2>&1 &
waiter=$!
until_true 50 test -s "$tmp/freepid" || fail "lock-free TERM of the command: the command did not start: $(cat "$tmp/wait.out")"
kill -TERM "$waiter"
wait "$waiter" 2>/dev/null
code=$?
sleep 0.3
read -r make_pid sleep_pid < "$tmp/freepid"
{ [[ $code -eq 143 ]] && dead "$make_pid" && dead "$sleep_pid"; } || fail "lock-free TERM of the command: exit $code, command pids [$make_pid $sleep_pid] alive"
waiter=""
# A holder that is a release call, a bench, a mutation pass, or a flake loop keeps the wait; an
# ordinary build or test does not.
for holder_command in "make check-changed BASE=origin/main" "$repo/scripts/land.sh x" "make dmg" "$repo/scripts/bench.sh x" "$repo/scripts/bench-pairs.sh x" \
    "$repo/scripts/mutation-pass.sh $repo batch" "$repo/scripts/flake-monitor/loop.sh x" "bash $repo/scripts/flake-monitor/loop.sh x" \
    "$repo/scripts/test-stress.sh --runs 1 out" "make bench FILTER=HeaderDragBenchmark" "make bench FILTER=ATests BTests" "make FILTER=ATests bench" "make DMG_X=1 dmg"; do
    FAKE_TARGETS="check-docs" HOLDER_COMMAND="$holder_command" lockfree freewait "holder $holder_command" "$fake/make" check-changed
done
for holder_command in "make test-filter ATests" "make test-filter FILTER=bench" "make benchmark-gate" "bash $repo/scripts/test-stress.test.sh"; do
    FAKE_TARGETS="check-docs" HOLDER_COMMAND="$holder_command" lockfree run "holder $holder_command" "$fake/make" check-changed
done
reset_builders

# A bench marker: with-lock.sh --bench-mark <command> times a shell script or a hook test while no
# lock-free call runs. A lock-free call keeps a file in dirigible-lock-free/ while it runs, and a
# marked call keeps a file in dirigible-bench-marks/. The fake check-changed.sh answers the load
# wait (--wait-load bench) and logs it to $BM_LOG, with the fake make of $fake/bm and the stubs.
# bm_start <case name> [command...] runs the marked call in the background and returns 0 when its
# marker file exists. If no file appears in 5 s, or the call ends first, it fails with the stderr
# of the call and returns 1, so each case asserts only after a 0.
marks="$repo/.git/dirigible-bench-marks" frees="$repo/.git/dirigible-lock-free" bmlog="$tmp/bm.log"
export BM_LOG="$bmlog"
mkdir -p "$fake/bm" "$repo/.build/debug"
printf '#!/bin/bash\necho "L-start $*" >> "$BM_LOG"\nsleep "${BM_SLEEP:-0}"\necho L-end >> "$BM_LOG"\n' > "$fake/bm/make"
printf '#!/bin/bash\necho "RAN-swift $*" >> "$BM_LOG"\n' > "$fake/bm/swift"
printf '#!/bin/bash\necho W-start >> "$BM_LOG"\nsleep 2\necho W-end >> "$BM_LOG"\n' > "$repo/.build/debug/whisper"
printf '#!/bin/bash\necho "RAN-built $*" >> "$BM_LOG"\n' > "$repo/.build/debug/stub"
for stub in land probe swift-test test-shards check-waits mutation-pass screenshots bundle; do
    printf '#!/bin/bash\necho "RAN-%s $*" >> "$BM_LOG"\n' "$stub" > "$repo/scripts/$stub.sh"
    chmod +x "$repo/scripts/$stub.sh"
done
chmod +x "$fake/bm/make" "$fake/bm/swift" "$repo/.build/debug/whisper" "$repo/.build/debug/stub"
bm_events() { awk '{ print $1 }' "$bmlog" | paste -sd' ' -; }
bm_files() { find "$marks" "$frees" -type f 2>/dev/null | paste -sd' ' -; }
free_up() { [[ -n "$(ls -A "$frees" 2>/dev/null)" ]]; }
bm_ready() { [[ -n "$(ls -A "$marks" 2>/dev/null)" ]] || ! kill -0 "$waiter" 2>/dev/null; }
is() { [[ "$2" == "$3" ]] || fail "$1: [$2] want [$3]"; }
bm_start() {
    local name="$1"
    shift
    [[ $# -gt 0 ]] || set -- bash -c 'sleep 8'
    : > "$bmlog"
    "$repo/scripts/with-lock.sh" --bench-mark "$@" > "$tmp/bm.out" 2> "$tmp/bm.err" &
    waiter=$!
    until_true 50 bm_ready || true
    [[ -z "$(ls -A "$marks" 2>/dev/null)" ]] || return 0
    kill "$waiter" 2>/dev/null
    wait "$waiter" 2>/dev/null
    fail "$name: no bench marker file; the marked call ended first or ran on for 5 s: $(tr '\n' ' ' < "$tmp/bm.err")"
    waiter=""
    return 1
}
bm_end() { kill "$waiter" 2>/dev/null; wait "$waiter" 2>/dev/null; waiter=""; }
# A pid that is dead: its files are stale.
( : ) & gone=$!
wait "$gone"
reset_builders
rm -rf "$marks" "$frees"

# A live marker blocks a lock-free test-hooks call, a lock-free check-changed call, and a run-only
# call (the Whisper form). The wait line names the marker, and the stderr line ends with the marker.
if bm_start 'marker blocks test-hooks'; then
    rm -f "$tmp/order" "$tmp/ran"
    out="$(WITH_LOCK_MAX_WAIT=1 WITH_LOCK_RETRY=0.5 "$repo/scripts/with-lock.sh" "$fake/make" test-hooks HOOK_TESTS=a 2>&1)"
    code=$?
    is 'marker blocks test-hooks: exit' "$code" 75
    [[ ! -s "$tmp/order" ]] || fail "marker blocks test-hooks: the command ran: $(cat "$tmp/order")"
    [[ "$out" == *'lock-free targets'* && "$out" == *'holds the lock, or while a bench marker is live'* ]] ||
        fail "marker blocks test-hooks: the lock-free line: $out"
    is 'marker blocks test-hooks: marker lines' "$(grep -c "bench marker pid $waiter (" <<<"$out")" 1
    is 'marker blocks test-hooks: held by pid lines' "$(grep -c 'held by pid' <<<"$out")" 0
    is 'marker file name' "$(ls "$marks")" "$waiter"
    out="$(FAKE_TARGETS=check-docs WITH_LOCK_MAX_WAIT=1 WITH_LOCK_RETRY=0.5 "$repo/scripts/with-lock.sh" "$fake/make" check-changed 2>&1)"
    code=$?
    [[ $code -eq 75 && ! -s "$tmp/order" ]] || fail "marker blocks check-changed: exit $code, order [$(cat "$tmp/order" 2>/dev/null)]: $out"
    printf '#!/bin/bash\ntouch "%s"\n' "$tmp/ran" > "$tmp/ro.sh"
    out="$(WITH_LOCK_RUN_ONLY=1 WITH_LOCK_MAX_WAIT=1 WITH_LOCK_RETRY=0.5 "$repo/scripts/with-lock.sh" bash "$tmp/ro.sh" 2>&1)"
    code=$?
    [[ $code -eq 75 && ! -e "$tmp/ran" ]] || fail "marker blocks run-only: exit $code, ran [$(ls "$tmp/ran" 2>/dev/null)]: $out"
    out="$(WITH_LOCK_MAX_WAIT=5 "$repo/scripts/with-lock.sh" bash -c 'echo ok' 2>&1)"
    code=$?
    [[ $code -eq 0 && "$out" == ok ]] || fail "lock taker ignores the marker: exit $code: $out"
    out="$("$repo/scripts/with-lock.sh" --release-holder 2>&1)"
    code=$?
    [[ $code -eq 1 && -z "$out" ]] || fail "marker and --release-holder: exit $code, output [$out]"
    is 'marker and --builders' "$("$repo/scripts/with-lock.sh" --builders 2>&1)" ""
    [[ ! -e "$lock" && -z "$(ls "$waiting" 2>/dev/null)" ]] || fail 'marker and the queries: a lock folder or a waiting marker'
    bm_end
fi
is 'marker gone after the end' "$(bm_files)" ""

# The marked command: its exit status passes, the usage line gives exit 2, and a TERM to the call
# stops the command and removes the marker. The command gets DIRIGIBLE_BENCH_MARK=<pid of the call>,
# so a lock-free call inside it runs at once.
: > "$bmlog"
"$repo/scripts/with-lock.sh" --bench-mark bash -c 'exit 7' > /dev/null 2>&1
is 'marker exit status' "$?" 7
"$repo/scripts/with-lock.sh" --bench-mark > /dev/null 2>&1
is 'marker usage' "$?" 2
rm -f "$tmp/dbm"
if bm_start 'marked command runs a lock-free call' bash -c "BM_SLEEP=1 '$repo/scripts/with-lock.sh' '$fake/bm/make' test-hooks HOOK_TESTS=a; echo \$DIRIGIBLE_BENCH_MARK > '$tmp/dbm'"; then
    marked=$waiter
    wait "$waiter"
    is 'marked command with a lock-free call: exit' "$?" 0
    waiter=""
    is 'DIRIGIBLE_BENCH_MARK in the command' "$(cat "$tmp/dbm" 2>/dev/null)" "$marked"
    is 'lock-free call inside the marked command' "$(bm_events)" 'wait-load L-start L-end'
fi
rm -f "$tmp/freepid"
if bm_start 'marker TERM' bash -c "sleep 30 & echo \$! > '$tmp/freepid'; wait"; then
    until_true 50 test -s "$tmp/freepid" || fail 'marker TERM: the command did not start'
    kill -TERM "$waiter"
    wait "$waiter" 2>/dev/null
    code=$?
    waiter=""
    sleep 0.3
    is 'marker TERM: exit' "$code" 143
    is 'marker TERM: marker' "$(bm_files)" ""
    dead "$(cat "$tmp/freepid")" || fail 'marker TERM: the command is alive'
fi

# Marked calls and lock holders: an ordinary holder is ignored (the call runs, no lock is taken), a
# long holder (make dmg) makes the call wait without a marker (exit 75 at the limit), the wait ends
# when the holder ends (one wait line of 6 columns that ends lockfree), a live ticket of a release
# call makes it wait, and a second marker makes it wait until the first ends.
: > "$bmlog"
reset_builders
hold
echo 'make test-filter ATests' > "$lock/command"
out="$("$repo/scripts/with-lock.sh" --bench-mark bash -c "echo ran > '$tmp/ran2'" 2>&1)"
code=$?
[[ $code -eq 0 && -s "$tmp/ran2" && "$(cat "$lock/pid")" == "$holder" && -z "$(bm_files)" ]] ||
    fail "marker call, ordinary holder: exit $code, files [$(bm_files)]: $out"
reset_builders
rm -f "$tmp/ran2"
hold
echo 'make dmg' > "$lock/command"
out="$(WITH_LOCK_MAX_WAIT=1 WITH_LOCK_RETRY=0.5 "$repo/scripts/with-lock.sh" --bench-mark bash -c "echo ran > '$tmp/ran2'" 2>&1)"
code=$?
[[ $code -eq 75 && ! -e "$tmp/ran2" && -z "$(bm_files)" && "$(grep -c "held by pid $holder" <<<"$out")" == 1 ]] ||
    fail "marker call, long holder: exit $code, files [$(bm_files)]: $out"
reset_builders
hold_for 1
echo 'make dmg' > "$lock/command"
out="$(WITH_LOCK_MAX_WAIT=10 "$repo/scripts/with-lock.sh" --bench-mark bash -c "echo ran > '$tmp/ran2'" 2>&1)"
code=$?
[[ $code -eq 0 && -s "$tmp/ran2" && "$(wc -l < "$waits" | tr -d ' ')" == 1 && "$(awk -F'\t' '{ print NF, $4, $NF }' "$waits")" == '6 make dmg lockfree' ]] ||
    fail "marker call, holder ends: exit $code, wait line [$(cat "$waits" 2>/dev/null)]: $out"
reset_builders
rm -f "$tmp/ran2"
sleep 60 & inner=$!
mkdir -p "$first/$inner"
out="$(WITH_LOCK_MAX_WAIT=1 WITH_LOCK_RETRY=0.5 "$repo/scripts/with-lock.sh" --bench-mark bash -c "echo ran > '$tmp/ran2'" 2>&1)"
code=$?
[[ $code -eq 75 && ! -e "$tmp/ran2" && -z "$(bm_files)" ]] || fail "marker call, release ticket: exit $code: $out"
kill "$inner" 2>/dev/null
wait "$inner" 2>/dev/null
inner=""
reset_builders
if bm_start 'marker call, second marker' bash -c 'sleep 1.5'; then
    first_marker=$waiter
    out="$(WITH_LOCK_MAX_WAIT=1 WITH_LOCK_RETRY=0.5 "$repo/scripts/with-lock.sh" --bench-mark bash -c 'echo ran' 2>&1)"
    is 'marker call, second marker, at the limit: exit' "$?" 75
    is 'marker call, second marker: cause lines' "$(grep -c "bench marker pid $first_marker (" <<<"$out")" 1
    out="$(WITH_LOCK_MAX_WAIT=20 "$repo/scripts/with-lock.sh" --bench-mark bash -c "[[ ! -e '$marks/$first_marker' ]] && touch '$tmp/ran3'" 2>&1)"
    code=$?
    [[ $code -eq 0 && -e "$tmp/ran3" ]] || fail "marker call, second marker: the second call ran while the first marker lived: exit $code: $out"
    wait "$waiter" 2>/dev/null
    waiter=""
fi
rm -f "$tmp/ran3"
reset_builders
if bm_start 'wait line names the marker' bash -c 'sleep 1.5'; then
    WITH_LOCK_MAX_WAIT=10 "$repo/scripts/with-lock.sh" "$fake/bm/make" test-hooks HOOK_TESTS=d > /dev/null 2>&1
    wait "$waiter" 2>/dev/null
    waiter=""
    is 'wait line names the marker' "$(awk -F'\t' '{ print NF, substr($4, 1, 16), $NF }' "$waits" 2>/dev/null)" '6 bench marker pid lockfree'
fi

# A lock-free call that runs when the marked call starts: the marked command starts after it ends,
# and a lock-free call that starts after the marker waits for the command. The file of the
# lock-free call is named after its pid while it runs.
: > "$bmlog"
reset_builders
BM_SLEEP=2 "$repo/scripts/with-lock.sh" "$fake/bm/make" test-hooks HOOK_TESTS=a > "$tmp/free.out" 2>&1 &
inner=$!
until_true 50 free_up || fail 'lock-free call in flight: no lock-free file'
is 'lock-free file name' "$(ls "$frees" 2>/dev/null)" "$inner"
WITH_LOCK_MAX_WAIT=30 "$repo/scripts/with-lock.sh" --bench-mark bash -c "echo M-start >> '$bmlog'; sleep 0.3; echo M-end >> '$bmlog'" > "$tmp/bm.out" 2>&1
is 'lock-free call in flight, then the marked call: exit' "$?" 0
wait "$inner"
inner=""
is 'lock-free call in flight, then the marked call: order' "$(bm_events)" 'L-start L-end wait-load M-start M-end'
is 'lock-free call in flight, then the marked call: files left' "$(bm_files)" ""
if bm_start 'marked call, then a lock-free call' bash -c "echo M-start >> '$bmlog'; sleep 1.5; echo M-end >> '$bmlog'"; then
    out="$(WITH_LOCK_MAX_WAIT=30 "$repo/scripts/with-lock.sh" "$fake/bm/make" test-hooks HOOK_TESTS=b 2>&1)"
    is 'marked call, then a lock-free call: exit' "$?" 0
    wait "$waiter" 2>/dev/null
    waiter=""
    is 'marked call, then a lock-free call: order' "$(bm_events)" 'wait-load M-start M-end L-start L-end'
fi
# Both start in the same instant: the two never overlap, and neither ends in exit 75.
bad=0
for round in $(seq 10); do
    : > "$bmlog"
    BM_SLEEP=0.2 WITH_LOCK_MAX_WAIT=30 "$repo/scripts/with-lock.sh" "$fake/bm/make" test-hooks HOOK_TESTS=r > /dev/null 2>&1 &
    inner=$!
    WITH_LOCK_MAX_WAIT=30 "$repo/scripts/with-lock.sh" --bench-mark bash -c "echo M-start >> '$bmlog'; sleep 0.2; echo M-end >> '$bmlog'" > /dev/null 2>&1 &
    waiter=$!
    wait "$inner"
    code1=$?
    wait "$waiter"
    code2=$?
    inner="" waiter=""
    seq_="$(awk '$1 != "wait-load" { print $1 }' "$bmlog" | paste -sd' ' -)"
    case "$seq_:$code1:$code2" in
        'L-start L-end M-start M-end:0:0' | 'M-start M-end L-start L-end:0:0') ;;
        *) bad=$((bad + 1)); fail "start together, round $round: events [$seq_], exits $code1 and $code2" ;;
    esac
done
is 'start together: rounds with an overlap' "$bad" 0

# The load wait: the marker lives while check-changed.sh --wait-load bench blocks, the command waits
# for it, and a lock-free call waits. A failing load wait gives exit 2, no command, and no marker.
: > "$tmp/gate"
if BM_GATE="$tmp/gate" bm_start 'load wait' bash -c "echo M-start >> '$bmlog'"; then
    sleep 0.5
    is 'load wait: the command waits' "$(grep -c M-start "$bmlog")" 0
    is 'load wait: marker' "$(ls "$marks" | wc -l | tr -d ' ')" 1
    WITH_LOCK_MAX_WAIT=1 WITH_LOCK_RETRY=0.5 "$repo/scripts/with-lock.sh" "$fake/bm/make" test-hooks HOOK_TESTS=c > /dev/null 2>&1
    is 'load wait: a lock-free call exits' "$?" 75
    rm -f "$tmp/gate"
    wait "$waiter"
    is 'load wait: exit after the gate' "$?" 0
    waiter=""
    is 'load wait: order' "$(bm_events)" 'wait-load M-start'
    is 'load wait: argument' "$(grep wait-load "$bmlog")" 'wait-load --wait-load bench'
fi
rm -f "$tmp/gate"
: > "$bmlog"
out="$(BM_LOAD_EXIT=3 "$repo/scripts/with-lock.sh" --bench-mark bash -c "echo M-start >> '$bmlog'" 2>&1)"
code=$?
[[ $code -eq 2 && "$(grep -c M-start "$bmlog")" == 0 && -z "$(bm_files)" ]] || fail "failing load wait: exit $code, files [$(bm_files)]: $out"
# A bench void of the load wait (exit 76 with the stop text on stdout) passes through: exit 76, the
# void line, no command, and no marker.
: > "$bmlog"
out="$(BM_LOAD_EXIT=76 BM_LOAD_STOP='load 9.00 after 300 s, not under 8' "$repo/scripts/with-lock.sh" --bench-mark bash -c "echo M-start >> '$bmlog'" 2>&1)"
code=$?
[[ $code -eq 76 && "$out" == *'bench: void: load 9.00 after 300 s, not under 8; the marked command did not run'* &&
    "$(grep -c M-start "$bmlog")" == 0 && -z "$(bm_files)" ]] || fail "bench void of the load wait: exit $code, files [$(bm_files)]: $out"

# The marked call waits for a lock-free call: one line names the call, the limit gives exit 75, no
# marker is left, and the command does not run. A lock-free call of the Whisper form (a built
# binary, WITH_LOCK_RUN_ONLY=1) is a lock-free call too, and the command runs after it ends.
: > "$bmlog"
BM_SLEEP=20 "$repo/scripts/with-lock.sh" "$fake/bm/make" test-hooks HOOK_TESTS=e > /dev/null 2>&1 &
inner=$!
until_true 50 free_up || fail 'marked call waits for a lock-free call: no lock-free file'
out="$(WITH_LOCK_MAX_WAIT=1 WITH_LOCK_RETRY=0.5 "$repo/scripts/with-lock.sh" --bench-mark bash -c "echo M-start >> '$bmlog'" 2>&1)"
code=$?
[[ $code -eq 75 && "$(grep -c M-start "$bmlog")" == 0 && "$(grep -c "lock-free call pid $inner (" <<<"$out")" == 1 ]] ||
    fail "marked call waits for a lock-free call: exit $code: $out"
[[ "$(tail -n 1 "$waits" 2>/dev/null | awk -F'\t' '{ print $3 "|" $6 }')" == "bash -c echo M-start >> '$bmlog'|exit75" ]] ||
    fail "marked call at the limit: no exit75 wait line: [$(tail -n 1 "$waits" 2>/dev/null)]"
is 'marked call at the limit: marker' "$(ls "$marks" 2>/dev/null | paste -sd' ' -)" ""
WITH_LOCK_MAX_WAIT=30 "$repo/scripts/with-lock.sh" --bench-mark echo x > /dev/null 2>&1 &
waiter=$!
until_true 50 bm_ready || fail 'waiting marked call: no marker'
is 'waiting marked call: marker' "$(ls "$marks" | wc -l | tr -d ' ')" 1
kill -TERM "$waiter"
wait "$waiter" 2>/dev/null
is 'waiting marked call: TERM exit' "$?" 143
waiter=""
is 'waiting marked call: marker after TERM' "$(ls "$marks" 2>/dev/null | paste -sd' ' -)" ""
out="$("$repo/scripts/with-lock.sh" --release-holder 2>&1)"
code=$?
[[ $code -eq 1 && -z "$out" ]] || fail "lock-free call live and --release-holder: exit $code, output [$out]"
is 'lock-free call live and --builders' "$("$repo/scripts/with-lock.sh" --builders 2>&1)" ""
kill -TERM "$inner"
wait "$inner" 2>/dev/null
is 'lock-free TERM: exit' "$?" 143
inner=""
is 'lock-free TERM: file' "$(ls "$frees" 2>/dev/null | paste -sd' ' -)" ""
: > "$bmlog"
WITH_LOCK_RUN_ONLY=1 "$repo/scripts/with-lock.sh" "$repo/.build/debug/whisper" > /dev/null 2>&1 &
inner=$!
until_true 50 free_up || fail 'run-only item: no lock-free file'
WITH_LOCK_MAX_WAIT=1 WITH_LOCK_RETRY=0.5 "$repo/scripts/with-lock.sh" --bench-mark bash -c "echo M-start >> '$bmlog'" > /dev/null 2>&1
is 'run-only item: the marked call at the limit' "$?" 75
wait "$inner"
inner=""
WITH_LOCK_MAX_WAIT=10 "$repo/scripts/with-lock.sh" --bench-mark bash -c "echo M-start >> '$bmlog'" > /dev/null 2>&1
is 'run-only item: the marked call after the item' "$(bm_events)" 'W-start W-end wait-load M-start'

# A marker or a lock-free file of a dead pid is ignored and removed. A lock-free file that cannot be
# written does not stop the call: it runs, with one stderr line that names the file, also after a wait.
mkdir -p "$marks"
echo "$repo" > "$marks/$gone"
rm -f "$tmp/order"
WITH_LOCK_MAX_WAIT=3 "$repo/scripts/with-lock.sh" "$fake/make" test-hooks HOOK_TESTS=a > /dev/null 2>&1
is 'dead marker: lock-free exit' "$?" 0
[[ -s "$tmp/order" && -z "$(bm_files)" ]] || fail "dead marker: order [$(cat "$tmp/order" 2>/dev/null)], files left [$(bm_files)]"
mkdir -p "$frees"
echo 'make test-hooks' > "$frees/$gone"
WITH_LOCK_MAX_WAIT=3 "$repo/scripts/with-lock.sh" --bench-mark bash -c 'exit 0' > /dev/null 2>&1
is 'dead lock-free file: marked exit' "$?" 0
is 'dead lock-free file: files left' "$(bm_files)" ""
rm -rf "$frees"
echo notadir > "$frees"
rm -f "$tmp/order"
out="$(WITH_LOCK_MAX_WAIT=3 "$repo/scripts/with-lock.sh" "$fake/make" test-hooks HOOK_TESTS=j 2>&1)"
code=$?
[[ $code -eq 0 && -s "$tmp/order" && "$(grep -c "cannot write the lock-free file [^ ]*dirigible-lock-free/[0-9]*; a bench marker cannot see this call" <<<"$out")" == 1 ]] ||
    fail "lock-free file not writable: exit $code: $out"
reset_builders
hold_for 1.5
echo 'make dmg' > "$lock/command"
rm -f "$tmp/order"
out="$(WITH_LOCK_MAX_WAIT=10 "$repo/scripts/with-lock.sh" "$fake/make" test-hooks HOOK_TESTS=j 2>&1)"
code=$?
[[ $code -eq 0 && -s "$tmp/order" && "$(grep -c 'cannot write the lock-free file' <<<"$out")" == 1 ]] ||
    fail "lock-free file not writable, after a wait: exit $code: $out"
reset_builders
rm -f "$frees"

# A file of a live pid with another start time in line 1 belongs to a process that the kernel gave
# the pid after a kill: it is ignored and removed, and no call waits for it.
stamped() { { LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" | sed 's/^ *//'; shift; printf '%s\n' "$@"; }; }
sleep 60 & inner=$!
mkdir -p "$marks" "$frees"
printf 'Mon Jan  1 00:00:00 2001\n1\n%s\n' "$repo" > "$marks/$inner"
rm -f "$tmp/order"
out="$(WITH_LOCK_MAX_WAIT=3 "$repo/scripts/with-lock.sh" "$fake/make" test-hooks HOOK_TESTS=a 2>&1)"
code=$?
[[ $code -eq 0 && -s "$tmp/order" && ! -e "$marks/$inner" && "$out" != *'bench marker pid'* ]] ||
    fail "marker of a reused pid: exit $code, marker [$(ls "$marks")]: $out"
printf 'Mon Jan  1 00:00:00 2001\nmake test-hooks\n' > "$frees/$inner"
out="$(WITH_LOCK_MAX_WAIT=3 "$repo/scripts/with-lock.sh" --bench-mark bash -c 'exit 0' 2>&1)"
code=$?
[[ $code -eq 0 && ! -e "$frees/$inner" && "$out" != *'lock-free call pid'* ]] || fail "lock-free file of a reused pid: exit $code, files [$(bm_files)]: $out"
stamped "$inner" 1 "$repo" > "$marks/$inner"
rm -f "$tmp/order"
out="$(WITH_LOCK_MAX_WAIT=1 WITH_LOCK_RETRY=0.5 "$repo/scripts/with-lock.sh" "$fake/make" test-hooks HOOK_TESTS=a 2>&1)"
code=$?
[[ $code -eq 75 && ! -s "$tmp/order" && -e "$marks/$inner" ]] || fail "marker of a live pid with its start time: exit $code, order [$(cat "$tmp/order" 2>/dev/null)]: $out"
# A file with an empty line 1 (ps printed nothing when it was written) is live while its pid runs.
printf '\n1\n%s\n' "$repo" > "$marks/$inner"
rm -f "$tmp/order"
out="$(WITH_LOCK_MAX_WAIT=1 WITH_LOCK_RETRY=0.5 "$repo/scripts/with-lock.sh" "$fake/make" test-hooks HOOK_TESTS=a 2>&1)"
code=$?
[[ $code -eq 75 && ! -s "$tmp/order" && -e "$marks/$inner" ]] || fail "marker of a live pid with an empty start time: exit $code, order [$(cat "$tmp/order" 2>/dev/null)], marker [$(ls "$marks")]: $out"
kill "$inner" 2>/dev/null
wait "$inner" 2>/dev/null
inner=""
rm -rf "$marks" "$frees"
# The start time in line 1 does not depend on the time zone or the locale: a marker that a call
# wrote in one zone still blocks a lock-free call in another zone.
if TZ=America/New_York LC_ALL=es_ES.UTF-8 bm_start 'marker of another time zone'; then
    rm -f "$tmp/order"
    out="$(TZ=UTC LC_ALL=C WITH_LOCK_MAX_WAIT=1 WITH_LOCK_RETRY=0.5 "$repo/scripts/with-lock.sh" "$fake/make" test-hooks HOOK_TESTS=a 2>&1)"
    code=$?
    [[ $code -eq 75 && ! -s "$tmp/order" && -e "$marks/$waiter" ]] ||
        fail "marker of another time zone: exit $code, order [$(cat "$tmp/order" 2>/dev/null)], marker [$(ls "$marks")]: $out"
    bm_end
fi
rm -rf "$marks" "$frees"

# A lock-free call that waits behind a holder prints a new line when a new cause appears: a marker
# after a push check.
reset_builders
hold
echo 'make dmg' > "$lock/command"
sleep 60 & inner=$!
WITH_LOCK_MAX_WAIT=30 WITH_LOCK_RETRY=0.2 "$repo/scripts/with-lock.sh" "$fake/make" test-hooks HOOK_TESTS=m > "$tmp/free.out" 2>&1 &
waiter=$!
until_true 50 grep -q 'held by pid' "$tmp/free.out" || fail "new cause: no holder line: $(cat "$tmp/free.out")"
mkdir -p "$marks"
stamped "$inner" "$(date +%s)" "$repo" > "$marks/$inner"
clear_hold
until_true 50 grep -q "bench marker pid $inner (" "$tmp/free.out" || fail "new cause: no line that names the marker: $(cat "$tmp/free.out")"
rm -f "$marks/$inner"
kill "$inner" 2>/dev/null
wait "$inner" 2>/dev/null
inner=""
wait "$waiter" 2>/dev/null
waiter=""
reset_builders
rm -rf "$marks"

# Two marked calls that start together: the older one (call start time, then pid) keeps its marker
# and waits until the other removes its own, and the other removes its marker and waits. A stub
# mkdir writes the marker of a second call just before the marker of the call under test, so that
# call finds it at its second look. The second call is a live sleep; the case plays its part.
mkdir -p "$fake/mk"
cat > "$fake/mk/mkdir" << 'EOF'
#!/bin/bash
for last; do :; done
if [[ "$last" == */dirigible-bench-marks && ! -e "$MK_DONE" ]]; then
    /bin/mkdir -p "$last" && : > "$MK_DONE"
    { LC_ALL=C TZ=UTC0 ps -o lstart= -p "$MK_PID" | sed 's/^ *//'; echo "$MK_AT"; echo "$MK_TREE"; } > "$last/$MK_PID"
fi
exec /bin/mkdir "$@"
EOF
chmod +x "$fake/mk/mkdir"
mk_call() { # <start time of the second call> ; the marked call runs in the background
    rm -rf "$marks" "$tmp/mkdone" "$tmp/ran5" "$tmp/mk.err"
    sleep 60 & inner=$!
    PATH="$fake/mk:$PATH" MK_PID="$inner" MK_AT="$1" MK_TREE="$repo" MK_DONE="$tmp/mkdone" WITH_LOCK_MAX_WAIT=20 WITH_LOCK_RETRY=0.2 \
        "$repo/scripts/with-lock.sh" --bench-mark bash -c "echo ran > '$tmp/ran5'" > /dev/null 2> "$tmp/mk.err" &
    waiter=$!
    until_true 50 test -e "$marks/$inner" || fail 'two marked calls: the marker of the second call did not appear'
    sleep 0.6
}
mk_end() {
    kill "$inner" 2>/dev/null
    wait "$inner" 2>/dev/null
    inner=""
    wait "$waiter" 2>/dev/null
    is "two marked calls, $1: exit" "$?" 0
    waiter=""
}
mk_call $(($(date +%s) + 3600))
is 'two marked calls, second one younger: the call keeps its marker' "$(ls "$marks" | wc -l | tr -d ' ')" 2
[[ ! -e "$tmp/ran5" ]] || fail 'two marked calls, second one younger: the command ran while the other marker lived'
rm -f "$marks/$inner"
until_true 50 test -e "$tmp/ran5" || fail 'two marked calls, second one younger: the command did not run after the other marker went'
is 'two marked calls, second one younger: wait lines' "$(grep -c "bench marker pid $inner (" "$tmp/mk.err")" 1
mk_end 'second one younger'
mk_call 1
is 'two marked calls, second one older: the call removes its marker' "$(ls "$marks" | tr '\n' ' ')" "$inner "
[[ ! -e "$tmp/ran5" ]] || fail 'two marked calls, second one older: the command ran while the older marker lived'
rm -f "$marks/$inner"
until_true 50 test -e "$tmp/ran5" || fail 'two marked calls, second one older: the command did not run after the older marker went'
is 'two marked calls, second one older: wait lines' "$(grep -c "bench marker pid $inner (" "$tmp/mk.err")" 1
mk_end 'second one older'
rm -rf "$marks" "$tmp/mkdone" "$tmp/ran5" "$tmp/mk.err"
reset_builders

# The header names the two causes that the held column of the wait log can hold.
[[ "$(sed -n '1,30p' "$script")" == *'"bench marker pid N (<tree>)" or "lock-free call pid N (<command>)"'* ]] ||
    fail 'the header does not name the two new forms of the held column'

# --bench-mark times only a shell script or a hook test: a command of the lock class that it can see
# gets exit 64, one stderr line with the lock form, no event, and no marker. A marker command runs.
# The stubs only log an event, so a form that runs builds nothing.
bm_refused() { # <name> <command>...
    local name="$1"
    shift
    : > "$bmlog"
    WITH_LOCK_MAX_WAIT=5 "$repo/scripts/with-lock.sh" --bench-mark "$@" > "$tmp/bm.out" 2> "$tmp/bm.err"
    is "refused $name: exit" "$?" 64
    is "refused $name: events" "$(bm_events)" ""
    is "refused $name: stderr lines" "$(wc -l < "$tmp/bm.err" | tr -d ' ')" 1
    is "refused $name: lock form" "$(grep -cF "run this command under the lock: scripts/with-lock.sh $*" "$tmp/bm.err")" 1
    is "refused $name: files" "$(bm_files)" ""
}
bm_allowed() { # <name> <events> <command>...
    local name="$1" want="$2"
    shift 2
    : > "$bmlog"
    WITH_LOCK_MAX_WAIT=5 "$repo/scripts/with-lock.sh" --bench-mark "$@" > "$tmp/bm.out" 2> "$tmp/bm.err"
    is "allowed $name: exit" "$?" 0
    is "allowed $name: events" "$(bm_events)" "$want"
    is "allowed $name: files" "$(bm_files)" ""
}
bm_refused 'swift build' "$fake/bm/swift" build
bm_refused 'make test' "$fake/bm/make" test
bm_refused 'land.sh' "$repo/scripts/land.sh"
bm_refused 'probe.sh' "$repo/scripts/probe.sh" "$tmp" "$fake/bm/swift" build
bm_refused 'a .build path' "$repo/.build/debug/stub" transcribe
bm_refused 'swift-test.sh' "$repo/scripts/swift-test.sh" --filter X
bm_refused 'env before swift' env X=1 "$fake/bm/swift" test
bm_refused 'bash before test-shards.sh' bash "$repo/scripts/test-shards.sh"
bm_refused 'make check-changed' "$fake/bm/make" check-changed
bm_refused 'make test-hooks with DIRIGIBLE_HOOKS_ALL=1' "$fake/bm/make" test-hooks HOOK_TESTS=a DIRIGIBLE_HOOKS_ALL=1
bm_refused 'make test-hooks with no HOOK_TESTS' "$fake/bm/make" test-hooks
bm_refused 'time -p before swift' time -p "$fake/bm/swift" build
bm_refused '/usr/bin/time -p before swift' /usr/bin/time -p "$fake/bm/swift" build
bm_refused 'env -u before swift' env -u X "$fake/bm/swift" build
bm_refused 'env -i before swift' env -i "$fake/bm/swift" build
bm_refused 'nice before swift' nice "$fake/bm/swift" build
bm_refused 'nice -n before swift' nice -n 5 "$fake/bm/swift" build
bm_refused 'xcrun before swift' xcrun "$fake/bm/swift" build
bm_refused 'two wrappers before swift' time -p nice env X=1 "$fake/bm/swift" build
bm_refused 'mutation-pass.sh' "$repo/scripts/mutation-pass.sh"
bm_refused 'screenshots.sh' "$repo/scripts/screenshots.sh"
bm_refused 'bundle.sh' "$repo/scripts/bundle.sh"
bm_refused 'sh -x before bundle.sh' sh -x "$repo/scripts/bundle.sh"
bm_refused 'bash -e -o pipefail before bundle.sh' bash -e -o pipefail "$repo/scripts/bundle.sh"
# env -S splits its argument into words that the call cannot see: exit 64, one line.
bm_refused_split() { # <name> <command>...
    local name="$1"
    shift
    : > "$bmlog"
    WITH_LOCK_MAX_WAIT=5 "$repo/scripts/with-lock.sh" --bench-mark "$@" > "$tmp/bm.out" 2> "$tmp/bm.err"
    is "refused $name: exit" "$?" 64
    is "refused $name: events" "$(bm_events)" ""
    is "refused $name: stderr lines" "$(wc -l < "$tmp/bm.err" | tr -d ' ')" 1
    is "refused $name: reason" "$(grep -c 'cannot see inside env -S' "$tmp/bm.err")" 1
    is "refused $name: files" "$(bm_files)" ""
}
bm_refused_split 'env -S' env -S 'swift build'
bm_refused_split 'env -S before a path' env -S "$fake/bm/swift build"
bm_refused_split 'env -S<string>' env "-S$fake/bm/swift build"
bm_refused_split 'env -iS' env -iS 'swift build'
bm_refused_split 'env --split-string' env --split-string 'swift build'
bm_refused_split 'env --split-string=' env '--split-string=swift build'
bm_refused_split 'time before env -S' time -p env -S 'swift build'
# A hook test runs only through make test-hooks HOOK_TESTS=: exit 64, one line that names that call.
bm_refused_hook() { # <name> <command>...
    local name="$1"
    shift
    : > "$bmlog"
    WITH_LOCK_MAX_WAIT=5 "$repo/scripts/with-lock.sh" --bench-mark "$@" > "$tmp/bm.out" 2> "$tmp/bm.err"
    is "refused $name: exit" "$?" 64
    is "refused $name: events" "$(bm_events)" ""
    is "refused $name: stderr lines" "$(wc -l < "$tmp/bm.err" | tr -d ' ')" 1
    is "refused $name: make form" "$(grep -c 'a hook test runs only through make test-hooks HOOK_TESTS=' "$tmp/bm.err")" 1
    is "refused $name: files" "$(bm_files)" ""
}
bm_refused_hook 'bash and a hook test' bash scripts/x.test.sh
bm_refused_hook 'a hook test' "$repo/scripts/x.test.sh"
bm_refused_hook 'env and a hook test' env X=1 bash scripts/x.test.sh
bm_refused_hook 'test-hooks.sh' "$repo/scripts/test-hooks.sh" scripts/x.test.sh
bm_refused_hook 'bash -e and a hook test' bash -e scripts/x.test.sh
bm_refused_hook 'bash -o pipefail and a hook test' bash -o pipefail scripts/x.test.sh
hold
echo 'make build' > "$lock/command"
DIRIGIBLE_BUILD_LOCK="$holder" bm_refused 'swift build in a locked process tree' "$fake/bm/swift" build
clear_hold
bm_allowed 'check-waits.sh' 'wait-load RAN-check-waits' "$repo/scripts/check-waits.sh"
bm_allowed 'env -u before check-waits.sh' 'wait-load RAN-check-waits' env -u X "$repo/scripts/check-waits.sh"
bm_allowed 'bash -e -o pipefail before check-waits.sh' 'wait-load RAN-check-waits' bash -e -o pipefail "$repo/scripts/check-waits.sh"
bm_allowed 'make test-hooks with HOOK_TESTS' 'wait-load L-start L-end' "$fake/bm/make" test-hooks HOOK_TESTS=a
bm_allowed 'make lint' 'wait-load L-start L-end' "$fake/bm/make" lint
# A marked call in a locked process tree (the pid file matches DIRIGIBLE_BUILD_LOCK) exits 64 with the
# plain form, runs nothing, and writes no marker: a marker cannot keep the lock-free calls of other
# trees out of a tree that already runs.
hold
echo 'make build' > "$lock/command"
: > "$bmlog"
out="$(DIRIGIBLE_BUILD_LOCK="$holder" "$repo/scripts/with-lock.sh" --bench-mark bash -c "echo ran > '$tmp/ran4'" 2>&1)"
code=$?
[[ $code -eq 64 && ! -e "$tmp/ran4" && -z "$(bm_events)" && -z "$(bm_files)" && "$out" == *'does not run inside a locked process tree'* && "$out" == *'scripts/with-lock.sh bash -c echo ran'* ]] ||
    fail "marker call under a lock: exit $code, events [$(bm_events)], files [$(bm_files)]: $out"
clear_hold
rm -f "$tmp/ran4" "$tmp/ran2" "$tmp/ran" "$tmp/ro.sh"
rm -rf "$repo/.build" "$marks" "$frees"
unset BM_LOG
rm -f "$repo/scripts/land.sh" "$repo/scripts/probe.sh" "$repo/scripts/swift-test.sh" "$repo/scripts/test-shards.sh" "$repo/scripts/check-waits.sh" "$repo/scripts/mutation-pass.sh" "$repo/scripts/screenshots.sh" "$repo/scripts/bundle.sh"
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
[[ "$out" == *'it waits while a release call (a push check, a land, or make dmg)'* ]] ||
    fail "lock-free wait: the lock-free line does not name the wait behind a release call: $out"
[[ "$out" == *'holds the lock, or while a bench marker is live'* ]] || fail "lock-free wait: the lock-free line does not end with the bench marker: $out"
[[ ! -e "$holds" ]] || fail "lock-free wait: a hold line: $(cat "$holds")"
[[ "$(wc -l < "$waits" 2>/dev/null | tr -d ' ')" == 1 && "$(awk -F'\t' '{ print NF, $4, $NF }' "$waits")" == '6 make dmg lockfree' ]] ||
    fail "lock-free wait: the wait line: [$(cat "$waits" 2>/dev/null)]"
# The wait line is no sign of a building tree: --builders lists no tree after it.
[[ -z "$("$repo/scripts/with-lock.sh" --builders 2>&1)" ]] || fail "lock-free wait: --builders lists [$("$repo/scripts/with-lock.sh" --builders 2>&1)]"
# (2) A holder that stays: exit 75 at the limit, no command, one exit75 wait line, no hold line,
# and the holder as it was.
lf_holder 'make dmg'
lf_start env WITH_LOCK_MAX_WAIT=2
lf_finish 80
[[ $code -eq 75 && ! -e "$tmp/state" && "$out" == *'still waiting after 2 s (WITH_LOCK_MAX_WAIT); run the same command again'* && "$out" == *'no lock; it waits while'* ]] ||
    fail "lock-free limit: exit $code after $elapsed s: $out"
[[ "$(wc -l < "$waits" 2>/dev/null | tr -d ' ')" == 1 && "$(awk -F'\t' '{ print NF, $4, $NF }' "$waits")" == '6 make dmg exit75' && ! -e "$holds" && "$(cat "$lock/pid")" == "$holder" && "$(cat "$lock/command")" == 'make dmg' ]] ||
    fail "lock-free limit: the wait line, a hold line, or a change of the holder: $(cat "$waits" "$holds" 2>/dev/null)"
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

# Run-only mode: WITH_LOCK_RUN_ONLY=1 takes no lock and waits only for a long holder (a bench, a
# release call). It runs only a built binary (a path under .build/ or build/Dirigible.app/) or
# bash <file> or sh <file>, after the words env, time, NAME=value, and probe.sh [--no-audio]
# <folder>. Every other form exits 2 and runs nothing. A stub of each tool that builds writes
# $tmp/marker; the stub probe.sh and the stub binary write their arguments there too.
cd "$repo" || exit 2
ro="$tmp/ro" marker="$tmp/marker"
mkdir -p "$ro/bin" "$repo/.build/debug" "$repo/build/Dirigible.app/Contents/MacOS" "$tmp/pf"
printf '#!/bin/bash\necho "$(basename "$0") $*" >> "%s"\n' "$marker" > "$ro/stub"
for name in swift swiftc make touch; do cp "$ro/stub" "$ro/bin/$name"; done
cp "$ro/stub" "$repo/scripts/land.sh"
printf '#!/bin/bash\n[[ "${1:-}" != --no-audio ]] || shift\ncd "$1" || exit 1\nshift\nexec "$@"\n' > "$repo/scripts/probe.sh"
cp "$ro/stub" "$repo/.build/debug/dirigible"
cp "$ro/stub" "$repo/build/Dirigible.app/Contents/MacOS/Dirigible"
chmod +x "$ro/bin/"* "$repo/scripts/land.sh" "$repo/scripts/probe.sh" "$repo/.build/debug/dirigible" "$repo/build/Dirigible.app/Contents/MacOS/Dirigible"
printf 'echo script >> "%s"\n' "$marker" > "$repo/run.sh"
cp "$repo/run.sh" "$tmp/pf/run.sh"
printf '"%s/scripts/with-lock.sh" swift build\n' "$repo" > "$repo/nested.sh"
# ro_call <variable value> <command...>: one call beside the holder that is there, with a limit of 2 s.
ro_call() {
    local value="$1"
    shift
    rm -f "$marker"
    out="$(PATH="$ro/bin:$PATH" WITH_LOCK_RUN_ONLY="$value" WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 "$repo/scripts/with-lock.sh" "$@" 2>&1)"
    code=$?
}
ro_idle() { [[ ! -e "$holds" && ! -e "$waits" && -z "$(ls -A "$waiting" 2>/dev/null)$(ls -A "$first" 2>/dev/null)" ]]; }
# (C5) A live ordinary holder: the call runs at once, with no lock. The same call with no variable
# waits for the holder and exits 75 at the limit.
reset_builders
hold
ro_call 1 .build/debug/dirigible info
[[ $code -eq 0 && "$(cat "$marker" 2>/dev/null)" == 'dirigible info' && "$out" == *'lock-free targets (run-only): no lock'* && "$(cat "$lock/pid")" == "$holder" ]] && ro_idle ||
    fail "run-only, ordinary holder: exit $code, marker [$(cat "$marker" 2>/dev/null)]: $out"
for value in "" 0; do
    ro_call "$value" .build/debug/dirigible info
    [[ $code -eq 75 && ! -e "$marker" && "$out" != *'lock-free targets'* ]] || fail "run-only, variable [$value]: exit $code (want 75), marker [$(cat "$marker" 2>/dev/null)]: $out"
done
# (C6) A long holder (a bench, a release call): the call waits with no lock, marker, or ticket, and exits 75 at the limit
# with one exit75 wait line and no hold line.
ro_x75() { [[ ! -e "$holds" && "$(awk -F'\t' '$6 == "exit75"' "$waits" 2>/dev/null)" == "$(cat "$waits")" && -s "$waits" && -z "$(ls -A "$waiting" 2>/dev/null)$(ls -A "$first" 2>/dev/null)" ]]; }
for holder_command in 'scripts/bench.sh EditBenchmark' 'make dmg'; do
    lf_holder "$holder_command"
    ro_call 1 .build/debug/dirigible info
    [[ $code -eq 75 && ! -e "$marker" && "$out" == *'no lock; it waits while'* && "$(cat "$lock/pid")" == "$holder" ]] && ro_x75 ||
        fail "run-only, holder [$holder_command]: exit $code (want 75), marker [$(cat "$marker" 2>/dev/null)]: $out"
done
# The holder ends during the wait: the command runs with no lock, and one wait line ends with lockfree.
lf_holder 'scripts/bench.sh EditBenchmark' 1
rm -f "$marker"
out="$(PATH="$ro/bin:$PATH" WITH_LOCK_RUN_ONLY=1 WITH_LOCK_MAX_WAIT=10 WITH_LOCK_RETRY=0.1 "$repo/scripts/with-lock.sh" .build/debug/dirigible info 2>&1)"
code=$?
[[ $code -eq 0 && "$(cat "$marker" 2>/dev/null)" == 'dirigible info' && ! -e "$holds" && "$(wc -l < "$waits" | tr -d ' ')" == 1 && "$(awk -F'\t' '{ print NF, $NF }' "$waits")" == '6 lockfree' ]] ||
    fail "run-only, the holder ends: exit $code, wait line [$(cat "$waits" 2>/dev/null)]: $out"
reset_builders
# (C7) A form that is not allowed exits 2 with a message that names the allowed forms: no command, no lock, no log line.
no_run() {
    ro_call 1 "$@"
    [[ $code -eq 2 && ! -e "$marker" && "$out" == *'a built binary'* && "$out" == *'bash <file>'* ]] && ro_idle ||
        fail "run-only, refused form [$*]: exit $code (want 2), marker [$(cat "$marker" 2>/dev/null)]: $out"
}
no_run swift build
no_run swiftc x.swift
no_run make test
no_run scripts/land.sh
no_run touch "$tmp/touched"
no_run env FOO=1 swiftc x.swift
no_run env FOO=1 touch "$tmp/touched"
no_run time swift build
no_run FOO=1 make test
no_run scripts/probe.sh "$tmp/pf" swiftc x.swift
no_run scripts/probe.sh "$tmp/pf" swift build
no_run scripts/probe.sh --no-audio "$tmp/pf" swift run x
no_run "$repo/scripts/probe.sh" "$tmp/pf" swift build
no_run env -i swift build
no_run env -S 'swift build' .build/debug/dirigible info
no_run env -S'swift build' .build/debug/dirigible info
no_run scripts/probe.sh "$tmp/pf" env -S 'swift build' "$repo/.build/debug/dirigible" info
no_run time -p swift build
no_run /usr/bin/time -p swift build
no_run /usr/bin/swift build
no_run xcrun swift build
no_run nice swift build
no_run nohup swift build
no_run caffeinate swift build
no_run exec swift build
no_run command swift build
no_run sh -c 'swift build'
no_run bash -c 'swift build'
no_run bash -x run.sh
no_run bash
no_run env
no_run scripts/probe.sh "$tmp/pf"
no_run scripts/probe.sh "$tmp/pf" .build/debug/dirigible info
no_run scripts/probe.sh --no-audio "$tmp/pf" build/Dirigible.app/Contents/MacOS/Dirigible info
no_run scripts/probe.sh "$tmp/pf" env FOO=1 .build/debug/dirigible info
no_run .build/../scripts/land.sh
no_run build/Dirigible.app/../../scripts/land.sh
# Near inputs of C7: each one runs.
ro_run() {
    local want="$1"
    shift
    ro_call 1 "$@"
    [[ $code -eq 0 && "$(cat "$marker" 2>/dev/null)" == "$want" && "$out" == *'lock-free targets (run-only): no lock'* ]] && ro_idle ||
        fail "run-only, allowed form [$*]: exit $code, marker [$(cat "$marker" 2>/dev/null)] (want [$want]): $out"
}
ro_run 'dirigible info' .build/debug/dirigible info
ro_run 'dirigible info' "$repo/.build/debug/dirigible" info
ro_run 'Dirigible info' build/Dirigible.app/Contents/MacOS/Dirigible info
ro_run 'dirigible info' env FOO=1 .build/debug/dirigible info
ro_run 'dirigible info' time .build/debug/dirigible info
ro_run 'dirigible info' env -u X .build/debug/dirigible info
ro_run 'dirigible info' nice -n 5 .build/debug/dirigible info
ro_run 'dirigible info' scripts/probe.sh "$tmp/pf" "$repo/.build/debug/dirigible" info
ro_run 'Dirigible info' "$repo/scripts/probe.sh" --no-audio "$tmp/pf" "$repo/build/Dirigible.app/Contents/MacOS/Dirigible" info
ro_run script scripts/probe.sh "$tmp/pf" bash run.sh
ro_run script bash run.sh
ro_run script sh run.sh
ro_run script env FOO=1 bash run.sh
# The mode applies to the call that sets the variable: a bash <file> that it runs and that calls
# with-lock.sh for a build takes the lock path, with no exit 2.
reset_builders
ro_call 1 bash nested.sh
[[ $code -eq 0 && "$(cat "$marker" 2>/dev/null)" == 'swift build' && "$out" != *'WITH_LOCK_RUN_ONLY=1 runs'* ]] ||
    fail "run-only, nested build call: exit $code (want 0), marker [$(cat "$marker" 2>/dev/null)]: $out"
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
# pair_in_time <seconds>: the call ran below WITH_LOCK_MAX_WAIT=10, the wait that it must not do.
# A loaded machine took 8 s (item 1217), so 8 s passes and 10 s fails.
pair_in_time() { [[ $1 -lt 10 ]]; }
pair_in_time 8 || fail 'pair bound: 8 s (a loaded call) fails'
! pair_in_time 10 || fail 'pair bound: 10 s (the wait limit) passes'
mkdir -p "$pair/scripts"
cp "$script" "$(dirname "$script")/lock-words.sh" "$(dirname "$script")/check-changed.sh" "$(dirname "$script")/swift-suites.sh" "$pair/scripts/"
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
    [[ $code -eq 3 ]] && pair_in_time "$elapsed" && [[ "$out" == 'check-changed: no changed path, and HEAD has commits past the merge base '*'give SINCE='* && "$(wc -l <<<"$out" | tr -d ' ')" == 1 ]] ||
        fail "real pair, holder [$holder_command]: exit $code after $elapsed s: $out"
    [[ ! -e "$pair/.git/dirigible-build-waits.log" && ! -e "$pair/.git/dirigible-build-holds.log" ]] || fail "real pair, holder [$holder_command]: a log line"
    [[ -z "$inner" ]] || { kill "$inner" 2>/dev/null; wait "$inner" 2>/dev/null; inner=""; }
done
# A FILTER that leaves out a default suite name of the changed source: the pair exits 3 at once
# behind a release holder, with the full FILTER in the reason, no make call, and no log line.
mkdir -p "$pair/Tests/DirigibleTests" "$pair/Sources/DirigibleApp"
printf 'struct SessionIndexCostTests {\n    @Test func t() {}\n}\n' > "$pair/Tests/DirigibleTests/SessionIndexCostTests.swift"
printf 'x\n' > "$pair/Sources/DirigibleApp/SessionIndexTable+Columns.swift"
rm -rf "$plock" "$pair/.git/dirigible-build-waits.log" "$tmp/order"
sleep 60 & inner=$!
mkdir "$plock" && echo "$inner" > "$plock/pid" && echo 'make dmg' > "$plock/command"
t0=$(date +%s)
out="$(cd "$pair" && WITH_LOCK_MAX_WAIT=10 WITH_LOCK_RETRY=0.1 scripts/with-lock.sh "$fake/make" check-changed FILTER=SessionIndexKeyTests 2>&1)"
code=$?
elapsed=$(($(date +%s) - t0))
[[ $code -eq 3 ]] && pair_in_time "$elapsed" && [[ "$out" == *"FILTER='SessionIndexKeyTests SessionIndexCostTests'"* && "$out" != *'held by pid'* && ! -e "$tmp/order" ]] ||
    fail "real pair, a FILTER with no default name: exit $code after $elapsed s, make [$(cat "$tmp/order" 2>/dev/null)]: $out"
[[ ! -e "$pair/.git/dirigible-build-waits.log" && ! -e "$pair/.git/dirigible-build-holds.log" ]] || fail "real pair, a FILTER with no default name: a log line"
kill "$inner" 2>/dev/null; wait "$inner" 2>/dev/null; inner=""
rm -rf "$plock"
reset_builders
# A script that builds nothing and only reads files (cost.sh, wiki.py) exits 2 at once with a live
# holder: it names DLV-157 and the bare command, and writes no wait line. Any other command waits.
for readonly in .claude/skills/reflect/scripts/cost.sh scripts/wiki.py; do
    hold
    out="$(WITH_LOCK_MAX_WAIT=10 "$repo/scripts/with-lock.sh" "$readonly" --since 1 2>&1)"
    code=$?
    [[ $code -eq 2 && "$out" == *DLV-157* && "$out" == *"$readonly builds nothing"* && ! -e "$waits" ]] ||
        fail "read-only script $readonly: exit $code (want 2), wait line [$(cat "$waits" 2>/dev/null)]: $out"
    clear_hold
done
hold
out="$(WITH_LOCK_MAX_WAIT=1 "$repo/scripts/with-lock.sh" touch "$tmp/ran" 2>&1)"
code=$?
[[ $code -eq 75 ]] || fail "a command that is not read-only waits: exit $code (want 75): $out"
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
# The window: a hold that ended 19 min ago counts, one that ended 21 min ago does not. A wait line
# is no sign of a building tree, and the old wait line of 4 columns has no tree. The trees are real
# folders, as --builders skips a path that does not exist.
reset_builders
mkdir -p "$tmp/in" "$tmp/out" "$tmp/wait-in" "$tmp/wait-out"
printf '%s\t30\tmake test\t%s\n%s\t30\tmake test\t%s\n' "$(ago 20)" "$tmp/in" "$(ago 22)" "$tmp/out" > "$holds"
printf '%s\t30\ttouch x\tmake test\t%s\n%s\t30\ttouch x\tmake test\t%s\n%s\t30\ttouch x\tmake test\n' "$(ago 20)" "$tmp/wait-in" "$(ago 22)" "$tmp/wait-out" "$(ago 5)" > "$waits"
out="$("$repo/scripts/with-lock.sh" --builders 2>&1)"
[[ "$out" == "$tmp/in" ]] || fail "--builders window: [$out]"
out="$(WITH_LOCK_BUILDERS_MIN=90 "$repo/scripts/with-lock.sh" --builders 2>&1)"
[[ "$out" == "$(printf '%s\n%s' "$tmp/in" "$tmp/out")" ]] || fail "--builders, 90 min: [$out]"
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
grep -qF 'builders in the last 20 min: 2 (/t/holder, /t/waiter); the cap is 2 (long-runs.md)' "$tmp/wait.out" || fail "builders line: $(cat "$tmp/wait.out")"
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
[[ "$out" == *"$cap_text: $ta, $tb; 16 min until $ta ages out"* ]] || fail "cap: no cap line with both trees and the minutes: $out"
[[ "$(grep -c "$cap_text" <<<"$out")" -eq 1 ]] || fail "cap: the cap line is not printed once: $out"
# The window is 20 min with no WITH_LOCK_BUILDERS_MIN: 2 other trees whose hold lines ended 19 min
# ago fill the cap, and 2 whose hold lines ended 21 min ago do not.
reset_builders
holdline 20 "$ta"
holdline 20 "$tb"
rm -f "$tmp/ran"
capcall "$repo" touch "$tmp/ran"
[[ $code -eq 75 && ! -e "$tmp/ran" && "$out" == *"$cap_text: "* && "$out" == *"$ta"* && "$out" == *"$tb"* ]] ||
  fail "cap, hold lines that ended 19 min ago: exit $code, ran [$(ls "$tmp/ran" 2>&1)] (want 75, no run): $out"
reset_builders
holdline 22 "$ta"
holdline 22 "$tb"
rm -f "$tmp/ran"
capcall "$repo" touch "$tmp/ran"
[[ $code -eq 0 && -e "$tmp/ran" && "$out" != *"$cap_text"* ]] ||
  fail "cap, hold lines that ended 21 min ago: exit $code (want 0 at once, no cap line): $out"
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
# The hooks pass of Phase 7 (make test-hooks with DIRIGIBLE_HOOKS_ALL=1 as a word, in the
# environment, or in MAKEFLAGS) takes no lock: with 2 other trees it runs at once, with no lock
# folder, a lock-free file of the kind hooks, and no hold line, and a lock-free call runs during it.
# The fake make runs until $tmp/hp.go exists.
mkdir -p "$fake/hp"
printf '#!/bin/bash\nwhile [[ ! -e "%s" ]]; do sleep 0.1; done\n' "$tmp/hp.go" > "$fake/hp/make"
chmod +x "$fake/hp/make"
for hp_env in '' DIRIGIBLE_HOOKS_ALL=1 'MAKEFLAGS=w -- DIRIGIBLE_HOOKS_ALL=1'; do
  reset_builders
  rm -rf "$frees"
  holdline 5 "$ta"
  holdline 3 "$tb"
  rm -f "$tmp/hp.go" "$tmp/order"
  hp_word=""
  [[ -n "$hp_env" ]] || hp_word=DIRIGIBLE_HOOKS_ALL=1
  (cd "$repo" && exec env ${hp_env:+"$hp_env"} WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=0.1 "$repo/scripts/with-lock.sh" "$fake/hp/make" test-hooks $hp_word) > "$tmp/wait.out" 2>&1 &
  waiter=$!
  until_true 50 test -s "$frees/$waiter" || fail "cap, hooks pass [$hp_env$hp_word]: no lock-free file at the cap: $(cat "$tmp/wait.out")"
  [[ ! -e "$lock" && "$(sed -n 3p "$frees/$waiter" 2>/dev/null)" == hooks ]] ||
    fail "cap, hooks pass [$hp_env$hp_word]: a lock folder, or a lock-free file with no kind hooks: [$(cat "$frees/$waiter" 2>/dev/null)]"
  out="$(FAKE_TARGETS=check-docs WITH_LOCK_MAX_WAIT=2 WITH_LOCK_RETRY=1 "$repo/scripts/with-lock.sh" "$fake/make" check-changed 2>&1)"
  code=$?
  [[ $code -eq 0 && -s "$tmp/order" ]] || fail "cap, hooks pass [$hp_env$hp_word]: a lock-free call during it: exit $code (want 0), order [$(cat "$tmp/order" 2>/dev/null)]: $out"
  touch "$tmp/hp.go"
  hp_pid=$waiter
  until_true 50 dead "$waiter"
  wait "$waiter"
  code=$?
  waiter=""
  [[ $code -eq 0 && "$(grep -c test-hooks "$holds")" == 0 && ! -e "$frees/$hp_pid" ]] ||
    fail "cap, hooks pass [$hp_env$hp_word]: exit $code, hold lines [$(cat "$holds")]"
done
# A make test-hooks call with no DIRIGIBLE_HOOKS_ALL=1 is an ordinary call: the cap holds it.
reset_builders
holdline 5 "$ta"
holdline 3 "$tb"
rm -f "$tmp/ran"
capcall "$repo" "$fake/make" test-hooks
[[ $code -eq 75 && "$out" == *"$cap_text"* ]] || fail "cap, test-hooks with no DIRIGIBLE_HOOKS_ALL: exit $code (want 75): $out"
# A release call fills no slot: a make dmg hold line of a third tree and one other builder leave
# the cap open, so an ordinary call takes the lock.
reset_builders
rm -f "$tmp/order" "$tmp/ran"
WITH_LOCK_BUILDERS_FLOOR=0 capcall "$tc" "$fake/make" dmg
[[ $code -eq 0 && "$(tail -n 1 "$holds" | awk -F'\t' '{ print $6 }')" == nocap ]] || fail "cap, make dmg hold line: exit $code [$(tail -n 1 "$holds")]: $out"
holdline 5 "$ta"
WITH_LOCK_BUILDERS_FLOOR=0 capcall "$repo" touch "$tmp/ran"
[[ $code -eq 0 && -e "$tmp/ran" ]] || fail "cap, make dmg hold line and one other tree: exit $code: $out"
# A line ages out after the call starts to wait: the call takes the lock.
reset_builders
printf '%s\t10\tmake test\t%s\n' "$(date -r $(($(date +%s) - 40)) +%FT%T)" "$ta" >> "$holds"
printf '%s\t10\tmake test\t%s\n' "$(date -r $(($(date +%s) - 68)) +%FT%T)" "$tb" >> "$holds"
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
  WITH_LOCK_BUILDERS_FLOOR=0 capcall "$dir" touch "$tmp/ran"
  [[ $code -eq 0 && -e "$tmp/ran" ]] || break
done
[[ "$dir" == "$tmp/wt2" && $code -eq 75 && ! -e "$tmp/ran" && "$out" == *"$cap_text: "* && "$out" == *"$repo_tree"* && "$out" == *"$wt_tree"* && "$out" == *'; 20 min until '* ]] ||
  fail "cap, three trees: the call of [$dir] has exit $code (want 75 for wt2 after two runs): $out"
# A hold line whose tree path does not exist does not count.
reset_builders
holdline 5 "$ta"
holdline 4 /t/gone-1
holdline 3 /t/gone-2
rm -f "$tmp/ran"
capcall "$repo" touch "$tmp/ran"
[[ $code -eq 0 && -e "$tmp/ran" ]] || fail "cap, trees that do not exist: exit $code: $out"
# The floor WITH_LOCK_BUILDERS_FLOOR (default 10 s): a tree counts for --builders and for the cap
# only when its hold lines of the window add up to 10 s or more. holdend <seconds since the line
# ended> <hold seconds> <tree> writes a hold line that ended that long ago.
holdend() { printf '%s\t%s\tmake test\t%s\n' "$(date -r $(($(date +%s) - $1 - $2)) +%FT%T)" "$2" "$3" >> "$holds"; }
# A tree whose folder was removed is no builder: not in --builders, and not in the builders line of
# a wait. The same hold line of an existing folder is.
gone="$tmp/gone"
mkdir "$gone"
rmdir "$gone"
reset_builders
holdend 300 30 "$gone"
out="$("$repo/scripts/with-lock.sh" --builders 2>&1)"
[[ -z "$out" ]] || fail "--builders, a removed folder: [$out]"
reset_builders
holdend 300 30 "$ta"
out="$("$repo/scripts/with-lock.sh" --builders 2>&1)"
[[ "$out" == "$ta" ]] || fail "--builders, an existing folder: [$out] (want $ta)"
reset_builders
hold
echo "$ta" > "$lock/tree"
holdend 300 30 "$gone"
capcall "$tmp/wt" touch "$tmp/ran"
[[ $code -eq 75 && "$out" == *'held by pid'* && "$out" != *'builders in the last'* ]] || fail "builders line, a removed folder: exit $code: $out"
reset_builders
hold
echo "$ta" > "$lock/tree"
holdend 300 30 "$tb"
capcall "$tmp/wt" touch "$tmp/ran"
[[ $code -eq 75 && "$out" == *"builders in the last 20 min: 2 ($ta, $tb); the cap is 2 (long-runs.md)"* ]] || fail "builders line, an existing folder: exit $code: $out"
# A wait line alone is no sign of a building tree: it needs a hold line.
reset_builders
printf '%s\t61\ttouch x\tmake test\t%s\n' "$(ago 5)" "$ta" > "$waits"
out="$("$repo/scripts/with-lock.sh" --builders 2>&1)"
[[ -z "$out" ]] || fail "--builders, a wait line alone: [$out]"
holdend 300 30 "$ta"
out="$("$repo/scripts/with-lock.sh" --builders 2>&1)"
[[ "$out" == "$ta" ]] || fail "--builders, a wait line and a hold line: [$out]"
# Two trees with one hold line of 9 s each are not listed, and the cap lets a call run; with two
# lines of 5 s each (10 s) they are listed and the cap holds the call.
reset_builders
holdend 300 9 "$ta"
holdend 200 9 "$tb"
out="$("$repo/scripts/with-lock.sh" --builders 2>&1)"
[[ -z "$out" ]] || fail "--builders, lines of 9 s: [$out]"
rm -f "$tmp/ran"
capcall "$repo" touch "$tmp/ran"
[[ $code -eq 0 && -e "$tmp/ran" && "$out" != *"$cap_text"* ]] || fail "cap, trees with 9 s: exit $code (want 0 at once, no cap line): $out"
reset_builders
holdend 400 5 "$ta"
holdend 300 5 "$ta"
holdend 200 5 "$tb"
holdend 100 5 "$tb"
out="$("$repo/scripts/with-lock.sh" --builders 2>&1)"
[[ "$out" == "$(printf '%s\n%s' "$ta" "$tb")" ]] || fail "--builders, two lines of 5 s: [$out]"
rm -f "$tmp/ran"
capcall "$repo" touch "$tmp/ran"
[[ $code -eq 75 && ! -e "$tmp/ran" && "$out" == *"$cap_text: "* ]] || fail "cap, trees with 5 s and 5 s: exit $code (want 75): $out"
# The minutes of the cap line: the time until the first tree falls under the floor. T keeps 5 s
# after its first line leaves the window (in 5 min 30 s), so it leaves the list then, not when its
# last line ends. U has one line of 30 s that ends 2 min ago.
reset_builders
holdend 870 5 "$ta"
holdend 300 5 "$ta"
holdend 120 30 "$tb"
rm -f "$tmp/ran"
capcall "$repo" touch "$tmp/ran"
[[ $code -eq 75 && "$out" == *"$cap_text: $ta, $tb; 6 min until $ta ages out"* ]] || fail "cap, T with 5 s and 5 s: exit $code (want 75, 6 min until T): $out"
# Near input: lines of 10 s keep T in the list until its last line leaves the window.
reset_builders
holdend 870 10 "$ta"
holdend 300 10 "$ta"
holdend 120 30 "$tb"
capcall "$repo" touch "$tmp/ran"
[[ $code -eq 75 && "$out" == *"$cap_text: $ta, $tb; 15 min until $ta ages out"* ]] || fail "cap, T with 10 s and 10 s: exit $code (want 75, 15 min until T): $out"
# Which tree the line names: A has one line of 30 s that ends 10 min ago, T has lines of 5 s that end
# 19 min 30 s and 1 min ago. T falls under the floor in 30 s, before A leaves.
reset_builders
holdend 600 30 "$ta"
holdend 1170 5 "$tb"
holdend 60 5 "$tb"
capcall "$repo" touch "$tmp/ran"
[[ $code -eq 75 && "$out" == *"$cap_text: $tb, $ta; 1 min until $tb ages out"* ]] || fail "cap, A and T: exit $code (want 75, 1 min until T): $out"
reset_builders
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
WITH_LOCK_BUILDERS_FLOOR=0 WITH_LOCK_NO_CAP=1 capcall "$repo" touch "$tmp/ran"
rm -f "$tmp/ran"
WITH_LOCK_BUILDERS_FLOOR=0 capcall "$tmp/wt" touch "$tmp/ran"
[[ $code -eq 0 && -e "$tmp/ran" ]] || fail "cap, a nocap line and one other tree: exit $code: $out"
# A NO_CAP call that waited writes a wait line with the last column nocap.
reset_builders
hold_for 1
WITH_LOCK_NO_CAP=1 WITH_LOCK_MAX_WAIT=5 capcall "$repo" touch "$tmp/ran"
[[ $code -eq 0 && "$(tail -n 1 "$waits" | awk -F'\t' '{ print NF, $6 }')" == '6 nocap' ]] || fail "cap, nocap wait line: exit $code [$(tail -n 1 "$waits" 2>&1)]: $out"
reset_builders

# scripts/bundle.sh takes the build lock itself, after its path check, and keeps the wait limit and
# the cap of an ordinary call. The copy in the temporary repo runs a fake icon.sh and a fake swift
# (first on the PATH) that logs whether the lock folder holds a live pid, and exits 3.
cp "$(dirname "$script")/bundle.sh" "$repo/scripts/bundle.sh"
printf '#!/bin/bash\necho icon >> "%s"\n' "$tmp/bundle.log" > "$repo/scripts/icon.sh"
chmod +x "$repo/scripts/icon.sh"
mkdir -p "$fake/bin"
cat > "$fake/bin/swift" << EOF
#!/bin/bash
pid="\$(cat "$lock/pid" 2>/dev/null)"
if [[ -n "\$pid" ]] && kill -0 "\$pid" 2>/dev/null; then echo swift-live-lock >> "$tmp/bundle.log"; else echo swift-no-lock >> "$tmp/bundle.log"; fi
exit 3
EOF
chmod +x "$fake/bin/swift"
# bundlecall <command...>: out and code hold the result; the wait limit is 1 s.
bundlecall() {
  out="$(cd "$repo" && PATH="$fake/bin:$PATH" WITH_LOCK_MAX_WAIT=1 WITH_LOCK_RETRY=1 "$@" 2>&1)"
  code=$?
}
no_run() { [[ ! -e "$tmp/bundle.log" ]] || fail "bundle.sh, $1: icon.sh or swift ran: $(cat "$tmp/bundle.log")"; }
reset_builders
rm -f "$tmp/bundle.log"
bundlecall scripts/bundle.sh
[[ $code -eq 3 && "$(paste -sd, "$tmp/bundle.log")" == icon,swift-live-lock && ! -e "$lock" ]] ||
  fail "bundle.sh, free lock: exit $code (want 3), log [$(paste -sd, "$tmp/bundle.log" 2>&1)]: $out"
# A live holder: the wait ends at the limit, with no icon.sh and no swift.
reset_builders
rm -f "$tmp/bundle.log"
hold
bundlecall scripts/bundle.sh
[[ $code -eq 75 && "$out" == *'still waiting after 1 s'* && "$(cat "$lock/pid")" == "$holder" ]] ||
  fail "bundle.sh, live holder: exit $code (want 75): $out"
no_run "live holder"
# Two other building trees and a free lock: the cap line and exit 75, with no swift.
reset_builders
rm -f "$tmp/bundle.log"
holdline 5 "$ta"
holdline 3 "$tb"
bundlecall scripts/bundle.sh
[[ $code -eq 75 && "$out" == *"$cap_text: $ta, $tb"* && ! -e "$lock" ]] ||
  fail "bundle.sh, 2 other building trees: exit $code (want 75, the cap line): $out"
no_run "2 other building trees"
# Under the hold of a caller (its DIRIGIBLE_BUILD_LOCK is in the pid file), and under an outer
# with-lock.sh call: it runs at once, once, and builds under that hold.
reset_builders
rm -f "$tmp/bundle.log"
hold
DIRIGIBLE_BUILD_LOCK=$holder bundlecall scripts/bundle.sh
[[ $code -eq 3 && "$(paste -sd, "$tmp/bundle.log")" == icon,swift-live-lock && ! -e "$waits" && ! -e "$holds" ]] ||
  fail "bundle.sh, under the hold of a caller: exit $code (want 3), log [$(paste -sd, "$tmp/bundle.log" 2>&1)]: $out"
reset_builders
rm -f "$tmp/bundle.log"
bundlecall scripts/with-lock.sh scripts/bundle.sh
[[ $code -eq 3 && "$(paste -sd, "$tmp/bundle.log")" == icon,swift-live-lock && ! -e "$waits" ]] ||
  fail "bundle.sh, under an outer with-lock.sh call: exit $code (want 3), log [$(paste -sd, "$tmp/bundle.log" 2>&1)]: $out"
# A bundle path outside build/ exits 2 before the lock: no lock folder, wait line, or hold line.
for path in /private/tmp/dirigible-guard.app build/../dirigible-guard.app; do
  reset_builders
  rm -f "$tmp/bundle.log"
  bundlecall scripts/bundle.sh "$path"
  [[ $code -eq 2 && "$out" == *'the bundle path must be build/<name>.app'* && ! -e "$lock" && ! -e "$waits" && ! -e "$holds" ]] ||
    fail "bundle.sh, path $path: exit $code (want 2, no lock, no log line): $out"
  no_run "path $path"
done
reset_builders

# The hold limit WITH_LOCK_MAX_HOLD: a command that runs past it gets TERM on its process group,
# then KILL after WITH_LOCK_HOLD_GRACE seconds; the lock goes, the hold line gets the fifth column
# limit, and the call exits 124. A command that ends in time keeps its status, and 0 turns the
# limit off. The default is in $lock/maxhold while the lock is held: 30 min, and for a call with no
# wait limit (a release call, WITH_LOCK_MAX_WAIT=0) 2 times hold_base of lock-words.sh, at least
# 60 min.
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
# A grace time that is not whole seconds exits 2 before the command runs: the hooks pass adds it to
# the bound in line 6 of its file.
rm -f "$tmp/grace.ran"
out="$(WITH_LOCK_HOLD_GRACE=0.5 "$repo/scripts/with-lock.sh" touch "$tmp/grace.ran" 2>&1)"
code=$?
[[ $code -eq 2 && ! -e "$tmp/grace.ran" && ! -e "$lock" && "$out" == *"WITH_LOCK_HOLD_GRACE is '0.5'; give whole seconds"* ]] ||
    fail "WITH_LOCK_HOLD_GRACE=0.5: exit $code (want 2), command ran [$(ls "$tmp/grace.ran" 2>/dev/null)]: $out"
# A step limit of test-shards.sh (the file <lock>/shard-limit) gives the hold line the column limit,
# so the push check that it ended is no base of a limit. The exit stays that of the command, and no
# "ran past WITH_LOCK_MAX_HOLD" line prints.
reset_builders
printf '#!/bin/bash\n: > "%s/shard-limit"\nexit 1\n' "$lock" > "$fake/shardlimit"
chmod +x "$fake/shardlimit"
"$repo/scripts/with-lock.sh" "$fake/shardlimit" > "$tmp/wait.out" 2>&1
code=$?
started="" seconds=0 command="" htree="" word=""
IFS=$'\t' read -r started seconds command htree word < "$holds"
[[ $code -eq 1 && "$word" == limit && "$command" == "$fake/shardlimit" ]] || fail "shard-limit file: exit $code, hold line [$started] [$seconds] [$command] [$htree] [$word]"
[[ "$(cat "$tmp/wait.out")" != *'ran past WITH_LOCK_MAX_HOLD'* && ! -e "$lock" ]] || fail "shard-limit file: a hold limit line or the lock stays: $(cat "$tmp/wait.out")"
# A TERM, an INT, or a HUP to a push check stops the process group of its command, gives its hold
# line the column limit too, and exits 143, 130, or 129. A command that exits 143 by itself keeps
# its four-column hold line. set -m: a background job of a script starts with INT ignored.
mkdir -p "$tmp/slowbin"
printf '#!/bin/bash\necho $$ > "%s"\nexec sleep 60\n' "$tmp/inner" > "$tmp/slowbin/make"
chmod +x "$tmp/slowbin/make"
for stop in TERM:143 INT:130 HUP:129; do
  sig="${stop%:*}"
  reset_builders
  rm -f "$tmp/inner"
  set -m
  "$repo/scripts/with-lock.sh" "$tmp/slowbin/make" check-changed BASE=origin/main > "$tmp/wait.out" 2>&1 &
  waiter=$!
  set +m
  until_true 50 test -s "$tmp/inner" || fail "a $sig to a push check: the command did not start"
  inner="$(cat "$tmp/inner" 2>/dev/null)"
  kill "-$sig" "$waiter"
  wait "$waiter"
  code=$?
  waiter=""
  until_true 50 dead "$inner" || { fail "a $sig to a push check: the command still runs"; kill "$inner" 2>/dev/null; }
  inner=""
  started="" seconds=0 command="" htree="" word="" mark=""
  IFS=$'\t' read -r started seconds command htree word mark < "$holds"
  [[ $code -eq ${stop#*:} && "$word" == limit && "$mark" == nocap && "$command" == "$tmp/slowbin/make check-changed BASE=origin/main" ]] ||
    fail "a $sig to a push check: hold line [$(cat "$holds" 2>/dev/null)], exit $code"
  [[ "$(cat "$tmp/wait.out")" != *'ran past WITH_LOCK_MAX_HOLD'* ]] || fail "a $sig to a push check: a hold limit line: $(cat "$tmp/wait.out")"
done
reset_builders
"$repo/scripts/with-lock.sh" bash -c 'exit 143' > /dev/null 2>&1
code=$?
[[ $code -eq 143 && "$(awk -F'\t' '{ print NF }' "$holds")" == 4 ]] || fail "a command that exits 143: exit $code, hold line [$(cat "$holds" 2>/dev/null)]"
# The default limit: 30 min for an ordinary call, 60 min for a release call with no push check in
# the log, and 2 times hold_base when that is over 30 min. A killed push check does not count.
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
# The fixtures test the window of hold_base, its limit slot, its numeric order, and a field that is
# no number. write_holds <seconds>[:limit]... writes the lines oldest first.
write_holds() {
  local s m=$# word
  for s in "$@"; do
    word=""
    [[ $s != *:limit ]] || word=limit
    printf '%s\t%s\tmake check-changed BASE=origin/main\t/t/a\t%s\tnocap\n' "$(ago $((m--)))" "${s%:limit}" "$word"
  done > "$holds"
}
for fixture in '6748|3374 s then 174 s|3374 174' \
  '3600|3374 s then ten 174 s|3374 174 174 174 174 174 174 174 174 174 174' \
  '6748|3374 s as the 10th uncut line before a limit line|3374 174 174 174 174 174 174 174 174 174 9000:limit' \
  '6748|3374 s then 999 s|3374 999' \
  '6748|a field that is no number, then 3374 s|x 3374'; do
  IFS='|' read -r want name spec <<< "$fixture"
  read -ra lines <<< "$spec"
  write_holds "${lines[@]}"
  out="$(WITH_LOCK_MAX_WAIT=0 "$repo/scripts/with-lock.sh" bash -c "cat '$lock/maxhold'" 2>&1)"
  [[ "$out" == "$want" ]] || fail "default hold limit, WITH_LOCK_MAX_WAIT=0, $name: [$out]"
  out="$("$repo/scripts/with-lock.sh" "$tmp/relbin/make" check-changed BASE=origin/main 2>&1)"
  [[ "$out" == "$want" ]] || fail "default hold limit, release call, $name: [$out]"
done
# --builders prints the hold seconds of the live holder, and its limit when the lock folder has one.
reset_builders
hold
echo /t/holder > "$lock/tree"
echo 1800 > "$lock/maxhold"
touch -t "$(date -r $(($(date +%s) - 100)) +%Y%m%d%H%M.%S)" "$lock/pid"
out="$("$repo/scripts/with-lock.sh" --builders 2>&1)"
[[ "$out" =~ holder:\ /t/holder\ held\ (99|100|101|102)\ s\ of\ 1800\ s ]] || fail "--builders, hold seconds: [$out]"
reset_builders

# --release-holder (header of with-lock.sh) takes no lock, writes no wait or hold line, and keeps no
# waiting marker. Inside a locked process tree (DIRIGIBLE_BUILD_LOCK holds the pid of the lock
# folder) it never reaches the exec of the command.
( : ) & rh_dead=$!
wait "$rh_dead"
# A dead group leader with a live member: kill -0 on the leader pid fails, kill -0 on -<leader> works.
set -m
( sleep 60 > /dev/null 2>&1 & echo $! > "$tmp/rh.member" ) &
rh_leader=$!
set +m
wait "$rh_leader"
rh_member="$(cat "$tmp/rh.member")"
rh_state() { # <kind>: write the lock state of a case
  reset_builders
  rm -rf "$marks" "$frees"
  case "$1" in
    hooks | plain-free)
      mkdir -p "$frees"
      printf '%s\nmake test-hooks DIRIGIBLE_HOOKS_ALL=1\n%s\n' "$(LC_ALL=C TZ=UTC0 ps -o lstart= -p $$ | sed 's/^ *//')" "${1/plain-free/}" > "$frees/$$" ;;
    release | dead-release | dead-release-child | dead-release-group | ordinary | bench | lane | dead-lane | filter | lane-test | pairs | compare | lines | make-bench | mutation | flake | dead-bench)
      mkdir -p "$lock"
      case "$1" in dead-release* | dead-lane | dead-bench) echo "$rh_dead" > "$lock/pid" ;; *) echo "$$" > "$lock/pid" ;; esac
      case "$1" in
        dead-release-child) echo "$$" > "$lock/child" ;;
        dead-release-group) echo "$rh_leader" > "$lock/child" ;;
      esac
      case "$1" in
        ordinary) echo 'make build' > "$lock/command" ;;
        bench | dead-bench) echo 'scripts/bench.sh' > "$lock/command" ;;
        pairs) echo 'scripts/bench-pairs.sh origin/main NavBench 5 /t/pairs' > "$lock/command" ;;
        compare) echo 'scripts/bench-pairs.sh --compare /t/pairs' > "$lock/command" ;;
        lines) echo 'scripts/bench-pairs.sh --lines /t/b.log' > "$lock/command" ;;
        make-bench) echo 'make FILTER=NavBench bench' > "$lock/command" ;;
        mutation) echo '.claude/skills/deliver/scripts/mutation-pass.sh /t/wt' > "$lock/command" ;;
        flake) echo 'scripts/flake-monitor/loop.sh' > "$lock/command" ;;
        lane | dead-lane) echo 'scripts/test-stress.sh --runs 1 out' > "$lock/command" ;;
        filter) echo 'make test-filter FILTER=ATests' > "$lock/command" ;;
        lane-test) echo 'bash scripts/test-stress.test.sh' > "$lock/command" ;;
        *) : > "$lock/release"; echo 'make check-changed BASE=origin/main' > "$lock/command" ;;
      esac ;;
    ticket) mkdir -p "$first/$$" ;;
    dead-ticket) mkdir -p "$first/$rh_dead" ;;
    marker | dead-marker)
      mkdir -p "$marks"
      if [[ "$1" == marker ]]; then printf '\n1\n/t/bench\n' > "$marks/$$"; else printf '\n1\n/t/bench\n' > "$marks/$rh_dead"; fi ;;
  esac
}
rh_check() { # <state> <want exit> <want stdout> [VAR=value...]
  local state="$1" want="$2" wout="$3" out code
  shift 3
  rh_state "$state"
  out="$(env WITH_LOCK_MAX_WAIT=2 "$@" "$repo/scripts/with-lock.sh" --release-holder 2> "$tmp/rh.err")"
  code=$?
  [[ $code -eq $want && "$out" == "$wout" ]] || fail "--release-holder, $state $*: exit $code, stdout [$out], want exit $want, stdout [$wout]"
  [[ ! -s "$tmp/rh.err" ]] || fail "--release-holder, $state $*: stderr [$(cat "$tmp/rh.err")]"
  [[ ! -e "$waits" && ! -e "$holds" && -z "$(ls "$waiting" 2>/dev/null)" ]] ||
    fail "--release-holder, $state $*: a wait line, a hold line, or a waiting marker"
}
rh_cmd='make check-changed BASE=origin/main'
rh_check release 0 "holder: $rh_cmd"
rh_check dead-release 1 ''
rh_check dead-release-child 0 "holder: $rh_cmd"
rh_check dead-release-group 0 "holder: $rh_cmd"
builtin kill "$rh_member" 2>/dev/null
rh_check ordinary 1 ''
rh_check bench 1 ''
# A stress lane is a holder as well; a make test-filter call, the test of the lane, and a dead lane are not.
rh_check lane 0 'holder: scripts/test-stress.sh --runs 1 out'
rh_check filter 1 ''
rh_check lane-test 1 ''
rh_check dead-lane 1 ''
rh_check free 1 ''
# A live lock-free hooks pass is a holder for the CPU share; a lock-free file of no kind is not.
rh_check hooks 0 'holder: make test-hooks DIRIGIBLE_HOOKS_ALL=1'
rh_check plain-free 1 ''
rh_check ticket 0 "ticket: $$"
rh_check dead-ticket 1 ''
[[ ! -e "$first/$rh_dead" ]] || fail '--release-holder: the ticket of a dead pid stays'
rh_check release 0 "holder: $rh_cmd" DIRIGIBLE_BUILD_LOCK=$$
rh_check ordinary 1 '' DIRIGIBLE_BUILD_LOCK=$$
rh_check dead-release 1 '' DIRIGIBLE_BUILD_LOCK=$rh_dead

# --long-holder (header of with-lock.sh), which agent-guard.sh reads: the --release-holder line
# first, then the holder of a bench, a pairs run, make bench, a mutation pass, or a flake loop, or a
# live bench marker. Each state exits 0 or 1 (never 127), with no lock, wait line, hold line, or
# waiting marker.
lh_check() { # <state> <want exit> <want stdout> [VAR=value...]
  local state="$1" want="$2" wout="$3" out code
  shift 3
  rh_state "$state"
  out="$(env WITH_LOCK_MAX_WAIT=2 "$@" "$repo/scripts/with-lock.sh" --long-holder 2> "$tmp/lh.err")"
  code=$?
  [[ $code -eq $want && "$out" == "$wout" ]] || fail "--long-holder, $state $*: exit $code, stdout [$out], want exit $want, stdout [$wout]"
  [[ ! -s "$tmp/lh.err" ]] || fail "--long-holder, $state $*: stderr [$(cat "$tmp/lh.err")]"
  [[ ! -e "$waits" && ! -e "$holds" && -z "$(ls "$waiting" 2>/dev/null)" ]] ||
    fail "--long-holder, $state $*: a wait line, a hold line, or a waiting marker"
}
lh_check bench 0 'holder: scripts/bench.sh'
lh_check pairs 0 'holder: scripts/bench-pairs.sh origin/main NavBench 5 /t/pairs'
lh_check make-bench 0 'holder: make FILTER=NavBench bench'
lh_check mutation 0 'holder: .claude/skills/deliver/scripts/mutation-pass.sh /t/wt'
lh_check flake 0 'holder: scripts/flake-monitor/loop.sh'
lh_check marker 0 "bench marker pid $$ (/t/bench)"
lh_check release 0 "holder: $rh_cmd"
lh_check lane 0 'holder: scripts/test-stress.sh --runs 1 out'
lh_check ticket 0 "ticket: $$"
lh_check ordinary 1 ''
# bench-pairs.sh --compare and --lines take no lock (long_words of lock-words.sh), so they are no long holder.
lh_check compare 1 ''
lh_check lines 1 ''
lh_check filter 1 ''
lh_check free 1 ''
# The lock-free hooks pass makes no agent wait: an ordinary call runs beside it.
lh_check hooks 1 ''
lh_check dead-bench 1 ''
lh_check dead-ticket 1 ''
lh_check dead-marker 1 ''
[[ ! -e "$marks/$rh_dead" ]] || fail '--long-holder: the bench marker of a dead pid stays'
lh_check bench 0 'holder: scripts/bench.sh' DIRIGIBLE_BUILD_LOCK=$$
reset_builders
rm -rf "$marks"

# The lock-free hooks pass. The fake scripts of $fake/hpl log "start <name> <words>" and
# "end <name> <words>"; the fake hooks pass also logs whether the lock folder exists and
# DIRIGIBLE_HOOKS_PASS, writes its pid to $HPL_STATE.pid, and runs until $HPL_GATE goes. hpl_pass [<word>...] starts make test-hooks
# with the words (default DIRIGIBLE_HOOKS_ALL=1) in the background ($inner), and returns 0 when it
# runs.
mkdir -p "$fake/hpl/flake-monitor"
cat > "$fake/hpl/make" << 'EOF'
#!/bin/bash
echo "start ${0##*/} $*" >> "$HPL_ORDER"
if [[ " $* " == *" test-hooks "* ]]; then
    echo $$ > "$HPL_STATE.pid"
    { [[ -d "$HPL_LOCK" ]] && echo lock || echo nolock; echo "${DIRIGIBLE_HOOKS_PASS-unset}"; } > "$HPL_STATE"
    while [[ -e "$HPL_GATE" ]]; do sleep 0.1; done
fi
echo "end ${0##*/} $*" >> "$HPL_ORDER"
EOF
chmod +x "$fake/hpl/make"
for n in bench.sh bench-pairs.sh land.sh test-stress.sh mutation-pass.sh flake-monitor/loop.sh swift; do cp "$fake/hpl/make" "$fake/hpl/$n"; done
export HPL_ORDER="$tmp/hpl.order" HPL_STATE="$tmp/hpl.state" HPL_GATE="$tmp/hpl.gate" HPL_LOCK="$lock"
hpl_order() { paste -sd'|' - < "$HPL_ORDER" 2>/dev/null; }
hpl_pass() {
    reset_builders
    rm -rf "$frees"
    rm -f "$HPL_ORDER" "$HPL_STATE" "$HPL_STATE.pid"
    touch "$HPL_GATE"
    "$repo/scripts/with-lock.sh" "$fake/hpl/make" test-hooks "${@:-DIRIGIBLE_HOOKS_ALL=1}" > "$tmp/hpl.out" 2>&1 &
    inner=$!
    until_true 50 test -s "$HPL_STATE"
}
hpl_end() { rm -f "$HPL_GATE"; until_true 50 dead "$inner"; wait "$inner" 2>/dev/null; hpl_code=$?; inner=""; }
# The hooks pass with no long holder: it runs at once with no lock, gives the command its pid as
# DIRIGIBLE_HOOKS_PASS, keeps a lock-free file of the kind hooks, and writes no wait or hold line.
if hpl_pass; then
    [[ "$(paste -sd' ' - < "$HPL_STATE")" == "nolock $inner" && "$(sed -n 3p "$frees/$inner" 2>/dev/null)" == hooks ]] ||
        fail "hooks pass: state [$(paste -sd' ' - < "$HPL_STATE")], file [$(cat "$frees/$inner" 2>/dev/null)], want [nolock $inner] and kind hooks"
    hpl_end
    [[ $hpl_code -eq 0 && ! -e "$waits" && ! -e "$holds" && "$(cat "$tmp/hpl.out")" == *'lock-free targets (test-hooks)'* ]] ||
        fail "hooks pass: exit $hpl_code, wait or hold line [$(cat "$waits" "$holds" 2>/dev/null)]: $(cat "$tmp/hpl.out")"
else
    fail "hooks pass: it did not run with no holder: $(cat "$tmp/hpl.out")"
    hpl_end
fi
# A HOOK_TESTS= word keeps the plain lock-free call: no kind hooks and no DIRIGIBLE_HOOKS_PASS.
hpl_pass HOOK_TESTS=a DIRIGIBLE_HOOKS_ALL=1 || fail "HOOK_TESTS= word: the call did not run: $(cat "$tmp/hpl.out")"
[[ "$(paste -sd' ' - < "$HPL_STATE")" == 'nolock unset' && -z "$(sed -n 3p "$frees/$inner" 2>/dev/null)" ]] ||
    fail "HOOK_TESTS= word: state [$(paste -sd' ' - < "$HPL_STATE")], file [$(cat "$frees/$inner" 2>/dev/null)]"
hpl_end
# A long holder that starts while the hooks pass runs waits with no lock, so an ordinary call runs
# during its wait, and it starts its command only after the pass ends.
for cmd in "bench.sh NavBench" "bench-pairs.sh /x/main NavBench 3 /x/pairs" "make check-changed BASE=origin/main" "land.sh t pr.md" \
    "make dmg" "test-stress.sh --runs 1 out" "flake-monitor/loop.sh 10 ATests" "mutation-pass.sh $repo batch"; do
    name="${cmd%% *}" name="start ${name##*/} ${cmd#* }"
    hpl_pass || { fail "$cmd: the hooks pass did not start: $(cat "$tmp/hpl.out")"; hpl_end; continue; }
    WITH_LOCK_MAX_WAIT=0 "$repo/scripts/with-lock.sh" "$fake/hpl/"$cmd > "$tmp/hpl-long.out" 2>&1 &
    waiter=$!
    until_true 50 grep -q 'hooks pass pid' "$tmp/hpl-long.out" || fail "$cmd: no wait line for the hooks pass: $(cat "$tmp/hpl-long.out")"
    sleep 0.3
    [[ ! -e "$lock" && "$(hpl_order)" != *"$name"* ]] ||
        fail "$cmd: during the pass: lock pid [$(cat "$lock/pid" 2>/dev/null)] (want no lock), order [$(hpl_order)]"
    out="$(WITH_LOCK_MAX_WAIT=2 "$repo/scripts/with-lock.sh" "$fake/hpl/swift" build 2>&1)"
    code=$?
    [[ $code -eq 0 && "$(hpl_order)" == *'|start swift build|end swift build' ]] ||
        fail "$cmd: an ordinary call during the wait of the long holder: exit $code, order [$(hpl_order)]: $out"
    hpl_end
    until_true 50 dead "$waiter"
    wait "$waiter" 2>/dev/null
    code=$?
    waiter=""
    [[ $code -eq 0 && "$(hpl_order)" == "start make test-hooks DIRIGIBLE_HOOKS_ALL=1|start swift build|end swift build|end make test-hooks DIRIGIBLE_HOOKS_ALL=1|$name"* ]] ||
        fail "$cmd: exit $code, order [$(hpl_order)]: $(cat "$tmp/hpl-long.out")"
done
# A long holder with a wait limit polls the pass each second, not each retry: it says so, and it
# starts within a few seconds after the pass ends.
if hpl_pass; then
    WITH_LOCK_RETRY=30 WITH_LOCK_MAX_WAIT=60 "$repo/scripts/with-lock.sh" "$fake/hpl/bench.sh" NavBench > "$tmp/hpl-long.out" 2>&1 &
    waiter=$!
    until_true 50 grep -q 'hooks pass pid' "$tmp/hpl-long.out" || fail "short poll: no wait line for the hooks pass: $(cat "$tmp/hpl-long.out")"
    sleep 1.5
    hpl_end
    until_true 50 grep -q 'start bench.sh NavBench' "$HPL_ORDER" ||
        fail "short poll: the long holder did not start in 5 s after the pass ended: order [$(hpl_order)]"
    until_true 50 dead "$waiter"
    wait "$waiter" 2>/dev/null
    code=$?
    waiter=""
    [[ $code -eq 0 && "$(grep -c 'hooks pass pid .*retry each 1 s$' "$tmp/hpl-long.out")" == 1 ]] ||
        fail "short poll: exit $code, want one wait line with retry each 1 s: $(cat "$tmp/hpl-long.out")"
else
    fail "short poll: the hooks pass did not start: $(cat "$tmp/hpl.out")"
    hpl_end
fi
# An ordinary call (make test-filter, swift build) starts at once while the hooks pass runs.
for cmd in "make test-filter FILTER=ATests" "swift build"; do
    hpl_pass || { fail "$cmd: the hooks pass did not start: $(cat "$tmp/hpl.out")"; hpl_end; continue; }
    out="$(WITH_LOCK_MAX_WAIT=2 "$repo/scripts/with-lock.sh" "$fake/hpl/"$cmd 2>&1)"
    code=$?
    [[ $code -eq 0 && "$(hpl_order)" == "start make test-hooks DIRIGIBLE_HOOKS_ALL=1|start $cmd"* ]] ||
        fail "$cmd during the hooks pass: exit $code, order [$(hpl_order)]: $out"
    hpl_end
done
# A long holder that waits for the pass starts before a second pass that starts during the wait.
if hpl_pass; then
    WITH_LOCK_MAX_WAIT=0 "$repo/scripts/with-lock.sh" "$fake/hpl/bench.sh" NavBench > "$tmp/hpl-long.out" 2>&1 &
    waiter=$!
    until_true 50 grep -q 'hooks pass pid' "$tmp/hpl-long.out" || fail "long holder before a second pass: no wait line: $(cat "$tmp/hpl-long.out")"
    WITH_LOCK_MAX_WAIT=0 "$repo/scripts/with-lock.sh" "$fake/hpl/make" test-hooks DIRIGIBLE_HOOKS_ALL=1 > "$tmp/hpl2.out" 2>&1 &
    other=$!
    sleep 0.5
    hpl_end
    until_true 50 dead "$waiter" && until_true 50 dead "$other" || fail "long holder before a second pass: a call did not end: $(hpl_order)"
    wait "$waiter" 2>/dev/null
    code=$?
    wait "$other" 2>/dev/null
    code2=$?
    waiter="" other=""
    hp="make test-hooks DIRIGIBLE_HOOKS_ALL=1"
    [[ $code -eq 0 && $code2 -eq 0 && "$(hpl_order)" == "start $hp|end $hp|start bench.sh NavBench|end bench.sh NavBench|start $hp|end $hp" ]] ||
        fail "long holder before a second pass: exit $code and $code2, order [$(hpl_order)]"
else
    fail "long holder before a second pass: the hooks pass did not start: $(cat "$tmp/hpl.out")"
    hpl_end
fi
# One hooks pass at a time: a second pass waits until the first one ends, and two passes that start
# together run one after the other.
hp="make test-hooks DIRIGIBLE_HOOKS_ALL=1"
if hpl_pass; then
    "$repo/scripts/with-lock.sh" "$fake/hpl/make" test-hooks DIRIGIBLE_HOOKS_ALL=1 > "$tmp/hpl2.out" 2>&1 &
    other=$!
    until_true 50 grep -q 'hooks pass pid' "$tmp/hpl2.out" || fail "a second hooks pass: no wait line: $(cat "$tmp/hpl2.out")"
    sleep 0.3
    [[ "$(hpl_order)" == "start $hp" ]] || fail "a second hooks pass: it ran beside the first: order [$(hpl_order)]"
    hpl_end
    until_true 50 dead "$other" || fail "a second hooks pass: it did not end after the first: $(cat "$tmp/hpl2.out")"
    wait "$other" 2>/dev/null
    code=$?
    other=""
    [[ $code -eq 0 && "$(hpl_order)" == "start $hp|end $hp|start $hp|end $hp" ]] ||
        fail "a second hooks pass: exit $code, order [$(hpl_order)]"
else
    fail "a second hooks pass: the first pass did not start: $(cat "$tmp/hpl.out")"
    hpl_end
fi
reset_builders
rm -rf "$frees"
rm -f "$HPL_ORDER" "$HPL_STATE" "$HPL_STATE.pid"
touch "$HPL_GATE"
"$repo/scripts/with-lock.sh" "$fake/hpl/make" test-hooks DIRIGIBLE_HOOKS_ALL=1 > "$tmp/hpl.out" 2>&1 &
inner=$!
"$repo/scripts/with-lock.sh" "$fake/hpl/make" test-hooks DIRIGIBLE_HOOKS_ALL=1 > "$tmp/hpl2.out" 2>&1 &
other=$!
sleep 1
[[ "$(hpl_order)" == "start $hp" ]] || fail "two hooks passes that start together: order after 1 s [$(hpl_order)], want one start"
rm -f "$HPL_GATE"
until_true 50 dead "$inner" && until_true 50 dead "$other" || fail "two hooks passes that start together: a pass did not end: $(hpl_order)"
wait "$inner" 2>/dev/null
code=$?
wait "$other" 2>/dev/null
code2=$?
inner="" other=""
[[ $code -eq 0 && $code2 -eq 0 && "$(hpl_order)" == "start $hp|end $hp|start $hp|end $hp" ]] ||
    fail "two hooks passes that start together: exit $code and $code2, order [$(hpl_order)]"
# A HUP or a KILL of the call of the hooks pass leaves no command that a long holder misses: HUP
# stops the process group of the command (it never logs its end), and after KILL the file stays live
# while that group runs.
for sig in HUP KILL; do
    hpl_pass || { fail "$sig: the hooks pass did not start: $(cat "$tmp/hpl.out")"; hpl_end; continue; }
    WITH_LOCK_MAX_WAIT=0 "$repo/scripts/with-lock.sh" "$fake/hpl/bench.sh" NavBench > "$tmp/hpl-long.out" 2>&1 &
    waiter=$!
    until_true 50 grep -q 'hooks pass pid' "$tmp/hpl-long.out" || fail "$sig: no wait line for the hooks pass: $(cat "$tmp/hpl-long.out")"
    kill "-$sig" "$inner"
    until_true 50 dead "$inner" || fail "$sig: the call of the pass did not end"
    wait "$inner" 2>/dev/null
    inner=""
    sleep 0.5
    want="start $hp|start bench.sh NavBench|end bench.sh NavBench"
    if [[ $sig == KILL ]]; then
        [[ "$(hpl_order)" == "start $hp" ]] || fail "KILL: the long holder did not wait for the command of the pass: order [$(hpl_order)]"
        want="start $hp|end $hp|start bench.sh NavBench|end bench.sh NavBench"
    fi
    rm -f "$HPL_GATE"
    until_true 50 dead "$(cat "$HPL_STATE.pid")" || fail "$sig: the command of the pass did not end: order [$(hpl_order)]"
    until_true 50 dead "$waiter" || fail "$sig: the long holder did not end: $(cat "$tmp/hpl-long.out")"
    wait "$waiter" 2>/dev/null
    code=$?
    waiter=""
    [[ $code -eq 0 && "$(hpl_order)" == "$want" ]] || fail "$sig: exit $code, order [$(hpl_order)], want [$want]"
done
# The hooks pass has a hold limit: a pass that never ends gets TERM at the limit and exits 124, and a
# waiting long holder then starts.
reset_builders
rm -rf "$frees"
rm -f "$HPL_ORDER" "$HPL_STATE" "$HPL_STATE.pid"
touch "$HPL_GATE"
WITH_LOCK_MAX_HOLD=1 WITH_LOCK_HOLD_GRACE=1 "$repo/scripts/with-lock.sh" "$fake/hpl/make" test-hooks DIRIGIBLE_HOOKS_ALL=1 > "$tmp/hpl.out" 2>&1 &
inner=$!
until_true 50 test -s "$HPL_STATE" || fail "hold limit: the hooks pass did not start: $(cat "$tmp/hpl.out")"
WITH_LOCK_MAX_WAIT=0 "$repo/scripts/with-lock.sh" "$fake/hpl/bench.sh" NavBench > "$tmp/hpl-long.out" 2>&1 &
waiter=$!
until_true 100 dead "$inner" || { fail "hold limit: the hooks pass did not stop at WITH_LOCK_MAX_HOLD=1: order [$(hpl_order)]"; rm -f "$HPL_GATE"; }
dead "$(cat "$HPL_STATE.pid")" || fail "hold limit: the command of the pass runs after the call ended"
wait "$inner" 2>/dev/null
code=$?
until_true 50 dead "$waiter" || fail "hold limit: the long holder did not start after the pass stopped: $(cat "$tmp/hpl-long.out")"
wait "$waiter" 2>/dev/null
code2=$?
hl_pid=$inner inner="" waiter=""
rm -f "$HPL_GATE"
[[ $code -eq 124 && $code2 -eq 0 && "$(hpl_order)" == "start $hp|start bench.sh NavBench|end bench.sh NavBench" &&
    "$(cat "$tmp/hpl.out")" == *'ran past WITH_LOCK_MAX_HOLD (1 s)'* && ! -e "$frees/$hl_pid" ]] ||
    fail "hold limit: exit $code (want 124), long holder exit $code2, order [$(hpl_order)]: $(cat "$tmp/hpl.out")"
# After a KILL of the call, no hold watcher stops the command of the pass, so its group keeps the
# file live only until the hold limit and the grace time end: a long holder then starts.
reset_builders
rm -rf "$frees"
rm -f "$HPL_ORDER" "$HPL_STATE" "$HPL_STATE.pid"
touch "$HPL_GATE"
WITH_LOCK_MAX_HOLD=3 WITH_LOCK_HOLD_GRACE=1 "$repo/scripts/with-lock.sh" "$fake/hpl/make" test-hooks DIRIGIBLE_HOOKS_ALL=1 > "$tmp/hpl.out" 2>&1 &
inner=$!
if until_true 50 test -s "$HPL_STATE" && until_true 50 awk 'NR == 5 { f = 1 } END { exit !f }' "$frees/$inner"; then
    kill -KILL "$inner"
    until_true 50 dead "$inner" || fail "bound after KILL: the call of the pass did not end"
    wait "$inner" 2>/dev/null
    WITH_LOCK_MAX_WAIT=0 "$repo/scripts/with-lock.sh" "$fake/hpl/bench.sh" NavBench > "$tmp/hpl-long.out" 2>&1 &
    waiter=$!
    until_true 100 dead "$waiter" || fail "bound after KILL: the long holder waits past the hold limit of the pass: order [$(hpl_order)]"
    wait "$waiter" 2>/dev/null
    code=$?
    [[ $code -eq 0 && "$(hpl_order)" == "start $hp|start bench.sh NavBench|end bench.sh NavBench" ]] && ! dead "$(cat "$HPL_STATE.pid")" ||
        fail "bound after KILL: exit $code, order [$(hpl_order)], want the bench beside the command of the pass: $(cat "$tmp/hpl-long.out")"
else
    fail "bound after KILL: the hooks pass did not start: $(cat "$tmp/hpl.out")"
fi
rm -f "$HPL_GATE"
until_true 50 dead "$(cat "$HPL_STATE.pid" 2>/dev/null)" || fail "bound after KILL: the command of the pass did not end"
inner="" waiter=""
# A hooks pass that cannot write its lock-free file exits 2 and runs nothing: no long holder could
# see it.
reset_builders
rm -rf "$frees"
rm -f "$HPL_ORDER" "$HPL_STATE" "$HPL_STATE.pid" "$HPL_GATE"
mkdir -p "$frees" && chmod a-w "$frees"
out="$("$repo/scripts/with-lock.sh" "$fake/hpl/make" test-hooks DIRIGIBLE_HOOKS_ALL=1 2>&1)"
code=$?
chmod u+w "$frees"
[[ $code -eq 2 && ! -e "$HPL_ORDER" && "$out" == *'cannot write the lock-free file'*'does not run'* ]] ||
    fail "unwritable lock-free folder: exit $code (want 2), order [$(hpl_order)]: $out"
# The hooks pass waits, with no lock, for a long holder that holds the lock.
HOLDER_COMMAND='make dmg' lockfree freewait "the hooks pass behind make dmg" "$fake/make" test-hooks DIRIGIBLE_HOOKS_ALL=1
reset_builders
rm -rf "$frees"
unset HPL_ORDER HPL_STATE HPL_GATE HPL_LOCK

# A pid variable that outlives its child can name a stranger when the kernel reuses the pid. A
# stranger is a process that is not a descendant of this shell: until_true and clear_hold (and so the
# EXIT trap) must leave it alone, and still stop a real child.
running() { local s; s="$(ps -o stat= -p "$1" 2>/dev/null)"; [[ -n "$s" && "$s" != Z* ]]; }
( sleep 30 & echo $! > "$tmp/stranger" )
stranger="$(cat "$tmp/stranger")"
waiter=$stranger
until_true 1 false
waiter=""
holder=$stranger
clear_hold
for _ in $(seq 10); do running "$stranger" || break; sleep 0.1; done
running "$stranger" || fail 'stale pid: until_true or clear_hold signalled a process that is not a child'
sleep 30 & mine=$!
holder=$mine
clear_hold
dead "$mine" || fail 'stale pid: clear_hold left a child of this shell running'
builtin kill "$stranger" 2>/dev/null

[[ $failures -eq 0 ]] && echo "with-lock tests: all passed"
exit $((failures > 0))
