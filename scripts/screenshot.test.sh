#!/bin/bash
# Check the arguments of screenshot.sh. A fake swift on PATH replaces the window list of the
# program with the list in FAKE_WINDOWS, so no case reads the screen. A fake screencapture records
# its arguments, so no case captures the screen. Run by `make test-hooks`.
set -uo pipefail
shot="$(cd "$(dirname "$0")" && pwd -P)/screenshot.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# The fake swift replaces the one window list line of the program with FAKE_WINDOWS.
# It exits 3 when the program has no such line or more than one.
# It also exits 3 when another line names CGWindowList.
# ponytail: the guard sees only CGWindowList lines. It does not catch another window source, for
# example ScreenCaptureKit or CGDisplayCreateImage. Upgrade to an injected window-list seam in
# screenshot.sh when the query changes.
real_swift="$(command -v swift)"
[[ -n "$real_swift" ]] || { echo "FAIL: swift not on PATH"; exit 1; }
mkdir "$tmp/bin"
cat >"$tmp/bin/swift" <<FAKE
#!/bin/bash
program="\$(awk '/^let windows = CGWindowListCopyWindowInfo/ { print ENVIRON["FAKE_WINDOWS"]; n++; next }
    /CGWindowList/ { other++ } { print } END { exit n != 1 || other }')" ||
    { echo "fake swift: not one window list line, or another CGWindowList line" >&2; exit 3; }
exec "$real_swift" - <<<"\$program"
FAKE
cat >"$tmp/bin/screencapture" <<FAKE
#!/bin/bash
echo "\$* " >"$tmp/screencapture.args"
touch "\${!#}"
FAKE
chmod +x "$tmp/bin/swift" "$tmp/bin/screencapture"
export PATH="$tmp/bin:$PATH"
export FAKE_WINDOWS='let windows: [[String: Any]] = []'
desktop='"kCGWindowOwnerName": "Dock", "kCGWindowLayer": -2147483623, "kCGWindowNumber": 41'

# Control: the fake refuses a second window query in another form. The query is in a comment, so
# a fake that passes it to the real swift does not read the screen.
err="$("$tmp/bin/swift" 2>&1 >/dev/null <<'PROGRAM'
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
// let all = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
PROGRAM
)"
code=$?
[[ $code -eq 3 ]] || fail "second window query: fake swift exit $code, not 3"
[[ "$err" == *"fake swift:"* ]] || fail "second window query: no fake swift message: $err"

# Control: the fake refuses a program with no window list line. The program reads no window.
err="$("$tmp/bin/swift" 2>&1 >/dev/null <<<'print("no window list")')"
code=$?
[[ $code -eq 3 ]] || fail "no window list line: fake swift exit $code, not 3"
[[ "$err" == *"fake swift:"* ]] || fail "no window list line: no fake swift message: $err"

err="$("$shot" 2>&1 >/dev/null)" && fail "no argument: exit 0"
[[ "$err" == *"usage: screenshot.sh"* ]] || fail "no argument: no usage text: $err"

err="$("$shot" --owner 2>&1 >/dev/null)" && fail "--owner with no name: exit 0"
[[ "$err" == *"usage: screenshot.sh"* ]] || fail "--owner with no name: no usage text: $err"

err="$("$shot" --owner NoSuchApp "$tmp/x.png" 2>&1 >/dev/null)"
code=$?
[[ $code -eq 1 ]] || fail "unknown owner: exit $code, not 1"
[[ "$err" == *"No NoSuchApp window on screen"* ]] || fail "unknown owner: wrong message: $err"
[[ ! -e "$tmp/x.png" ]] || fail "unknown owner: a file was written"

# The Dock has an on-screen window, but only below layer 0 (the desktop). The owner mode once
# took the first window of the owner, a tooltip in place of the session window (run record-over-gap).
export FAKE_WINDOWS="let windows: [[String: Any]] = [[$desktop]]"
err="$("$shot" --owner Dock "$tmp/dock.png" 2>&1 >/dev/null)"
code=$?
[[ $code -eq 1 ]] || fail "owner with only a desktop window: exit $code, not 1"
[[ "$err" == *"No Dock window on screen"* ]] || fail "owner with only a desktop window: wrong message: $err"
[[ ! -e "$tmp/dock.png" ]] || fail "owner with only a desktop window: a file was written"

# Control: the same list with a normal window of the Dock. The case passes only through the fake list.
export FAKE_WINDOWS="let windows: [[String: Any]] = [[$desktop], [\"kCGWindowOwnerName\": \"Dock\", \"kCGWindowLayer\": 0, \"kCGWindowNumber\": 4242]]"
err="$("$shot" --owner Dock "$tmp/dock.png" 2>&1 >/dev/null)"
code=$?
[[ $code -eq 0 ]] || fail "owner with a normal window: exit $code, not 0: $err"
[[ "$(cat "$tmp/screencapture.args" 2>/dev/null)" == *"-l 4242 "* ]] || fail "owner with a normal window: screencapture did not get -l 4242"

err="$("$shot" --window 2>&1 >/dev/null)" && fail "--window with no ID: exit 0"
[[ "$err" == *"usage: screenshot.sh"* ]] || fail "--window with no ID: no usage text: $err"

# The --window cases use the same two windows (41 and 4242). No window has the number 0, so the
# script matches the number, not the position in the list.
err="$("$shot" --window 0 "$tmp/x.png" 2>&1 >/dev/null)"
code=$?
[[ $code -eq 1 ]] || fail "unknown window: exit $code, not 1"
[[ "$err" == *"No window 0 on screen"* ]] || fail "unknown window: wrong message: $err"
[[ ! -e "$tmp/x.png" ]] || fail "unknown window: a file was written"

# --window takes the window with that number.
rm -f "$tmp/screencapture.args"
err="$("$shot" --window 4242 "$tmp/w.png" 2>&1 >/dev/null)"
code=$?
[[ $code -eq 0 ]] || fail "window by number: exit $code, not 0: $err"
[[ "$(cat "$tmp/screencapture.args" 2>/dev/null)" == *"-l 4242 "* ]] || fail "window by number: screencapture did not get -l 4242"
export FAKE_WINDOWS='let windows: [[String: Any]] = []'

[[ $failures -eq 0 ]] && echo "screenshot tests: all passed" || { echo "screenshot tests: $failures failed"; exit 1; }
