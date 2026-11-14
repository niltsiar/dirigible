#!/bin/bash
# Check that bench.sh clears the PCH files and the module caches of its copy when the copy was
# built under another root (a .build cloned from another checkout), and keeps them when the root
# is the same. Check that the names join into one filter, that a run with no test exits 1, that a
# bare bench.sh takes the build lock of its repo, and that the benches of one bench-pairs.sh run
# share one hold. A fake swift and a stub check-changed.sh stand in for the build and the load wait.
# Run by scripts/bench-pairs.test.sh, which make test-hooks runs.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

root="$tmp/root" cache="$tmp/root/.build/bench/.build"
mkdir -p "$root/scripts" "$root/Sources/App" "$root/Tests/T" "$tmp/bin"
cp "$here/bench.sh" "$here/bench-pairs.sh" "$here/with-lock.sh" "$here/lock-words.sh" "$root/scripts/"
printf '#!/bin/bash\nexit 0\n' > "$root/scripts/check-changed.sh"
# The fake swift logs its arguments in args.log, and the hold value that it gets and the pid file of
# the lock of the repo in lock.log. With FAKE_NONE=1, its test run prints the two no-test strings
# of test-filter.sh.
export FAKE_PID_FILE="$root/.git/dirigible-build.lock/pid" FAKE_DIR="$tmp" FAKE_NONE=""
cat > "$tmp/bin/swift" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_DIR/args.log"
[[ -z "${FAKE_MOVE:-}" ]] || git -C "$FAKE_MOVE" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m moved
echo "${DIRIGIBLE_BUILD_LOCK:-none} $(cat "$FAKE_PID_FILE" 2>/dev/null || echo free)" >> "$FAKE_DIR/lock.log"
if [[ "$1" == test && -n "$FAKE_NONE" ]]; then
    echo 'No matching test cases were run'
    echo 'Test run with 0 tests passed after 0.001 seconds.' >&2
else
    [[ -z "${FAKE_UNREAD:-}" ]] || printf '◇ Suite XBenchmark started.\nXBenchmark wobble %s seconds\n' "$FAKE_UNREAD"
    echo "XBenchmark a: p50 0.001 seconds, p95 0.001 seconds"
    echo "Test run with 1 test passed"
fi
EOF
chmod +x "$root/scripts/check-changed.sh" "$tmp/bin/swift"
printf '.executableTarget(name: "App")\n' > "$root/Package.swift"
printf '{}\n' > "$root/Package.resolved"
printf '@main\nstruct App {}\n' > "$root/Sources/App/main.swift"
printf 'x\n' > "$root/Tests/T/t.swift"
# The bench copy stays out of git, so each bench log says tree clean, as bench-pairs.sh needs.
printf '.build/\n' > "$root/.gitignore"
git -C "$root" init -q && git -C "$root" add -A &&
    git -C "$root" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
# The main side of a pair run: a worktree of the same repo (one build lock) on another commit.
git -C "$root" worktree add -q --detach "$tmp/main" &&
    git -C "$tmp/main" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m main

# seed: a PCH file and a module cache in the copy, as a build leaves them.
seed() { mkdir -p "$cache/x/release/ModuleCache" && touch "$cache/x/release/a.pch" "$cache/x/release/ModuleCache/m"; }
run() { PATH="$tmp/bin:$PATH" "$root/scripts/bench.sh" X > "$tmp/out" 2>&1 || fail "$1: bench.sh failed: $(cat "$tmp/out")"; }

seed
run "no stamp"
[[ ! -e "$cache/x/release/a.pch" && ! -e "$cache/x/release/ModuleCache" ]] || fail "no stamp: the cache stays"
[[ "$(cat "$cache/dirigible-bench-root" 2>/dev/null)" == "$root/.build/bench" ]] || fail "no stamp: the stamp is not the copy path"

seed
run "the same root"
[[ -e "$cache/x/release/a.pch" && -e "$cache/x/release/ModuleCache/m" ]] || fail "the same root: the cache is gone"

echo /other/root/.build/bench > "$cache/dirigible-bench-root"
run "another root"
[[ ! -e "$cache/x/release/a.pch" && ! -e "$cache/x/release/ModuleCache" ]] || fail "another root: the cache stays"

