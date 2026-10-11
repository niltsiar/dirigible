#!/bin/bash
# Check that mutate.py tells a killed, a surviving, and an unbuilt mutant apart, counts a kill
# with --expect only when the test output has the text outside a progress line, applies extra
# old/new pairs as one mutant, refuses an old text that is not in the file once, and always
# restores the file, counts a test past --timeout as a kill, replays a control from its log only
# with a time limit, reports a run of no test as NO TESTS, applies --in=<file> pairs to a second
# file, restores the file on SIGINT, SIGTERM, and SIGHUP, also when killpg raises EPERM, and in a
# git tree holds a lock that a second run refuses. Run by `make test-hooks`.
set -uo pipefail
mutate="$(cd "$(dirname "$0")" && pwd)/mutate.py"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Outside a git tree: no lock in the git dir of the repo that runs the tests.
cd "$tmp" || exit 1
file="$tmp/x.txt"
printf 'a = 1\nb = 1\n' > "$file"
before="$(shasum -a 256 "$file")"
build="grep -q 'a =' '$file'"
test="grep -q 'a = 1' '$file'"

expect() {
  local want="$1" name="$2" old="$3" new="$4" got
  shift 4
  got="$("$mutate" "$file" "$old" "$new" "$tmp/log" "$build" "$test" "$@" 2>&1)"
  got="$?:${got%%:*}"
  [[ "$got" == "$want" ]] || { echo "FAIL: expected $want, got $got: $name"; failures=$((failures + 1)); }
  [[ "$(shasum -a 256 "$file")" == "$before" ]] || { echo "FAIL: file changed after: $name"; failures=$((failures + 1)); }
}

expect '0:killed' 'the test fails on the mutant' 'a = 1' 'a = 2'
expect '1:survived' 'the test passes on the mutant' 'b = 1' 'b = 2'
expect '2:BUILD FAILED' 'the mutant does not build' 'a = 1' 'a 1'
# A build piped into another command: the build fails, the pipe ends with a command that passes.
build="grep -q 'a =' '$file' | cat"
expect '2:BUILD FAILED' 'a piped build that fails' 'a = 1' 'a 1'
build="grep -q 'a =' '$file'"
expect '2:mutate' 'the old text is not in the file' 'c = 1' 'c = 2'
expect '2:mutate' 'the old text is in the file twice' ' = 1' ' = 2'
# Two pairs are one mutant: the first edit alone survives, the second one kills it.
expect '0:killed' 'a second pair is in the same mutant' 'b = 1' 'b = 2' 'a = 1' 'a = 2'
expect '2:mutate' 'a second pair with no new text' 'b = 1' 'b = 2' 'a = 1'
expect '2:mutate' 'a second old text that is not in the file' 'b = 1' 'b = 2' 'c = 1' 'c = 2'

# --expect: the test prints its own failure message.
test="grep -q 'a = 1' '$file' || { echo 'expected a = 1'; exit 1; }"
expect_text() {
  local want="$1" name="$2" text="$3" got
  got="$("$mutate" --expect "$text" "$file" 'a = 1' 'a = 2' "$tmp/log" "$build" "$test" 2>&1)"
  got="$?:${got%%:*}"
  [[ "$got" == "$want" ]] || { echo "FAIL: expected $want, got $got: $name"; failures=$((failures + 1)); }
  [[ "$(shasum -a 256 "$file")" == "$before" ]] || { echo "FAIL: file changed after: $name"; failures=$((failures + 1)); }
}
expect_text '0:killed' 'the test output has the expected text' 'expected a = 1'
expect_text '4:WRONG FAILURE' 'the test fails with another message' 'index out of range'
# The expected text in the header of the log (the build command) does not count.
build="grep -q 'a =' '$file' # index out of range"
expect_text '4:WRONG FAILURE' 'the expected text is only in the log header' 'index out of range'
build="grep -q 'a =' '$file'"
# A test name is in the progress lines of every run (Swift Testing and XCTest), so it is not a reason.
test="echo '◇ Test foo(bar:) started.'; echo \"Test Case '-[T foo]' started.\"; echo '✔ Test foo(bar:) passed after 0.1 seconds.'; grep -q 'a = 1' '$file' || { echo 'expected a = 1'; exit 1; }"
expect_text '4:WRONG FAILURE' 'the expected text is only in a progress line' 'foo('
expect_text '4:WRONG FAILURE' 'the expected text is only in an XCTest progress line' '[T foo]'
expect_text '0:killed' 'the failure line after the progress lines has the text' 'expected a = 1'
# WRONG FAILURE prints, after the result line, up to 10 compared lines that hold a failure mark
# (the form to copy into the next --expect).
test="echo 'plain line'; for i in 1 2 3 4 5 6 7 8 9; do echo \"✘ Test t\$i() recorded an issue: (x → nil) == \$i\"; done; echo 'error: line 10'; echo 'line 11 failed'; exit 1"
got="$("$mutate" --expect 'not in the output' "$file" 'a = 1' 'a = 2' "$tmp/log" "$build" "$test" 2>&1)"
[[ "$(sed -n 2p <<<"$got")" == '✘ Test t1() recorded an issue: (x → nil) == 1' ]] || { echo "FAIL: WRONG FAILURE: no failing line after the result: $got"; failures=$((failures + 1)); }
[[ "$got" == *'error: line 10'* && "$got" != *'line 11 failed'* && "$got" != *'plain line'* ]] || { echo "FAIL: WRONG FAILURE: not the first 10 failing lines: $got"; failures=$((failures + 1)); }
test="grep -q 'a = 1' '$file' || { echo 'expected a = 1'; exit 1; }"

