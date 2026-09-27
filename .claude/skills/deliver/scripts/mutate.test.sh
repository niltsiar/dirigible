#!/bin/bash
# Check that mutate.py tells a killed, a surviving, and an unbuilt mutant apart, applies extra
# old/new pairs as one mutant, refuses an old text that is not in the file once, and always
# restores the file. Run by `make test-hooks`.
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

[[ $failures -eq 0 ]] && echo "mutate tests: all passed"
exit $((failures > 0))
