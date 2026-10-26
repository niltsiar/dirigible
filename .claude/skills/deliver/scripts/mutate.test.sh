#!/bin/bash
# Check that mutate.py tells a killed, a surviving, and an unbuilt mutant apart, counts a kill
# with --expect only when the test output has the text outside a progress line, applies extra
# old/new pairs as one mutant, refuses an old text that is not in the file once, and always
# restores the file, counts a test past --timeout as a kill, refuses an unknown option (the removed
# replay mode), reports a run of no test as NO TESTS, applies --in=<file> pairs to a second
# file, restores the file on SIGINT, SIGTERM, and SIGHUP, also when killpg raises EPERM, and in a
# git tree holds a lock that a second run refuses, refuses an --expect text that Swift Testing never
# prints before the build, and reports an exit 75 of the build or test as LOCK WAIT. A lone call
# runs under scripts/with-lock.sh once. Run by `make test-hooks`.
set -uo pipefail
unset MUTATION_PASS_HELD
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

# The replay mode and its side-effects flags are gone (each mutant of a pass runs once): an unknown
# option is refused before any change.
test="grep -q 'a = 1' '$file' || { echo 'expected a = 1'; exit 1; }"
for option in --replay --side-effects --allow-side-effects; do
  check '2:mutate' "the removed option $option" "$option" "$file" 'b = 1' 'b = 2' "$tmp/log" "$build" "$test"
done

# A test run that runs no test (a filter that matches nothing) proves nothing: NO TESTS, not survived.
printf 'a = 1\nb = 1\n' > "$file"
before="$(shasum -a 256 "$file")"
check '5:NO TESTS' 'a SwiftPM run with no matching test' "$file" 'b = 1' 'b = 2' "$tmp/log" "$build" \
  "echo 'warning: No matching test cases were run'"
check '5:NO TESTS' 'a Swift Testing run of 0 tests' "$file" 'b = 1' 'b = 2' "$tmp/log" "$build" \
  "echo '✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.'"
check '1:survived' 'a run of 1 test that passes' "$file" 'b = 1' 'b = 2' "$tmp/log" "$build" \
  "echo '✔ Test run with 1 test in 1 suite passed after 0.001 seconds.'"

