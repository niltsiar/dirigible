# Releases

Created: 2026-09-24

This file orders the requirements of `brief.md` into releases. The feature IDs, their source, and their state are in [features.md](features.md). The ranking and the app comparison stay in `docs/research/podcast-features.md`. The workflow of a release is in `docs/workflow/release-cycle.md`. The decisions are in `docs/decisions/`. Each release ends with a working app on `main`.

## Release 1: record, edit, export

Status: closed

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

- Every command has a menu item with a key equivalent (F16). Use the Hindenburg default keys where macOS does not already own the key. Hindenburg records with Control-Space, which macOS uses to change the input source, so Record is Command-R (0014), and Record with Pre-roll is P (0070).
- Delete leaves a gap. Ripple edit is Release 2.
- JKL: J is Play Backward (0016).

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

Status: closed

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
| R16 | Part: `dirigible mcp`, an MCP server on package files ([0041](../decisions/0041-mcp-server.md)). |

Rules for Release 2:

- Each run lands through its own pull request.
- From run 4 on, each user-facing run updates `docs/guide.md`, and the screenshots when the window changes. The check-docs rule of run 4 refuses a menu name that is not in the guide.
- Each toolbar item is also a menu item with a key (F16).
- Each new public library feature that operates on a session package or an audio file (an edit, an import, a render, or an export) gets a `dirigible` command and a `DirigibleCLITests` test in the same run (0011, CLI parity). An edit command also gets an MCP tool (0041).
- No bench case gets worse than `main` by more than 10 % or 1 ms (0022). A run that adds a drawn element or a gesture adds a bench case for it.
- A run that adds user data to `session.xml` raises the session version (0003). The writer writes the lowest version that holds the data of the session: a session with no app route and no fades stays version 1. Each version bump has a test that a session without the new data writes the old version. Rollback limit: an older app refuses a session that uses newer data ("unsupported version") and does not change the file. A session that uses no new data opens in the older app. The version policy is 0024.
- Delete keeps the gap. Cut of a range closes the gap on all tracks, as Hindenburg PRO Cut (run 12 default, decided; decision 0037). Cut of a clip set leaves the gaps (decision 0038).

Run order. The research for this order is in `docs/research/final-cut-pro.md`, `logic-garageband-update.md`, `macos-ui-shell.md`, `app-icon.md`, `readme-and-guide.md`, and `podcasting-2.md`. The new feature IDs (F68 to F93) are in `podcast-features.md`.

1. **UI shell.** Decision 0023. Research: `macos-ui-shell.md`. The ui-shell run splits it into two runs, each with its own pull request:
   - **1a Window chrome.** A unified AppKit `NSToolbar` with user customization (F93) and the Show/Hide Toolbar and Customize Toolbar commands. Each toolbar item is a menu item with a key (F16). The menus and their keys are in [the guide](../guide.md). Stop (Command-period) is in the Transport menu. The window subtitle shows the rate and the track count, and the record time left when it is short (F152). The transport bar row is gone: its warnings are banners, and the record-over warning is an overlay over the lanes. An empty session shows an Add Track button (0023).
   - **1b Track header panel.** A drag handle sets the width of the track header panel (F85 part), 180 to 480 pt, default 340 pt. An opaque header background keeps the lanes out from under it, and the lanes have a dark palette in Dark Mode (0023).
2. **Timeline navigation.** An overview strip above the ruler (click to center, drag the view frame, drag an edge to zoom, double-click to fit), smart zoom, a page scroll with Option-Page Up and Option-Page Down (Page Up and Page Down stay Previous and Next Marker, 0018), the zoom toggle and history (F83, Hindenburg "H and back"), track height keys (Command-Down and Command-Up Arrow), Command-= for Zoom In, and autoscroll during a drag. The scroll bars follow the macOS "Show scroll bars" setting. Decision 0025.
3. **App icon.** An Icon Composer `.icon` source in `Support/`, compiled by `actool` into `Assets.car` and `AppIcon.icns` at deployment target 14.0, `CFBundleIconName`, a `make icon-preview` target, and an `AppBundleTests` test. Decision 0026. Research: `app-icon.md`.
   Then the DMG run: `make dmg` builds a UDZO DMG with the app, an Applications link, and the volume icon, and `make test-dmg` checks it. Ad-hoc signature, no notarization (C1).
