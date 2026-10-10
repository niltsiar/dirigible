#!/bin/bash
# Make the screenshots of the README and the guide from the scripted "Demo Episode" session.
# Usage: scripts/screenshots.sh <folder>. The script builds the app and the CLI of this tree first.
# The folder holds the session and its `say` audio. It must be a new folder under .scratchpads/ or
# /private/tmp: the session build runs through scripts/probe.sh, which refuses other folders.
# The script opens build/Dirigible.app in English (US number format) and light mode, and writes
# docs/images/screenshot-edit.png, screenshot-zoom.png, screenshot-inspector.png,
# screenshot-episode.png, and screenshot-crossfade.png. The app also
# writes its preferences (the recent list, the inspector) for the real bundle ID, so do not run
# this script as a check.
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

"$repo/scripts/bundle.sh" >/dev/null
swift build --package-path "$repo" --product dirigible >/dev/null
cli="$(swift build --package-path "$repo" --show-bin-path)/dirigible"

# The session: two tracks with alternate lines of two `say` voices, the marker Intro, the chapter
# Interview, two fades, a gain of -6 dB, and a crossfade of 200 ms where a cut of 0.25 s at 2 s
# into Host 1 closes. The file name is the clip label in the window.
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
    clip="$("$cli" clip place "$pkg" --track "$track" --file "$id" --start "$at" --length "$frames")"
    if [[ "$who $n" == "Host 1" ]]; then
        "$cli" clip clear "$pkg" --track "$track" --from $((at + 96000)) --to $((at + 108000))
        "$cli" clip move "$pkg" "$clip@$((at + 108000))" --track "$track" --start $((at + 96000))
        "$cli" clip crossfade "$pkg" --clip "$clip" --length 9600 >/dev/null
    fi
    [[ "$who $n" != "Host 1" ]] || "$cli" clip fade "$pkg" --clip "$clip" --in 24000 >/dev/null
    [[ "$who $n" != "Host 4" ]] || "$cli" clip fade "$pkg" --clip "$clip" --out 24000 >/dev/null
    [[ "$who $n" != "Guest 2" ]] || "$cli" clip gain "$pkg" "$clip" --db -6 >/dev/null
    [[ "$who $n" != "Host 1" ]] || "$cli" marker set "$pkg" --name Intro --at "$at" >/dev/null
    [[ "$who $n" != "Host 2" ]] || "$cli" marker set "$pkg" --name Interview --kind chapter --at "$at" >/dev/null
    at=$((at + frames + 24000))
done
' screenshots "$cli"
session="$(cd "$folder" && pwd -P)/Demo Episode.dirigible"
# The episode details, with the app icon as the artwork.
sips -s format png -Z 1024 "$app/Contents/Resources/AppIcon.icns" --out "$folder/cover.png" >/dev/null
"$cli" episode set "$session" --title "Demo Episode 1: How podcasts get made" --show "The Demo Show" \
    --author "Samantha and Daniel" --season 1 --episode 1 --date 2026-10-10 --language eng \
    --copyright "© 2026 The Demo Show" --summary "Two microphones, one take, and a clean edit." \
    --notes "In this episode, Daniel tells how he records and edits a conversation." --artwork "$folder/cover.png"

refuse_running
pid=""
trap '[[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true' EXIT
# The View preferences in the arguments win over the stored ones, so the images do not depend on
# them. The inspector toggle below starts from hidden.
open -a "$app" "$session" --args -NSRequiresAquaSystemAppearance YES -AppleLanguages "(en)" \
    -AppleLocale en_US -ApplePersistenceIgnoreState YES -view.inspector.shown NO -view.loudness.shown YES
# No copy ran before the launch, so the one Dirigible process is the launched one.
# open can return before the process shows, so wait up to 10 s for it.
for _ in $(seq 1 20); do
    pid="$(pgrep -x Dirigible || true)"
    [[ -z "$pid" ]] || break
    sleep 0.5
done
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
# Option-Command-I: show the inspector of the selection.
key 34 --command --option
sleep 1
shot screenshot-inspector.png
# Shift-Command-I: File > Episode Info. Esc gives the focus back to the lanes. Then hide the
# inspector again, because the app stores the choice for new windows.
key 34 --command --shift
sleep 1
shot screenshot-episode.png
key 53
key 34 --command --option
# Esc clears the selection. Home, then Shift-Right two times: the playhead goes to the join in
# Host 1. View > Zoom In six times (the menu, so the key layout does not matter): zoom in at the
# playhead, so the X of the crossfade is about 200 pt.
key 53
key 115
key 124 --shift
key 124 --shift
for _ in 1 2 3 4 5 6; do swift "$repo/scripts/ax.swift" press "View > Zoom In" >/dev/null; done
sleep 1
shot screenshot-crossfade.png

for png in "$images"/screenshot-{edit,zoom,inspector,episode,crossfade}.png; do
    [[ "$(stat -f %z "$png")" -le 1000000 ]] || sips --resampleWidth 1600 "$png" >/dev/null
    echo "$png"
done