# --expect: a text that Swift Testing can never print exits 2 before the build (the fake build leaves
# no marker file). Swift Testing prints each operand of the outermost comparison with its value
# ((rows(model) → [...]) == []), so the source text of the comparison is never in the output. Only
# the #expect and #require conditions of the --exact names of the test command are read, under Tests/.
mkdir -p "$tmp/Tests/Suite"
cat > "$tmp/Tests/Suite/CutTests.swift" <<'SWIFT'
@Suite struct CutTests {
    @Test func aUserCutShowsNoRow() { #expect(rows(model) == []) }
    @Test func aNestedComma() { #expect(f(a, b) == c) }
    @Test func aTwoBodyName() { #expect(ready) }
    @Test func anAndCondition() { #expect(x == 1 && y == 2) }
    @Test func aTryCondition() { #expect(try await load() == 3) }
    @Test func aLiteralLeft() { #expect([] == rows(model)) }
    @Test func aCommentArgument() { #expect(a == b, "a == b") }
    @Test func aCountBesideAnd() { #expect(rows.count == 0); #expect(ready && rows.count == 0) }
    @Test func aLoadBesideTry() { #expect(load() == 3); #expect(try await load() == 3) }
    @Test func aHelperMessage() { check("before the first tick") }
    func check(_ step: String) { #expect(ok, "\(step): edge") }
}
@Suite struct OtherTests {
    @Test func aTwoBodyName() { #expect(count(x) == 3) }
}
SWIFT
marker="$tmp/built"
mbuild="touch '$marker'"
# refuses <name> <text> <names>: exit 2, a reason about the printed form, and no build.
refuses() {
  local name="$1" text="$2" names="$3" got code
  rm -f "$marker"
  got="$("$mutate" --expect "$text" "$file" 'b = 1' 'b = 2' "$tmp/log" "$mbuild" "echo boom; exit 1 # --exact $names" 2>&1)"
  code=$?
  [[ $code -eq 2 && "$got" == *'Swift Testing prints each operand'* && "$got" == *'copy the text from the failure output'* ]] \
    || { echo "FAIL: $name: exit $code: $got"; failures=$((failures + 1)); }
  [[ ! -e "$marker" ]] || { echo "FAIL: $name: the build ran"; failures=$((failures + 1)); }
  [[ "$(shasum -a 256 "$file")" == "$before" ]] || { echo "FAIL: file changed after: $name"; failures=$((failures + 1)); }
}
# allows <name> <text> <test command>: the build ran, so the text was not refused.
allows() {
  local name="$1" text="$2" tcommand="$3" got
  rm -f "$marker"
  got="$("$mutate" --expect "$text" "$file" 'b = 1' 'b = 2' "$tmp/log" "$mbuild" "$tcommand" 2>&1)"
  [[ -e "$marker" ]] || { echo "FAIL: $name: the build did not run: $got"; failures=$((failures + 1)); }
  [[ "$(shasum -a 256 "$file")" == "$before" ]] || { echo "FAIL: file changed after: $name"; failures=$((failures + 1)); }
}
refuses 'the source of a comparison' 'rows(model) == []' aUserCutShowsNoRow
refuses 'a comparison in the second body of one name' 'count(x) == 3' aTwoBodyName
refuses 'a comparison with a comma in its operand' 'f(a, b) == c' aNestedComma
arrow=$'\xe2\x86\x92'
fail_with() { echo "echo 'boom'; exit 1 # --exact $1"; }
allows 'a printed operand with its value' "(rows(model) $arrow " "$(fail_with aUserCutShowsNoRow)"
allows 'Caught error' 'Caught error' "$(fail_with aUserCutShowsNoRow)"
allows 'none was thrown' 'none was thrown' "$(fail_with aUserCutShowsNoRow)"
allows 'Expectation failed:' 'Expectation failed:' "$(fail_with aUserCutShowsNoRow)"
allows 'the interpolated message of a helper' 'before the first tick: edge' "$(fail_with aHelperMessage)"
allows 'the same text in the comment argument' 'a == b' "$(fail_with aCommentArgument)"
allows 'an operand of a top-level &&' 'x == 1' "$(fail_with anAndCondition)"
allows 'a condition with try and await' 'load() == 3' "$(fail_with aTryCondition)"
allows 'a comparison that an operand of && also holds' 'rows.count == 0' "$(fail_with aCountBesideAnd)"
allows 'a comparison that a condition with try also holds' 'load() == 3' "$(fail_with aLoadBesideTry)"
allows 'the paren that closes the left operand' ') == []' "$(fail_with aUserCutShowsNoRow)"
allows 'a literal left operand' '[] == rows' "$(fail_with aLiteralLeft)"
allows 'a test command with no --exact' 'rows(model) == []' 'echo boom; exit 1'
allows 'the recorded issue form' 'aUserCutShowsNoRow() recorded an issue' "$(fail_with aUserCutShowsNoRow)"
# In a --schema batch the refused mutant prints its line and no build runs.
mkdir -p "$tmp/refusal"
printf '%s\0' --expect 'rows(model) == []' --switch expr "$file" 'b = 1' 'b = 2' "$tmp/log" "$mbuild" "echo boom; exit 1 # --exact aUserCutShowsNoRow" > "$tmp/refusal/1"
rm -f "$marker"
got="$("$mutate" --schema "$tmp/refusal" 1 2>&1)"
[[ "$got" == '1 mutate: Swift Testing prints each operand'* && ! -e "$marker" ]] || { echo "FAIL: a refused text in --schema: [$got]"; failures=$((failures + 1)); }
rm -rf "$tmp/Tests" "$tmp/refusal"

# An exit 75 of the build or the test is the exit of a with-lock.sh wait over its limit. Nothing was
# tested: LOCK WAIT with exit 75, never BUILD FAILED or killed. Exit 2 of the build stays BUILD FAILED.
check '75:LOCK WAIT' 'a build that waits for the lock' "$file" 'b = 1' 'b = 2' "$tmp/log" 'exit 75' "$test"
check '75:LOCK WAIT' 'a test that waits for the lock' "$file" 'b = 1' 'b = 2' "$tmp/log" "$build" 'exit 75'
check '2:BUILD FAILED' 'a build that exits 2' "$file" 'b = 1' 'b = 2' "$tmp/log" 'exit 2' "$test"

# A lone call in a git tree with scripts/with-lock.sh runs itself under it once, before any edit;
# MUTATION_PASS_HELD=1 (mutation-pass.sh holds the lock) takes no lock. The shim counts its calls.
git init -q "$tmp/locked"
mkdir "$tmp/locked/scripts"
printf '#!/bin/bash\necho call >> "$LOCK_COUNT"\nexec "$@"\n' > "$tmp/locked/scripts/with-lock.sh"
chmod +x "$tmp/locked/scripts/with-lock.sh"
cp "$file" "$tmp/locked/x.txt"
export LOCK_COUNT="$tmp/lock-count"
: > "$LOCK_COUNT"
lbuild="[[ \$MUTATION_PASS_HELD == 1 ]] && grep -q 'a =' x.txt"
got="$(cd "$tmp/locked" && "$mutate" x.txt 'a = 1' 'a = 2' "$tmp/log" "$lbuild" "grep -q 'a = 1' x.txt" 2>&1)"
[[ $? -eq 0 && "$got" == killed* && "$(wc -l < "$LOCK_COUNT" | tr -d ' ')" == 1 ]] \
  || { echo "FAIL: a lone call: result [$got], with-lock.sh calls $(wc -l < "$LOCK_COUNT" | tr -d ' '), not 1"; failures=$((failures + 1)); }
: > "$LOCK_COUNT"
got="$(cd "$tmp/locked" && MUTATION_PASS_HELD=1 "$mutate" x.txt 'a = 1' 'a = 2' "$tmp/log" "$lbuild" "grep -q 'a = 1' x.txt" 2>&1)"
[[ $? -eq 0 && "$got" == killed* && ! -s "$LOCK_COUNT" ]] \
  || { echo "FAIL: a call with MUTATION_PASS_HELD=1: result [$got], with-lock.sh calls $(wc -l < "$LOCK_COUNT" | tr -d ' '), not 0"; failures=$((failures + 1)); }
# The shim fails to run the command (a wait over its limit): the file has no mutant in it.
printf '#!/bin/bash\necho call >> "$LOCK_COUNT"\nexit 75\n' > "$tmp/locked/scripts/with-lock.sh"
got="$(cd "$tmp/locked" && "$mutate" x.txt 'a = 1' 'a = 2' "$tmp/log" "$lbuild" "grep -q 'a = 1' x.txt" 2>&1)"
[[ $? -eq 75 && "$(cat "$tmp/locked/x.txt")" == "$(cat "$file")" ]] || { echo "FAIL: a lock wait over its limit: exit $?, [$got]"; failures=$((failures + 1)); }
unset LOCK_COUNT
rm -rf "$tmp/locked"

# --in=<file>: one mutant in two files. The first edit alone survives; the edit in the second file
# kills it. Both files are restored.
file2="$tmp/y.txt"
printf 'c = 1\n' > "$file2"
before2="$(shasum -a 256 "$file2")"
test="grep -q 'a = 1' '$file' && grep -q 'c = 1' '$file2' || { echo 'expected c = 1'; exit 1; }"
check '0:killed' 'a pair in a second file' --expect 'expected c = 1' --timeout 10 "$file" 'b = 1' 'b = 2' "$tmp/two" "$build" "$test" \
  "--in=$file2" 'c = 1' 'c = 2'
[[ "$(shasum -a 256 "$file2")" == "$before2" ]] || { echo "FAIL: the second file changed"; failures=$((failures + 1)); }
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

# --switch on a one-mutant call: the text change runs as before.
printf 'a = 1\nb = 1\n' > "$file"
before="$(shasum -a 256 "$file")"
test="grep -q 'a = 1' '$file'"
check '0:killed' '--switch on one mutant' --switch expr "$file" 'a = 1' 'a = 2' "$tmp/log" "$build" "$test"
check '2:mutate' '--switch with another form' --switch block "$file" 'a = 1' 'a = 2' "$tmp/log" "$build" "$test"

# --schema <folder> <n>...: the switch mutants of a batch in one build. Each <folder>/<n> holds the
# mutate.py arguments of mutant n, NUL-separated. The files are named relative to the tree ($tmp).
sdir="$tmp/schema"
src="$tmp/s.swift" src2="$tmp/t.swift"
reset_schema() {
  rm -rf "$sdir"; mkdir -p "$sdir"
  printf 'let a = 10\nlet b = 20\nlet c = 30\n' > "$src"
  printf 'let d = 40\n' > "$src2"
  sbefore="$(shasum -a 256 "$src" "$src2")"
  : > "$tmp/builds"; : > "$tmp/runs"
}
sbuild="echo b >> '$tmp/builds'; cp '$src' '$tmp/seen'; grep -q 'private let dirigibleMutant' '$src'"
# The test kills mutant n when a file has the switch of n, except mutant 2, and logs the ID it sees.
stest="echo \${DIRIGIBLE_MUTANT:-unset} >> '$tmp/runs'; [[ \${DIRIGIBLE_MUTANT:-2} == 2 ]] || ! grep -qE \"dirigibleMutant == \$DIRIGIBLE_MUTANT [?{]\" '$src' '$src2'"
marg() { local n="$1"; shift; printf '%s\0' "$@" > "$sdir/$n"; }
schema() { sout="$("$mutate" --schema "$sdir" "$@" 2>&1)"; scode=$?; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
has() { grep -qE -- "$1" <<<"$sout" || fail "$2: no line /$1/ in: $sout"; }
same() { [[ "$(shasum -a 256 "$src" "$src2")" == "$sbefore" ]] || fail "$1: a source file changed"; }
builds() { [[ "$(wc -l < "$tmp/builds" | tr -d ' ')" == "$1" ]] || fail "$2: $(wc -l < "$tmp/builds" | tr -d ' ') builds, not $1"; }
runs() { [[ "$(paste -sd' ' - < "$tmp/runs")" == "$1" ]] || fail "$2: runs [$(paste -sd' ' - < "$tmp/runs")], not [$1]"; }

# Three switch mutants: one build, one baseline run with no ID, then one run for each ID.
reset_schema
marg 1 --switch expr s.swift 10 11 "$tmp/l1" "$sbuild" "$stest"
marg 2 --switch expr s.swift 20 21 "$tmp/l2" "$sbuild" "$stest"
marg 3 --switch expr s.swift 30 31 "$tmp/l3" "$sbuild" "$stest"
schema 1 2 3
[[ $scode -eq 0 ]] || fail "schema: exit $scode: $sout"
has "^1 killed: $tmp/l1\$" schema; has "^2 survived: $tmp/l2\$" schema; has "^3 killed: $tmp/l3\$" schema
builds 1 schema; runs 'unset 1 2 3' schema; same schema
grep -qx '# result: survived' "$tmp/l2" || fail "schema: no result in the log of mutant 2"

# Two mutants on one span make one chain; each runs its own branch.
reset_schema
marg 1 --switch expr s.swift 10 11 "$tmp/l1" "$sbuild" "$stest"
marg 3 --switch expr s.swift 10 12 "$tmp/l3" "$sbuild" "$stest"
schema 1 3
has "^1 killed: " chain; has "^3 killed: " chain; builds 1 chain; same chain
grep -qF 'let a = (dirigibleMutant == 1 ? (11) : (dirigibleMutant == 3 ? (12) : (10)))' "$tmp/seen" || fail "chain: the wrap is $(head -1 "$tmp/seen")"
# The statement form.
reset_schema
marg 1 --switch stmt s.swift 'let b = 20' 'let b = 21' "$tmp/l1" "$sbuild" "$stest"
schema 1
has "^1 killed: " stmt
[[ "$(sed -n 2,6p "$tmp/seen" | paste -sd'|' -)" == 'if dirigibleMutant == 1 {|let b = 21|} else {|let b = 20|}' ]] || fail "stmt: the wrap is $(cat "$tmp/seen")"

# Before the build: a span in another span, an empty expr new text, and another build command get
# their own build; a build command with a pipe and an old text that is not in the file once are
# refused; the others run.
reset_schema
marg 1 --switch expr s.swift 10 11 "$tmp/l1" "$sbuild" "$stest"
marg 2 --switch expr s.swift 'a = 10' 'a = 11' "$tmp/l2" "$sbuild" "$stest"
marg 3 --switch expr s.swift 20 '' "$tmp/l3" "$sbuild" "$stest"
marg 4 --switch expr t.swift 40 41 "$tmp/l4" "$sbuild # other" "$stest"
marg 5 --switch expr s.swift 30 31 "$tmp/l5" "$sbuild | tail -3" "$stest"
marg 6 --switch expr s.swift 99 98 "$tmp/l6" "$sbuild" "$stest"
marg 7 --switch expr s.swift 30 31 "$tmp/l7" "$sbuild" "$stest"
schema 1 2 3 4 5 6 7
has '^1 killed: ' refusals; has '^2 own build: .*mutant 1' refusals; has '^3 own build: .*empty' refusals
has '^4 own build: .*build command' refusals; has '^5 mutate: .*pipe' refusals; has '^6 mutate: .*0 times' refusals
has '^7 killed: ' refusals; builds 1 refusals; runs 'unset 1 7' refusals; same refusals

# A wrap that swiftc -parse refuses gets its own build, before any batch build.
reset_schema
marg 1 --switch expr s.swift 10 '11 +' "$tmp/l1" "$sbuild" "$stest"
schema 1
has '^1 own build: .*parse' parse; builds 0 parse; same parse
# The parse is in Swift 6 mode: a bare-slash regex that Swift 5 mode refuses (as in SessionWriter.swift)
# keeps the switch. A file whose original does not parse keeps it too: the build decides.
reset_schema
printf '%s\n' 'func f(_ name: String) -> Bool {' \
  '    guard let match = name.wholeMatch(of: /\.session\.xml\.(.+)\.tmp/), let n = Int(String(match.1)) else { return false }' \
  '    return n > 0' '}' 'let e = 50' > "$tmp/r.swift"
printf 'let q = (\nlet g = 60\n' > "$tmp/u.swift"
ptest="[[ \${DIRIGIBLE_MUTANT:-} == '' ]]"
marg 1 --switch expr r.swift 50 51 "$tmp/l1" "echo b >> '$tmp/builds'" "$ptest"
marg 2 --switch expr u.swift 60 61 "$tmp/l2" "echo b >> '$tmp/builds'" "$ptest"
schema 1 2
has '^1 killed: ' 'Swift 6 parse'; has '^2 killed: ' 'original does not parse'; builds 1 'Swift 6 parse'

# A build error in a file (an absolute path, the batch names it relative) sends the mutants of that
# file to their own build, and the batch builds again; a second failure sends all.
reset_schema
ebuild="echo b >> '$tmp/builds'; ! grep -qF '(41)' '$src2' || { echo '$(cd "$tmp" && pwd -P)/t.swift:1:9: error: bad'; exit 1; }"
marg 1 --switch expr s.swift 10 11 "$tmp/l1" "$ebuild" "$stest"
marg 2 --switch expr t.swift 40 41 "$tmp/l2" "$ebuild" "$stest"
schema 1 2
has '^1 killed: ' 'build error'; has '^2 own build: .*build' 'build error'; builds 2 'build error'; same 'build error'
reset_schema
ebuild="echo b >> '$tmp/builds'; echo '$src:1:9: error: bad'; exit 1"
marg 1 --switch expr s.swift 10 11 "$tmp/l1" "$ebuild" "$stest"
marg 2 --switch expr t.swift 40 41 "$tmp/l2" "$ebuild" "$stest"
schema 1 2
has '^1 own build: ' 'second build error'; has '^2 own build: ' 'second build error'; builds 2 'second build error'
reset_schema
ebuild="echo b >> '$tmp/builds'; echo 'error: no file'; exit 1"
marg 1 --switch expr s.swift 10 11 "$tmp/l1" "$ebuild" "$stest"
marg 2 --switch expr t.swift 40 41 "$tmp/l2" "$ebuild" "$stest"
schema 1 2
has '^1 own build: ' 'error with no file'; has '^2 own build: ' 'error with no file'; builds 1 'error with no file'; same 'error with no file'

# A baseline that fails, or that runs past the largest --timeout of its mutants, sends the mutants
# of that test command to their own build.
reset_schema
marg 1 --switch expr s.swift 10 11 "$tmp/l1" "$sbuild" "[[ -n \${DIRIGIBLE_MUTANT:-} ]]"
marg 2 --timeout 1 --switch expr s.swift 20 21 "$tmp/l2" "$sbuild" "[[ -n \${DIRIGIBLE_MUTANT:-} ]] || sleep 30"
marg 3 --switch expr s.swift 30 31 "$tmp/l3" "$sbuild" "$stest"
started=$SECONDS
schema 1 2 3
has '^1 own build: .*baseline' baseline; has '^2 own build: .*baseline' baseline; has '^3 killed: ' baseline
(( SECONDS - started < 10 )) || fail "baseline: the hung baseline ran $((SECONDS - started)) s"

# --expect and --timeout give the result words of one mutant.
reset_schema
rtest="case \${DIRIGIBLE_MUTANT:-} in 1) echo 'other failure'; exit 1 ;; 2) sleep 30 | cat ;; 3) echo '✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.' ;; esac"
marg 1 --expect 'expected a = 10' --switch expr s.swift 10 11 "$tmp/l1" "$sbuild" "$rtest"
marg 2 --timeout 1 --switch expr s.swift 20 21 "$tmp/l2" "$sbuild" "$rtest"
marg 3 --switch expr s.swift 30 31 "$tmp/l3" "$sbuild" "$rtest"
schema 1 2 3
has '^1 WRONG FAILURE: ' results; has '^2 killed \(hang\): ' results; has '^3 NO TESTS: ' results; same results

# The call reads only the files that it names; a whole-call refusal exits 2.
reset_schema
marg 1 --switch expr s.swift 10 11 "$tmp/l1" "$sbuild" "$stest"
marg 9 --switch expr s.swift 30 31 "$tmp/l9" "$sbuild" "$stest"
schema 1
has '^1 killed: ' 'named files'; ! grep -q '^9 ' <<<"$sout" || fail "named files: mutant 9 ran: $sout"; runs 'unset 1' 'named files'
schema
[[ $scode -eq 2 ]] || fail "no names: exit $scode"
sout="$("$mutate" --schema "$tmp/none" 1 2>&1)"
[[ $? -eq 2 ]] || fail "no folder: $sout"

# orig.tsv lists the index and path of each copy while files hold switches: it stays after a
# SIGKILL, and an ended call removes it.
[[ ! -e "$sdir/orig.tsv" ]] || fail "orig.tsv is left after an ended call"
reset_schema
rm -f "$tmp/pid"
marg 1 --switch expr s.swift 10 11 "$tmp/l1" "$sbuild" "[[ \${DIRIGIBLE_MUTANT:-} != 1 ]] || { sleep 35 & echo \$! > '$tmp/pid'; wait; }"
"$mutate" --schema "$sdir" 1 > "$tmp/kill.out" 2>&1 &
runner=$!
for _ in $(seq 300); do [[ -s "$tmp/pid" ]] && break; sleep 0.1; done
kill -KILL "$runner"; wait "$runner" 2>/dev/null
kill "$(cat "$tmp/pid")" 2>/dev/null
[[ "$(cat "$sdir/orig.tsv" 2>/dev/null)" == "0	$(cd "$tmp" && pwd -P)/s.swift" ]] || fail "orig.tsv after SIGKILL: [$(cat "$sdir/orig.tsv" 2>/dev/null)]"
cp "$sdir/0.orig" "$src"; same 'the copy of orig.tsv'

# A stop during a mutant test restores each file, ends the test, and exits 130.
for sig in TERM INT HUP; do
  reset_schema
  rm -f "$tmp/pid"
  marg 1 --switch expr s.swift 10 11 "$tmp/l1" "$sbuild" "[[ \${DIRIGIBLE_MUTANT:-} != 1 ]] || { sleep 34 & echo \$! > '$tmp/pid'; wait; }"
  marg 2 --switch expr t.swift 40 41 "$tmp/l2" "$sbuild" "$stest"
  "$mutate" --schema "$sdir" 1 2 > "$tmp/stop.out" 2>&1 &
  runner=$!
  for _ in $(seq 300); do [[ -s "$tmp/pid" ]] && break; sleep 0.1; done
  [[ -s "$tmp/pid" ]] || fail "schema SIG$sig: the test did not start"
  kill -"$sig" "$runner"
  wait "$runner"
  code=$?
  [[ $code -eq 130 ]] && grep -q '^stopped' "$tmp/stop.out" || fail "schema SIG$sig: exit $code: $(cat "$tmp/stop.out")"
  same "schema SIG$sig"
  ended "$(cat "$tmp/pid")" || { fail "schema SIG$sig: the test still runs"; kill "$(cat "$tmp/pid")"; }
done

[[ $failures -eq 0 ]] && echo "mutate tests: all passed"
exit $((failures > 0))
