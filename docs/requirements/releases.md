# Releases

Date: 2026-09-24

This file orders the requirements of `brief.md` into releases. The feature IDs (F01 to F67), the ranking, and the Hindenburg PRO, GarageBand, and Logic Pro comparison are in `docs/research/podcast-features.md`. The decisions are in `docs/decisions/`. Each release ends with a working app on `main`.

## Release 1: record, edit, export

Goal: record two or more devices, make a rough edit, and export one file. This is the thin path that R1 needs first.

| Requirement | What Release 1 gives |
|---|---|
| R1 | The first record, edit, and export path of the recorder and editor. |
| R2 | Runs on macOS 14 and later. |
| R3 | Several devices record at the same time, one track per route (F01, F02, F03). |
| R4 | One IOProc per device, no aggregate device (0004). |
| R5 | The session is a package with `session.xml` (F60, 0003). |
| R6 | 24-bit WAV clips in `Clips/`. Captured audio survives a crash (F04, 0004). |
| R7 | Part: transport, select, cut, copy, paste, delete, split, move, trim, undo, zoom, previous and next clip, JKL, markers (F10 to F15, F17, F19). |
| R11 | Part: export to WAV, AAC, and FLAC (F50, F51, F52, 0007). |
| R13 | Part: every UI string in English and Spanish, following the macOS language (F65, 0010). |
| R15 | Mono or stereo per track, and a mono or stereo mix export (F41). |

Rules for Release 1:

- Every command has a menu item with a key equivalent (F16). Use the Hindenburg default keys where macOS does not already own the key. Hindenburg records with Control-Space, which macOS uses to change the input source, so the Release 1 run picks another Record key and records why.
- Delete leaves a gap. Ripple edit is Release 2.
- JKL: the Release 1 run decides between reverse play and J as skip-back, because `AVAudioPlayerNode` cannot play backward.

Run order. Each run lands through its own pull request.

1. **Session core.** `DirigibleCore`: session, tracks, clips, routes, markers, snapshot undo, XML version 1 in a package, the import-rule test.
2. **Capture.** Two runs in `DirigibleAudio`. capture-finalize: segments, finalize, recovery, the `Studio` core, and the package lock. capture-live: IOProcs, rings, device events, and the hardware checks from 0004.
3. **Record UI.** The window, tracks with routes and meters during a take, record and stop, the microphone permission check, the first `.lproj` strings.
   - **Input monitor** (run 3b). The meter of an armed track before a take, and a device-list listener. The record UI run split it off (0014).
4. **Timeline and playback.** Waveforms, `Player`, selection, edit commands with keys, markers. The timeline-playback run splits it into three runs:
   - **4a Player and transport.** The `Player` (AVAudioEngine), the playhead, record from the playhead, the transport bar, JKL, previous and next clip, the missing-media state, and `dirigible render` (F10, F15 part, F17).
   - **4b Timeline view.** The track lanes with clips and waveforms (peak files), the playhead line, the markers ruler, zoom, and the selection (F15 part).
   - **4c Edit commands.** Cut, copy, paste, delete with a gap, split, nudge, markers and chapters (add, rename, delete, next and previous), remove track, and "Show Clips in Finder", each with its menu item, its key, and a `dirigible` command for each package edit (F11 to F14, F16, F19). The edit-commands run split the mouse edits off to run 4d.
   - **4d Direct edits on the lanes.** A click that selects a clip, a drag that moves it, an edge drag that trims it, Shift-drag, the drag of a marker and of the in and out triangles, and the ruler menu, with the hit-test zones and a frame budget per mouse event at 2 h (F13). It uses the Core edits of 4c and adds no `dirigible` command.
5. **Export.** `exportMix` to WAV, AAC, and FLAC, mono or stereo.

## Release 2: a podcast-ready episode

Goal: record a remote guest, level the clips, and publish at the podcast loudness.

| Requirement | What Release 2 gives |
|---|---|
| R1 | Part: the UI shell with a customizable toolbar (F93) and a resizable track header panel (F85 part), timeline navigation with an overview strip and the zoom toggle and history (F83), the app icon, the README, and the user guide. |
| R7 | Part: ripple edit and ripple trim, clip gain, fades, crossfades, a clip inspector, file import (F20, F68, F31, F32, F33, F84, F61). |
| R9 | Auto-level of each clip to a loudness target (F30, 0008). |
| R10 | Part: loudness meter and normalization at export (F40, F54, 0008), autosave and backups (F62), and a `chapters.json` export from the chapter markers (F56 part). |
| R11 | MP3 through LAME (F53, 0007). |
| R12 | Audio from other apps through process taps, and a call preset (F05, F06, 0006). |
| R13 | The language preference in Settings (F66, 0010). |
| R14 | Part: a "Use headphones" warning when a session has an app source and the output is the built-in speakers (F43, 0004). The feature catalog put F43 in Release 1, but its trigger needs an app source. |

