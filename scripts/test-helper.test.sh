#!/bin/bash
# Check that test-helper.sh signs its copy of the helper only when the source changes or the copy
# has no get-task-allow, leaves no copy when the sign fails, finds its copy from any working folder,
# and execs the copy with the arguments, the DYLD variables, and stderr on stdout.
# A fake codesign on PATH stands in for the sign. The fake helper is a small C program, because
# macOS removes the DYLD variables when it starts /bin/bash, so a bash fake cannot show them.
# make test-hooks runs it.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

root="$tmp/root" copy="$tmp/root/.build/test-helper/swiftpm-testing-helper"
mkdir -p "$root/scripts" "$tmp/bin"
cp "$here/test-helper.sh" "$root/scripts/"
# The fake helper prints its arguments and the three variables on stdout, and the report line on
# stderr. V gives two sources with other bytes.
for v in 1 2; do
    xcrun clang -x c -o "$tmp/helper-$v" -DV=$v - <<'EOF' || { echo "FAIL: cannot build the fake helper"; exit 1; }
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    printf("version %d\n", V);
    for (int i = 1; i < argc; i++) printf("arg %s\n", argv[i]);
    const char *names[] = {"DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES"};
    for (int i = 0; i < 3; i++) { const char *v = getenv(names[i]); printf("%s=%s\n", names[i], v ? v : ""); }
    fflush(stdout);
    fprintf(stderr, "Test run with 1 test passed\n");
    return 0;
}
EOF
done
# DYLD_INSERT_LIBRARIES must name a dylib that loads.
echo 'int insert_marker;' | xcrun clang -x c -dynamiclib -o "$tmp/libinsert.dylib" - || { echo "FAIL: cannot build the dylib"; exit 1; }
# The fake codesign logs each sign, and keeps the shasum of each file that it signed: a display
# of a file with a signed sum shows get-task-allow. FAKE_SIGN_FAIL=1 makes the sign fail.
cat > "$tmp/bin/codesign" <<'EOF'
#!/bin/bash
file="${*: -1}"
if [[ "$1" == -d ]]; then
    grep -qxF "$(shasum < "$file")" "$FAKE_DIR/signed" 2>/dev/null && echo '[Key] com.apple.security.get-task-allow'
    exit 0
fi
[[ -z "${FAKE_SIGN_FAIL:-}" ]] || exit 1
echo "sign $*" >> "$FAKE_DIR/sign.log"
shasum < "$file" >> "$FAKE_DIR/signed"
EOF
chmod +x "$tmp/bin/codesign"
export FAKE_DIR="$tmp" TEST_HELPER_SOURCE="$tmp/source"
signs() { grep -c . "$tmp/sign.log" 2>/dev/null || echo 0; }
call() { PATH="$tmp/bin:$PATH" "$root/scripts/test-helper.sh" "$@" 2> "$tmp/err"; }

cp "$tmp/helper-1" "$tmp/source"
out="$(call --test-bundle-path /b --filter 'A|B')" || fail "first call: exit $?: $out $(cat "$tmp/err")"
[[ "$(signs)" -eq 1 && -x "$copy" ]] || fail "first call: $(signs) signs, copy $(ls "$copy" 2>&1)"
[[ "$out" == *$'arg --test-bundle-path\narg /b\narg --filter\narg A|B'* ]] || fail "first call: the arguments: $out"
[[ "$out" == *"DYLD_FRAMEWORK_PATH=$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"* &&
    "$out" == *"DYLD_LIBRARY_PATH=$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"* &&
    "$out" == *$'DYLD_INSERT_LIBRARIES=\n'* ]] || fail "first call: the DYLD variables: $out"
# Swift Testing prints the report line on stderr; xctrace --target-stdout logs only stdout.
[[ "$out" == *'Test run with 1 test passed'* ]] || fail "first call: no report line on stdout: $out"

out="$(TEST_HELPER_INSERT="$tmp/libinsert.dylib" call)" || fail "second call: exit $?"
[[ "$(signs)" -eq 1 ]] || fail "second call with the same source: $(signs) signs"
[[ "$out" == *"DYLD_INSERT_LIBRARIES=$tmp/libinsert.dylib"* ]] || fail "insert: $out"

out="$(cd / && call)" || fail "another working folder: exit $?"
[[ "$(signs)" -eq 1 && "$out" == *'version 1'* ]] || fail "another working folder: $(signs) signs: $out"

cp "$tmp/helper-2" "$tmp/source"
out="$(call)" || fail "changed source: exit $?"
[[ "$(signs)" -eq 2 && "$out" == *'version 2'* ]] || fail "changed source: $(signs) signs: $out"

# A copy with no get-task-allow (a stop between the copy and the sign) is signed again. One more
# byte gives a sum that the fake codesign did not sign.
printf x >> "$copy"
out="$(call)" || fail "unsigned copy: exit $?"
[[ "$(signs)" -eq 3 && "$out" == *'version 2'* ]] || fail "unsigned copy: $(signs) signs: $out"

# A failed sign exits nonzero, names the cause, and leaves no copy and no temporary file.
rm -rf "$root/.build/test-helper"
out="$(FAKE_SIGN_FAIL=1 call)"
code=$?
[[ $code -ne 0 && "$(cat "$tmp/err")" == *'test-helper: cannot sign'* ]] || fail "failed sign: exit $code: $out $(cat "$tmp/err")"
leftover="$(ls -A "$root/.build/test-helper" 2>/dev/null | grep -v '^entitlements.plist$')"
[[ ! -e "$copy" && -z "$leftover" ]] || fail "failed sign: files stay: $(ls -A "$root/.build/test-helper")"

[[ $failures -eq 0 ]] && echo "test-helper tests: all passed"
exit $((failures > 0))