4. **README and guide.** A new `README.md` (a light and dark banner, two screenshots, install steps for an app that is not notarized), `docs/guide.md` (a first episode, how-to sections, a key table with Spanish names), scripted screenshots, and a check-docs rule that each `menu.*` name is in the guide. Research: `readme-and-guide.md`. Then the Help guide run: a Help menu item, **Dirigible Guide**, that opens an HTML copy of `docs/guide.md` in the app bundle.
5. **Test pool health.** Async test hooks in place of the semaphore gates on pool threads, the CLI test helper made async with a bound on its running children, and the flake monitor in `scripts/`. Test-only, apart from the async types of four test seams in Sources/.
6. **App sources (R12, R14 part).** Record another app through a process tap (F05), a call preset that makes a microphone track and an app track (F06), and the "Use headphones" warning (F43). The track header picks a device or an app. `dirigible` sets an app route. The app route is in `session.xml` version 2, written only when a session has an app route (0029). The tap and its aggregate device have one owner (0030, 0006).
7. **Player off the pool.** The refill of the `Player` runs on its own serial executor, so a busy concurrency pool cannot make an audible gap (0016).
8. **Loudness and auto-level (R9).** The BS.1770 meter in `DirigibleAudio` (0008) with the EBU Tech 3341 tests, auto-level of each clip at stop and on a selection (Cmd-L, F30), per clip or equally per track, and `dirigible loudness` and `dirigible level` (0008, 0031).
9. **Export normalization and loudness meter (R10 part).** Two runs: **9a** (0032) is the export normalization, the limiter, the dither, the report, and `--loudness`; **9b** (0033) is the loudness meter (F40): a strip below the lanes, and a short-term value in each armed track header. The export measures the mix and applies one static gain, with the true-peak meter of 0008 (EBU Tech 3341 cases 15 to 19), a true-peak limiter at -1 dBTP, the presets of 0008, and the result in the export report (F54). `dirigible export --loudness <preset>` has a `DirigibleCLITests` test. The 16-bit dither is seeded TPDF (0032).
10. **MP3 export (R11).** LAME as the static C target `CLame` (0007), the LGPL files in the bundle, the warnings rule for vendored C code, and `dirigible export` to MP3 (0034).
11. **Clip gain, fades, and crossfades (R7 part).** A gain line on each clip (F31), fade handles on the clip corners and Cmd-F on a range (F32), equal-power crossfades that use the media handles (F33), and a clip inspector with numeric gain and fades (F84). The Player and the export render them. The fades are in session version 3 and the crossfades in version 4, with no overlap of clips. The gain line and the fade handles are mouse zones of the gesture model (0020).
   - **11a Clip fades.** Fade-in and fade-out on each clip (session version 3), the render, Edit > Fade (Command-F), the fade in the lanes, and `dirigible clip fade` (0035).
   - **11b-1 Gain line and fade handles.** The mouse gain line and fade handles of each clip, the drag readout, and the double-click resets (amends 0020, 0035).
   - **11b-2 Inspector.** The inspector pane of 0023 with numeric gain and fades, "Mixed" for many clips, and a batch `setGains` with its `dirigible` command.
   - **11c-1 Crossfade model.** Equal-power crossfades at a butt join from the media handles: the model, session version 4, the render, and `dirigible clip crossfade` (0036).
   - **11c-2 Crossfade editing.** Command-F across a join, the crossfade handle drag, the X draw in the lanes, and the benches (0036).
12. **Ripple edit (R7 part).** Ripple Delete, Ripple Cut, and Ripple Insert, a ripple trim with a modifier (F68), and a context menu on the lanes. No session format change. A ripple changes all tracks by default, and markers follow it in every scope (0037). The ripple trim modifier is in the gesture model (0020). A clip click, then Ripple Delete, keeps every track in sync. Research: `final-cut-pro.md` section 10.
13. **File import (R7 part).** Three runs.
   - **13a Import by menu and CLI (0040).** Import WAV, AIFF, FLAC, MP3, and M4A into a track (F61) with File > Import Audio… (Command-T) and `dirigible import`. The file is converted to a WAV at the session rate in `Clips/` and auto-leveled (run 8), as one undo entry.
   - **13b Paste across packages (0042).** One clipboard per app in memory; `pasteClipboard` copies or converts the files of the clips under new file IDs; the copies stay after Undo; `clip paste --source` and `clip paste-clips --source`.
   - **13c The drop on a lane.** A Finder drop at the frame under the pointer, a new track for a drop below the last lane and for each file of a multi-file drop, the drop cue, and its bench case.