Rules for Release 2:

- Each run lands through its own pull request.
- From run 4 on, each user-facing run updates `docs/guide.md`, and the screenshots when the window changes. The check-docs rule of run 4 refuses a menu name that is not in the guide.
- Each toolbar item is also a menu item with a key (F16). Monitor Inputs has a menu item with no key today; run 1a adds its key.
- Each new public library feature that operates on a session package or an audio file (an edit, an import, a render, or an export) gets a `dirigible` command and a `DirigibleCLITests` test in the same run (0011, AGENTS.md).
- No bench case gets worse than `main` by more than 10 % or 1 ms (0022). A run that adds a drawn element or a gesture adds a bench case for it.
- A run that adds user data to `session.xml` raises the session version (0003). The writer writes the lowest version that holds the data of the session: a session with no app route and no fades stays version 1. Each version bump has a test that a session without the new data writes the old version. Rollback limit: an older app refuses a session that uses newer data ("unsupported version") and does not change the file. A session that uses no new data opens in the older app. The version policy is 0024.
- Delete and Cut keep the Release 1 gap until the user decides otherwise (see run 12).

Run order. The research for this order is in `docs/research/final-cut-pro.md`, `logic-garageband-update.md`, `macos-ui-shell.md`, `app-icon.md`, `readme-and-guide.md`, and `podcasting-2.md`. The new feature IDs (F68 to F93) are in `podcast-features.md`.

1. **UI shell.** Decision 0023. Research: `macos-ui-shell.md`. The ui-shell run splits it into two runs, each with its own pull request:
   - **1a Window chrome.** A unified AppKit `NSToolbar` with user customization (F93) and `ToolbarCommands` (Show/Hide Toolbar, Option-Command-T; Customize Toolbar…). The default set, leading to trailing: Add Track, space, Monitor Inputs, Stop, Play, Record, the time display, space, Split, Delete, flexible space, Zoom Out, Zoom In, Zoom to Session, Export. Cut, Copy, Paste, Go to Start, and Go to End are in the customization palette only. Each item is a menu item with a key (F16); Monitor Inputs gets Shift-Command-M, and Stop (Command-period) moves to the Transport menu. A new window opens at min(1180 pt, the screen width) x 720 pt and cascades; the minimum width is 720 pt, so the transport and the time display stay out of the overflow menu. The time display does not redraw at the display rate: it shows tenths of a second during play (at most 10 updates a second) and milliseconds when stopped, and no SwiftUI body reads the playhead. The window subtitle shows the rate, the track count, and the record time left. The transport bar row goes; its warnings become banners, and the record-over warning is an overlay over the lanes. The subtitle can be cut off, so a low-record-time banner shows before a take under 60 min and during a take under 10 min, and hides 60 s over the limit, ahead of the 0004 disk stop. A window test at the minimum window width with a long package name shows the banner. An empty session shows an Add Track button. Promote the HID driver to `scripts/`. One-way decisions: AppKit `NSToolbar` against the SwiftUI toolbar bridge; the content controller that later holds an inspector; the toolbar and item identifiers. Manual check: the WindowServer CPU during play on macOS 14 and 26. Bench case: the play tick.
   - **1b Track header panel.** A drag handle sets the width of the track header panel (F85 part), 180 to 480 pt, default 340 pt. An opaque header background keeps the lanes out from under it, and the lanes get a dark palette in Dark Mode. One-way decision: the headers stay in the vertical ruler, not a split pane. Bench case: a header-width drag.
2. **Timeline navigation.** An overview strip above the ruler (click to center, drag the view frame, drag an edge to zoom, double-click to fit), smart zoom, a page scroll with Option-Page Up and Option-Page Down (Page Up and Page Down stay Previous and Next Marker, 0018), the zoom toggle and history (F83, Hindenburg "H and back"), track height keys (Command-Down and Command-Up Arrow), Command-= for Zoom In, and autoscroll during a drag. The scroll bars follow the macOS "Show scroll bars" setting. Decision 0025. One-way decisions: how the overview strip draws and where its geometry lives (`DirigibleTimeline`). Bench case: the overview render.
3. **App icon.** An Icon Composer `.icon` source in `Support/`, compiled by `actool` into `Assets.car` and `AppIcon.icns` at deployment target 14.0, `CFBundleIconName`, a `make icon-preview` target, and an `AppBundleTests` test. The user approves the preview before the merge. One-way decisions: the `.icon` format and the concept and colors (the brand). Research: `app-icon.md`.
   Then the DMG run: `make dmg` builds a UDZO DMG with the app, an Applications link, and the volume icon, and `make test-dmg` checks it. Ad-hoc signature, no notarization (C1).
