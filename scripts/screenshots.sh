#!/bin/bash
# Make the screenshots of the README and the guide from the scripted "Demo Episode" session.
# Usage: scripts/screenshots.sh <folder>. Run `make app` first.
# The folder holds the session and its `say` audio. It must be a new folder under .scratchpads/ or
# /private/tmp: the session build runs through scripts/probe.sh, which refuses other folders.
# The script opens build/Dirigible.app in English and light mode, and writes
# docs/images/screenshot-edit.png and docs/images/screenshot-zoom.png.
# The terminal app needs the Screen Recording and Accessibility permissions, and the screen must be
# unlocked. Keep the pointer and other windows off the Dirigible window while the script runs.
set -euo pipefail
folder="${1:?usage: screenshots.sh <folder>}"
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
[[ ! -e "$pkg" ]] || { echo "screenshots.sh: $pkg exists. Give a new folder." >&2; exit 1; }
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

# A running copy of the app ignores the launch arguments, so quit it first.
quit() { pkill -f "$app/Contents/MacOS/Dirigible" || true; }
quit
while pgrep -f "$app/Contents/MacOS/Dirigible" >/dev/null; do sleep 0.2; done
trap quit EXIT
open -a "$app" "$session" --args -NSRequiresAquaSystemAppearance YES -AppleLanguages "(en)" \
    -ApplePersistenceIgnoreState YES

# The size of a new session window: a content size of 1180 x 720 pt (placeAsSessionWindow) and
# the toolbar. Another size (a narrow screen, a saved window) gives other images.
size=""
for _ in $(seq 60); do
    size="$(swift - <<'SWIFT'
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
if let window = windows.first(where: {
    $0[kCGWindowOwnerName as String] as? String == "Dirigible" && $0[kCGWindowLayer as String] as? Int == 0
}), let bounds = window[kCGWindowBounds as String] as? [String: Any] {
    print("\(bounds["Width"]!) x \(bounds["Height"]!)")
}
SWIFT
)"
    [[ -z "$size" ]] || break
    sleep 0.5
done
want="1180 x 772"
[[ "$size" == "$want" ]] || { echo "screenshots.sh: the window is '$size' pt, not $want pt." >&2; exit 1; }
sleep 1

key() { swift "$repo/scripts/hid.swift" key "$@"; }
mkdir -p "$images"
# Home, then Taller Tracks two times: the two tracks fill more of the window.
key 115
key 125 --command
key 125 --command
sleep 1
"$repo/scripts/screenshot.sh" "$images/screenshot-edit.png" >/dev/null
# Page Down, I, Page Down, O: select from the marker Intro to the chapter Interview. H: zoom to it.
for code in 121 34 121 31 4; do key "$code"; done
sleep 1
"$repo/scripts/screenshot.sh" "$images/screenshot-zoom.png" >/dev/null

for png in "$images/screenshot-edit.png" "$images/screenshot-zoom.png"; do
    [[ "$(stat -f %z "$png")" -le 1000000 ]] || sips --resampleWidth 1600 "$png" >/dev/null
    echo "$png"
done