14. **Autosave and backups (R10 part).** Backups of `session.xml` and a revert that is one undo entry and keeps `<recording>` (F62, 0043). macOS Versions takes no part.
15. **Language preference (R13).** A Settings window with English, Spanish, or the macOS language (F66, 0010).
16. **Chapters export (R10 part).** File > Export Chapters writes `chapters.json` 1.2.0 from the chapter markers, and `dirigible chapters export`. The chapters use the same range as the audio export. Test: Export Selection from frame N gives a chapter at N + k with `startTime` k / rate. Import and chapters inside the MP3 or M4A file landed in Release 3 with F55 and F56. Test: the chapters export of a session after a ripple with the music track out of scope gives literal times. Research: `podcasting-2.md`.
17. **MCP server on package files (R16 part).** `dirigible mcp` serves each `dirigible` edit command as an MCP tool over stdio, plus `session_create` and `session_info`. It refuses a package that the app has open. No tool records. Decision 0041.

## Release 3: Hindenburg-style production

Status: closed

Goal: match the Hindenburg tools that save time on each episode. The release closed at what landed. The work that did not land is in Release 4 to 7 and in [features.md](features.md).

| Requirement | What Release 3 gave |
|---|---|
| R3 | Record monitor: hear the input of a track in the output (F02 part). |
| R5 | Remove unused clip files (F87). |
| R7 | Part: vari-speed, snap to clip edges, a track volume fader in the track header, and the transcript import and the cut by words (F18, F82, F94, F27 part). |
| R10 | Part: episode metadata and artwork, and chapters inside the audio file (F55, F56 part). |
| R16 | The MCP server in the running app (off by default, a Settings switch, a toolbar mark, the agent name in Undo), and recording after a consent sheet (0041). |

Podcast metadata inside the audio file (title, artwork, chapters as ID3 or MP4 chapters) is Release 3, runs 4 and 5. The user asked for all the metadata that podcast apps read. The `chapters.json` export of Release 2 run 16 does not wait for it: it is a separate file next to the export, not metadata inside the audio file, and it uses only the chapter markers of Release 1.

Run order. The research for this order is in `docs/research/podcast-features.md`, `document-window.md`, `mouse-edits.md`, `final-cut-pro.md`, `logic-garageband-update.md`, and `podcasting-2.md`. The tester requests of runs 1 to 3 are from a tester, 2026-10-04.