# Names in one argument (make bench FILTER='A B') or in several join into one filter.
for names in "A B" "A  B"; do
    : > "$tmp/args.log"
    PATH="$tmp/bin:$PATH" "$root/scripts/bench.sh" $names > "$tmp/out" 2>&1 || fail "names '$names': bench.sh failed: $(cat "$tmp/out")"
    grep -q -- '--filter A|B$' "$tmp/args.log" || fail "names '$names': no joined filter: $(cat "$tmp/args.log")"
done
: > "$tmp/args.log"
PATH="$tmp/bin:$PATH" "$root/scripts/bench.sh" "A B" > "$tmp/out" 2>&1 || fail "one argument: bench.sh failed: $(cat "$tmp/out")"
grep -q -- '--filter A|B$' "$tmp/args.log" || fail "one argument 'A B': no joined filter: $(cat "$tmp/args.log")"

# A test run with both no-test strings ran no test: exit 1, with a line that names the filter.
FAKE_NONE=1 PATH="$tmp/bin:$PATH" "$root/scripts/bench.sh" NoSuchBench > "$tmp/out" 2>&1
code=$?
[[ $code -eq 1 && "$(cat "$tmp/out")" == *'bench: no test matched the filter NoSuchBench'* ]] ||
    fail "no test: exit $code: $(cat "$tmp/out")"

# A timed run whose output has a time line that bench-pairs.sh --compare reads in no form exits 1
# and names the line; a trace run is no timing, so it does not check the lines.
FAKE_UNREAD=0.5 PATH="$tmp/bin:$PATH" "$root/scripts/bench.sh" X > "$tmp/out" 2>&1
code=$?
[[ $code -eq 1 && "$(tail -1 "$tmp/out")" == 'bench: no pairs form: XBenchmark wobble 0.5 seconds' ]] ||
    fail "an unread time line: exit $code: $(cat "$tmp/out")"
PATH="$tmp/bin:$PATH" "$root/scripts/bench.sh" X > "$tmp/out" 2>&1 || fail "read time lines: bench.sh failed: $(cat "$tmp/out")"

# A bare bench.sh takes the lock of its repo: each swift call gets the value in the pid file.
: > "$tmp/lock.log"
run "lock"
[[ "$(grep -cE '^([0-9]+) \1$' "$tmp/lock.log")" -eq 2 ]] || fail "lock: swift ran with no hold of the lock: $(cat "$tmp/lock.log")"

# One bench-pairs.sh run (an A/A pair and one main/branch pair) holds the lock once: its four
# benches get one value, and it is in the pid file. Its out folder is in .build/, which git ignores.
: > "$tmp/lock.log"
PATH="$tmp/bin:$PATH" "$root/scripts/bench-pairs.sh" "$tmp/main" X 1 "$root/.build/pairs" > "$tmp/out" 2>&1 ||
    fail "pairs: bench-pairs.sh failed: $(cat "$tmp/out")"
grep -vqE '^([0-9]+) \1$' "$tmp/lock.log" && fail "pairs: a bench ran with no hold of the lock: $(cat "$tmp/lock.log")"
[[ "$(sort -u "$tmp/lock.log" | wc -l | tr -d ' ')" -eq 1 && "$(wc -l < "$tmp/lock.log" | tr -d ' ')" -eq 8 ]] ||
    fail "pairs: the benches did not share one hold: $(cat "$tmp/lock.log")"

# A pair run checks its provenance at the start, not only at --compare. A change in a bench input
# of a tree refuses the run with exit 2 before a bench; an untracked doc is not a bench input, so
# its tree stays clean; a HEAD that moves during the run stops the run before the next bench.
echo '// x' >> "$tmp/main/Sources/App/main.swift"
: > "$tmp/args.log"
out="$(PATH="$tmp/bin:$PATH" "$root/scripts/bench-pairs.sh" "$tmp/main" X 1 "$root/.build/pairs-dirty" 2>&1)"
code=$?
[[ $code -eq 2 && "$out" == *'has a change in the bench inputs'* ]] || fail "a changed bench input: exit $code: $out"
[[ ! -s "$tmp/args.log" && ! -e "$root/.build/pairs-dirty" ]] || fail 'a changed bench input: a bench ran or the folder was made'
git -C "$tmp/main" checkout -q -- Sources
echo note > "$root/notes.md"
run "an untracked doc"
grep -q '^bench: commit [0-9a-f]* tree clean filter X$' "$tmp/out" || fail "an untracked doc made the tree dirty: $(head -1 "$tmp/out")"
out="$(FAKE_MOVE="$tmp/main" PATH="$tmp/bin:$PATH" "$root/scripts/bench-pairs.sh" "$tmp/main" X 1 "$root/.build/pairs-moved" 2>&1)"
code=$?
[[ $code -eq 1 && "$out" == *'moved during the run'* ]] || fail "a moved HEAD: exit $code: $out"
[[ -e "$root/.build/pairs-moved/aa-1.log" && ! -e "$root/.build/pairs-moved/aa-2.log" ]] || fail "a moved HEAD: the run did not stop after aa-1: $(ls "$root/.build/pairs-moved" 2>/dev/null | xargs)"

