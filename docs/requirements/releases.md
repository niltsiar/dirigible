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
| R7 | Part: ripple edit, clip gain, fades, crossfades, file import (F20, F31, F32, F33, F61). |
| R9 | Auto-level of each clip to a loudness target (F30, 0008). |
| R10 | Part: loudness meter and normalization at export (F40, F54, 0008), autosave and backups (F62). |
| R11 | MP3 through LAME (F53, 0007). |
| R12 | Audio from other apps through process taps, and a call preset (F05, F06, 0006). |
| R13 | The language preference in Settings (F66, 0010). |
| R14 | Part: a "Use headphones" warning when a session has an app source and the output is the built-in speakers (F43, 0004). The feature catalog put F43 in Release 1, but its trigger needs an app source. |

## Release 3: Hindenburg-style production

Goal: match the Hindenburg tools that save time on each episode.

| Requirement | What Release 3 gives |
|---|---|
| R7 | Part: punch-in, pre-roll, vari-speed, replace and room-tone fill, clipboard, split stereo to mono (F07, F08, F18, F21, F22, F25). |
| R8 | Noise reduction with one control (F35, 0009). |
| R10 | Part: favorites, silence removal, ducking, EQ and compressor, episode metadata and artwork, chapter markers, export presets, templates (F23, F26, F34, F36, F55, F56, F57, F63). |
| R14 | Offline removal of the remote guest from the local microphone track (F42). |

Podcast metadata (title, artwork, chapters) is Release 3: the user did not ask for it, and the ranking puts it after leveling and MP3.

## Later

Each item needs its own design run.

- R5: session interchange, first the AES31-3 ADL export (F67, 0003).
- R7 and R10: transcripts and text editing (F27), Voice Profiler (F37), Magic Levels (F38), time stretch (F28), track groups (F24), Audio Unit plug-ins (F39), upload to hosts (F58), user-defined shortcuts (F64), retroactive capture (F09).