1. **Record monitor (F02 part).** The tester asked for it two times. A Monitor button in each track header, next to Arm, sends the input of the track to the output, before and during a take. Each listened device has one `Listener` with its own input IOProc and a default output unit, with no aggregate device (0044). When the output is the built-in speakers, the monitor plays nothing, its button keeps its state, and the "Use headphones" banner shows (F43). An app track has no monitor: the user already hears the call app. The meter item is **Record > Input Levels** and the monitor item is **Track > Monitor Track**. The monitor state is window state, as Arm, so the session version does not change. No `dirigible` command: the monitor writes nothing to a package, and its output is for a person (0015). Research: `document-window.md` section 8, `process-taps.md` line 143, 0015. Tag: `v0.3.4`.
2. **Track fader (F94).** The tester asked for a volume control in the track header. `Track.gain` is in the session, the mix, `dirigible track gain`, and the MCP tool `track_gain`. The run adds the UI: a fader in the header with a dB readout, and a double-click that resets it to 0 dB. A drag plays the new gain at once and makes one edit at the mouse-up: one undo entry and one autosave. A gain change during play uses the mix crossfade of 0039, so it does not step at a chunk boundary. The fader is off during a take, as M and S (0039). Every edit path (the app, `dirigible`, MCP) refuses a gain outside -96 to +96 dB. -60 to +20 dB is only the fader travel: a stored value outside the travel pins the thumb, and a drag or a key step does not move it further out. Tag: `v0.3.4`.
3. **Snap (F82).** A clip move, a trim, and a range drag snap to clip edges, the playhead, and the markers, and an alignment guide line shows. View > Snap turns it on and off, with a key. Command held during a drag turns snap off for that drag. The snap setting is an app preference, so the session version does not change. No `dirigible` command: snap changes only a mouse gesture, as run 4d of Release 1. The snap step is in the gesture model (0020). Research: `mouse-edits.md` section 5, `logic-garageband-update.md`. Tag: `v0.3.4`.
4. **Episode metadata and artwork (F55).** All the metadata that podcast apps read (user request). The fields: title, show (album), host or author (artist), episode and season numbers, date, genre Podcast, language, copyright, the explicit flag, the episode notes and description (ID3 COMM and TDES, MP4 `desc` and `ldes`), the episode and feed URLs (WXXX, WOAF, WFED), the podcast flags (PCST, TGID), and the artwork (APIC, `covr`). They go in the session, in the MP3 (ID3) and M4A files, in a metadata panel in the app, and in a `dirigible` option for each field. The fields are one episode element in `session.xml` version 6 (0045). Tag: `v0.3.4`.
5. **Chapters inside the audio file (F56 part).** ID3 CHAP and CTOC in MP3 with the sub-frames TIT2, WXXX, and APIC, and a chapter track in M4A, from the chapter markers of run 16 of Release 2. Each chapter has a title, a URL, and an image, also in `chapters.json` (`url`, `img`). Tag: `v0.3.5`.
6. **MCP server in the app (R16 part).** Slice 2 of 0041: the server in the running app, off by default, a Settings switch, a Copy Setup Command pull-down (Claude Code, Codex, opencode, any MCP app), a toolbar mark while an agent is connected, and the agent name in Undo (0046). The live edit tools map to `Studio.edit(ripple:)`, which refuses a ripple under a pending take (`.rippleBlocked`). Tag: `v0.3.6`.
7. **Record with consent (R16 part).** Slice 3 of 0041: an agent asks to record, and the app shows a consent sheet; the take starts only when the user clicks Record. Then the long audio tools (`export`, `render`, `level`, `loudness`, `import`) with `notifications/progress` and `notifications/cancelled` (0048, 0049). Tag: `v0.3.7`.
8. **Remove unused clip files (F87).** `dirigible file remove` removes one pool entry that no clip uses, but the WAV stays in `Clips/`. This run adds a scan for pool files that no clip uses and for WAV files in `Clips/` that the pool does not name (after an import that stopped, or a revert to a backup). File > Remove Unused Files shows the list and the size, and moves the files to the Trash after a confirmation. `dirigible file prune` does the same, with `--dry-run`. The files go to the Trash, and a file that a backup or an undo entry uses stays (0047). Tag: `v0.3.8`.
9. **Vari-speed (F18).** Play at a different speed with the pitch kept. The speed node is in the `Player` engine (0052). Pre-roll moved to Release 6 (0070). Tag: `v0.3.9`.
10. **Transcript import and cut by words (F27 part).** Import a transcript (Whisper JSON, WebVTT, or SRT; SRT came in Release 4, F118) and cut the audio by words, in the `dirigible` CLI and the agent tools. The words are stored in a write-once file for each transcript (0055). Tag: `v0.3.10`.

Merges between the runs have a fourth-number tag (`v0.3.4.1` to `v0.3.10.4`): the agent tools and onboarding, the record grant, the ripple of several ranges, UI polish, and the hardening for the first real episode.

## Release 4: sound repair

Status: closed

Goal: repair a recording: reduce noise and hum, level a voice, match voices, and fix harsh sounds and peaks. The list order fixes no version.

| Requirement | What Release 4 gives |
|---|---|
| R1 | Part: the record time and its warning only under 3 hours (F152). |
| R2, R3, R12, R13 | Part: diagnostics: a local journal of each launch, a hang watchdog, and a problem report that the user sends by hand (F162). |
| R7 | Part: markers during a take, a drop of files on an empty session, a click in an empty lane that selects its track, and split stereo to mono, and timeline clarity (F107, F108, F109, F25, F153, F154, F155, F156), heal of touching pieces (F161), a crossfade at a seamless join (F163), a take time map (F164), an SRT transcript import (F118 part), a gain envelope on a clip with range gains (F75), and marquee selection of clips (F127). |
| R8 | Noise reduction, hum removal, a render of a range through an effect, a render link, and a repair set: rumble, clipped peaks, and harsh "s" sounds (F35, F77, F89, F110, F98, F99, F100). |
| R9 | Part: a leveler that rides the gain inside a clip (F38 part). |
| R10 | Part: voice match, and the leveler (F37 part, F38 part), a text chapter list (F160), a transcript export (F121 part), and track roles and the duck of the music under speech (F72, F34). |
| R11 | Part: a warning in an export to MP3 or M4A with no episode title (F166). |
| R12 | Part: the meter and the permission state of an armed app track before a take (F114). |
| R13 | More UI languages (F113), the export title warning of the window (F166), and European Portuguese beside Brazilian Portuguese (F169). |
| R16 | Part: the agent pack, an import in one call, a reuse of the same audio, a compact session read, the reads by time, the agent transport, and the agent batch (F157, F158, F159, F164, F165, F167, F168). |

