#!/bin/bash
# Check that test-shards.sh builds once, lists the tests, and runs every listed test in exactly one
# shard: a free function (an ID with no slash) too, the CLI tests in their own shard, and no
# AppBundleTests or DiskImageTests test. Check that a shard that crashes, exits 0 with no report
# line, runs fewer tests than it listed, or matches no test (exit 69) prints the text that
# run-checks.sh reads as no rerun ("the test process ended before its report"), and fails the run
# after the other shards end. Check that a failed test fails the run with its line once in the
# output, that a report line with no suite count counts, that TEST_SHARDS sets the count, that the
# weights file balances the shards and names its stale keys, that a failed build runs no shard, that the build, the list,
# and the shards share one hold of the lock, and that a TERM leaves no test process alive.
# A fake swift and a stub test-helper.sh stand in for the toolchain. make test-hooks runs it.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
failures=0
tmp="$(mktemp -d)"
trap 'pkill -f "$tmp/root/scripts/test-helper.sh" 2>/dev/null; rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE TEST_SHARDS DIRIGIBLE_BUILD_LOCK DIRIGIBLE_LOCKED_SCRIPT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

root="$tmp/root"
mkdir -p "$root/scripts" "$tmp/bin"
cp "$here/test-shards.sh" "$here/with-lock.sh" "$root/scripts/"
export FAKE_DIR="$tmp" FAKE_PID_FILE="$root/.git/dirigible-build.lock/pid"
# The fake swift logs its arguments and the lock hold; FAKE_BUILD_FAIL makes the build fail.
cat > "$tmp/bin/swift" <<'EOF'
#!/bin/bash
echo "swift $*" >> "$FAKE_DIR/args.log"
echo "${DIRIGIBLE_BUILD_LOCK:-none} $(cat "$FAKE_PID_FILE" 2>/dev/null || echo free)" >> "$FAKE_DIR/lock.log"
[[ -z "${FAKE_BUILD_FAIL:-}" ]] || { echo "error: the build failed"; exit 1; }
EOF
# The stub runner: --list-tests prints the list. Else it runs the IDs of the list that match its
# --filter (an extended regex, as Swift Testing matches the ID), and prints the lines of Swift
# Testing. A name in FAKE_CRASH, FAKE_FAIL, FAKE_SHORT, FAKE_NOREPORT, or FAKE_HANG changes the run
# of the shard that has it: exit 132 with no report, a failed test, one test fewer in the report,
# exit 0 with no report, or a wait of 60 s.
cat > "$root/scripts/test-helper.sh" <<'EOF'
#!/bin/bash
echo "runner $*" >> "$FAKE_DIR/args.log"
echo "${DIRIGIBLE_BUILD_LOCK:-none} $(cat "$FAKE_PID_FILE" 2>/dev/null || echo free)" >> "$FAKE_DIR/lock.log"
filter="" skips=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list-tests) cat "$FAKE_DIR/list.txt"; exit 0 ;;
        --filter) filter="$2"; shift ;;
        --skip) skips+=("$2"); shift ;;
    esac
    shift
done
ids="$(grep -E -- "$filter" "$FAKE_DIR/list.txt")"
for s in ${skips[@]+"${skips[@]}"}; do ids="$(grep -vE -- "$s" <<<"$ids")"; done
has() { [[ -n "$1" ]] && grep -q "$1" <<<"$ids"; }
[[ -n "$ids" ]] || { echo "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds."; exit 69; }
if has "${FAKE_HANG:-}"; then echo $$ >> "$FAKE_DIR/hang.pid"; echo "◇ Test hang() started."; sleep 60; fi
has "${FAKE_CRASH:-}" && { echo "◇ Test crash() started."; exit 132; }
n=0 code=0
while IFS= read -r id; do
    name="${id##*[./]}"
    [[ "$name" == "${FAKE_SHORT:-none}()" ]] && continue
    n=$((n + 1))
    if [[ "$name" == "${FAKE_FAIL:-none}()" ]]; then
        echo "✘ Test $name failed after 0.1 seconds with 1 issue."
        code=1
    else
        echo "✔ Test $name passed after 0.1 seconds."
    fi
done <<<"$ids"
has "${FAKE_NOREPORT:-}" && exit 0
suites=" in 1 suite"
# A real run of free functions only prints "in 0 suites"; FAKE_NOSUITE drops the part.
[[ -z "${FAKE_NOSUITE:-}" ]] || suites=""
if [[ $code -eq 0 ]]; then echo "✔ Test run with $n tests$suites passed after 0.1 seconds."
else echo "✘ Test run with $n tests$suites failed after 0.1 seconds with 1 issue."; fi
exit "$code"
EOF
chmod +x "$tmp/bin/swift" "$root/scripts/test-helper.sh"
git -C "$root" init -q && git -C "$root" add -A &&
    git -C "$root" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base

