#!/bin/bash
# Make, drive, and stop the verify copy of the app: build/verify/Dirigible-verify.app with the
# bundle ID com.delineas.dirigible.verify. A check that writes preferences or a recent list, or
# answers a privacy prompt, runs on this copy, so the real app keeps its state.
# The script does not build the app: run `make app` first.
#
# usage: verify-copy.sh start [<package>] [-- <open arguments>]
#                                  stop a running copy, clean up, copy build/Dirigible.app, set
#                                  the bundle ID, sign it, open it, and print its PID
#        verify-copy.sh ax <ax.swift arguments>
#                                  run scripts/ax.swift on the copy (DIRIGIBLE_BUNDLE_ID)
#        verify-copy.sh prompt <button>
#                                  press the button of the privacy prompt of the copy, by its
#                                  whole name; wait up to VERIFY_COPY_PROMPT_WAIT s (default 10)
#        verify-copy.sh stop       stop the copy and clean up its TCC grants, its preferences,
#                                  its saved state, and build/verify
#
# Safety: the script finds the copy only by the absolute path of its executable (pgrep -f with an
# anchor), and kills only those PIDs. It never stops a process by name. Each recursive delete acts
# only on build/verify or the saved state of the copy ID. tccutil and defaults get only the copy ID.
# Exit: 0 done, 1 a failed step (the message names it), 2 usage or a pgrep error.
set -euo pipefail

usage="usage: verify-copy.sh start [<package>] [-- <open arguments>]
       verify-copy.sh ax <ax.swift arguments>
       verify-copy.sh prompt <button>
       verify-copy.sh stop"

# A plain assignment: `local root=$(...)` hides the exit code of git.
root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
real_app="$root/build/Dirigible.app"
copy="$root/build/verify/Dirigible-verify.app"
copy_id=com.delineas.dirigible.verify
exe="$copy/Contents/MacOS/Dirigible"
# The pattern matches the executable path at the start of the command line, then a space or the
# end. Escape each regex character of the path (a temp folder name can have a dot).
exe_pattern="^$(printf '%s' "$exe" | sed 's/[][\.*^$+?(){}|]/\\&/g')( |\$)"

# Print the PIDs of the copy, one per line. pgrep exit 1 means no copy runs. Another exit ends the
# script with exit 2 and the stderr of pgrep. Call it only in a plain assignment, so `set -e`
# applies.
copy_pids() {
    local out rc=0
    out="$(pgrep -f "$exe_pattern" 2>&1)" || rc=$?
    case $rc in
        0) printf '%s\n' "$out" ;;
        1) ;;
        *) echo "verify-copy.sh: pgrep failed (exit $rc): $out" >&2 && exit 2 ;;
    esac
}

# Stop each copy process: SIGTERM, then a wait of up to 5 s, then SIGKILL to the same PID.
stop_copy() {
    local pids pid
    pids="$(copy_pids)"
    if [[ -z "$pids" ]]; then
        echo "No verify copy runs."
        return 0
    fi
    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 50); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
        echo "Stopped the verify copy (PID $pid)."
    done
}

# Reset the copy ID: its TCC grants, its preferences, its saved state, and build/verify. tccutil
# runs before the delete of build/verify, so LaunchServices still finds the bundle. Accept only the
# known results for no data: tccutil "No such bundle identifier" when the copy bundle is absent,
# and defaults exit 1 with "Domain (<id>) not found." Another failure still deletes the folders,
# then returns 1 and names the tool.
cleanup() {
    local out rc failed=""
    rc=0
    out="$(tccutil reset All "$copy_id" 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]] && ! [[ ! -e "$copy" && "$out" == *"No such bundle identifier \"$copy_id\""* ]]; then
        echo "verify-copy.sh: tccutil reset All $copy_id failed (exit $rc): $out" >&2
        failed+=" tccutil"
    fi
    rc=0
    out="$(defaults delete "$copy_id" 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]] && ! [[ $rc -eq 1 && "$out" == *"Domain ($copy_id) not found."* ]]; then
        echo "verify-copy.sh: defaults delete $copy_id failed (exit $rc): $out" >&2
        failed+=" defaults"
    fi
    rm -rf "$HOME/Library/Saved Application State/$copy_id.savedState"
    rm -rf "$root/build/verify"
    if [[ -n "$failed" ]]; then
        echo "verify-copy.sh: the cleanup failed:$failed" >&2
        return 1
    fi
}