4. **README and guide.** A new `README.md` (a light and dark banner, two screenshots, install steps for an app that is not notarized), `docs/guide.md` (a first episode, how-to sections, a key table with Spanish names), scripted screenshots, and a check-docs rule that each `menu.*` name is in the guide. One-way decisions: none. Research: `readme-and-guide.md`. Then the Help guide run: a Help menu item, **Dirigible Guide**, that opens an HTML copy of `docs/guide.md` in the app bundle (the repository is private).
5. **Test pool health.** Async test hooks in place of the semaphore gates on pool threads, the CLI test helper made async with a bound on its running children, and the flake monitor in `scripts/`. Test-only, apart from the async types of four test seams in Sources/; the timed tests then have limits below one suite run. One-way decisions: none.
6. **App sources (R12, R14 part).** Record another app through a process tap (F05), a call preset that makes a microphone track and an app track (F06), and the "Use headphones" warning (F43). The track header picks a device or an app. `dirigible` sets an app route. Hardware checks of 0006 as manual checks. A probe measures the peak of a tapped call app; the run decides what the finalize does with float samples over full scale. This is the riskiest Release 2 run: a permission, macOS 14.2, and call apps with helper processes. One-way decisions: the app route in `session.xml` (session version 2, written only when a session has an app route), and the owner of the tap and its aggregate device and the thread of the rebuild (default: the Owners rule of 0013; amends 0006).
7. **Player off the pool.** The refill of the `Player` runs on its own serial executor, so a busy concurrency pool cannot make an audible gap. Probe `assumeIsolated` on a dispatch-queue executor on macOS 14 first. One-way decision: the threading model of the `Player` (amends 0016).
8. **Loudness and auto-level (R9).** The BS.1770 meter in `DirigibleAudio` (0008) with the EBU Tech 3341 tests, auto-level of each clip at stop and on a selection (Cmd-L, F30), per clip or equally per track, and `dirigible loudness` and `dirigible level`. One-way decisions: where the analysis runs relative to the finalize, and the undo of an automatic gain.
9. **Export normalization and loudness meter (R10 part).** Two runs: **9a** (done, 0032) is the export normalization, the limiter, the dither, the report, and `--loudness`; **9b** (done, 0033) is the loudness meter (F40): a strip below the lanes, and a short-term value in each armed track header. Measure the mix, one static gain, the true-peak meter of 0008 with Tech 3341 cases 15 to 19, a true-peak limiter at -1 dBTP, the presets of 0008, the result in the export report (F54), and a loudness meter (F40). `dirigible export --loudness <preset>` with a `DirigibleCLITests` test. One-way decisions: the limiter design (look-ahead and oversampling); where the meter shows; and TPDF dither for 16-bit files, which amends 0019 P3 (seeded or random, FLAC too, and what the tests assert, because FLAC equals WAV bit for bit today).
10. **MP3 export (R11).** LAME as the static C target `CLame` (0007), the LGPL files in the bundle, the warnings rule for vendored C code, and `dirigible export` to MP3. One-way decision: the vendored C target and its warnings rule (a decision record next to 0007).
11. **Clip gain, fades, and crossfades (R7 part).** A gain line on each clip (F31), fade handles on the clip corners and Cmd-F on a range (F32), equal-power crossfades that use the media handles (F33), and a clip inspector with numeric gain and fades (F84). The Player and the export render them. One-way decisions: the fade and crossfade fields (session version 3), the crossfade model with no overlap of clips, the inspector pane, and the new mouse zones (the gain line and the fade handles) in the gesture model, which amends 0020. The run can split at its plan.
   - **11a Clip fades.** Fade-in and fade-out on each clip (session version 3), the render, Edit > Fade (Command-F), the fade in the lanes, and `dirigible clip fade` (0035).
   - **11b-1 Gain line and fade handles.** The mouse gain line and fade handles of each clip, the drag readout, and the double-click resets (amends 0020, 0035).
   - **11b-2 Inspector.** The inspector pane of 0023 with numeric gain and fades, "Mixed" for many clips, and a batch `setGains` with its `dirigible` command.
   - **11c-1 Crossfade model.** Equal-power crossfades at a butt join from the media handles: the model, session version 4, the render, and `dirigible clip crossfade` (0036).
   - **11c-2 Crossfade editing.** Command-F across a join, the crossfade handle drag, the X draw in the lanes, and the benches (0036).
