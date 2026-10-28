#!/bin/bash
# Make, drive, and stop the verify copy of the app: build/verify/Dirigible-verify.app with the
# bundle ID com.delineas.dirigible.verify-<8 hex>, from a hash of the worktree root. A check that
# writes preferences or a recent list, or answers a privacy prompt, runs on this copy, so the real
# app keeps its state. Each worktree gets its own ID: with one shared ID, hid.swift finds the
# copies of two trees and refuses, and a stop in one tree resets the grants of the other copy.
# The script does not build the app: run `make app` first.
#
# usage: verify-copy.sh start [--agents] [--accent <n>] [<package>] [-- <open arguments>]
#                                  stop a running copy, clean up, copy build/Dirigible.app, set
#                                  the bundle ID, sign it, open it with its own MCP socket
#                                  (DIRIGIBLE_MCP_SOCKET=build/verify/mcp.sock), and print its PID
#                                  and a DIRIGIBLE_MCP_SOCKET line for an MCP client; --agents
#                                  turns the agents switch on; --accent <n> (-1 Graphite to 6)
#                                  writes the global accent (defaults -g AppleAccentColor) before
#                                  the open, after it saves the old value in the file
#                                  dirigible-screen-accent-old beside the screen lock (only when
#                                  the file is absent); while the copy of another worktree runs,
#                                  wait for the screen lock up to VERIFY_COPY_SCREEN_WAIT s
#                                  (default 480), then exit 1; a socket path of 104 bytes or more
#                                  exits 1 (sun_path holds 103)
#        verify-copy.sh id         print the bundle ID of the copy of this worktree (no build);
#                                  call it by the absolute path of the tree that runs the copy
#        verify-copy.sh ax <ax.swift arguments>
#                                  run scripts/ax.swift on the copy (DIRIGIBLE_BUNDLE_ID)
#        verify-copy.sh prompt <button>
#                                  press the button of the privacy prompt of the copy, by its
#                                  whole name; wait up to VERIFY_COPY_PROMPT_WAIT s (default 10)
#        verify-copy.sh doctor     print four ok lines, for the facts (a) to (f): (a) the copy
#                                  runs; the build is current: (b) build/Dirigible.app did not
#                                  change after start, (c) no source is newer than it; (d) the
#                                  copy shows a window, (e) with Accessibility trust; (f) the
#                                  screen is unlocked
#        verify-copy.sh stop       stop the copy and clean up its TCC grants, its preferences,
#                                  its saved state, and build/verify; put back the saved global
#                                  accent, then remove the screen lock
#
# Only the tree that holds the screen lock puts back the saved accent: at stop, and at its next
# start (also after the takeover of a dead copy). A failed restore keeps the file and exits 1.
#
# Safety: the script finds the copy only by the absolute path of its executable (pgrep -f with an
# anchor), and kills only those PIDs. It never stops a process by name. Each recursive delete acts
# only on build/verify or the saved state of the copy ID. tccutil and defaults get only the copy ID,
# apart from the defaults calls of the global accent.
# Exit: 0 done, 1 a failed step (the message names it), 2 usage or a pgrep error.
set -euo pipefail

usage="usage: verify-copy.sh start [--agents] [--accent <n>] [<package>] [-- <open arguments>]
       verify-copy.sh id
       verify-copy.sh ax <ax.swift arguments>
       verify-copy.sh prompt <button>
       verify-copy.sh doctor
       verify-copy.sh stop"

# A plain assignment: `local root=$(...)` hides the exit code of git.
root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
real_app="$root/build/Dirigible.app"
copy="$root/build/verify/Dirigible-verify.app"
socket="$root/build/verify/mcp.sock"
copy_id="com.delineas.dirigible.verify-$(printf '%s' "$root" | shasum | cut -c1-8)"
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

# The screen lock: one verify copy on the screen at a time, for all worktrees. The folder
# dirigible-screen of the git common dir holds the root of the tree and the PID of its copy (the
# PID of start until the copy runs). A lock with no PID file is held.
screen="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/dirigible-screen"
# The global accent before the first start --accent: a number, or unset. A file beside the lock
# folder, so release_screen, cleanup, and a worktree removal keep it.
saved_accent="$screen-accent-old"

