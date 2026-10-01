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

stop() {
    stop_copy
    cleanup
}

case "${1:-}" in
    start) shift; start "$@" ;;
    ax) shift; DIRIGIBLE_BUNDLE_ID="$copy_id" swift "$root/scripts/ax.swift" "$@" ;;
    stop) [[ $# -eq 1 ]] || { echo "$usage" >&2 && exit 2; }; stop ;;
    *) echo "$usage" >&2 && exit 2 ;;
esac
