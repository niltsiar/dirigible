#!/bin/bash
# Check that test-filter.sh runs the tests of FILTER in two processes: process 1
# skips the CLI tests and gets one --filter for each word, process 2 runs the CLI tests of a
# word that a CLI test file names. Check that --exact anchors each name and escapes its regex
# characters, and that --no-parallel reaches both processes. Check that --skip-build gives both
# processes --skip-build --disable-xctest, and that then the Swift Testing string alone means no
# test. Check that it fails closed: no test
# in each process that ran, a nonzero swift exit, no word, or a swift exit 0 with no report line
# (scripts/swift-test.sh). Check that a name that no listed test ID matches fails with exit 1
# (one `swift test list` call, only when the output shows no test of a name). Check that a bare
# swift-test.sh takes the build lock of its repo. A fake swift on PATH logs its arguments. Run by
# `make test-hooks`.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# A package copy: the scripts and one CLI test file that names the suite CLIWordTests. It is a git
# repo, so swift-test.sh takes the lock of the copy (with-lock.sh exits 2 outside a repo).
mkdir -p "$tmp/pkg/scripts" "$tmp/pkg/Tests/DirigibleCLITests" "$tmp/bin"
cp "$repo/scripts/test-filter.sh" "$repo/scripts/swift-suites.sh" "$repo/scripts/swift-test.sh" "$repo/scripts/with-lock.sh" "$repo/scripts/lock-words.sh" "$tmp/pkg/scripts/"
git init -q "$tmp/pkg"
export FAKE_PID_FILE="$tmp/pkg/.git/dirigible-build.lock/pid"
printf 'struct CLIWordTests {\n    @Test func cliWordRuns() {}\n}\n' > "$tmp/pkg/Tests/DirigibleCLITests/CLIWordTests.swift"

# The fake swift logs one line for each call. FAKE_P1 and FAKE_P2 set the output of process 1
# (the call with --skip DirigibleCLITests) and process 2: none (the two no-test strings of
# mutate.py), xctest (only the XCTest string, and tests ran), swift0 (only the Swift Testing
# no-test string, as with --disable-xctest), tests, or fail (tests, exit 1).
# Swift Testing writes its summary to stderr: real (the summary of a real run, on stderr) and
# noreport (exit 0 and no summary line, on stderr, as when an AppKit call ends the process).
# In <log>.lock it logs the hold value that it gets and the pid file of the lock of the copy.
# A `swift test list` call goes to <log>.list: it prints the file FAKE_LIST, writes FAKE_LIST_ERR
# to stderr, and exits with FAKE_LIST_EXIT. A test call prints the lines of FAKE_STARTED (process 1)
# or FAKE_STARTED2 (process 2) before its mode output.
cat > "$tmp/bin/swift" <<'EOF'
#!/bin/bash
if [[ "${1:-} ${2:-}" == "test list" ]]; then
  echo "swift $*" >> "$FAKE_LOG.list"
  [[ -z "${FAKE_LIST_ERR:-}" ]] || echo "$FAKE_LIST_ERR" >&2
  [[ "${FAKE_LIST_EXIT:-0}" -eq 0 ]] || exit "$FAKE_LIST_EXIT"
  cat "$FAKE_LIST"
  exit 0
fi
echo "swift $*" >> "$FAKE_LOG"
echo "${DIRIGIBLE_BUILD_LOCK:-none} $(cat "$FAKE_PID_FILE" 2>/dev/null || echo free)" >> "$FAKE_LOG.lock"
mode="$FAKE_P2"
[[ " $* " == *" --skip DirigibleCLITests "* ]] && mode="$FAKE_P1"
started="${FAKE_STARTED2:-}"
[[ " $* " == *" --skip DirigibleCLITests "* ]] && started="${FAKE_STARTED:-}"
[[ -z "$started" ]] || printf '%s\n' "$started"
case "$mode" in
  none) echo 'No matching test cases were run'; echo 'Test run with 0 tests passed after 0.001 seconds.' ;;
  xctest) echo 'No matching test cases were run'; echo 'Test run with 3 tests passed after 0.1 seconds.' ;;
  swift0) echo 'Test run with 0 tests passed after 0.001 seconds.' ;;
  tests) echo 'Test run with 3 tests passed after 0.1 seconds.' ;;
  fail) echo 'Test run with 3 tests failed after 0.1 seconds with 1 issue.'; exit 1 ;;
  real) echo '✘ Test run with 1980 tests in 247 suites passed after 431.790 seconds with 4 known issues.' >&2 ;;
  noreport) echo '	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds' >&2 ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/swift"

