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

# The fake swift fails when the program has not exactly one window list line, so a changed
# screenshot.sh cannot make a case read the real screen.
mkdir "$tmp/bin"
cat >"$tmp/bin/swift" <<FAKE
#!/bin/bash
program="\$(awk '/^let windows = CGWindowListCopyWindowInfo/ { print ENVIRON["FAKE_WINDOWS"]; n++; next }
    { print } END { exit n != 1 }')" || { echo "fake swift: no single window list line" >&2; exit 3; }
exec $(command -v swift) - <<<"\$program"
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
export FAKE_WINDOWS='let windows: [[String: Any]] = []'

err="$("$shot" --window 2>&1 >/dev/null)" && fail "--window with no ID: exit 0"
[[ "$err" == *"usage: screenshot.sh"* ]] || fail "--window with no ID: no usage text: $err"

# No window has the number 0.
err="$("$shot" --window 0 "$tmp/x.png" 2>&1 >/dev/null)"
code=$?
[[ $code -eq 1 ]] || fail "unknown window: exit $code, not 1"
[[ "$err" == *"No window 0 on screen"* ]] || fail "unknown window: wrong message: $err"
[[ ! -e "$tmp/x.png" ]] || fail "unknown window: a file was written"

[[ $failures -eq 0 ]] && echo "screenshot tests: all passed" || { echo "screenshot tests: $failures failed"; exit 1; }