# --timeout: a test that runs past the limit is killed with its process group and counts as a kill.
check() {
  local want="$1" name="$2" got
  shift 2
  got="$("$mutate" "$@" 2>&1)"
  got="$?:${got%%:*}"
  [[ "$got" == "$want" ]] || { echo "FAIL: expected $want, got $got: $name"; failures=$((failures + 1)); }
  [[ "$(shasum -a 256 "$file")" == "$before" ]] || { echo "FAIL: file changed after: $name"; failures=$((failures + 1)); }
}
build="grep -q 'a =' '$file'"
started=$SECONDS
check '0:killed (hang)' 'a test that hangs' --timeout 1 "$file" 'a = 1' 'a = 2' "$tmp/log" "$build" 'sleep 30 | cat'
(( SECONDS - started < 10 )) || { echo "FAIL: the hung test ran $((SECONDS - started)) s"; failures=$((failures + 1)); }
# A test runner in its own process group (swiftpm-testing-helper makes one) must stop too.
check '0:killed (hang)' 'a hang in another process group' --timeout 1 "$file" 'a = 1' 'a = 2' "$tmp/log" "$build" \
  "bash -c 'set -m; sleep 31 & echo \$! > $tmp/pid; wait'"
sleep 0.5
! kill -0 "$(cat "$tmp/pid")" 2>/dev/null || { echo "FAIL: the process in another group still runs"; kill "$(cat "$tmp/pid")"; failures=$((failures + 1)); }
check '1:survived' 'a test under the limit' --timeout 10 "$file" 'b = 1' 'b = 2' "$tmp/log" "$build" "grep -q 'a = 1' '$file'"

# --replay: the control of a log runs again from its header, with its --expect.
test="grep -q 'a = 1' '$file' || { echo 'expected a = 1'; exit 1; }"
"$mutate" --expect 'expected a = 1' --timeout 10 "$file" 'b = 1' 'b = 2' "$tmp/first" "$build" "$test" 'a = 1' 'a = 2' > /dev/null
check '0:killed' 'a replay of a two-pair control' --replay "$tmp/first" "$tmp/again"
grep -q "^# expect: 'expected a = 1'" "$tmp/again" || { echo "FAIL: the replay lost --expect"; failures=$((failures + 1)); }
check '4:WRONG FAILURE' 'a replay with another --expect' --expect 'index out of range' --replay "$tmp/first" "$tmp/again"
# A replay needs a time limit, from the log header or the command line (start-window Phase 7: a
# replay with no limit hung for hours in a batch).
"$mutate" "$file" 'b = 1' 'b = 2' "$tmp/nolimit" "$build" "$test" > /dev/null
check '2:mutate' 'a replay with no time limit' --replay "$tmp/nolimit" "$tmp/nolimit-again"
[[ ! -e "$tmp/nolimit-again" ]] || { echo "FAIL: the replay with no limit ran"; failures=$((failures + 1)); }
check '1:survived' 'a replay with --timeout on the command line' --timeout 10 --replay "$tmp/nolimit" "$tmp/nolimit-again"
# A later change of the old text: the replay refuses, and the file stays.
printf 'a = 1\nb = 3\n' > "$file"
before="$(shasum -a 256 "$file")"
check '2:mutate' 'a replay after the old text changed' --replay "$tmp/first" "$tmp/again"

