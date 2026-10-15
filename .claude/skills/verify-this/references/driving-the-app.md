# Driving the app

## Launch and stop

- For app behavior, launch the bundle with `make run`, then run `scripts/screenshot.sh <out.png>`. After the check, stop the app with `pkill -f "^$PWD/build/Dirigible.app/Contents/MacOS/Dirigible"`.
- A check that writes preferences or a recent list, or answers a privacy prompt, runs on the verify copy. Run `make app`, then `scripts/verify-copy.sh start` with a Bash `timeout` of 600000, and `doctor`, then `ax` and `prompt Allow`, then `stop`. Press the prompt by name, never with `hid.swift`.
- `scripts/screenshots.sh` writes `docs/images` and the preferences of the real app, so it is not a check.
- For a light or a Spanish capture on a Mac in Dark Mode or in English, pass launch arguments (`open -a "$PWD/build/Dirigible.app" <package> --args -NSRequiresAquaSystemAppearance YES -AppleLanguages "(es)"`); do not write user defaults.
- The speakers are real. Before a play-only check, mute each track of a fixture copy with `dirigible track mute <package> <track>` (no HID, no undo entry), also after an import. A check that needs signal (export, loudness, meter) sets a low `dirigible track gain` and does not mute.

## Capture

- Capture one window, never the whole screen: a full-screen capture records private content.
- For a window of another process (the Gatekeeper dialog of `CoreServicesUIAgent`, Finder), use `scripts/screenshot.sh --owner <process>`. Read its text and button names with `osascript -e 'tell application "System Events" to get entire contents of window 1 of process "<process>"'`. Close it with the button that changes nothing, by its name. The agent leaves an Automation prompt for the terminal app: it is the user's. Name it in the report.
- A layer read or an offscreen render (`layer.render(in:)`, `cacheDisplay`) does not show what the window server composites, so only a screenshot of the built app after the real gesture proves a redraw or pixel claim.
- When the change keeps old pixels (a dirty rect, a redraw policy), also compare that screenshot with one after a forced full redraw of the same state.
- A renderer adds soft pixels (a drop shadow, antialiasing), so a pixel criterion states its alpha threshold.
- Never open Mission Control or leave the pointer over a test window while tests run: a capture during the transition is scaled or at other bounds.

## Drive and inspect

- To drive the app, run `scripts/hid.swift` (`drag <x> <y> <dx> <dy>` (an offset; `--dry-run` prints the end), a drag with `--no-up` and then `up` (at the pointer) or `up <x> <y>` in window points, `click <x> <y>` with `--right` or `--double`, Esc, Cmd-Z with `key 6 --command`, `--shift` and `--option`, a trackpad scroll with `scroll ... --phases`).
- Send keys and text only through `hid.swift` (`key`, `type <text>`), never `osascript` keystroke or key code. It refuses (exit 4) when the app is not frontmost and releases each modifier key it presses.
- Walk the accessibility tree of the built app with `scripts/ax.swift` down to each new control: a test that calls the accessibility methods of an element does not prove that VoiceOver reaches it.
- Drive a setup step with `press` of a menu path from `ax.swift dump` (`press "File > Open Recent > Clear Menu"`), not with a key, a title alone, or a toolbar point; `--role AXMenuBarItem` opens a menu.
- `swift scripts/ax.swift` compiles on each call: for a poll, compile it once with `swiftc -O scripts/ax.swift -o <scratchpad>/ax`. On the verify copy, set `DIRIGIBLE_BUNDLE_ID="$(<worktree>/scripts/verify-copy.sh id)"` (an absolute path) for `ax.swift` and `hid.swift`.
- A claim that something does not happen, from a poll, states the largest gap between samples around each event. An effect shorter than that gap is not tested.
- For a menu claim, run `scripts/ax.swift dump` per UI language (`-AppleLanguages "(es)"`) before and in each new state; compare the key and `Enabled=`. In a transient state, add `--witness <text>`, a text of only that state (progress `Value=0.`); exit 1 (no witness line) voids the dump: read again.
- A locked screen blocks menus, popovers, HID CGEvents, and the AX window tree; the window capture still works. When `screenshot.sh` warns about the lock, make every interaction check manual, with no HID or AX probe.

## A visual report of the user

- First find where it is. Diff a capture after the gesture with one after a full redraw, map the box of the changed pixels to view rects, and run the same probe on `main`.
- A "does not reproduce" result counts only when the probe uses the event path of the user (HID scroll events with phases and momentum, on an unlocked screen) and the content that the user named (a real waveform). Else the report stays `INCONCLUSIVE` with a manual check.
- Another defect that the probe finds gets its own claim; it does not close the report.

## System text in docs

A capture of a macOS dialog shows one locale only. Before a doc quotes a system dialog, button, or pane name, read the `.loctable` of the app that owns it (for example `/System/Library/CoreServices/CoreServicesUIAgent.app/Contents/Resources/Quarantine.loctable`) for each locale that the doc serves. For English, these are `en`, `en_GB`, and `en_AU`.
