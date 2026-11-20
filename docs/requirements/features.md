# Features

This file lists each feature that we found, one row for each ID. It is the one place that holds the state of a feature. A feature never leaves the file: a feature that we do not build keeps its row with the state `Dropped (<reason>)`. The order of the features in each release is in [releases.md](releases.md). The source research is `docs/research/podcast-features.md`. The steering rules are in `docs/workflow/release-cycle.md`.

## States

- `done, Release <n> run <m>`: the feature landed. Several parts join with ` and `, for example `done, Release 2 run 16 and Release 3 run 5`. A part can list runs: `Release 2 runs 11a and 11b-1`. A run ID can have letters in Release 1 to 3; from Release 4 on it is digits only. A note in parentheses can follow. A part that stays open goes after `; Later: `. The state stays done.
- `Release <n>`: the feature waits in the open release n. The Release n section of `releases.md` names the ID.
- `Later`: the feature waits for its own design run. A note in parentheses can follow.
- `Dropped (<reason>)`: we do not build the feature.

## Rules

- Land: the landing run of an ID sets `done, Release <n> run <m>` in its own pull request. The `- Lands:` line of `run.md` names the IDs of the land, or says `none`. `check-governance.sh` refuses the land when an ID of the line keeps its state. A part that stays open goes after `; Later: `.
- Run number: a run that lands an ID takes the lowest open release and the next run number of that release. A feature of a later release that lands early moves to that release, with `(moved from Release <k>)` in its state. `check-governance.sh` refuses a new run number that is not 1 + the highest run number of that release at the base. The order in `releases.md` fixes no version.
- IDs: a new request gets the next free ID. An ID is never used again. The `Feature` and `Req` cells of a row stay as they are. A `Release <n> run <m>` part of a done state stays.
- From: the cell names a reference app, a brief ID such as `brief R12`, or a role with a date such as `user 2026-10-14` or `tester 2026-10-04`. It names no scratch label and no run.
- Role: a source names a role, never a person. It has no name, no handle, and no pronoun for a tester.
- Req: the cell holds the requirement IDs of `brief.md`. A catalog ID keeps the Req of the catalog, also `-`.