# A test run that runs no test (a filter that matches nothing) proves nothing: NO TESTS, not survived.
printf 'a = 1\nb = 1\n' > "$file"
before="$(shasum -a 256 "$file")"
check '5:NO TESTS' 'a SwiftPM run with no matching test' "$file" 'b = 1' 'b = 2' "$tmp/log" "$build" \
  "echo 'warning: No matching test cases were run'"
check '5:NO TESTS' 'a Swift Testing run of 0 tests' "$file" 'b = 1' 'b = 2' "$tmp/log" "$build" \
  "echo '✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.'"
check '1:survived' 'a run of 1 test that passes' "$file" 'b = 1' 'b = 2' "$tmp/log" "$build" \
  "echo '✔ Test run with 1 test in 1 suite passed after 0.001 seconds.'"

# --in=<file>: one mutant in two files. The first edit alone survives; the edit in the second file
# kills it. Both files are restored, and a replay reads both files from the log header.
file2="$tmp/y.txt"
printf 'c = 1\n' > "$file2"
before2="$(shasum -a 256 "$file2")"
test="grep -q 'a = 1' '$file' && grep -q 'c = 1' '$file2' || { echo 'expected c = 1'; exit 1; }"
check '0:killed' 'a pair in a second file' --expect 'expected c = 1' --timeout 10 "$file" 'b = 1' 'b = 2' "$tmp/two" "$build" "$test" \
  "--in=$file2" 'c = 1' 'c = 2'
[[ "$(shasum -a 256 "$file2")" == "$before2" ]] || { echo "FAIL: the second file changed"; failures=$((failures + 1)); }
check '0:killed' 'a replay of a two-file control' --replay "$tmp/two" "$tmp/two-again"
[[ "$(shasum -a 256 "$file2")" == "$before2" ]] || { echo "FAIL: the second file changed after the replay"; failures=$((failures + 1)); }
check '2:mutate' 'a second-file pair with no new text' "$file" 'b = 1' 'b = 2' "$tmp/log" "$build" "$test" "--in=$file2" 'c = 1'
check '2:mutate' 'a second-file old text that is not there' "$file" 'b = 1' 'b = 2' "$tmp/log" "$build" "$test" \
  "--in=$file2" 'd = 1' 'd = 2'

# --expect with --timeout: a hang is a kill only when the expect text came before the kill. A test
# whose failure report hangs (a large value in the assert message) prints no text, so it is not a
# kill of the control (timeline-navigation Phase 7: three such logs said killed (hang)).
check '4:WRONG FAILURE' 'a hang with no expect text' --expect 'expected a = 1' --timeout 1 "$file" 'a = 1' 'a = 2' \
  "$tmp/log" "$build" 'sleep 30 | cat'
check '0:killed (hang)' 'a hang after the expect text' --expect 'expected a = 1' --timeout 1 "$file" 'a = 1' 'a = 2' \
  "$tmp/log" "$build" "echo 'expected a = 1'; sleep 30 | cat"

# --side-effects: the test command acts on shared state (it opens Mission Control, posts HID events,
# or starts a probe). A replay of its log refuses unless --allow-side-effects is given
# (timeline-navigation Phase 7: a batch replay opened Mission Control during a test run).
"$mutate" --side-effects --timeout 10 "$file" 'b = 1' 'b = 2' "$tmp/fx" "$build" "$test" > /dev/null
grep -q '^# side-effects: yes' "$tmp/fx" || { echo "FAIL: the log does not mark the side effects"; failures=$((failures + 1)); }
check '2:mutate' 'a replay of a control with side effects' --replay "$tmp/fx" "$tmp/fx-again"
[[ ! -e "$tmp/fx-again" ]] || { echo "FAIL: the refused replay ran"; failures=$((failures + 1)); }
check '1:survived' 'an allowed replay of a control with side effects' --allow-side-effects --replay "$tmp/fx" "$tmp/fx-again"
grep -q '^# side-effects: yes' "$tmp/fx-again" || { echo "FAIL: the replay lost the mark"; failures=$((failures + 1)); }