# Take the screen lock for this tree. While the copy of another tree runs, print the holder once,
# poll each second, and exit 1 after VERIFY_COPY_SCREEN_WAIT s (default 480). The lock of a dead
# PID is taken over by one start at a time (the folder <lock>.reap).
take_screen() {
    local wait="${VERIFY_COPY_SCREEN_WAIT:-480}" holder pid i
    [[ "$wait" =~ ^[0-9]+$ ]] || { echo "verify-copy.sh: VERIFY_COPY_SCREEN_WAIT is not a whole number of seconds: $wait" >&2 && exit 2; }
    for ((i = 0; ; i++)); do
        mkdir "$screen" 2>/dev/null && break
        holder="$(cat "$screen/root" 2>/dev/null)" pid="$(cat "$screen/pid" 2>/dev/null)"
        [[ "$holder" != "$root" ]] || break
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && mkdir "$screen.reap" 2>/dev/null; then
            if [[ "$(cat "$screen/pid" 2>/dev/null)" == "$pid" ]]; then
                echo "$root" >"$screen/root"
                echo "verify-copy.sh: took over the screen lock of the dead PID $pid" >&2
                rmdir "$screen.reap"
                break
            fi
            rmdir "$screen.reap"
            continue
        fi
        [[ $i -gt 0 ]] || echo "verify-copy.sh: the verify copy of ${holder:-another tree} (PID ${pid:-unknown}) holds the screen; wait up to $wait s (VERIFY_COPY_SCREEN_WAIT)" >&2
        if [[ $i -ge $wait ]]; then
            echo "verify-copy.sh: the verify copy of ${holder:-another tree} (PID ${pid:-unknown}) is still on the screen after $wait s; wait and start again, and stop it only when scripts/wiki.py runs shows that run done" >&2
            exit 1
        fi
        sleep 1
    done
    echo "$root" >"$screen/root"
    echo $$ >"$screen/pid"
}

# When this tree holds the screen lock and an accent is saved, put it back, then remove the file.
# A failed write keeps the file and returns 1. For unset, a key that is already gone is restored:
# a delete of it exits 1 ("Domain (kCFPreferencesAnyApplication) not found"), and a read tells.
restore_accent() {
    local old out rc=0
    [[ "$(cat "$screen/root" 2>/dev/null)" == "$root" && -f "$saved_accent" ]] || return 0
    old="$(cat "$saved_accent")"
    if [[ "$old" == unset ]]; then
        out="$(defaults delete -g AppleAccentColor 2>&1)" || rc=$?
        [[ $rc -eq 0 || "$(defaults read -g AppleAccentColor 2>&1)" != *"does not exist"* ]] || rc=0
    else
        out="$(defaults write -g AppleAccentColor -int "$old" 2>&1)" || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        echo "verify-copy.sh: the restore of the global accent $old failed (exit $rc): $out. The value stays in $saved_accent." >&2
        return 1
    fi
    rm -f "$saved_accent"
}

# Put back the saved accent, then remove the screen lock, when this tree holds it. A failed
# restore still removes the lock and returns 1.
release_screen() {
    local rc=0
    [[ "$(cat "$screen/root" 2>/dev/null)" == "$root" ]] || return 0
    restore_accent || rc=$?
    rm -f "$screen/root" "$screen/pid"
    rmdir "$screen" 2>/dev/null || true
    return "$rc"
}

# Save the old global accent (only when no value is saved), then write the accent $1.
set_accent() {
    local out rc=0 old
    out="$(defaults read -g AppleAccentColor 2>&1)" || rc=$?
    if [[ $rc -eq 0 && "$out" =~ ^-?[0-9]+$ ]]; then
        old="$out"
    elif [[ $rc -eq 1 && "$out" == *"does not exist"* ]]; then
        old=unset
    else
        echo "verify-copy.sh: defaults read -g AppleAccentColor failed (exit $rc): $out" >&2
        exit 1
    fi
    [[ -e "$saved_accent" ]] || echo "$old" >"$saved_accent"
    out="$(defaults write -g AppleAccentColor -int "$1" 2>&1)" ||
        { echo "verify-copy.sh: defaults write -g AppleAccentColor -int $1 failed: $out" >&2 && exit 1; }
}