12. **Ripple edit (R7 part).** Ripple Delete, Ripple Cut, and Ripple Insert, a ripple trim with a modifier (F68), and a context menu on the lanes. No session format change. One-way decisions: the ripple trim modifier in the gesture model, which amends 0020; the scope (default: all tracks, whatever the track selection; only an explicit act such as a modifier limits it to the selected tracks), the marker rule, and the keys (the user decides if Cut closes the gap, as in Hindenburg). Input to the marker rule: with the music track out of scope, the speech moves and the chapters stay, so they no longer match. The session has no speech role (F72 is Release 3), so the rule uses only tracks and markers (for example: markers follow the ripple in every scope, or the user chooses at the edit). Tests: a clip click, then Ripple Delete, keeps every track in sync; a ripple with the music track out of scope gives literal marker frames in the session (through `Session` and `dirigible`). Research: `final-cut-pro.md` section 10.
13. **File import (R7 part).** Import WAV, AIFF, FLAC, MP3, and M4A into a track (F61), by menu and by a drop on a lane. The file is converted to a WAV at the session rate in `Clips/` and auto-leveled (run 8). Paste across packages. `dirigible import`. One-way decisions: the conversion (a copy in the package, the rate converter); for paste across packages, where the clipboard lives (app memory, or a named `NSPasteboard`, see 0018 probe B1), the file-ID map and the file copy in one library function, and the undo of a copied file (the copy stays in the pool after undo, or redo copies it again). The plan of the run can move paste across packages to its own run.
14. **Autosave and backups (R10 part).** Backups of `session.xml` and a revert that is one undo entry and keeps `<recording>` (F62, 0014). One-way decision: the backup place and format, and whether macOS Versions takes part.
15. **Language preference (R13).** A Settings window with English, Spanish, or the macOS language (F66, 0010). One-way decisions: none (0010).
16. **Chapters export (R10 part).** File > Export Chapters writes `chapters.json` 1.2.0 from the chapter markers, and `dirigible chapters export`. The chapters use the same range as the audio export (for example a check box in the export panel, or the Marks when set). Test: Export Selection from frame N gives a chapter at N + k with `startTime` k / rate. Import and chapters inside the MP3 or M4A file stay in Release 3 with F55 and F56. One-way decisions: none. Test: the chapters export of a session after a ripple with the music track out of scope gives literal times. Research: `podcasting-2.md`.

## Release 3: Hindenburg-style production

Goal: match the Hindenburg tools that save time on each episode.

| Requirement | What Release 3 gives |
|---|---|
| R5 | Remove unused clip files (F87). |
| R7 | Part: punch-in, pre-roll, vari-speed, replace and room-tone fill, clipboard, split stereo to mono (F07, F08, F18, F21, F22, F25). Roll and slip, a follow track, sync by waveform, a gain envelope, a session index, waveform zoom, drag modes, close gaps, snap to clip edges (F69, F70, F74, F75, F76, F78, F80, F81, F82). |
| R8 | Noise reduction with one control (F35, 0009). Hum removal, and a render of a range through an effect (F77, F89). |
| R10 | Part: favorites, silence removal, ducking, EQ and compressor, episode metadata and artwork, chapters inside the audio file (F56 part), export presets, templates, track roles (F23, F26, F34, F36, F55, F56, F57, F63, F72). |
| R11 | Stem export: one file per track or per role (F73). |
| R14 | Offline removal of the remote guest from the local microphone track (F42). |

Podcast metadata inside the audio file (title, artwork, chapters as ID3 or MP4 chapters) is Release 3: the user did not ask for it, and the ranking puts it after leveling and MP3. The `chapters.json` export of Release 2 run 16 does not wait for it: it is a separate file next to the export, not metadata inside the audio file, and it uses only the chapter markers of Release 1.

## Later

Each item needs its own design run.

- R5: session interchange, first the AES31-3 ADL export (F67, 0003).
- R7 and R10: transcripts and text editing (F27), Voice Profiler (F37), Magic Levels (F38), time stretch (F28), track groups (F24), Audio Unit plug-ins (F39), upload to hosts (F58), user-defined shortcuts (F64), retroactive capture (F09), connected clips (F71), the height of one track (F85 part), help tags with keys (F86), session alternatives (F88), lock a track (F90), take folders and comps (F91), a large time display (F92).
