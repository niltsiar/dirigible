#!/bin/bash
# Save a PNG of one window only (not the whole screen), for UI evidence.
# Usage: scripts/screenshot.sh [--owner <name> | --window <id>] <out.png>. Start the app first
# with `make run`.
# The default owner is Dirigible. The owner mode takes a normal window (layer 0) before a tooltip
# of the owner, and never a desktop window (below layer 0). For a window of another process, for example the Gatekeeper
# dialog, give its process name: --owner CoreServicesUIAgent. For one window of several, give its
# kCGWindowNumber: --window <id>. A full-screen capture records private content, so this script
# never makes one.
# The terminal app needs the Screen Recording permission.
set -euo pipefail
usage="usage: screenshot.sh [--owner <name> | --window <id>] <out.png>"
owner=Dirigible
window=""
case "${1:-}" in
    --owner) owner="${2:?$usage}" && shift 2 ;;
    --window) window="${2:?$usage}" && owner="" && shift 2 ;;
esac
out="${1:?$usage}"

id="$(OWNER="$owner" WINDOW="$window" swift - <<'SWIFT'
import CoreGraphics
import Foundation
// On a locked screen a window capture still works, but a menu or a popover does not come on
// screen. Say so, so that the caller makes those UI checks manual checks.
let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
if session["CGSSessionScreenIsLocked"] as? Bool == true {
    FileHandle.standardError.write(Data("The screen is locked: menus, popovers, HID events, and the AX window tree do not work. Make every interaction check a manual check.\n".utf8))
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let env = ProcessInfo.processInfo.environment
let number = Int(env["WINDOW"] ?? "")
// The owner mode prefers a layer-0 window (a normal window) over a tooltip of the owner, which is at
// a higher layer. A dialog of a system process can be at a higher layer only. A window below layer 0
// is the desktop, never an app window.
let owned = windows.filter { $0[kCGWindowOwnerName as String] as? String == env["OWNER"] }
let layer = { (window: [String: Any]) in window[kCGWindowLayer as String] as? Int ?? -1 }
if let window = number == nil
    ? owned.first(where: { layer($0) == 0 }) ?? owned.first(where: { layer($0) > 0 })
    : windows.first(where: { $0[kCGWindowNumber as String] as? Int == number })
{
    print(window[kCGWindowNumber as String] ?? "")
}
SWIFT
)"
[[ -n "$id" ]] || { echo "No ${owner:+$owner window}${window:+window $window} on screen. Start it first." >&2; exit 1; }
screencapture -x -o -l "$id" "$out"
echo "$out"
