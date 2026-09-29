#!/bin/bash
# Make the screenshots of the README and the guide from the scripted "Demo Episode" session.
# Usage: scripts/screenshots.sh <folder>. Run `make app` first.
# The folder holds the session and its `say` audio. It must be a new folder under .scratchpads/ or
# /private/tmp: the session build runs through scripts/probe.sh, which refuses other folders.
# The script opens build/Dirigible.app in English and light mode, and writes
# docs/images/screenshot-edit.png and docs/images/screenshot-zoom.png.
# The terminal app needs the Screen Recording and Accessibility permissions, and the screen must be
# unlocked. Keep the pointer and other windows off the Dirigible window while the script runs.
# A running copy of the app ignores the launch arguments, and it can hold a real session. The
# script does not stop it: it refuses to start.
set -euo pipefail
folder="${1:?usage: screenshots.sh <folder>}"
refuse_running() {
    if pgrep -x Dirigible >/dev/null; then
        echo "screenshots.sh: Dirigible runs. Quit it, then run this script again." >&2
        exit 1
    fi
}
refuse_running
repo="$(cd "$(dirname "$0")/.." && pwd -P)"
app="$repo/build/Dirigible.app"
images="$repo/docs/images"
[[ -d "$app" ]] || { echo "screenshots.sh: no $app. Run make app first." >&2; exit 1; }

swift build --package-path "$repo" --product dirigible >/dev/null
cli="$(swift build --package-path "$repo" --show-bin-path)/dirigible"

# The session: two tracks with alternate lines of two `say` voices, the marker Intro, and the
# chapter Interview. The file name is the clip label in the window.
"$repo/scripts/probe.sh" "$folder" bash -c '
set -euo pipefail
cli="$1"
pkg="Demo Episode.dirigible"
"$cli" create "$pkg" --sample-rate 48000 >/dev/null
host="$("$cli" track add "$pkg" --name Host --layout mono)"
guest="$("$cli" track add "$pkg" --name Guest --layout mono)"
lines=(
    "Host|Samantha|Welcome to the Demo Episode. I am your host, and this is a show about how podcasts get made."
    "Guest|Daniel|Thanks for having me. It is good to be here."
    "Host|Samantha|Let us start with the basics. How do you record a conversation with two microphones?"
    "Guest|Daniel|I plug in both microphones, give each one its own track, and press record. Then I edit the tracks later."
    "Host|Samantha|And what do you do when somebody makes a mistake?"
    "Guest|Daniel|I select the mistake, cut it, and close the gap. Nobody hears it in the finished episode."
    "Host|Samantha|That is all for today. Thank you for listening to the Demo Episode."
)
at=48000
hosts=0
guests=0
for line in "${lines[@]}"; do
    IFS="|" read -r who voice text <<<"$line"
    if [[ "$who" == Host ]]; then hosts=$((hosts + 1)); n=$hosts; track="$host"; else guests=$((guests + 1)); n=$guests; track="$guest"; fi
    file="$who $n.wav"
    say -v "$voice" -o "$pkg/Clips/$file" --data-format=LEI16@48000 "$text"
    frames="$(afinfo "$pkg/Clips/$file" | awk "/audio packets/ {print \$3}")"
    id="$("$cli" file add "$pkg" --path "$file" --layout mono --length "$frames")"
    "$cli" clip place "$pkg" --track "$track" --file "$id" --start "$at" --length "$frames" >/dev/null
    [[ "$who $n" != "Host 1" ]] || "$cli" marker set "$pkg" --name Intro --at "$at" >/dev/null
    [[ "$who $n" != "Host 2" ]] || "$cli" marker set "$pkg" --name Interview --kind chapter --at "$at" >/dev/null
    at=$((at + frames + 24000))
done
' screenshots "$cli"
session="$(cd "$folder" && pwd -P)/Demo Episode.dirigible"

refuse_running
pid=""
trap '[[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true' EXIT
open -a "$app" "$session" --args -NSRequiresAquaSystemAppearance YES -AppleLanguages "(en)" \
    -ApplePersistenceIgnoreState YES
# No copy ran before the launch, so the one Dirigible process is the launched one.
pid="$(pgrep -x Dirigible)"
[[ "$pid" =~ ^[0-9]+$ ]] || { echo "screenshots.sh: not one Dirigible process: '$pid'." >&2; exit 1; }

# The size of a new session window: a content size of 1180 x 720 pt (placeAsSessionWindow) and
# the toolbar. Another size (a narrow screen, a saved window) gives other images.
# The window is the "Demo Episode" window of the launched process, not a window of another copy.
found=""
for _ in $(seq 60); do
    found="$(PID="$pid" swift - <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int(ProcessInfo.processInfo.environment["PID"] ?? "")
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
if let window = windows.first(where: {
    $0[kCGWindowOwnerPID as String] as? Int == pid && $0[kCGWindowName as String] as? String == "Demo Episode"
        && $0[kCGWindowLayer as String] as? Int == 0
}), let bounds = window[kCGWindowBounds as String] as? [String: Any] {
    print("\(window[kCGWindowNumber as String]!) \(bounds["Width"]!) x \(bounds["Height"]!)")
}
SWIFT
)"
    [[ -z "$found" ]] || break
    sleep 0.5
done
id="${found%% *}"
size="${found#* }"
want="1180 x 772"
[[ "$size" == "$want" ]] || { echo "screenshots.sh: the window is '$size' pt, not $want pt." >&2; exit 1; }
sleep 1

# Capture into the folder, and refuse a display scale other than 2x (Retina): it gives images of
# another size. Only a good capture replaces the image in docs/images.
width="${size%% *}"
shot() {
    "$repo/scripts/screenshot.sh" --window "$id" "$folder/$1" >/dev/null
    local px
    px="$(sips -g pixelWidth "$folder/$1" | awk '/pixelWidth/ {print $2}')"
    if [[ "$px" -ne $((2 * width)) ]]; then
        echo "screenshots.sh: $1 is $px px wide for a window of $width pt: the display scale is" \
            "$(awk "BEGIN {print $px / $width}")x, not 2x. Use a Retina display." >&2
        exit 1
    fi
    mv "$folder/$1" "$images/$1"
}

key() { swift "$repo/scripts/hid.swift" key "$@"; }
# Home, then Taller Tracks two times: the two tracks fill more of the window.
key 115
key 125 --command
key 125 --command
sleep 1
shot screenshot-edit.png
# Page Down, I, Page Down, O: select from the marker Intro to the chapter Interview. H: zoom to it.
for code in 121 34 121 31 4; do key "$code"; done
sleep 1
shot screenshot-zoom.png

for png in "$images/screenshot-edit.png" "$images/screenshot-zoom.png"; do
    [[ "$(stat -f %z "$png")" -le 1000000 ]] || sips --resampleWidth 1600 "$png" >/dev/null
    echo "$png"
done
