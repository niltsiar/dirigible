#!/bin/bash
# Check that test-filter.sh runs the tests of FILTER in two processes: process 1
# skips the CLI tests and gets one --filter for each word, process 2 runs the CLI tests of a
# word that a CLI test file names. Check that --exact anchors each name and escapes its regex
# characters, and that --no-parallel reaches both processes. Check that it fails closed: no test
# in each process that ran, a nonzero swift exit, no word, or a swift exit 0 with no report line
# (scripts/swift-test.sh). Check that a bare swift-test.sh takes the build
# lock of its repo. A fake swift on PATH logs its arguments. Run by `make test-hooks`.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# A package copy: the scripts and one CLI test file that names the suite CLIWordTests. It is a git
# repo, so swift-test.sh takes the lock of the copy (with-lock.sh exits 2 outside a repo).
mkdir -p "$tmp/pkg/scripts" "$tmp/pkg/Tests/DirigibleCLITests" "$tmp/bin"
cp "$repo/scripts/test-filter.sh" "$repo/scripts/swift-test.sh" "$repo/scripts/with-lock.sh" "$tmp/pkg/scripts/"
git init -q "$tmp/pkg"
export FAKE_PID_FILE="$tmp/pkg/.git/dirigible-build.lock/pid"
printf 'struct CLIWordTests {\n    @Test func cliWordRuns() {}\n}\n' > "$tmp/pkg/Tests/DirigibleCLITests/CLIWordTests.swift"

# The fake swift logs one line for each call. FAKE_P1 and FAKE_P2 set the output of process 1
# (the call with --skip DirigibleCLITests) and process 2: none (the two no-test strings of
# mutate.py), xctest (only the XCTest string, and tests ran), tests, or fail (tests, exit 1).
# Swift Testing writes its summary to stderr: real (the summary of a real run, on stderr) and
# noreport (exit 0 and no summary line, on stderr, as when an AppKit call ends the process).
# In <log>.lock it logs the hold value that it gets and the pid file of the lock of the copy.
cat > "$tmp/bin/swift" <<'EOF'
#!/bin/bash
echo "swift $*" >> "$FAKE_LOG"
echo "${DIRIGIBLE_BUILD_LOCK:-none} $(cat "$FAKE_PID_FILE" 2>/dev/null || echo free)" >> "$FAKE_LOG.lock"
mode="$FAKE_P2"
[[ " $* " == *" --skip DirigibleCLITests "* ]] && mode="$FAKE_P1"
case "$mode" in
  none) echo 'No matching test cases were run'; echo 'Test run with 0 tests passed after 0.001 seconds.' ;;
  xctest) echo 'No matching test cases were run'; echo 'Test run with 3 tests passed after 0.1 seconds.' ;;
  tests) echo 'Test run with 3 tests passed after 0.1 seconds.' ;;
  fail) echo 'Test run with 3 tests failed after 0.1 seconds with 1 issue.'; exit 1 ;;
  real) echo '✘ Test run with 1980 tests in 247 suites passed after 431.790 seconds with 4 known issues.' >&2 ;;
  noreport) echo '	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds' >&2 ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/swift"

# run <p1> <p2> <words...>: sets code and out; the fake swift log is in $tmp/log.
run() {
  local p1="$1" p2="$2"
  shift 2
  : > "$tmp/log"
  : > "$tmp/log.lock"
  out="$(cd / && PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" FAKE_P1="$p1" FAKE_P2="$p2" "$tmp/pkg/scripts/test-filter.sh" "$@" 2>&1)"
  code=$?
}
p1='swift test --skip AppBundleTests --skip DiskImageTests --skip DirigibleCLITests'

run tests tests ClipTests TrackTests
[[ $code -eq 0 ]] || fail "two words: exit $code: $out"
[[ "$(cat "$tmp/log")" == "$p1 --filter ClipTests --filter TrackTests" ]] || fail "two words: calls differ: $(cat "$tmp/log")"
# The bare swift-test.sh took the lock of the copy: swift got the value that the pid file holds.
grep -qE '^([0-9]+) \1$' "$tmp/log.lock" || fail "lock: swift ran with no hold of the lock of the copy: $(cat "$tmp/log.lock")"