# --trace <file>: the run step is an xctrace record of the bundle through scripts/test-helper.sh,
# with no swift test. The fake xcrun logs its arguments in xcrun.log. Its record prints the report
# line of FAKE_TESTS tests (FAKE_NONE: the two no-test strings) and exits FAKE_RECORD_EXIT; its
# --toc lists a time-profile table unless FAKE_NO_TABLE is set; its table export writes two samples:
# the leaf Leaf under the frame Span, and the leaf Setup.
cp "$here/trace-top.py" "$root/scripts/"
printf '#!/bin/bash\nexit 0\n' > "$root/scripts/test-helper.sh"
chmod +x "$root/scripts/test-helper.sh"
cat > "$tmp/bin/xcrun" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_DIR/xcrun.log"
output=""
for ((i = 1; i < $#; i++)); do [[ "${!i}" == --output ]] && { j=$((i + 1)); output="${!j}"; }; done
case "$2 $*" in
record*)
    mkdir "$output" || exit 9
    if [[ -n "$FAKE_NONE" ]]; then
        echo 'No matching test cases were run'
        echo 'Test run with 0 tests passed after 0.001 seconds.'
    else
        [[ -z "${FAKE_UNREAD:-}" ]] || printf '◇ Suite XBenchmark started.\nXBenchmark wobble %s seconds\n' "$FAKE_UNREAD"
        echo "Test run with ${FAKE_TESTS:-1} test passed"
    fi
    exit "${FAKE_RECORD_EXIT:-0}" ;;
*--toc*) [[ -n "${FAKE_NO_TABLE:-}" ]] && echo '<table schema="cpu-profile"/>' || echo '<table schema="time-profile"/>' ;;
export*) echo '<trace-query-result><node><row><backtrace id="1"><frame id="2" name="Leaf"/><frame id="3" name="Span"/></backtrace></row><row><backtrace id="4"><frame id="5" name="Setup"/></backtrace></row></node></trace-query-result>' > "$output" ;;
esac
EOF
chmod +x "$tmp/bin/xcrun"
mkdir -p "$tmp/logs"
# trace <name> <file> <names...>: run bench.sh --trace from $tmp (so the file can be relative).
trace() {
    local file="$2"
    shift 2
    rm -rf "$tmp/logs/"* && : > "$tmp/xcrun.log" && : > "$tmp/args.log"
    (cd "$tmp" && PATH="$tmp/bin:$PATH" "$root/scripts/bench.sh" --trace "$file" "$@") > "$tmp/out" 2>&1
    code=$?
}
bundle="$root/.build/bench/.build/$(uname -m)-apple-macosx/release/DirigiblePackageTests.xctest/Contents/MacOS/DirigiblePackageTests"
want="xctrace record --template Time Profiler --no-prompt --time-limit 10m --output $tmp/logs/a.trace"
want+=" --env DIRIGIBLE_SLOW_TESTS=1 --target-stdout - --launch -- $root/scripts/test-helper.sh"
want+=" --test-bundle-path $bundle --testing-library swift-testing --no-parallel --filter A|B"
trace pass logs/a.trace A B
[[ $code -eq 0 ]] || fail "trace: exit $code: $(cat "$tmp/out")"
[[ "$(head -1 "$tmp/xcrun.log")" == "$want" ]] || fail "trace: the record call: $(head -1 "$tmp/xcrun.log")"
grep -q '^test ' "$tmp/args.log" && fail "trace: swift test ran: $(cat "$tmp/args.log")"
# The provenance line names the trace, so the cost review of reflect does not count it as a repeat
# of a timed bench of the same commit and filter.
grep -qE '^bench: commit [0-9a-f]+ tree clean filter A\|B trace$' "$tmp/out" || fail "trace: the provenance line: $(head -1 "$tmp/out")"
[[ "$(cat "$tmp/logs/a.trace.top.txt" 2>&1)" == $'Leaf 1 50.0%\nSetup 1 50.0%' ]] || fail "trace: the top frames: $(cat "$tmp/logs/a.trace.top.txt" 2>&1)"
# --under <name>: the same record call, and the top list counts only the samples under <name>.
trace under logs/a.trace --under Span A B
[[ $code -eq 0 && "$(head -1 "$tmp/xcrun.log")" == "$want" ]] || fail "trace --under: exit $code, the record call: $(head -1 "$tmp/xcrun.log") $(cat "$tmp/out")"
[[ "$(cat "$tmp/logs/a.trace.top.txt" 2>&1)" == 'Leaf 1 100.0%' ]] || fail "trace --under: the top frames: $(cat "$tmp/logs/a.trace.top.txt" 2>&1)"
FAKE_UNREAD=0.5 trace unread logs/a.trace A
[[ $code -eq 0 && "$(cat "$tmp/out")" != *'no pairs form'* ]] || fail "trace with an unread time line: exit $code: $(cat "$tmp/out")"
# A bench miss fails the test, and xctrace then exits nonzero: the trace is still the result.
FAKE_RECORD_EXIT=54 trace miss logs/a.trace A
[[ $code -eq 0 && -s "$tmp/logs/a.trace.top.txt" ]] || fail "trace of a failed test: exit $code: $(cat "$tmp/out")"
FAKE_TESTS=0 trace zero logs/a.trace A
[[ $code -eq 1 && "$(cat "$tmp/out")" == *'bench: the traced run printed no Test run with line of 1 test or more'* ]] ||
    fail "trace with 0 tests: exit $code: $(cat "$tmp/out")"
