#!/bin/bash
# Runs the tests that match the names under Address Sanitizer (address) or Thread Sanitizer
# (thread): make test-asan and make test-tsan.
# Usage: scripts/sanitize.sh <address|thread> <name> [<name>...]
# `swift test --sanitize` does not run on this Mac: dyld refuses the sanitizer runtime in the
# Apple-signed test helper ("Sanitizer load violates platform policy"). So the script builds the
# tests with the sanitizer in a scratch path of its own (.build/asan or .build/tsan), and runs the
# bundle through scripts/test-helper.sh with the runtime of `xcrun clang -print-file-name` inserted.
# The names, also with spaces in one argument, join into one --filter '<name>|<name>'. The --skip
# list is a copy of the one of scripts/test-filter.sh: the app bundle and disk image tests need a
# build of their own, and the inserted runtime reaches the `dirigible` binary that the CLI tests
# start, so they fail.
# ASAN_OPTIONS stops at the first report and does not check leaks. TSAN_OPTIONS reports each race,
# with the LAME tables of scripts/tsan.supp suppressed. The script fails on a sanitizer report, on
# a test failure, when no test matched, and when the test process ended before its report line.
# Limits: ASan does not check the memory of a swift_release write or of the Apple frameworks.
# The script holds the build lock (with-lock.sh) once for the build and the run. Under the hold of
# a caller, it runs at once. scripts/sanitize.test.sh tests it.
set -euo pipefail
usage="usage: scripts/sanitize.sh <address|thread> <name> [<name>...]"
[[ $# -ge 2 && ("$1" == address || "$1" == thread) ]] || { echo "$usage" >&2; exit 2; }
# with-lock.sh runs this script again with the marker, and the marker stops a second wrap.
[[ "${DIRIGIBLE_LOCKED_SCRIPT:-}" == "$0" ]] || DIRIGIBLE_LOCKED_SCRIPT="$0" exec "$(dirname "$0")/with-lock.sh" "$0" "$@"
kind="$1"
shift
read -ra names <<< "$*"
filter="$(IFS='|'; echo "${names[*]}")"
short=asan
[[ "$kind" == address ]] || short=tsan
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift build --build-tests --sanitize="$kind" --scratch-path "$root/.build/$short"
export ASAN_OPTIONS=halt_on_error=1:detect_leaks=0
export TSAN_OPTIONS="halt_on_error=0:report_signal_unsafe=0:suppressions=$root/scripts/tsan.supp"
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
code=0
TEST_HELPER_INSERT="$(xcrun clang -print-file-name="libclang_rt.${short}_osx_dynamic.dylib")" \
    "$root/scripts/test-helper.sh" \
    --test-bundle-path "$root/.build/$short/$(uname -m)-apple-macosx/debug/DirigiblePackageTests.xctest/Contents/MacOS/DirigiblePackageTests" \
    --testing-library swift-testing --filter "$filter" --skip AppBundleTests --skip DiskImageTests --skip DirigibleCLITests |
    tee "$out" || code=$?
if grep -qE 'ERROR: AddressSanitizer|WARNING: ThreadSanitizer' "$out"; then
    echo "sanitize: the sanitizer reported a defect (filter $filter)" >&2
    exit 1
fi
# The runner runs only Swift Testing, so this line alone means that no test ran.
if grep -qF 'Test run with 0 tests' "$out"; then
    echo "sanitize: no test matched the filter $filter" >&2
    exit 1
fi
[[ $code -eq 0 ]] || exit "$code"
grep -qF 'Test run with' "$out" || { echo "sanitize: the test process ended before its report (filter $filter)" >&2; exit 1; }