run tests tests ClipTests CLIWordTests
[[ $code -eq 0 ]] || fail "a CLI word: exit $code: $out"
want="$p1 --filter ClipTests --filter CLIWordTests
swift test --filter DirigibleCLITests.*CLIWordTests"
[[ "$(cat "$tmp/log")" == "$want" ]] || fail "a CLI word: calls differ: $(cat "$tmp/log")"

run none none NoSuchTestName
[[ $code -eq 1 ]] || fail "no test: expected exit 1, got $code"
[[ "$out" == *"test-filter: no test matched"* ]] || fail "no test: no reason: $out"

run xctest none ClipTests
[[ $code -eq 0 ]] || fail "only the XCTest string: exit $code: $out"

run none tests CLIWordTests
[[ $code -eq 0 ]] || fail "process 1 with no test, process 2 with tests: exit $code: $out"

run none none CLIWordTests
[[ $code -eq 1 ]] || fail "no test in both processes: expected exit 1, got $code"
[[ "$(grep -c '^swift ' "$tmp/log")" -eq 2 ]] || fail "no test in both processes: calls: $(cat "$tmp/log")"

# A failed test: process 2 still runs, so a rerun sees each CLI test. The
# exit status is the first nonzero status, and the text check does not hide it.
run fail tests ClipTests CLIWordTests
[[ $code -eq 1 ]] || fail "a failed test in process 1: expected exit 1, got $code"
[[ "$(grep -c '^swift ' "$tmp/log")" -eq 2 ]] || fail "a failed test in process 1: process 2 did not run: $(cat "$tmp/log")"
run tests fail CLIWordTests
[[ $code -ne 0 ]] || fail 'a failed test in process 2: exit 0'

# --exact anchors each name to the end of its test ID ('/<name>('), so a name that is a prefix
# of another test name runs only its own test. The CLI process takes a name with 'func <name>('.
run tests tests --exact theLanes
[[ $code -eq 0 ]] || fail "--exact: exit $code: $out"
[[ "$(cat "$tmp/log")" == "$p1 --filter /theLanes\\(" ]] || fail "--exact: calls differ: $(cat "$tmp/log")"

run tests tests --exact 'a.b*'
[[ "$(cat "$tmp/log")" == "$p1 --filter /a\\.b\\*\\(" ]] || fail "--exact with regex characters: calls differ: $(cat "$tmp/log")"

run tests tests --exact cliWordRuns cliWord
want="$p1 --filter /cliWordRuns\\( --filter /cliWord\\(
swift test --filter DirigibleCLITests.*/cliWordRuns\\("
[[ "$(cat "$tmp/log")" == "$want" ]] || fail "--exact with a CLI name and its prefix: calls differ: $(cat "$tmp/log")"

run tests tests --exact --no-parallel cliWordRuns
want="$p1 --filter /cliWordRuns\\( --no-parallel
swift test --filter DirigibleCLITests.*/cliWordRuns\\( --no-parallel"
[[ "$(cat "$tmp/log")" == "$want" ]] || fail "--no-parallel: calls differ: $(cat "$tmp/log")"

run tests tests --exact
[[ $code -eq 2 && ! -s "$tmp/log" ]] || fail "--exact and no word: expected exit 2 and no swift call, got $code"

run tests tests
[[ $code -eq 2 ]] || fail "no word: expected exit 2, got $code"
[[ "$out" == *"usage: "* ]] || fail "no word: no usage: $out"
[[ ! -s "$tmp/log" ]] || fail "no word: swift ran: $(cat "$tmp/log")"

# A test process that ends with exit 0 and no report line fails, with the reason. The summary of
# a real run, on stderr, passes.
run noreport tests ClipTests
[[ $code -eq 1 ]] || fail "process 1 with no report: expected exit 1, got $code: $out"
[[ "$out" == *"the test process ended before its report"* ]] || fail "no report: no reason: $out"
run tests noreport CLIWordTests
[[ $code -eq 1 ]] || fail "process 2 with no report: expected exit 1, got $code: $out"
run real real ClipTests
[[ $code -eq 0 ]] || fail "a real summary on stderr: exit $code: $out"

[[ $failures -eq 0 ]] && echo "test-filter tests: all passed"
exit $((failures > 0))