1. **More UI languages (F113).** Portuguese, German, French, Italian, and Dutch, with the language preference of Release 2 (0010).
2. **Markers during a take (F107).** Add a marker while the take runs.
3. **Empty session drop and lane click (F108, F109).** A drop of files on an empty session makes one track for each file. A click in an empty lane selects its track.
4. **Split stereo to mono (F25).** Split a stereo clip into two mono clips, each with a menu item, a key, a `dirigible` command, and an MCP tool (0053).
5. **Noise reduction and the clip render (F35, F89).** Noise reduction on the render of a clip through an effect: L1 has a fixed 12 dB, and L2 adds the one control, a dial in dB. Decision 0054.
6. **Render link (F110).** A rendered clip keeps a link to its original, so that the user changes the amount of the effect later or restores the original. Decision 0057.
7. **Hum removal and the dial (F77).** Hum removal at 50 or 60 Hz, and the preview dial of the noise reduction. Decision 0054.
8. **The leveler (F38 part).** Gain riding inside a clip, as a second gain layer of the clip (Tools > Level Over Time). Decision 0060.
9. **Voice match (F37 part).** Match the EQ of a track to a reference clip or to a range of it. Decision 0074.
10. **The repair set (F98, F99, F100).** Reduce rumble with a high-pass filter, repair clipped peaks, and soften harsh "s" sounds.
11. **Armed app track (F114).** A level meter and the permission state of an armed app track before a take.
12. **Record time only when relevant (F152).** The window subtitle shows the record time left, and a banner warns, only under 3 hours of record time.
13. **Timeline clarity (F153, F154, F155, F156).** The record-over warning is a chip over the track headers. Each cut between two clips has a join, and the playhead is neutral with a head on the ruler. A drag on the ruler makes a range, and a click on a clip selects the clip as a set of clips. Each clip has a bar with its name. Decisions 0017 and 0023.
14. **Agent pack (F122, F157 to F161).** An import shapes its clip in one call, and an import of the same audio reuses the WAV. `session_info` has a compact form. Chapters export as a text list and import from a Podcasting 2.0 file, and Heal joins touching pieces of one file. Decisions 0011, 0040, and 0041.
15. **Diagnostics (F162).** A journal file for each launch, a main-thread hang watchdog with stacks, and one redacted report file that the user saves from the Help menu and sends by hand. Decision 0059.
16. **Gain envelope (F75, moved from Release 7).** Gain points on each clip and range gains with ramps, in playback, export, `session.xml` version 10, the `dirigible` CLI, and the MCP tools. The app draws the curve, and the user edits the points with the mouse, the keyboard, and the inspector. Decision 0060.
17. **Track roles and ducking (F72, F34, moved from Release 7).** A dialogue, music, or effects role on a track, with a color strip and a letter in its header, in `session.xml` version 11. Tools > Duck Music Under Speech... lowers the music under the speech in one undo step, and so do `dirigible duck` and the `duck` MCP tool. Decision 0060.
18. **Agent reads by time (F165).** `dirigible silences`, `dirigible nearest-pause`, and `dirigible meter`, and their MCP tools, give the silences of a range, the best cut point near a frame, and the loudness and the peaks of the heard stereo mix of a range, with no export. On a session that is open in the app, they read the session of the window. Decision 0062.
19. **Export title warning (F166).** An export to MP3 or M4A with no episode title warns that the file has no title tag.
20. **Marquee selection (F127).** A Shift-drag on the lanes selects the clips that the rectangle holds whole. A tester asked for it on 2026-10-15 (0038).
21. **European Portuguese UI (F169).** A `pt-PT` table beside the Brazilian `pt` table, with its own item in the language pop-up (0010). The user asked for it on 2026-10-16.
22. **Transcript import and export (F118, F121).** An SRT transcript imports, and a transcript exports as VTT or SRT (0061). The import of Podcasting 2.0 JSON and the JSON export are Later.
23. **Crossfade at a seamless join (F163).** A crossfade at a join with two different gains uses the equal-gain curve (0036).
24. **Take time map and sync state (F164).** The take time maps to the edited timeline, and the agent learns when an edit breaks the sync with the take (0061).
25. **Agent transport and batch (F167, F168).** An agent plays a range, stops, and locates in the running app (0046). Many edit calls make one undo step in the app and one save on the files (0063).