grep -q 'export' "$tmp/xcrun.log" && fail "trace with 0 tests: an export ran"
FAKE_NONE=1 trace none logs/a.trace NoSuchBench
[[ $code -eq 1 && "$(cat "$tmp/out")" == *'bench: no test matched the filter NoSuchBench'* ]] || fail "trace with no test: exit $code: $(cat "$tmp/out")"
FAKE_NO_TABLE=1 trace table logs/a.trace A
[[ $code -eq 1 && "$(cat "$tmp/out")" == *'has no time-profile table'* && ! -e "$tmp/logs/a.trace.xml" ]] ||
    fail "trace with no table: exit $code: $(cat "$tmp/out")"
# A trace that exists is refused before the build: the script does not delete it.
rm -rf "$tmp/logs/"* && mkdir "$tmp/logs/a.trace" && : > "$tmp/args.log"
(cd "$tmp" && PATH="$tmp/bin:$PATH" "$root/scripts/bench.sh" --trace logs/a.trace A) > "$tmp/out" 2>&1
code=$?
[[ $code -eq 2 && "$(cat "$tmp/out")" == *'bench: the trace exists'* && -d "$tmp/logs/a.trace" && ! -s "$tmp/args.log" ]] ||
    fail "an existing trace: exit $code: $(cat "$tmp/out")"
# A derived file of an earlier trace is refused before the build too: else the export fails after
# the full traced run.
for derived in a.trace.xml a.trace.top.txt; do
    rm -rf "$tmp/logs/"* && : > "$tmp/logs/$derived" && : > "$tmp/args.log"
    (cd "$tmp" && PATH="$tmp/bin:$PATH" "$root/scripts/bench.sh" --trace logs/a.trace A) > "$tmp/out" 2>&1
    code=$?
    [[ $code -eq 2 && "$(cat "$tmp/out")" == *"bench: the trace exists: $tmp/logs/$derived"* && ! -s "$tmp/args.log" ]] ||
        fail "an existing $derived: exit $code: $(cat "$tmp/out")"
done
# A call with no --trace calls no xcrun.
: > "$tmp/xcrun.log"
run "no trace"
[[ ! -s "$tmp/xcrun.log" ]] || fail "no trace: xcrun ran: $(cat "$tmp/xcrun.log")"

[[ $failures -eq 0 ]] && echo "bench tests: all passed"
exit $((failures > 0))
