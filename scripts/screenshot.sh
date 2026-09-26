#!/bin/bash
# Save a PNG of the Dirigible window only (not the whole screen), for UI evidence.
# Usage: scripts/screenshot.sh <out.png>. Start the app first with `make run`.
# The terminal app needs the Screen Recording permission.
set -euo pipefail
out="${1:?usage: screenshot.sh <out.png>}"

id="$(swift - <<'SWIFT'
import CoreGraphics
import Foundation
// On a locked screen a window capture still works, but a menu or a popover does not come on
// screen. Say so, so that the caller makes those UI checks manual checks.
let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
if session["CGSSessionScreenIsLocked"] as? Bool == true {
    FileHandle.standardError.write(Data("The screen is locked: menus, popovers, HID events, and the AX window tree do not work. Make every interaction check a manual check.\n".utf8))
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
if let window = windows.first(where: { $0[kCGWindowOwnerName as String] as? String == "Dirigible" }) {
    print(window[kCGWindowNumber as String] ?? "")
}
SWIFT
)"
[[ -n "$id" ]] || { echo "No Dirigible window on screen. Run make run first." >&2; exit 1; }
screencapture -x -o -l "$id" "$out"
echo "$out"