## Release 5: edit by text

Status: closed

Goal: edit the audio from its transcript, and cut silence with a review list.

| Requirement | What Release 5 gives |
|---|---|
| R7 | The text pane of a transcript, cut edges at the word edges, and transcription in the app (F27, F111, F112). |
| R10 | The silence tool with a review list (F26, F96). |
| R11 | Export one file for each chapter or marker (F95). |

1. **The text pane (F27).** Show the transcript beside the lanes, select words, and cut the audio from the text. The import and the cut by words in the CLI landed in Release 3 run 10. Decision 0055.
2. **Cut edges (F111).** A cut by words lands at the word edges. The cut lands at the exact word times. The quietest point near a word edge waits for tester feedback (F111, `docs/research/cut-edges.md`).
3. **Transcription in the app (F112).** whisper.cpp in the app, vendored as LAME is (0034).
4. **The silence tool (F26, F96).** Find the long pauses, and shorten, mute, or mark each one from a review list.
5. **Export one file for each chapter or marker (F95).**

## Release 6: timeline editing

Status: closed

Goal: edit the timeline faster: pre-roll, replace and fill, and the timeline edits of Logic Pro and Final Cut Pro.

| Requirement | What Release 6 gives |
|---|---|
| R6 | Remove the raw CAF of a take after its WAV passes the checks (F170). |
| R7 | Part: pre-roll, replace, room-tone fill, duplicate, close gaps, roll and slip trims, a follow track, drag modes, a session index, waveform zoom, and sync by waveform (F08, F21, F69, F70, F74, F76, F78, F80, F81). |

1. **Pre-roll (F08).** Record at the playhead after a pre-roll of the other tracks, with a length in Settings. The run decides playback during a take and its take anchor (amends 0039).
2. **Replace, room-tone fill, and Duplicate (F21).** Each with a menu item, a key, a `dirigible` command, and an MCP tool (0018, 0053).
3. **Timeline edits (F81, F69, F70, F80).** Close gaps, roll and slip trims, a follow track in a ripple, and drag modes. The run splits at its plan.
4. **Session index and waveform zoom (F76, F78).** A list of clips, markers, and chapters with search, and a vertical zoom of the waveforms.
5. **Sync by waveform (F74).** F74 lands in two steps.
   - **L1 Waveform sync.** Align a clip to another track by its audio waveform.
   - **L2 Drift fit.** F74 also aligns an outside recording that has its own clock. Examples: the file that a remote guest recorded on the guest computer, a backup recorder, or camera audio. An outside recording has no shared host clock, so F74 measures the drift from the audio. The drift fit is a cross-correlation at several points across the clip, a line fit of offset and rate, and one resample. The line fit is the fit of 0004, but from the audio. F74 reads the original file of the outside recording. It does the rate conversion and the drift correction in one resample, as Finalize does (0004). A drift of 50 ppm is about 180 ms in one hour. Edge cases that the F74 run handles:
     - A pause or a gap in the outside recording: one drift fit for each segment.
     - 44.1 kHz against 48 kHz.
     - Call-track dropouts with no correlation peak: the line fit rejects outliers.
     - A clean microphone against a codec-degraded copy of the call.
     - Several remote people in one call track: each outside recording aligns on its own, against the segments where that person talks alone.
     - The original file is gone: the F74 run picks the source of the resample.
6. **Raw capture removal (F170).** A take removes its raw CAF after its WAV passes the frame, rate, and alignment checks (0071).

## Release 7: mix and organization

Status: closed

Goal: export stems, organize the work with presets, templates, favorites, and bins, and merge a session that another Dirigible recorded.