# Succeeds when the process <pid> ends in [tenths] tenths of a second (default 50). A killed
# orphan exists until launchd reaps it, so one check at once is not enough.
ended() {
  for _ in $(seq "${2:-50}"); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

# ended waits for a process that ends 0.5 s after the call (flakes-2: under load, the killed sleep
# of the stop case was not reaped yet at the first check).
sleep 0.5 &
ended $! || { echo "FAIL: the test still runs after a late exit"; failures=$((failures + 1)); }
# A process that lives past the bound has not ended.
sleep 30 &
late=$!
! ended "$late" 3 || { echo "FAIL: a process that lives past the bound has ended"; failures=$((failures + 1)); }
{ kill "$late" && wait "$late"; } 2>/dev/null

# A stop by SIGTERM (not only SIGINT) restores the file and ends the test (start-window Phase 7: a
# replay ran for hours, and SIGTERM skipped the restore).
printf 'a = 1\nb = 1\n' > "$file"
before="$(shasum -a 256 "$file")"
# EPERM: on macOS, killpg of a group whose only member is an unreaped zombie raises EPERM (probe of
# run 2026-10-08-upkeep-batch-4); under load that failed the SIGTERM case. The fake does the real
# kill, then raises EPERM.
mkdir -p "$tmp/fake"
printf '%s\n' 'import errno, os' '_real = os.killpg' 'def killpg(pgid, sig):' '    _real(pgid, sig)' \
  "    raise PermissionError(errno.EPERM, 'Operation not permitted')" 'os.killpg = killpg' > "$tmp/fake/sitecustomize.py"
PYTHONPATH="$tmp/fake" check '0:killed (hang)' 'a hang when killpg raises EPERM' --timeout 1 "$file" 'a = 1' 'a = 2' "$tmp/log" "$build" 'sleep 33 | cat'
for sig in TERM HUP INT EPERM; do
  fake=""
  [[ $sig == EPERM ]] && sig=TERM fake="$tmp/fake"
  PYTHONPATH="$fake" "$mutate" "$file" 'b = 1' 'b = 2' "$tmp/stop" "$build" "sleep 32 & echo \$! > $tmp/pid; wait" > "$tmp/stop.out" 2>&1 &
  runner=$!
  started=no
  for _ in $(seq 300); do grep -q 'b = 2' "$file" && [[ -s "$tmp/pid" ]] && started=yes && break; sleep 0.1; done
  [[ $started == yes ]] || { echo "FAIL: the test did not start under SIG$sig"; failures=$((failures + 1)); }
  kill -"$sig" "$runner"
  wait "$runner"
  code=$?
  [[ "$code:$(cut -d: -f1 "$tmp/stop.out")" == "130:stopped" ]] || { echo "FAIL: SIG$sig gave $code: $(cat "$tmp/stop.out")"; failures=$((failures + 1)); }
  [[ "$(shasum -a 256 "$file")" == "$before" ]] || { echo "FAIL: file changed after SIG$sig"; failures=$((failures + 1)); }
  ended "$(cat "$tmp/pid")" || { echo "FAIL: the test still runs after SIG$sig"; kill "$(cat "$tmp/pid")"; failures=$((failures + 1)); }
  rm -f "$tmp/pid"
done

# In a git tree, a run holds a lock in the git dir. A second run refuses while the holder lives; the
# lock of a dead holder is taken over; the lock is gone after the run.
git init -q "$tmp/repo"
lock="$(git -C "$tmp/repo" rev-parse --absolute-git-dir)/dirigible-mutate.lock"
cd "$tmp/repo" || exit 1
mkdir "$lock" && echo $$ > "$lock/pid"
expect '2:mutate' 'a live lock holder' 'a = 1' 'a = 2'
sh -c 'exit 0' & dead=$!
wait "$dead"
echo "$dead" > "$lock/pid"
expect '0:killed' 'the lock of a dead holder' 'a = 1' 'a = 2'
[[ ! -e "$lock" ]] || { echo "FAIL: the lock is left after the run"; failures=$((failures + 1)); }
cd "$tmp" || exit 1

[[ $failures -eq 0 ]] && echo "mutate tests: all passed"
exit $((failures > 0))