# The list: two app suites (one with a parameterized test), an audio suite, a free function, two
# CLI tests, and one test each of the app bundle and disk image suites, which no shard runs.
cat > "$tmp/list.txt" <<'EOF'
DirigibleTests.ATests/a1()
DirigibleTests.ATests/a2(value:)
DirigibleTests.BTests/b1()
DirigibleAudioTests.CTests/c1()
DirigibleCoreTests.freeFunction()
DirigibleCLITests.DTests/d1()
DirigibleCLITests.DTests/d2()
DirigibleTests.AppBundleTests/bundle()
DirigibleTests.DiskImageTests/image()
EOF

# run <environment assignments>: a call from another folder with fresh logs; sets code and out.
run() {
    : > "$tmp/args.log" && : > "$tmp/lock.log"
    (cd / && env PATH="$tmp/bin:$PATH" "$@" "$root/scripts/test-shards.sh") > "$tmp/out" 2>&1
    code=$?
}
ran() { grep -cE "^(✔|✘) Test $1 (passed|failed)" "$tmp/out"; }

# (a) Each listed test runs once; the CLI tests in their own shard; no app bundle or disk image test.
run TEST_SHARDS=2
[[ $code -eq 0 ]] || fail "pass: exit $code: $(cat "$tmp/out")"
for t in 'a1\(\)' 'a2\(value:\)' 'b1\(\)' 'c1\(\)' 'freeFunction\(\)' 'd1\(\)' 'd2\(\)'; do
    [[ "$(ran "$t")" -eq 1 ]] || fail "pass: $t did not run once: $(cat "$tmp/out")"
done
[[ "$(ran 'bundle\(\)')$(ran 'image\(\)')" == 00 ]] || fail "pass: an app bundle or disk image test ran"
grep -qE '^test-shards: 7 of 7 tests in [0-9]+ s$' "$tmp/out" || fail "pass: no count line: $(tail -3 "$tmp/out")"
[[ "$(grep -c '^runner .*--filter' "$tmp/args.log")" -eq 3 ]] || fail "pass: not 2 shards and the CLI shard: $(cat "$tmp/args.log")"
grep -q "^runner .*--filter ^(DirigibleCLITests\\\\.)" "$tmp/args.log" || fail "pass: no CLI shard: $(cat "$tmp/args.log")"
[[ "$(grep -c '^swift build --build-tests$' "$tmp/args.log")" -eq 1 ]] || fail "pass: not one build: $(cat "$tmp/args.log")"
grep -q -- "--test-bundle-path $root/.build/debug/DirigiblePackageTests.xctest/Contents/MacOS/DirigiblePackageTests" "$tmp/args.log" ||
    fail "pass: the bundle path: $(cat "$tmp/args.log")"
[[ -f "$root/.build/test-shards/shard-1.log" && -f "$root/.build/test-shards/shard-cli.log" ]] || fail "pass: no shard logs"
# One hold of the lock of the repo for the build, the list, and the shards.
[[ "$(grep -cE '^([0-9]+) \1$' "$tmp/lock.log")" -eq 5 && "$(sort -u "$tmp/lock.log" | wc -l | tr -d ' ')" -eq 1 ]] ||
    fail "pass: no one hold of the lock: $(cat "$tmp/lock.log")"

# The weights file: a heavy suite gets a shard of its own; a key with no weight counts 0.5 s a test.
# With no weights file, no stale line.
grep -q 'stale weights' "$tmp/out" && fail "pass: a stale line with no weights file"
printf 'DirigibleTests.BTests\t100\n' > "$root/scripts/test-shards.weights"
run TEST_SHARDS=4
[[ $code -eq 0 ]] || fail "weights: exit $code"
grep -qF -- '--filter ^(DirigibleTests\.BTests)(/|$)' "$tmp/args.log" || fail "weights: BTests is not alone: $(cat "$tmp/args.log")"
# A stale weights file shows in one line: the keys with no weight and the weight keys with no
# test. The CLI keys need no weight.
want='test-shards: stale weights: no weight: DirigibleAudioTests.CTests DirigibleCoreTests.freeFunction() DirigibleTests.ATests; no test: none'
grep -qxF "$want" "$tmp/out" || fail "weights: no stale line: $(grep stale "$tmp/out")"
printf 'DirigibleTests.BTests\t1\nDirigibleTests.ATests\t1\nDirigibleAudioTests.CTests\t1\nDirigibleCoreTests.freeFunction()\t1\nDirigibleTests.GoneTests\t1\n' > "$root/scripts/test-shards.weights"
run TEST_SHARDS=4
grep -qxF 'test-shards: stale weights: no weight: none; no test: DirigibleTests.GoneTests' "$tmp/out" || fail "weights: no stale key line: $(grep stale "$tmp/out")"
rm "$root/scripts/test-shards.weights"

# (f) The default is 4 shards and the CLI shard; a shard with no test does not start.
run
[[ $code -eq 0 ]] || fail "default: exit $code: $(cat "$tmp/out")"
[[ "$(grep -c '^runner .*--filter' "$tmp/args.log")" -eq 5 ]] || fail "default: not 4 shards and the CLI shard: $(cat "$tmp/args.log")"

