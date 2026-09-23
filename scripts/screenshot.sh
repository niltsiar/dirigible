#!/bin/bash
# Save a PNG of the Dirigible window only (not the whole screen), for UI evidence.
# Usage: scripts/screenshot.sh <out.png>. Start the app first with `make run`.
# The terminal app needs the Screen Recording permission.
set -euo pipefail
out="${1:?usage: screenshot.sh <out.png>}"

id="$(swift - <<'SWIFT'
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
if let window = windows.first(where: { $0[kCGWindowOwnerName as String] as? String == "Dirigible" }) {
    print(window[kCGWindowNumber as String] ?? "")
}
SWIFT
)"
[[ -n "$id" ]] || { echo "No Dirigible window on screen. Run make run first." >&2; exit 1; }
screencapture -x -o -l "$id" "$out"
echo "$out"