| Requirement | What Release 7 gives |
|---|---|
| R6 | Session archive (F132). |
| R7 | Import Session (F151). |
| R10 | Export presets and templates, favorites, and clipboard bins (F63, F23, F22). |
| R11 | Stem export and export presets (F73, F57). |

1. **Stem export (F73).** One file for each track or each role, all from the same start. Run 1 lands the command line and the MCP tool. Run 2 lands File > Export Stems... in the app.
2. **Export presets and session templates (F57, F63).** Several targets in one step, and a new session from a template package.
3. **Favorites and clipboard bins (F23, F22).** A clipboard that all sessions share, and named groups of clips in a session.
4. **Import Session (F151).** Merge another Dirigible package into the open session (Hindenburg PRO has Import Session Into Session). The use case: two people record apart, with no link between the apps. One of them sends the full package for the edit. A recording from another app, such as Audacity, uses Import Audio and Sync by waveform. The merge adds one track for each imported track, with its name, and the markers as an option. It copies the files with the copy function of the paste across packages (0042: new file IDs, `NewClipFiles`). It gets a `dirigible` command (0011, CLI parity). The other package has no clock in common with this one, so the import keeps the positions of its own timeline, plus an offset: a rough start. The package has one timebase, so all its tracks align with the same drift fit of Sync by waveform (Release 6). The drift fit pairs two tracks that hold one voice, for example the microphone track of one package and the call track of the other. Until the drift fit, the import keeps the source positions plus the offset.
5. **Session archive (F132).** File > Archive Session... converts each 24-bit clip WAV to FLAC with the same samples, usually to half the size, and Unarchive Session converts them back. `session.xml` is version 22 with `archive="flac"` while the session is archived, so an older build refuses it. An edit, Play, an export, and Record unarchive first, with a progress sheet. It gets `dirigible file archive` and `dirigible file unarchive` and the tools `file_archive` and `file_unarchive` (0011, CLI parity). Decision 0072. Research: `archive.md`.

## Versions

The app version is `0.<release>.<run>`, from the release and the run number of this file, with the fourth number of bullet 1. Release 3 run 4 is `0.3.4`, and Release 4 run 1 is `0.4.1`. A run that lands an F-ID takes the lowest open release and the next run number of that release; the list order below fixes no version.

- A version never goes down. A merge that changes app code (`Sources/`, `Package.swift`, `Package.resolved`, `Support/`) gets the next fourth number on the newest tag when the lead tags it, if it is not a numbered run or if it lands after a higher run (runs land in parallel): `0.3.4.1`, `0.3.4.2`; run 7 after `v0.3.8.1` is `0.3.8.2`, not `0.3.7.1`. The fourth number counts the tags, not the merges. The next numbered run resets it.
- The source of the version is an annotated tag `v<version>` on `main`. A lightweight tag does not count. There is no GitHub release.
- After the land, the lead tags the next merge that ships app code. One tag can cover earlier untagged app-code merges. Push the tag before `make dmg`. Then compare `git rev-parse <tested>^{tree}` with `git rev-parse origin/main^{tree}`, where `<tested>` is the commit of the `stamp: reuse <commit>` line of the land output, else the head of the run branch. Equal: detach the run worktree at the tagged commit and run `make dmg` there, so the DMG comes from the tested tree. Else: build the DMG from a checkout of `main` at the tagged commit. A DMG built before the tag gets the describe version in its name and in the app.
- `scripts/land.sh` merges with a rebase, so `main` has no merge commit, and the head commit of the pull request is not on `main`. Tag the commit that `gh pr view <n> --json mergeCommit -q .mergeCommit.oid` prints: the last commit of the pull request on `main`.
- Tag with `scripts/tag-release.sh <version> <commit> '<run>'`. It makes the annotated tag, checks it, and pushes it. It refuses a version that is not higher than the newest tag of origin, a commit that is not on `origin/main`, and a commit that does not hold the newest tag. Its header gives the details.
- `scripts/version.sh` prints the version of a work tree: the nearest tag without its `v`, plus `-<n>-g<commit>` for a commit after the tag. `scripts/bundle.sh` writes it to `CFBundleShortVersionString`, with `-dirty` for a tree with uncommitted changes. With no tag, the version is `0.0.0`. `CFBundleVersion` stays 1.
- The version shows in **Dirigible > About Dirigible**, in the start window, in the DMG name, and in the output of `dirigible --version`.

## Later

Each feature with the state Later in [features.md](features.md) waits for its own design run.