# A report line with no suite count counts its tests.
run TEST_SHARDS=2 FAKE_NOSUITE=1
[[ $code -eq 0 ]] || fail "no suite count: exit $code: $(tail -5 "$tmp/out")"
grep -qE '^test-shards: 7 of 7 tests in' "$tmp/out" || fail "no suite count: the count line: $(tail -3 "$tmp/out")"

# (c) A failed test fails the run; the other shards run to their end; the failed line shows once.
run TEST_SHARDS=2 FAKE_FAIL=b1
[[ $code -eq 1 ]] || fail "failed test: exit $code"
[[ "$(grep -c '^✘ Test b1() failed after' "$tmp/out")" -eq 1 ]] || fail "failed test: the failed line: $(cat "$tmp/out")"
[[ "$(ran 'd2\(\)')" -eq 1 ]] || fail "failed test: the CLI shard did not end"
grep -qF 'ended before its report' "$tmp/out" && fail "failed test: a rerunnable failure says the report ended"

# (b), (d), (e), and a crash: a lost test is never a flake.
for c in FAKE_CRASH=c1 FAKE_NOREPORT=c1 FAKE_SHORT=c1; do
    run TEST_SHARDS=2 "$c"
    [[ $code -eq 1 ]] || fail "$c: exit $code"
    grep -qE '^test-shards: shard [0-9]+: the test process ended before its report' "$tmp/out" ||
        fail "$c: no report-end line: $(tail -5 "$tmp/out")"
    [[ "$(ran 'd1\(\)')" -eq 1 ]] || fail "$c: the CLI shard did not end"
done
run TEST_SHARDS=2 FAKE_SHORT=c1
grep -qE '^test-shards: shard [0-9]+ ran 1 of 2 tests' "$tmp/out" || fail "short: no count message: $(tail -5 "$tmp/out")"
grep -qE '^test-shards: 6 of 7 tests in' "$tmp/out" || fail "short: the count line: $(tail -3 "$tmp/out")"
# (e) A shard that matches no test: a wrapper of the stub gives exit 69 and a report of 0 tests
# for each shard but the CLI shard.
mv "$root/scripts/test-helper.sh" "$tmp/helper.real"
cat > "$root/scripts/test-helper.sh" <<EOF
#!/bin/bash
[[ " \$* " == *" --list-tests "* ]] && exec "$tmp/helper.real" "\$@"
[[ " \$* " == *DirigibleCLITests* ]] && exec "$tmp/helper.real" "\$@"
echo "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds."
exit 69
EOF
chmod +x "$root/scripts/test-helper.sh"
run TEST_SHARDS=1
[[ $code -eq 1 ]] || fail "no match: exit $code"
grep -qE '^test-shards: shard 1: the test process ended before its report' "$tmp/out" || fail "no match: no report-end line: $(tail -5 "$tmp/out")"
mv "$tmp/helper.real" "$root/scripts/test-helper.sh"

# (g) A failed build runs no shard.
run TEST_SHARDS=2 FAKE_BUILD_FAIL=1
[[ $code -ne 0 ]] || fail "build: exit 0"
grep -q '^runner' "$tmp/args.log" && fail "build: a runner ran: $(cat "$tmp/args.log")"

# A TERM stops every shard, leaves no test process, keeps the logs, names only the shard that ran,
# prints its tail, and exits 143.
: > "$tmp/hang.pid"
: > "$tmp/args.log" && : > "$tmp/lock.log"
# The lock marker skips the with-lock.sh wrap, so the TERM and the exit code are the script's own.
(cd / && exec env PATH="$tmp/bin:$PATH" TEST_SHARDS=2 FAKE_HANG=c1 DIRIGIBLE_LOCKED_SCRIPT="$root/scripts/test-shards.sh" \
    "$root/scripts/test-shards.sh") > "$tmp/out" 2>&1 &
pid=$!
for _ in $(seq 100); do [[ -s "$tmp/hang.pid" ]] && break; sleep 0.1; done
[[ -s "$tmp/hang.pid" ]] || fail "term: the hanging shard did not start"
kill -TERM "$pid"
wait "$pid"
code=$?
[[ $code -eq 143 ]] || fail "term: exit $code, want 143"
[[ "$(grep -c '^test-shards: shard .* stopped' "$tmp/out")" -eq 1 ]] || fail "term: not only the running shard named: $(grep stopped "$tmp/out")"
sleep 0.5
! kill -0 "$(cat "$tmp/hang.pid")" 2>/dev/null || fail "term: a test process is alive"
pgrep -f "$root/scripts/test-helper.sh" > /dev/null && fail "term: a runner is alive"
grep -q '◇ Test hang() started.' "$tmp/out" || fail "term: no tail of the unfinished shard: $(cat "$tmp/out")"
[[ -f "$root/.build/test-shards/shard-cli.log" ]] || fail "term: no shard logs"

[[ $failures -eq 0 ]] || { echo "test-shards.test.sh: $failures failures"; exit 1; }
echo "test-shards.test.sh: all passed"
