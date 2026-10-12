#!/bin/bash
# Check that sanitize.sh builds the tests with the sanitizer in its own scratch path, runs the bundle
# through scripts/test-helper.sh with the runtime inserted, the joined filter, and the skipped
# targets, fails on no test, on no report line, on a runner failure, and on a sanitizer report, and
# holds the build lock of its repo once for the build and the run. A fake swift, a stub
# test-helper.sh, and a stub xcrun stand in for the toolchain.
# make test-hooks runs it.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

root="$tmp/root"
mkdir -p "$root/scripts" "$tmp/bin"
cp "$here/sanitize.sh" "$here/with-lock.sh" "$here/tsan.supp" "$root/scripts/"
export FAKE_DIR="$tmp" FAKE_PID_FILE="$root/.git/dirigible-build.lock/pid" FAKE_OUT="Test run with 1 test passed" FAKE_EXIT=0
# The fake swift and the stub runner log their arguments, and the hold value that they get and the
# pid file of the lock of the repo in lock.log. The stub runner prints FAKE_OUT and exits FAKE_EXIT.
cat > "$tmp/bin/swift" <<'EOF'
#!/bin/bash
echo "swift $*" >> "$FAKE_DIR/args.log"
echo "${DIRIGIBLE_BUILD_LOCK:-none} $(cat "$FAKE_PID_FILE" 2>/dev/null || echo free)" >> "$FAKE_DIR/lock.log"
EOF
cat > "$root/scripts/test-helper.sh" <<'EOF'
#!/bin/bash
echo "runner $*" >> "$FAKE_DIR/args.log"
echo "insert $TEST_HELPER_INSERT" >> "$FAKE_DIR/args.log"
echo "asan ${ASAN_OPTIONS:-}" >> "$FAKE_DIR/args.log"
echo "tsan ${TSAN_OPTIONS:-}" >> "$FAKE_DIR/args.log"
echo "${DIRIGIBLE_BUILD_LOCK:-none} $(cat "$FAKE_PID_FILE" 2>/dev/null || echo free)" >> "$FAKE_DIR/lock.log"
printf '%b\n' "$FAKE_OUT"
exit "$FAKE_EXIT"
EOF
cat > "$tmp/bin/xcrun" <<'EOF'
#!/bin/bash
[[ "$1 $2" == "clang -print-file-name="* ]] || exit 1
echo "/clang/lib/darwin/${2#-print-file-name=}"
EOF
chmod +x "$tmp/bin/swift" "$tmp/bin/xcrun" "$root/scripts/test-helper.sh"
git -C "$root" init -q && git -C "$root" add -A &&
    git -C "$root" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base

# run <name> <arguments>: a call from another folder, with a fresh log.
run() {
    : > "$tmp/args.log" && : > "$tmp/lock.log"
    (cd / && PATH="$tmp/bin:$PATH" "$root/scripts/sanitize.sh" "${@:2}") > "$tmp/out" 2>&1
    code=$?
}
bundle="$(uname -m)-apple-macosx/debug/DirigiblePackageTests.xctest/Contents/MacOS/DirigiblePackageTests"
skips="--skip AppBundleTests --skip DiskImageTests --skip DirigibleCLITests"

run asan address A B
[[ $code -eq 0 ]] || fail "asan: exit $code: $(cat "$tmp/out")"
grep -qxF "swift build --build-tests --sanitize=address --scratch-path $root/.build/asan" "$tmp/args.log" ||
    fail "asan: the build call: $(cat "$tmp/args.log")"
grep -q -- '-Wno-' "$tmp/args.log" && fail "asan: a warning flag: $(cat "$tmp/args.log")"
grep -qxF "runner --test-bundle-path $root/.build/asan/$bundle --testing-library swift-testing --filter A|B $skips" "$tmp/args.log" ||
    fail "asan: the runner call: $(cat "$tmp/args.log")"
grep -qxF 'insert /clang/lib/darwin/libclang_rt.asan_osx_dynamic.dylib' "$tmp/args.log" || fail "asan: the insert: $(cat "$tmp/args.log")"
grep -qxF 'asan halt_on_error=1:detect_leaks=0' "$tmp/args.log" || fail "asan: ASAN_OPTIONS: $(cat "$tmp/args.log")"
# One hold of the lock of the repo for the build and the run: both get the value in the pid file.
[[ "$(grep -cE '^([0-9]+) \1$' "$tmp/lock.log")" -eq 2 && "$(sort -u "$tmp/lock.log" | wc -l | tr -d ' ')" -eq 1 ]] ||
    fail "asan: no one hold of the lock: $(cat "$tmp/lock.log")"

FAKE_OUT='No matching test cases were run\nTest run with 0 tests passed after 0.001 seconds.' run none address NoSuch
[[ $code -eq 1 && "$(cat "$tmp/out")" == *'sanitize: no test matched the filter NoSuch'* ]] || fail "no test: exit $code: $(cat "$tmp/out")"
FAKE_OUT='a crash with no report' run noreport address A
[[ $code -eq 1 && "$(cat "$tmp/out")" == *'sanitize: the test process ended before its report'* ]] || fail "no report line: exit $code: $(cat "$tmp/out")"
FAKE_OUT='Test run with 1 test failed' FAKE_EXIT=1 run failed address A
[[ $code -eq 1 ]] || fail "a failed test: exit $code: $(cat "$tmp/out")"
FAKE_OUT='==1==ERROR: AddressSanitizer: heap-buffer-overflow\nTest run with 1 test passed' run asanreport address A
[[ $code -eq 1 && "$(cat "$tmp/out")" == *'sanitize: the sanitizer reported a defect'* ]] || fail "an ASan report: exit $code: $(cat "$tmp/out")"

run tsan thread A
[[ $code -eq 0 ]] || fail "tsan: exit $code: $(cat "$tmp/out")"
grep -qxF "swift build --build-tests --sanitize=thread --scratch-path $root/.build/tsan" "$tmp/args.log" ||
    fail "tsan: the build call: $(cat "$tmp/args.log")"
grep -qxF "runner --test-bundle-path $root/.build/tsan/$bundle --testing-library swift-testing --filter A $skips" "$tmp/args.log" ||
    fail "tsan: the runner call: $(cat "$tmp/args.log")"
grep -qxF 'insert /clang/lib/darwin/libclang_rt.tsan_osx_dynamic.dylib' "$tmp/args.log" || fail "tsan: the insert: $(cat "$tmp/args.log")"
grep -qF "suppressions=$root/scripts/tsan.supp" "$tmp/args.log" || fail "tsan: TSAN_OPTIONS: $(cat "$tmp/args.log")"
FAKE_OUT='WARNING: ThreadSanitizer: data race (pid=1)\nTest run with 1 test passed' run tsanreport thread A
[[ $code -eq 1 && "$(cat "$tmp/out")" == *'sanitize: the sanitizer reported a defect'* ]] || fail "a TSan report: exit $code: $(cat "$tmp/out")"

run usage memory A
[[ $code -eq 2 && "$(cat "$tmp/out")" == *'usage: scripts/sanitize.sh'* && ! -s "$tmp/args.log" ]] || fail "a wrong kind: exit $code: $(cat "$tmp/out")"

[[ $failures -eq 0 ]] && echo "sanitize tests: all passed"
exit $((failures > 0))