start() {
    local open_args=() pid=""
    if [[ $# -gt 0 && "$1" != -- ]]; then open_args+=("$1") && shift; fi
    if [[ $# -gt 0 ]]; then
        [[ "$1" == -- ]] || { echo "$usage" >&2 && exit 2; }
        shift
        open_args+=("$@")
    fi
    [[ -d "$real_app" ]] || { echo "verify-copy.sh: no $real_app: run make app first." >&2 && exit 1; }
    stop_copy >/dev/null
    cleanup
    mkdir -p "$root/build/verify"
    cp -R "$real_app" "$copy"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $copy_id" "$copy/Contents/Info.plist"
    stat -f %m "$real_app/Contents/MacOS/Dirigible" >"$root/build/verify/source-mtime"
    codesign --force --sign - "$copy" 2>/dev/null
    open -a "$copy" ${open_args[@]+"${open_args[@]}"}
    for _ in $(seq 50); do
        pid="$(copy_pids)"
        [[ -z "$pid" ]] || break
        sleep 0.2
    done
    [[ -n "$pid" ]] || { echo "verify-copy.sh: the copy did not start in 10 s." >&2 && exit 1; }
    printf '%s\n' "$pid" | head -1
}

# One poll: find the prompt window of UserNotificationCenter, check that its text names the app,
# and click the button with the whole name, in one script, so no other window comes between the
# check and the click. With no prompt window, the script fails with "no prompt window" (-1719).
# Else it returns one status line: clicked, app <text>, or buttons <names>.
prompt_script='on run argv
    set appName to item 1 of argv
    set buttonName to item 2 of argv
    tell application "System Events"
        if not (exists process "UserNotificationCenter") then error "no prompt window" number -1719
        tell process "UserNotificationCenter"
            if not (exists window 1) then error "no prompt window" number -1719
            set promptText to ""
            repeat with label in static texts of window 1
                set labelText to value of label
                if labelText is missing value then set labelText to name of label
                if labelText is not missing value then set promptText to promptText & labelText & " "
            end repeat
            if promptText does not contain appName then return "app " & promptText
            if not (exists button buttonName of window 1) then
                set names to {}
                repeat with candidate in buttons of window 1
                    set candidateName to name of candidate
                    if candidateName is not missing value then set end of names to candidateName
                end repeat
                set AppleScript'"'"'s text item delimiters to ", "
                return "buttons " & (names as text)
            end if
            click button buttonName of window 1
            return "clicked"
        end tell
    end tell
end run'

# Poll for the prompt. Only "no prompt window" in a failed call means no prompt yet. Another
# failure (-1743: no Automation grant; -1719 with another text: no assistive access) exits 2.
prompt() {
    local button="$1" wait="${VERIFY_COPY_PROMPT_WAIT:-10}" out rc last="" i
    [[ "$wait" =~ ^[1-9][0-9]*$ ]] || { echo "verify-copy.sh: VERIFY_COPY_PROMPT_WAIT is not a whole number of seconds: $wait" >&2 && exit 2; }
    # Two polls per second, with a sleep after each, so the wait is at least the limit.
    for ((i = 0; i < wait * 2; i++)); do
        rc=0
        out="$(osascript - "Dirigible-verify.app" "$button" <<<"$prompt_script" 2>&1)" || rc=$?
        if [[ $rc -eq 0 ]]; then
            case "$out" in
                clicked) echo "Pressed $button." && return 0 ;;
                "app "*) echo "verify-copy.sh: the prompt does not name Dirigible-verify.app: ${out#app }" >&2 && exit 1 ;;
                "buttons "*) echo "verify-copy.sh: the prompt has no button \"$button\". Buttons: ${out#buttons }" >&2 && exit 1 ;;
                *) echo "verify-copy.sh: osascript gave an unknown result: $out" >&2 && exit 2 ;;
            esac
        fi
        [[ "$out" == *"no prompt window"* ]] || { echo "verify-copy.sh: osascript failed (exit $rc): $out" >&2 && exit 2; }
        last="$out"
        sleep 0.5
    done
    echo "verify-copy.sh: no privacy prompt in $wait s. osascript: $(tail -1 <<<"$last")" >&2
    exit 1
}

stop() {
    stop_copy
    cleanup
}

case "${1:-}" in
    start) shift; start "$@" ;;
    ax) shift; DIRIGIBLE_BUNDLE_ID="$copy_id" swift "$root/scripts/ax.swift" "$@" ;;
    prompt) [[ $# -eq 2 && -n "$2" ]] || { echo "$usage" >&2 && exit 2; }; prompt "$2" ;;
    stop) [[ $# -eq 1 ]] || { echo "$usage" >&2 && exit 2; }; stop ;;
    *) echo "$usage" >&2 && exit 2 ;;
esac