| ID | Feature | From | State | Req |
|---|---|---|---|---|
| F01 | Multitrack recording, one track per input, from 2+ devices | Hindenburg PRO, GarageBand, Logic Pro | done, Release 1 run 2 | R3, R4 |
| F02 | Arm, input meter, and record monitor per track | Hindenburg PRO, GarageBand, Logic Pro | done, Release 1 runs 3 and 3b and Release 3 run 1 (v0.3.4: the record monitor); Later: a Show Record Head menu item | R3 |
| F03 | Per-device clock data and track alignment | GarageBand, Logic Pro | done, Release 1 run 2 | R3, R4 |
| F04 | Captured audio survives a crash, unplug, or full disk | Logic Pro | done, Release 1 run 2 | R6 |
| F05 | Record audio from other apps to its own track | Hindenburg PRO | done, Release 2 run 6 | R12 |
| F06 | Call recording preset: local mic and remote app on two tracks | Hindenburg PRO | done, Release 2 run 6 | R12 |
| F07 | Punch-in recording | Hindenburg PRO, Logic Pro | Later (Autopunch at a selection; record at the playhead is done, Release 1 run 4a) | R7 |
| F08 | Pre-roll, record at the playhead | Hindenburg PRO | done, Release 6 runs 2 and 3 | R7 |
| F09 | Retroactive capture of a take | Logic Pro | Later | - |
| F10 | Transport: play, stop, go to start or end | Hindenburg PRO, GarageBand, Logic Pro | done, Release 1 run 4a; Later: Stop when stopped goes to the start, as in Logic | R7 |
| F11 | Select, cut, copy, paste, delete clip | Hindenburg PRO, GarageBand, Logic Pro | done, Release 1 run 4c; Later: progress and cancel for a paste across sessions | R7 |
| F12 | Split clip at the playhead or at the selection edges | Hindenburg PRO, GarageBand, Logic Pro | done, Release 1 run 4c | R7 |
| F13 | Move and trim clip | Hindenburg PRO, GarageBand, Logic Pro | done, Release 1 runs 4c and 4d | R7 |
| F14 | Undo and redo | Hindenburg PRO, GarageBand, Logic Pro | done, Release 1 run 1 | R7 |
| F15 | Zoom and go to the previous or next clip | Hindenburg PRO | done, Release 1 runs 4a and 4b | R7 |
| F16 | Base keyboard shortcuts: each command has a menu item with a key | Hindenburg PRO | done, Release 1 run 4c | R7 |
| F17 | JKL shuttle | Hindenburg PRO | done, Release 1 run 4a | R7 |
| F18 | Vari-speed playback | Hindenburg PRO | done, Release 3 run 9 (v0.3.9); Later: a typed speed value, as in Hindenburg | R7 |
| F19 | Markers: add, rename, go to | Hindenburg PRO, GarageBand, Logic Pro | done, Release 1 run 4c | R7 |
| F20 | Ripple edit: cut closes the gap, insert pushes later clips | Hindenburg PRO | done, Release 2 run 12 | R7, R10 |
| F21 | Replace, room-tone fill, duplicate | Hindenburg PRO | done, Release 6 run 1; Later: Duplicate | R7 |
| F22 | Clipboard with groups (bins) | Hindenburg PRO | Release 7 (also: a paste near the last track adds tracks, as in Audition) | R7, R10 |
| F23 | Favorites: a clipboard shared by all sessions | Hindenburg PRO | Release 7 | R10 |
| F24 | Group or link tracks; merge clips | Hindenburg PRO | Later | R7 |
| F25 | Split a stereo clip into two mono clips | Hindenburg PRO | done, Release 4 run 17 | R7 |
| F26 | Silence removal | Logic Pro | done, Release 5 run 4 (Shorten in Tools > Find Silences, `dirigible silence-edit`, and the agent tool `silence_edit`) | R10 |
| F27 | Transcript and text-based editing | Hindenburg PRO | done, Release 5 run 1 (the Transcript tab: read, follow, select, and cut by words; the import and the cut by words came in Release 3 run 10, v0.3.10) | R7 |
| F28 | Time stretch | Hindenburg PRO | Later | R7 |
| F30 | Auto level per clip on record and import | Hindenburg PRO | done, Release 2 run 8 | R9 |
| F31 | Clip gain | GarageBand, Logic Pro | done, Release 2 run 11b-1 | R7 |
| F32 | Fade in and fade out | Hindenburg PRO, GarageBand, Logic Pro | done, Release 2 runs 11a and 11b-1 | R7 |
| F33 | Crossfades | Hindenburg PRO, Logic Pro | done, Release 2 runs 11c-1 and 11c-2 | R7 |
| F34 | Ducking music under speech | Hindenburg PRO, Logic Pro | done, Release 4 run 9 (moved from Release 7) | R10 |
| F35 | Noise reduction, one control | Hindenburg PRO | done, Release 4 run 25 (run 19 landed a fixed 12 dB) | R8 |
| F36 | EQ and one-dial compressor per track | Hindenburg PRO, Logic Pro | Later | R7 |
| F37 | Voice Profiler: learned EQ per voice | Hindenburg PRO | done, Release 4 run 31 (voice match to a reference clip or to a range of it); Later: a profile per voice | R10 |
| F38 | Magic Levels: bleed, gain riding, auto duck | Hindenburg PRO | done, Release 4 run 30 (gain riding as Level Over Time; bleed is F42, auto duck is F34) | R10 |
| F39 | Audio Unit plug-ins | Hindenburg PRO, GarageBand, Logic Pro | Later | - |
| F40 | Loudness meter (ITU-R BS.1770, EBU R128) | Hindenburg PRO, Logic Pro | done, Release 2 run 9b | R10 |
| F41 | Mono or stereo per track and for the mix | Hindenburg PRO, GarageBand, Logic Pro | done, Release 1 run 5 | R11, R15 |
| F42 | Remove remote-guest bleed from the local mic track, offline after the recording | Hindenburg PRO | Later (the reference can be the clean file that the guest recorded, after F74 aligns it) | R14 |
| F43 | Headphone check: warn when the output is the built-in speakers during recording | brief R14 | done, Release 2 run 6 | R14 |
| F50 | Export mix to WAV | Hindenburg PRO, GarageBand, Logic Pro | done, Release 1 run 5 | R11 |
| F51 | Export mix to AAC (.m4a) | Hindenburg PRO, GarageBand, Logic Pro | done, Release 1 run 5 | R11 |
| F52 | Export mix to FLAC | Hindenburg PRO | done, Release 1 run 5 | R6, R11 |
| F53 | Export mix to MP3 | Hindenburg PRO, GarageBand, Logic Pro | done, Release 2 run 10 | R11 |
| F54 | Loudness normalization at export | Hindenburg PRO, Logic Pro | done, Release 2 run 9a | R10, R11 |
| F55 | Episode metadata and artwork | Hindenburg PRO, Logic Pro | done, Release 3 run 4 (v0.3.4) | R10 |
| F56 | Chapter markers with title, image, URL | Hindenburg PRO | done, Release 2 run 16 and Release 3 run 5 (v0.3.5) | R10 |
| F57 | Export presets: several targets in one step | Hindenburg PRO, Logic Pro | Release 7 | R11 |
| F58 | Upload to podcast hosts | Hindenburg PRO | Later | - |
| F60 | Session XML file and clips folder | GarageBand, Logic Pro | done, Release 1 run 1 | R5, R6 |
| F61 | Import audio files into a track | Hindenburg PRO, GarageBand, Logic Pro | done, Release 2 run 13 | R7 |
| F62 | Autosave and session backups | Logic Pro | done, Release 2 run 14; Later: open a backup as a copy, as in Final Cut Pro | R5 |
| F63 | Session templates | Hindenburg PRO | Release 7 | R10 |
| F64 | User-defined keyboard shortcuts | brief R7 | Later | R7 |
| F65 | UI text in English and Spanish, follows macOS | GarageBand, Logic Pro | done, Release 1 run 3 | R13 |
| F66 | Language preference in the app | brief R13 | done, Release 2 run 15 | R13 |
| F67 | Session interchange (AES31, AAF, FCPXML, Pro Tools) | Hindenburg PRO | Later | R5 |
| F68 | Ripple trim: an edge drag with a modifier ripples the tracks | FCP | done, Release 2 run 12 | R7 |
| F69 | Roll and slip trims | FCP | done, Release 6 run 6 | R7 |
| F70 | Follow track: in a ripple, its clips move whole and never split | FCP | done, Release 6 run 7 | R7 |
| F71 | Connected clips: a clip anchored to a clip on another track | FCP | Later | R7 |
| F72 | Track role (dialogue, music, effects) with a color | FCP | done, Release 4 run 9 (moved from Release 7) | R10 |
| F73 | Stem export: one file per track or per role, all from the same start | FCP | done, Release 7 run 1 (the command line and the MCP tool; the app command comes in the next run of the release) | R11 |
| F74 | Sync a clip to another track by its audio waveform | FCP | done, Release 6 run 13 and Release 6 run 14 | R7 |
| F75 | Gain envelope per clip; a range gain makes ramps | FCP | done, Release 4 runs 7, 8 and 26 (moved from Release 7) | R7 |
| F76 | Session index: a list of clips, markers, and chapters with search | FCP | done, Release 6 run 9 and Release 6 run 10 | R7 |
| F77 | Hum removal at 50 or 60 Hz | FCP | done, Release 4 run 25 | R8 |
| F78 | Waveform vertical zoom | FCP | done, Release 6 run 11 and Release 6 run 12 | R7 |
| F79 | No feature: the catalog skipped this ID | - | Dropped (ID not used) | - |
| F80 | Drag mode: overlap, no overlap, auto crossfade, shuffle | Logic | done, Release 6 run 8 | R7 |
| F81 | Close gaps between the selected clips | Logic | done, Release 6 run 5 | R7 |
| F82 | Snap to clip edges with an alignment guide | GarageBand, Logic | done, Release 3 run 3 (v0.3.4) | R7 |
| F83 | Zoom toggle and zoom history | Logic | done, Release 2 run 2; Later: center the playhead after a zoom, as in Hindenburg Narrator | R1 |
| F84 | Clip inspector with numeric gain and fades | Logic | done, Release 2 run 11b-2 | R7 |
| F85 | Width of the track headers; height of one track | Logic | Later (the height of one track; View > Taller Tracks and Shorter Tracks change the height of all tracks; the header width is done, Release 2 run 1b) | R1 |
| F86 | Help tags that show the key equivalent | Logic | Later | R1 |
| F87 | Remove unused clip files | GarageBand, Logic | done, Release 3 run 8 (v0.3.8) | R5 |
| F88 | Session alternatives | Logic | Later | R5 |
| F89 | Render a range through an effect | Logic | done, Release 4 run 19 (the clip render; a range cut at the range edges stays Later) | R8, R10 |
| F90 | Lock a track | GarageBand | Later | R7 |
| F91 | Take folders and comps for punch-in | Logic | Later | R7 |
| F92 | Time display format and a large time window | Logic | Later (also: the selection length in the time display, as in Hindenburg, and a click on the time to type a time) | R7 |
| F93 | Customizable toolbar | Logic | done, Release 2 run 1a | R1 |
| F94 | A track volume fader in the track header | Hindenburg PRO | done, Release 3 run 2 (v0.3.4) | R7 |
| F95 | Export one file for each chapter or marker | Audition, Audacity; user 2026-10-14 | done, Release 5 run 6 (the Files pop-up of File > Export and Export Selection, `dirigible export --split`, and the `split` argument of the agent tool `export`) | R11 |
| F96 | Silence tool with a review list: shorten, mute, or mark each long pause | Audition, Audacity; user 2026-10-14 | done, Release 5 run 4 (the Silences tab with Shorten, Mute, Mark, and Skip for each row, in one undo step) | R10 |
| F97 | Clip audio type (voice, music, call) that sets the defaults | Audition; user 2026-10-14 | Later | R10 |
| F98 | Reduce rumble (a high-pass filter) | Audition; user 2026-10-14 | done, Release 4 run 29 | R8 |
| F99 | Repair clipped peaks (de-clip) | Audition; user 2026-10-14 | done, Release 4 run 29 | R8 |
| F100 | Soften harsh "s" sounds (de-ess) | SoundCraft; user 2026-10-14 | done, Release 4 run 29 | R8 |
| F101 | Fit a music bed to a duration | Audition; user 2026-10-14 | Later | R7 |
| F102 | Agent tools on files outside the session folder (MCP roots) | SoundCraft; user 2026-10-14 | Later | R16 |
| F103 | Match the loudness of files outside a session | Audition | Later | R9 |
| F104 | Noise gate or expander | Logic, Audacity, SoundCraft | Later | R8 |
| F105 | Click repair | Audition, Audacity | Later | R8 |
| F106 | Health check of a session and its files | SoundCraft | Later | R5 |
| F107 | Markers during a take | Hindenburg; user 2026-10-14 | done, Release 4 run 21 | R7 |
| F108 | A drop of files on an empty session makes one track for each file | Logic; user 2026-10-14 | done, Release 4 run 22 | R7 |
| F109 | A click in an empty lane selects its track | user 2026-10-14 | done, Release 4 run 22 | R7 |
| F110 | Render link: change the amount of a rendered effect later, or restore the original | user 2026-10-14 | done, Release 4 run 23 (Reduce Noise; voice match adds its kind) | R8 |
| F111 | Transcript cut edges at the word edges | Descript, Hindenburg; user 2026-10-14 | done, Release 3 run 10 and Release 5 run 3 (a cut by words lands at the exact word times, as the user chose for now, with the quietest point after tester feedback; the measurement is in docs/research/cut-edges.md); Later: the quietest point near the word edge, after tester feedback | R7 |
| F112 | Transcription in the app (whisper.cpp) | Hindenburg; user 2026-10-15 | done, Release 5 runs 2 and 5 (Tools > Transcribe Track..., `dirigible transcribe`, and the agent tool `transcribe`: whisper.cpp on the CPU, with three models that download on first use; run 5: a model file of the user, checked in a helper process, and a hint when a firewall holds the download) | R7 |
| F113 | More UI languages: Portuguese, German, French, Italian, Dutch | user 2026-10-14 | done, Release 4 run 2 | R13 |
| F114 | An armed app track before a take: a level meter and the permission state | brief R12 | done, Release 4 run 24 | R12 |
| F115 | A taller automatic track height | Hindenburg; tester 2026-10-04 | Dropped (covered by View > Taller Tracks) | R1 |
| F116 | Record (input) gain for each device track | user 2026-10-14 | Later | R3 |
| F117 | The agent log of a session in the app | user 2026-10-14 | Later | R16 |
| F118 | Transcript import of SRT and Podcasting 2.0 JSON | Podcasting 2.0 | done, Release 4 run 11; Later: Podcasting 2.0 JSON, VTT word time tags | R7 |
| F119 | Transcript speakers: names, and a speaker-to-track map | Descript | Later | R7 |
| F120 | Transcript text corrections, shown cut words, and find | Hindenburg, Descript | Later | R7 |
| F121 | Transcript export: VTT, SRT, and JSON | Podcasting 2.0, Apple Podcasts, Spotify | done, Release 4 run 11; Later: JSON | R10 |
| F122 | Chapters import from chapters.json | Podcasting 2.0 | done, Release 4 run 4 | R10 |
| F123 | Cue point import from recorder files, and the marker number keys | Hindenburg | Later | R7 |
| F124 | A second copy of each take on a second disk | REAPER; tester 2026-10-11 | Later | R6 |
| F125 | Episode metadata in WAV and FLAC, a three-state explicit flag, keywords, and category | Hindenburg | Later | R10 |
| F126 | Fade curves: linear, S-curve, and -3 dB | Final Cut Pro, Logic | Later | R7 |
| F127 | Marquee selection of clips | Logic, Final Cut Pro | done, Release 4 run 27 (moved from Later) | R7 |
| F128 | A short automatic fade at each cut | Hindenburg | Later | R7 |
| F129 | An output device choice for playback | brief R7 | Later | R7 |
| F130 | Snap to a time grid, and snap of a marker drag | Logic, Final Cut Pro; tester 2026-10-04 | Later | R7 |
| F131 | More export formats and options: AIFF, ALAC, Opus, BWF, 32 kHz, MP3 at 32 and 320 kbit/s | Hindenburg, Logic | Later | R11 |
| F132 | Compact session: FLAC clip files | user 2026-10-05 | Later | R6 |
| F133 | Exclusive solo and solo safe | Audition | Later | R7 |
| F134 | Crossfade shapes: an asymmetric crossfade and a moved pivot | Logic, Hindenburg | Later | R7 |
| F135 | Inspector extras: relative gain, a scrub drag, and a File section | Logic, Final Cut Pro, Hindenburg | Later | R7 |
| F136 | JKL: hold K for fast | Hindenburg | Later | R7 |
| F137 | Move a clip to another track with a key | Hindenburg | Later | R7 |
| F138 | Import extras: paste a Finder file, and promised files from Mail or Music | Hindenburg, Logic | Later | R7 |
| F139 | Double-click and triple-click on a clip or a gap, and a drag of a clip to Finder | Hindenburg | Later | R7 |
| F140 | Recovery extras: salvage a damaged CAF, reveal an unplaced segment, a missing-audio dialog | REAPER, Hindenburg | Later | R6 |
| F141 | Reopen the last session at launch | Logic | Later | R1 |
| F142 | Edit > Insert Silence | Logic | Later | R7 |
| F143 | Keyboard ripple trims (Q and W) | Hindenburg | Later | R7 |
| F144 | Track > Arm Track (Shift-R), and Option-click to arm all tracks | Hindenburg, Pro Tools | Later | R3 |
| F145 | Agent setup for MCP clients other than Claude Code | user 2026-10-12 | Later | R16 |
| F146 | The take length during a take | Hindenburg | Later | R1 |
| F147 | Agent tools for peaks, capture place, take finalize, capture add, and file add | brief R16 (decision 0041 parity list) | Later | R16 |
| F148 | A clip mark on a live peak at 0 dBFS during a take | Audacity | Later | R3 |
| F149 | Split a whole stereo track into L and R tracks that replace it | Audacity | Later | R7 |
| F150 | Pan (balance) of a track | Hindenburg, Logic | Later | R7 |
| F151 | Import Session: merge the tracks of another Dirigible package into the open session | Hindenburg PRO; user 2026-10-15 | Release 7 | R7 |
| F152 | The record time and its warning show only under 3 hours | tester 2026-10-15 | done, Release 4 run 1 | R1 |
| F153 | The record-over warning is a chip over the track headers, with a menu to go to the end, show the clip, or turn off record | tester 2026-10-15 | done, Release 4 run 3 | R7 |
| F154 | A join at each cut between two clips, and a neutral playhead with a head on the ruler | tester 2026-10-15 | done, Release 4 run 3 | R7 |
| F155 | A drag on the ruler makes a range, and a click on a clip selects it as a set of clips | tester 2026-10-15 | done, Release 4 run 15 | R7 |
| F156 | A bar with the clip name at the top of each clip | tester 2026-10-15 | done, Release 4 run 16 | R7 |
| F157 | An import shapes its clip in one call: the part of the file, the gain, the fades, and the clip ID | tester 2026-10-16 | done, Release 4 run 4 | R16 |
| F158 | An import of the same audio again reuses the WAV in the session | tester 2026-10-16 | done, Release 4 run 4 | R16 |
| F159 | A compact session read for agents | tester 2026-10-16 | done, Release 4 run 4 | R16 |
| F160 | A text chapter list, one line for each chapter with its time and title | tester 2026-10-16 | done, Release 4 run 4 | R10 |
| F161 | Heal: join touching pieces of one file with no change of sound | tester 2026-10-16, Pro Tools | done, Release 4 run 6 | R7 |
| F162 | Diagnostics: a local journal, a hang watchdog, and Report a Problem | tester 2026-10-15; user 2026-10-16 | done, Release 4 run 5 | R2, R3, R12, R13 |
| F163 | A crossfade at a seamless join with two gains, with the equal-gain curve | tester 2026-10-16, Pro Tools | done, Release 4 run 6 | R7 |
| F164 | Take time map and sync state: map take time to the edited timeline, and tell the agent when an edit breaks the sync with the take | tester 2026-10-16 | done, Release 4 runs 10 and 12 | R7, R16 |
| F165 | Agent reads by time: silences, the nearest pause, and the level and loudness of a range | tester 2026-10-16 | done, Release 4 run 13 | R16, R10 |
| F166 | An export to MP3 or M4A with no episode title warns that the file has no title tag | tester 2026-10-16 | done, Release 4 run 14 | R11, R13 |
| F167 | Agent transport: play a range, stop, and locate in the running app | tester 2026-10-16 | done, Release 4 run 18 | R16 |
| F168 | Agent batch: many edit calls as one undo step in the app and one save on the files | tester 2026-10-16 | done, Release 4 run 20 | R16 |
| F169 | European Portuguese UI (pt-PT) beside Brazilian Portuguese | user 2026-10-16 | done, Release 4 run 28 | R13 |
| F170 | Remove the raw CAF of a take after its WAV passes the frame, rate, and alignment checks | user 2026-10-17 | done, Release 6 run 4 | R6 |
