#!/bin/bash
# Check the argument parsing of hid.swift, the frontmost guard (exit 4), and the order of its key
# events (--dry-run). It posts no event: each case ends before the post. Run by `make test-hooks`.
set -uo pipefail
hid="$(cd "$(dirname "$0")" && pwd -P)/hid.swift"
failures=0

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# expect_usage <case> <args...>: exit 2 and the usage text on stderr.
expect_usage() {
    local name="$1"
    shift
    local err
    err="$(swift "$hid" "$@" 2>&1 >/dev/null)"
    local code=$?
    [[ $code -eq 2 ]] || fail "$name: exit $code, not 2"
    [[ "$err" == *"usage: hid.swift"* ]] || fail "$name: no usage text: $err"
}

expect_usage "no command"
expect_usage "unknown command" wiggle 1 2
expect_usage "drag with two numbers" drag 10 20
expect_usage "up with a word" up 10 left
expect_usage "up with one number" up 5
expect_usage "key with no code" key
expect_usage "scroll with one number" scroll 5

expect_usage "click with one number" click 10
expect_usage "an unknown flag" key 53 --hyper
expect_usage "type with no text" type --dry-run
expect_usage "type with a modifier flag" type a --command

# The usage comes from the flag table of each verb: the click line lists every flag that click
# takes, and a flag of another verb is a usage error. No app has the bundle ID, so nothing posts.
usage_text="$(swift "$hid" 2>&1)"
grep -qE '^ *(usage: )?hid\.swift click <x> <y> .*--command' <<<"$usage_text" || fail "the click usage has no --command: $usage_text"
DIRIGIBLE_BUNDLE_ID=com.example.no-such-app expect_usage "drag with a click flag" drag 1 2 3 4 --right

expect_usage "type with a newline" type $'a\nb'
expect_usage "type with a tab" type $'a\tb'

# A real command with no target app (no app has the bundle ID): exit 4 and no event line. The
# incident of run 2026-10-04-hid-front sent the keys to the terminal. The check comes before the
# Accessibility check, so the case posts nothing. A dry run needs no target app, so no case
# depends on the frontmost app of the desktop or brings an app to the front.
errf="$(mktemp)"
for args in "key 53" "type -20" "click 10 20" "scroll 10 20 0 -3"; do
    # shellcheck disable=SC2086
    out="$(DIRIGIBLE_BUNDLE_ID=com.example.no-such-app swift "$hid" $args 2>"$errf")"
    code=$?
    [[ $code -eq 4 ]] || fail "$args with no target app: exit $code, not 4"
    [[ -z "$out" ]] || fail "$args with no target app: an event line: $out"
    grep -q "not frontmost" "$errf" || fail "$args with no target app: no message"
done
rm -f "$errf"
[[ "$(DIRIGIBLE_BUNDLE_ID=com.example.no-such-app swift "$hid" key 53 --dry-run 2>&1)" == $'down 53 flags 0\nup 53 flags 0' ]] \
    || fail "a dry run with no target app"
[[ "$(swift "$hid" type -20 --dry-run 2>&1)" == "type -20" ]] || fail "type -20 in a dry run"

# A dry run of an up prints its origin and exits before the Accessibility check and any post. A
# bare up goes to the pointer, also when the target app has a window on screen (Finder): the
# window branch read a point that a bare up does not have.
for app in com.example.no-such-app com.apple.finder; do
    out="$(DIRIGIBLE_BUNDLE_ID=$app swift "$hid" up --dry-run 2>&1)"
    code=$?
    [[ $code -eq 0 && "$out" =~ ^up\ pointer\ -?[0-9]+\ -?[0-9]+$ ]] || fail "a bare up with $app: exit $code: $out"
done
out="$(DIRIGIBLE_BUNDLE_ID=com.example.no-such-app swift "$hid" up 5 5 --dry-run 2>&1)"
code=$?
[[ $code -eq 0 && "$out" =~ ^up\ pointer\ -?[0-9]+\ -?[0-9]+$ ]] || fail "up 5 5 with no target app: exit $code: $out"

# The modifier keys go down before the key and up after it (55 Command, 58 Option; flags 1048576
# and 524288): a flag on the key event alone left the system modifier held.
events="$(swift "$hid" key 17 --command --option --dry-run 2>&1)"
want="down 55 flags 1048576
down 58 flags 1572864
down 17 flags 1572864
up 17 flags 1572864
up 58 flags 1048576
up 55 flags 0"
[[ "$events" == "$want" ]] || fail "the modifier keys around a key: $events"
[[ "$(swift "$hid" key 53 --dry-run 2>&1)" == $'down 53 flags 0\nup 53 flags 0' ]] || fail "a key with no modifier"

# A Shift wheel event (timeline-navigation N20): the Shift key down, the wheel event with the
# Shift flag (131072), and the Shift key up, so no modifier stays held.
events="$(swift "$hid" scroll 100 200 0 -30 --shift --dry-run 2>&1)"
want="down 56 flags 131072
wheel 0 -30 lines flags 131072
up 56 flags 0"
[[ "$events" == "$want" ]] || fail "the Shift key goes up around a wheel event: $events"
[[ "$(swift "$hid" scroll 100 200 0 -30 --dry-run 2>&1)" == "wheel 0 -30 lines flags 0" ]] || fail "a wheel event with no modifier"
# A mouse wheel event is in lines: macOS turns Shift with the wheel into a horizontal scroll only
# for lines (timeline-navigation Phase 7: a Shift wheel event in pixels did not scroll the lanes).
# A trackpad gesture (--phases) is in pixels.
[[ "$(swift "$hid" scroll 100 200 0 -30 --phases --dry-run 2>&1)" == "wheel 0 -30 pixels flags 0" ]] \
    || fail "a trackpad gesture is in pixels"

# drag --outside (run 13c C13): the start is in a Finder window in front, and the end is in the
# target window. HID_TEST_WINDOWS gives the windows of a dry run, front to back, as `owner x y w h`
# groups; the owner `target` is the target app. No app has the bundle ID, so nothing posts.
expect_usage "click with --outside" click 1 2 --outside
# expect_drag <case> <windows> <exit> <stdout or stderr text> <drag args...>
expect_drag() {
    local name="$1" windows="$2" want_code="$3" want_text="$4"
    shift 4
    local out code
    out="$(DIRIGIBLE_BUNDLE_ID=com.example.no-such-app HID_TEST_WINDOWS="$windows" swift "$hid" drag "$@" --outside --dry-run 2>&1)"
    code=$?
    [[ $code -eq $want_code ]] || fail "$name: exit $code, not $want_code: $out"
    [[ "$out" == *"$want_text"* ]] || fail "$name: no \"$want_text\": $out"
}
side="target 100 100 800 600 Finder 1000 100 400 400"
expect_drag "a start in a Finder window and an end in the target window" "$side" 0 "drag 1050 200 to 550 200" 950 100 -500 0
expect_drag "an end outside the target window" "$side" 5 "outside the target window" 950 100 0 0
expect_drag "a start outside every Finder window" "$side" 5 "not in a Finder window" 1500 100 -1000 0
over="target 100 100 800 600 Finder 500 100 400 400"
expect_drag "a target window over a Finder window at the start" "$over" 5 "not in a Finder window" 500 100 -200 0
behind="Finder 500 100 400 400 target 100 100 800 600"
expect_drag "a Finder window over the target window at the start" "$behind" 0 "drag 600 200 to 400 200" 500 100 -200 0

[[ $failures -eq 0 ]] && echo "hid tests: all passed" || { echo "hid tests: $failures failed"; exit 1; }
