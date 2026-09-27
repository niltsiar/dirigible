#!/bin/bash
# Check that mutate.py tells a killed, a surviving, and an unbuilt mutant apart, counts a kill
# with --expect only when the test output has the text, applies extra
# old/new pairs as one mutant, refuses an old text that is not in the file once, and always
# restores the file, and counts a test past --timeout as a kill. Run by `make test-hooks`.
set -uo pipefail
mutate="$(cd "$(dirname "$0")" && pwd)/mutate.py"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
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

[[ $failures -eq 0 ]] && echo "mutate tests: all passed"
exit $((failures > 0))