# The test IDs of `swift test list`: a suite of each target, and the CLI suite that a CLI file names.
cat > "$tmp/list" <<'EOF'
DirigibleTests.ClipTests/clipRuns()
DirigibleTests.TrackTests/trackRuns()
DirigibleTests.LaneTests/theLanes()
DirigibleCLITests.CLIWordTests/cliWordRuns()
AppBundleTests.BundleTests/bundleOpens()
EOF

# run <p1> <p2> <words...>: sets code and out; the fake swift log is in $tmp/log and the list
# calls are in $tmp/log.list. FAKE_LIST, FAKE_STARTED, FAKE_LIST_EXIT, and FAKE_LIST_ERR set the fake.
run() {
  local p1="$1" p2="$2"
  shift 2
  : > "$tmp/log"
  : > "$tmp/log.lock"
  : > "$tmp/log.list"
  out="$(cd / && PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" FAKE_LIST="${FAKE_LIST:-$tmp/list}" FAKE_P1="$p1" FAKE_P2="$p2" "$tmp/pkg/scripts/test-filter.sh" "$@" 2>&1)"
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

# --skip-build: the control of a mutation pass builds once, so each process runs the built tests
# with no second build and no XCTest pass. With no XCTest pass, the Swift Testing no-test string
# alone means that no test ran.
run tests tests --skip-build --exact cliWordRuns
want="$p1 --filter /cliWordRuns\\( --skip-build --disable-xctest
swift test --filter DirigibleCLITests.*/cliWordRuns\\( --skip-build --disable-xctest"
[[ $code -eq 0 ]] || fail "--skip-build: exit $code: $out"
[[ "$(cat "$tmp/log")" == "$want" ]] || fail "--skip-build: calls differ: $(cat "$tmp/log")"
run swift0 swift0 --skip-build NoSuchTestName
[[ $code -eq 1 ]] || fail "--skip-build with no test: expected exit 1, got $code: $out"
[[ "$out" == *"test-filter: no test matched"* ]] || fail "--skip-build with no test: no reason: $out"
run swift0 tests ClipTests
[[ $code -eq 0 ]] || fail "only the Swift Testing no-test string with no --skip-build: exit $code: $out"

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

# A name that no listed test ID matches: swift test exits 0 when a filter matches no test, and
# the other names ran tests. The script lists the IDs once, only when a name shows in no started
# line of the test output, and exits 1 for each name that no ID of its processes matches.
run tests tests ClipTests NoSuchTestName
[[ $code -eq 1 ]] || fail "one name matches, one does not: expected exit 1, got $code: $out"
grep -qxF 'test-filter: no test ID matches NoSuchTestName' <<<"$out" || fail "one name matches, one does not: no refusal line: $out"
grep -x 'test-filter: no test ID matches .*' <<<"$out" | grep -qF ClipTests && fail "one name matches, one does not: the line names ClipTests: $out"
run tests tests ClipTests TrackTests
[[ $code -eq 0 ]] || fail "two listed names: exit $code: $out"
[[ "$(cat "$tmp/log.list")" == "swift test list --skip-build" ]] || fail "two listed names: list calls: $(cat "$tmp/log.list")"
run tests tests --skip-build ClipTests
[[ "$(cat "$tmp/log.list")" == "swift test list --skip-build --disable-xctest" ]] || fail "list in --skip-build: list calls: $(cat "$tmp/log.list")"

# --exact reads a name as '/<name>(' in an ID, as swift test does.
run tests tests --exact theLane
[[ $code -eq 1 ]] || fail "--exact prefix: expected exit 1, got $code: $out"
grep -qxF 'test-filter: no test ID matches theLane' <<<"$out" || fail "--exact prefix: no refusal line: $out"
run tests tests theLane
[[ $code -eq 0 ]] || fail "a prefix with no --exact: exit $code: $out"
run tests tests --exact theLanes
[[ $code -eq 0 ]] || fail "--exact whole name: exit $code: $out"

# A name matches only the IDs that one of the two processes runs: process 1 skips the app bundle,
# disk image, and CLI IDs, and process 2 runs a CLI ID only for a name that a CLI file has.
run tests tests BundleTests
[[ $code -eq 1 ]] || fail "a skipped target: expected exit 1, got $code: $out"
grep -qxF 'test-filter: no test ID matches BundleTests' <<<"$out" || fail "a skipped target: no refusal line: $out"
run tests tests 'cliWord.uns'
[[ $code -eq 1 ]] || fail "a CLI regex that no CLI file holds: expected exit 1, got $code: $out"
run tests tests CLIWordTests
[[ $code -eq 0 ]] || fail "a CLI name: exit $code: $out"

# The list call runs only when a name shows in no started line. The line "Test run started."
# and a name inside another name ('subtheLanes(') do not show.
: > "$tmp/empty"
FAKE_LIST="$tmp/empty" FAKE_STARTED=$'◇ Test run started.\n◇ Suite ClipTests started.\n◇ Test theLanes() started.' run tests tests ClipTests theLanes
[[ $code -eq 0 ]] || fail "names that show: exit $code: $out"
[[ ! -s "$tmp/log.list" ]] || fail "names that show: list calls: $(cat "$tmp/log.list")"
FAKE_STARTED=$'◇ Test run started.' run tests tests run
[[ $code -eq 1 ]] || fail "the run line is no show: expected exit 1, got $code: $out"
[[ "$(wc -l < "$tmp/log.list" | tr -d ' ')" -eq 1 ]] || fail "the run line is no show: list calls: $(cat "$tmp/log.list")"
FAKE_STARTED=$'◇ Test subtheLanes() started.' run tests tests --exact theLanes
[[ "$(wc -l < "$tmp/log.list" | tr -d ' ')" -eq 1 ]] || fail "exact suffix is no show: list calls: $(cat "$tmp/log.list")"
FAKE_LIST="$tmp/empty" FAKE_STARTED=$'◇ Test theLanes(x:) started.' run tests tests --exact theLanes
[[ $code -eq 0 && ! -s "$tmp/log.list" ]] || fail "exact name shows: exit $code, list calls: $(cat "$tmp/log.list")"
# The started lines of both processes count.
FAKE_LIST="$tmp/empty" FAKE_STARTED2=$'◇ Suite CLIWordTests started.' run tests tests ClipTests CLIWordTests
[[ $code -eq 1 ]] || fail "ClipTests shows in no line: expected exit 1, got $code: $out"
FAKE_LIST="$tmp/empty" FAKE_STARTED=$'◇ Suite ClipTests started.' FAKE_STARTED2=$'◇ Suite CLIWordTests started.' run tests tests ClipTests CLIWordTests
[[ $code -eq 0 && ! -s "$tmp/log.list" ]] || fail "names that show in both processes: exit $code: $out"

# A name whose tests all skip ran no test: a skipped line in the output makes the one list call, and
# a name whose listed tests each have a skipped line ("skipped." or "skipped: <comment>") and no
# started line fails. The full name of a test keeps its argument labels, as the ID and the line do.
printf 'DirigibleTests.S/a()\nDirigibleTests.S/b()\n' > "$tmp/list-skip"
printf 'DirigibleTests.S/a(x:)\n' > "$tmp/list-label"
# only_skipped <case> <names>: the last run exits 1 with the refusal and its hint, and makes one
# list call.
only_skipped() {
  [[ $code -eq 1 ]] || fail "$1: expected exit 1, got $code: $out"
  grep -qxF "test-filter: only skipped tests match $2" <<<"$out" || fail "$1: no refusal line: $out"
  grep -q '^test-filter: .*DIRIGIBLE_SLOW_TESTS=1' <<<"$out" || fail "$1: no hint: $out"
  [[ "$(wc -l < "$tmp/log.list" | tr -d ' ')" -eq 1 ]] || fail "$1: list calls: $(cat "$tmp/log.list")"
}
FAKE_LIST="$tmp/list-skip" FAKE_STARTED=$'◇ Suite S started.\n➜ Test a() skipped.\n➜ Test b() skipped.' run tests tests S
only_skipped 'a suite whose tests all skip' S
FAKE_LIST="$tmp/list-skip" FAKE_STARTED=$'◇ Suite S started.\n◇ Test a() started.\n➜ Test b() skipped.' run tests tests S
[[ $code -eq 0 ]] || fail "a suite with one started and one skipped test: exit $code: $out"
[[ "$(wc -l < "$tmp/log.list" | tr -d ' ')" -eq 1 ]] || fail "a suite with one started and one skipped test: list calls: $(cat "$tmp/log.list")"
FAKE_LIST="$tmp/list-skip" FAKE_STARTED=$'◇ Suite S started.\n➜ Test a() skipped.' run tests tests --exact a
only_skipped '--exact name of a skipped test' a
FAKE_LIST="$tmp/list-label" FAKE_STARTED=$'◇ Suite S started.\n➜ Test a(x:) skipped.' run tests tests a
only_skipped 'a skipped test with argument labels' a
FAKE_LIST="$tmp/list-label" FAKE_STARTED=$'◇ Suite S started.\n➜ Test a(x:) skipped: "q"' run tests tests a
only_skipped 'a skipped test with a comment' a
# The lines name no suite: a started test of the same full name in another suite counts as started.
printf 'DirigibleTests.S/a()\nDirigibleTests.U/a()\n' > "$tmp/list-two"
FAKE_LIST="$tmp/list-two" FAKE_STARTED=$'◇ Suite S started.\n◇ Test a() started.\n◇ Suite U started.\n➜ Test a() skipped.' run tests tests S U
[[ $code -eq 0 ]] || fail "one function name skipped in one suite and started in another: exit $code: $out"

# A failed test or no test ran: the old exit stays and the script makes no list call.
run fail tests ClipTests NoSuchTestName
[[ $code -eq 1 && ! -s "$tmp/log.list" ]] || fail "a failed test: exit $code, list calls: $(cat "$tmp/log.list")"
run none none NoSuchTestName
[[ $code -eq 1 && ! -s "$tmp/log.list" ]] || fail "no test ran: exit $code, list calls: $(cat "$tmp/log.list")"
[[ "$out" == *"test-filter: no test matched"* ]] || fail "no test ran: the old reason is gone: $out"

# A list call that ends in exit 75 gives exit 75 (run it again). Another failure gives exit 1 and a
# line that mutate.py does not read as a wrong filter.
FAKE_LIST_EXIT=75 run tests tests ClipTests
[[ $code -eq 75 ]] || fail "list exit 75: expected exit 75, got $code: $out"
FAKE_LIST_EXIT=3 run tests tests ClipTests
[[ $code -eq 1 ]] || fail "list exit 3: expected exit 1, got $code: $out"
grep -qxF 'test-filter: test list failed (exit 3)' <<<"$out" || fail "list exit 3: no failure line: $out"
grep -q '^test-filter: no test' <<<"$out" && fail "list exit 3: the failure line has the no-test marker: $out"

# Only a stdout line in the ID form is an ID: a name on stderr or a build line does not match, and
# a test outside a suite has an ID with no slash.
FAKE_LIST_ERR='NoSuchTestName' run tests tests NoSuchTestName
[[ $code -eq 1 ]] || fail "a name on the stderr of the list: expected exit 1, got $code: $out"
printf 'Building for debugging...\nDirigibleCoreTests.freeRuns()\n' > "$tmp/list2"
FAKE_LIST="$tmp/list2" run tests tests freeRuns
[[ $code -eq 0 ]] || fail "an ID with no slash: exit $code: $out"
FAKE_LIST="$tmp/list2" run tests tests debugging
[[ $code -eq 1 ]] || fail "a build line is no ID: expected exit 1, got $code: $out"

# A refused name that is the file name of a Swift file with only extensions gets a hint line for
# each extended type that is a suite: a type with a @Test in a top-level block under Tests/, its
# declaration or an extension. The hint reads the files; the fake swift is not asked.
mkdir -p "$tmp/pkg/Tests/DirigibleTests"
t="$tmp/pkg/Tests/DirigibleTests"
printf 'struct ClipTests {\n    @Test func clipRuns() {}\n}\n' > "$t/ClipTests.swift"
printf 'extension ClipTests {\n    @Test func tableRuns() {}\n}\n' > "$t/ClipTableTests.swift"
printf 'extension ClipTests {\n    @Test func mixRuns() {}\n}\n\nextension Clip {\n    var rows: Int { 1 }\n}\n' > "$t/ClipMixTests.swift"
printf '@MainActor struct GhostTests {}\n\nextension Other {\n    @Test func otherRuns() {}\n}\n' > "$t/GhostTests.swift"
printf 'extension ClipTests {\n    var rows: [Int] { [1] }\n}\n\nextension Helper {\n    var rows: Int { 1 }\n}\n' > "$t/ClipRowsTests.swift"
printf 'struct Helper {\n    let x = 1\n}\n\n@Test func freeRuns() {}\n' > "$t/Helper.swift"
hint() { echo "test-filter: Tests/DirigibleTests/$1.swift declares no suite $1; it extends $2: give FILTER the suite name $2"; }
run none none ClipTableTests
[[ $code -eq 1 ]] || fail "extension-only file, no test ran: expected exit 1, got $code: $out"
grep -qxF 'test-filter: no test matched ClipTableTests' <<<"$out" || fail "extension-only file, no test ran: the refusal line is gone: $out"
grep -qxF "$(hint ClipTableTests ClipTests)" <<<"$out" || fail "extension-only file, no test ran: no hint line: $out"
run tests tests ClipTests ClipTableTests
[[ $code -eq 1 ]] || fail "extension-only file, list path: expected exit 1, got $code: $out"
grep -qxF 'test-filter: no test ID matches ClipTableTests' <<<"$out" || fail "extension-only file, list path: no refusal line: $out"
grep -qxF "$(hint ClipTableTests ClipTests)" <<<"$out" || fail "extension-only file, list path: no hint line: $out"
run none none NoSuchTestName
grep -q 'declares no suite' <<<"$out" && fail "a name with no file: a hint line prints: $out"
# With --exact the suite name is refused too, so the hint names the call without --exact.
run none none --exact ClipTableTests
[[ $code -eq 1 ]] || fail "--exact extension-only file: expected exit 1, got $code: $out"
grep -qxF "test-filter: Tests/DirigibleTests/ClipTableTests.swift declares no suite ClipTableTests; it extends ClipTests: run the suite name ClipTests without --exact" <<<"$out" || fail "--exact extension-only file: no hint without --exact: $out"
grep -q 'give FILTER the suite name' <<<"$out" && fail "--exact extension-only file: the hint tells to give the suite name to --exact: $out"
# Held out: an extension of a type that is no suite gives no hint, a file that declares its own type
# gives none, an extension whose type has its @Test in another file gives a hint, and a @Test after
# the closing brace of a type belongs to no type.
run none none ClipMixTests
[[ "$(grep -c 'declares no suite' <<<"$out")" -eq 1 ]] && grep -qxF "$(hint ClipMixTests ClipTests)" <<<"$out" || fail "a file with a suite and a plain extension: the hint is not for ClipTests only: $out"
run tests tests GhostTests
grep -q 'declares no suite' <<<"$out" && fail "a file that declares its own type: a hint line prints: $out"
run none none ClipRowsTests
[[ "$(grep -c 'declares no suite' <<<"$out")" -eq 1 ]] && grep -qxF "$(hint ClipRowsTests ClipTests)" <<<"$out" || fail "an extension with no @Test of a suite declared in another file: the hint is not for ClipTests only: $out"

[[ $failures -eq 0 ]] && echo "test-filter tests: all passed"
exit $((failures > 0))
