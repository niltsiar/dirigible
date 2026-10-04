# Driving the app

## Launch and stop

- For app behavior, launch the bundle with `make run`, then run `scripts/screenshot.sh <out.png>`. After the check, stop the app with `pkill -f "^$PWD/build/Dirigible.app/Contents/MacOS/Dirigible"`.
- A check that writes preferences or a recent list, or answers a privacy prompt, runs on the verify copy. Run `make app`, then `scripts/verify-copy.sh start` and `doctor`, then `ax` and `prompt Allow`, then `stop`. Press the prompt by name, never with `hid.swift`. With no command, it prints the usage.
- `scripts/screenshots.sh` writes `docs/images` and the preferences of the real app, so it is not a check.
- For a light or a Spanish capture on a Mac in Dark Mode or in English, pass launch arguments (`open -a "$PWD/build/Dirigible.app" <package> --args -NSRequiresAquaSystemAppearance YES -AppleLanguages "(es)"`); do not write user defaults.
- The speakers are real: before a play of generated audio, set a low track gain with `dirigible track gain`.

## Capture

- Capture one window, never the whole screen: a full-screen capture records private content.
- For a window of another process (the Gatekeeper dialog of `CoreServicesUIAgent`, Finder), use `scripts/screenshot.sh --owner <process>`. Read its text and button names with `osascript -e 'tell application "System Events" to get entire contents of window 1 of process "<process>"'`. Close it with the button that changes nothing, by its name.
- A layer read or an offscreen render (`layer.render(in:)`, `cacheDisplay`) does not show what the window server composites, so it cannot prove a redraw or pixel claim. Prove such a claim with a screenshot of the built app after the real gesture.
- When the change keeps old pixels (a dirty rect, a redraw policy), also compare that screenshot with one after a forced full redraw of the same state.
- A renderer adds soft pixels (a drop shadow, antialiasing), so a pixel criterion states its alpha threshold.
- Never open Mission Control or leave the pointer over a test window while tests run: a capture during the transition is scaled or at other bounds.

## Drive and inspect

- To drive the app, run `scripts/hid.swift` (a drag, a drag with `--no-up` and then `up` outside the window, `click <x> <y>` with `--right` or `--double`, Esc, Cmd-Z with `key 6 --command`, `--shift` and `--option`, a trackpad scroll with `scroll ... --phases`).
- Send keys and text only through `hid.swift` (`key`, `type <text>`), never `osascript` keystroke or key code. It refuses (exit 4) when the app is not frontmost, and it releases each modifier key it presses.
- Walk the accessibility tree of the built app with `scripts/ax.swift` (`dump`, `find`, `press`, `step`) down to each new control: a test that calls the accessibility methods of an element does not prove that VoiceOver reaches it.
- Press a menu item by its menu path (`press "File > Open Recent > Clear Menu"`), never by its title alone.
- `swift scripts/ax.swift` compiles on each call (1 to 2 s): for a poll, compile it once with `swiftc -O scripts/ax.swift -o <scratchpad>/ax`. On the verify copy, set `DIRIGIBLE_BUNDLE_ID=com.delineas.dirigible.verify` for `ax.swift` and `hid.swift`.
- A claim that something does not happen, from a poll, states the largest gap between samples around each event. An effect shorter than that gap is not tested.
- For a claim about menu key equivalents, run `scripts/ax.swift dump` once for each UI language (`-AppleLanguages "(es)"`) and compare the key fields of each menu item line with the claim.
- A locked screen blocks menus, popovers, HID CGEvents, and the AX window tree; the window capture still works. When `screenshot.sh` warns about the lock, make every interaction check manual, with no HID or AX probe.

## A visual report of the user

- First find where it is. Diff a capture after the gesture with a capture after a full redraw, map the box of the changed pixels to view rects, and run the same probe on `main`.
- A "does not reproduce" result counts only when the probe uses the event path of the user (HID scroll events with phases and momentum, on an unlocked screen) and the content that the user named (for example a real waveform). Else the report stays `INCONCLUSIVE` with a manual check.
- Another defect that the probe finds gets its own claim; it does not close the report.

## System text in docs

A capture of a macOS dialog shows one locale only. Before a doc quotes a system dialog, button, or pane name, read the `.loctable` of the app that owns it (for example `/System/Library/CoreServices/CoreServicesUIAgent.app/Contents/Resources/Quarantine.loctable`) for each locale that the doc serves. For English, these are `en`, `en_GB`, and `en_AU`.