start() {
    local open_args=() pid="" out agents=0 accent="" arg has_args=0 bytes
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agents) agents=1 && shift ;;
            --accent)
                [[ $# -ge 2 && "$2" =~ ^(-1|[0-6])$ ]] || { echo "$usage" >&2 && exit 2; }
                accent="$2" && shift 2 ;;
            *) break ;;
        esac
    done
    if [[ $# -gt 0 && "$1" != -- ]]; then open_args+=("$1") && shift; fi
    if [[ $# -gt 0 ]]; then
        [[ "$1" == -- ]] || { echo "$usage" >&2 && exit 2; }
        shift
        open_args+=("$@")
    fi
    [[ -d "$real_app" ]] || { echo "verify-copy.sh: no $real_app: run make app first." >&2 && exit 1; }
    bytes="$(printf '%s' "$socket" | wc -c | tr -d ' ')"
    if [[ $bytes -ge 104 ]]; then
        echo "verify-copy.sh: the socket path $socket is $bytes bytes; a socket path holds 103 bytes. Move the checkout to a shorter path." >&2
        exit 1
    fi
    take_screen
    restore_accent || exit 1
    stop_copy >/dev/null
    cleanup
    mkdir -p "$root/build/verify"
    if [[ -n "$accent" ]]; then
        # A failed start puts the old accent back; a good start clears the trap.
        trap 'restore_accent || true' EXIT
        set_accent "$accent"
    fi
    cp -R "$real_app" "$copy"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $copy_id" "$copy/Contents/Info.plist"
    stat -f %m "$real_app/Contents/MacOS/Dirigible" >"$root/build/verify/source-mtime"
    out="$(codesign --force --sign - "$copy" 2>&1)" || { echo "verify-copy.sh: codesign failed: $out" >&2 && exit 1; }
    for arg in ${open_args[@]+"${open_args[@]}"}; do [[ "$arg" != --args ]] || has_args=1; done
    if [[ $agents -eq 1 ]]; then
        [[ $has_args -eq 1 ]] || open_args+=(--args)
        open_args+=(-agents.edit.open.sessions YES)
    fi
    open -a "$copy" --env "DIRIGIBLE_MCP_SOCKET=$socket" ${open_args[@]+"${open_args[@]}"}
    for _ in $(seq 50); do
        pid="$(copy_pids)"
        [[ -z "$pid" ]] || break
        sleep 0.2
    done
    [[ -n "$pid" ]] || { echo "verify-copy.sh: the copy did not start in 10 s." >&2 && exit 1; }
    pid="$(printf '%s\n' "$pid" | head -1)"
    echo "$pid" >"$screen/pid"
    trap - EXIT
    echo "$pid"
    echo "DIRIGIBLE_MCP_SOCKET=$socket"
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

# Print locked or unlocked. Exit 1 when there is no GUI session (screenshot.sh reads the same key).
lock_script='import CoreGraphics
import Foundation
guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
    FileHandle.standardError.write(Data("No GUI session.\n".utf8))
    exit(1)
}
print(session["CGSSessionScreenIsLocked"] as? Bool == true ? "locked" : "unlocked")'

# Check each fact and print one line for it. Exit 1 after all facts when one failed. A dirty tree
# is normal during a verify, so no fact reads git.
doctor() {
    local failed="" pids rc out source_mtime recorded build_ok=1
    local source_exe="$real_app/Contents/MacOS/Dirigible"
    # Not local: the EXIT trap runs after the function returns.
    errf="$(mktemp)"
    trap 'rm -f "$errf"' EXIT
    pids="$(copy_pids)"
    if [[ -n "$pids" ]]; then
        echo "ok (a) the verify copy runs: PID ${pids//$'\n'/ }"
    else
        echo "FAIL (a) no verify copy runs. Run scripts/verify-copy.sh start." && failed+=" (a)"
    fi
    source_mtime="$(stat -f %m "$source_exe" 2>/dev/null || echo none)"
    recorded="$(cat "$root/build/verify/source-mtime" 2>/dev/null || echo none)"
    if [[ "$source_mtime" != "$recorded" ]]; then
        echo "FAIL (b) build/Dirigible.app changed after start (mtime $source_mtime, start saw $recorded). Run start again."
        failed+=" (b)" build_ok=0
    fi
    rc=0
    out="$(cd "$root" && find Sources Support Package.swift -newer "$source_exe" -print -quit 2>"$errf")" || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FAIL (c) find failed (exit $rc): $(cat "$errf")" && failed+=" (c)" build_ok=0
    elif [[ -n "$out" ]]; then
        echo "FAIL (c) the build is stale: $out is newer than build/Dirigible.app. Run make app, then start." && failed+=" (c)" build_ok=0
    fi
    [[ $build_ok -eq 0 ]] || echo "ok (b, c) the build is current"
    rc=0
    out="$(DIRIGIBLE_BUNDLE_ID="$copy_id" swift "$root/scripts/ax.swift" dump 2 2>"$errf")" || rc=$?
    case $rc in
        0) if grep -q 'Role=AXWindow' <<<"$out"; then echo "ok (d, e) the copy shows a window"; else
            echo "FAIL (d) the copy shows no window." && failed+=" (d)"; fi ;;
        3) echo "FAIL (e) $(cat "$errf")" && failed+=" (e)" ;;
        *) echo "FAIL (d) ax failed: $(cat "$errf")" && failed+=" (d)" ;;
    esac
    rc=0
    out="$(swift - <<<"$lock_script" 2>"$errf")" || rc=$?
    if [[ $rc -eq 0 && "$out" == unlocked ]]; then
        echo "ok (f) the screen is unlocked"
    else
        echo "FAIL (f) the screen is locked or has no session (exit $rc: $out $(cat "$errf")). Make the interaction checks manual checks."
        failed+=" (f)"
    fi
    [[ -z "$failed" ]] || { echo "verify-copy.sh: doctor failed:$failed" >&2 && exit 1; }
}

# A failed cleanup does not skip the restore of the accent and the release of the lock.
stop() {
    local rc=0
    stop_copy
    cleanup || rc=$?
    release_screen || rc=$?
    return "$rc"
}

case "${1:-}" in
    start) shift; start "$@" ;;
    id) [[ $# -eq 1 ]] || { echo "$usage" >&2 && exit 2; }; echo "$copy_id" ;;
    ax) shift; DIRIGIBLE_BUNDLE_ID="$copy_id" swift "$root/scripts/ax.swift" "$@" ;;
    prompt) [[ $# -eq 2 && -n "$2" ]] || { echo "$usage" >&2 && exit 2; }; prompt "$2" ;;
    doctor) [[ $# -eq 1 ]] || { echo "$usage" >&2 && exit 2; }; doctor ;;
    stop) [[ $# -eq 1 ]] || { echo "$usage" >&2 && exit 2; }; stop ;;
    *) echo "$usage" >&2 && exit 2 ;;
esac
