# 0033. Loudness meter: a strip below the lanes, the values of the heard frame, a short-term value per armed track

- Status: accepted
- Date: 2026-10-03
- Accepted: 2026-10-03, after a UI panel of three, prototype P1, and plan gates 1 and 2 of run `2026-10-03-loudness-meter`.
- Amends: 0008 (the live meter), 0016 (the Player feeds the meter), 0023 (the strip is a row of the content, not a side pane), and 0002 (the new files).
- Amended: 2026-10-13, run `2026-10-13-preroll-varispeed` (9a). Only a 1x forward play at the speed 1x feeds the meter: a play at another vari-speed gives no value, as the other shuttle rates do (0052).

## Context

F40 asks for a loudness meter during play. Release 2 run 9 names "where the meter shows" a one-way decision. The constraints:

- `macos-ui-shell.md` section 5 puts no master meter in the toolbar and no critical information in a bottom bar. 0023 keeps one `NSHostingController`; the first side pane makes it an `NSSplitViewController`.
- 0023: no SwiftUI body reads `Studio.play`, and no SwiftUI view updates at the display rate.
- The Player schedules 0.1 s chunks up to 0.3 s ahead of the output (0016). A meter fed at render time leads the sound and counts audio that a stop drops.
- Each input device has its own clock, so a summed record mix has no common time.

The panel had three lenses: Apple pro apps (Logic Loudness Meter, the Final Cut Pro Audio Meters pane), podcast tools (Hindenburg, Auphonic, Descript), and performance first. At the 720 pt minimum width with the 340 pt default headers, a trailing pane of 132 pt leaves 248 pt of lanes.

## Decision

**Place.** An opaque strip of 28 pt below the lanes, the full width of the timeline pane, a row of `SessionView`. It holds no critical information: the export sets the loudness (0032), and the take state stays in the banners. So it is not the bottom bar of the research. View > Show/Hide Loudness Meter (Shift-Command-8, the key of the Final Cut Pro Audio Meters) toggles it. The app preference `view.loudness.shown` is a `Bool`, default true; it never changes its meaning or type.

**Values.** Loudness is the short-term value (3 s), the big number: clip gain can still fix it, and the export fixes the integrated value. A bar shows the momentary value (400 ms) from -40 to 0 LUFS, at most 360 pt wide. Average is the integrated value with its measured time. Peak is the highest true peak. Target is the line of the export target. The EBU names are in the tooltips. A nil value shows an en dash.

**Target line and colors.** The line is the stereo target of the export preset (`export.loudness`); Off gives -16. The meter measures the stereo mix, so a mono export at -19 equals this line. The bar is green up to the line and yellow over it (Logic). Peak turns red over -1 dBTP and keeps its number.

**Reset and shuttle.** A play from the frame where the last 1x forward play stopped adds to I and TP; a play from another frame starts them again. Reverse, half speed, 2x, and 4x do not feed the meter and keep I and TP. Each stop (the user, the session end, an output change, Record) holds I and TP and clears M and S.

**Data path.** `PlayerLoudness` keeps the scheduled chunks of a 1x forward play, keyed by output frames from the play start, and feeds each chunk when the output has played it. A stop drops the chunks that the output did not play. An underrun restart feeds the played chunks and starts the keys again at 0. `LiveLoudness` holds `LoudnessMeter` (momentary, short-term) and `TruePeakMeter`, and computes I once per new block. `Reading` carries the values; `Studio.loudness` stores them with `@ObservationIgnored`, and the rule "M and S only during a 1x forward play" acts at its writes. The display tick draws the strip: layers for the bar, set only on a pixel change, and drawn text at most 4 times a second. VoiceOver reads one level indicator, "Loudness meter", whose value changes at most once a second. A hidden strip does no work; the DSP goes on.

**Record and monitor.** No summed mix. Each track of a device writer has a `LoudnessMeter` at the rate and the layout of its route, fed on the writer drain, never in the IO proc. A record with another nominal rate makes the meter again. Each armed track header shows its short-term value in whole LU; a one-line row under 262 pt has no room for it. A lost device and a stopped retry clear it. While the armed tracks meter their inputs and nothing plays (a take, or a monitor with no play), the strip shows dashes, not the held values of a play, and its tooltip points to the headers. A monitor only meters (0015), so during a play the strip shows the play mix.

**Gate.** `Loudness.integrated` compares mean squares, not LUFS: with a log10 per block, one step at 2 h took 2.3 ms p95; it takes 0.66 ms (budget 1 ms).

**CLI.** No command: the strip is window chrome on the Player output. `dirigible loudness` measures files and packages.

## Consequences

- The lanes lose 28 pt of height while the strip shows; they keep their full width at every window width.
- I covers only the frames heard since the last reset. The export measures the whole mix (0032).
- A resume after an output change starts I again: the Player stores the stop frame of its own position, and the playhead keeps the last poll.
- With a device output latency, an underrun restart feeds its played chunks up to that latency early.
- A take that plays nothing shows dashes in the strip.

## Alternatives considered

- **A trailing pane of 132 pt (panel 1).** Rejected: 248 pt of lanes at the minimum width, and the first side pane makes the content an `NSSplitViewController`. It stays the reverse path if the strip reads badly.
- **Integrated as the big number.** Rejected: the export fixes it.
- **Rows per armed track in the strip, or a summed record mix.** Rejected: the header has a row per track, and the devices have different clocks.
- **A meter tap on the engine output.** Rejected: a real-time callback and a second path, with no time alignment gain.
- **An `@Observable` value that a SwiftUI view reads.** Rejected: a view update at the poll rate (0023).
