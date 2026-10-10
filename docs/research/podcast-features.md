# Podcast features in Hindenburg PRO, GarageBand, and Logic Pro

Date: 2026-09-23

This catalog lists the features of Hindenburg PRO, GarageBand, and Logic Pro that help a podcaster. It gives each feature a value for a podcaster (1 to 5) and an effort for Dirigible (S, M, L). It maps each feature to the brief (`docs/requirements/brief.md`). R14 (remote-guest bleed removal) comes from a later user message of 2026-09-23. Then it ranks the features and proposes the releases. The sources are the Hindenburg site and manual, and the Apple user guides. The Hindenburg manual in [HM] is for Hindenburg Journalist 1.21. Hindenburg PRO 2 can use different defaults. The local apps are GarageBand 10.4.14 and Logic Pro 12.3.1. A claim that no primary source confirms has the mark "(unconfirmed)". The effort values are our estimates.

## Features

Value: 5 = a podcaster needs it for each episode, 1 = rarely used. Effort: S = days, M = one to two weeks, L = more than two weeks. The IDs leave gaps between areas.

| ID | Feature | Area | Hindenburg PRO | GarageBand | Logic Pro | Value | Effort | Req | Source |
|---|---|---|---|---|---|---|---|---|---|
| F01 | Multitrack recording, one track per input, from 2+ devices | record | One track per input, "as many channels as you have inputs"; plug and play devices | Records many tracks, but from one input device; 2+ devices need an aggregate device | Same as GarageBand: one input device, aggregate device for more | 5 | L | R3, R4 | [HF] [HT] [GM] [AG] |
| F02 | Arm, input meter, and record monitor per track | record | Arm with R; small meter on the track; monitor on or off per track | Record enable and monitoring per track | Record enable and input monitoring per track | 5 | S | R3 | [HM] [GM] |
| F03 | Per-device clock data and track alignment | record | No documented method (unconfirmed) | Aggregate device with drift correction | Aggregate device with drift correction | 5 | L | R3, R4 | [AG] |
| F04 | Captured audio survives a crash, unplug, or full disk | record | No documented method (unconfirmed) | Not documented (unconfirmed) | Autosave dialog at reopen | 5 | M | R6 | [LA] |
| F05 | Record audio from other apps to its own track | record | "Hindenburg Audio Device"; track source "Other Applications > Stereo" | No built-in method (unconfirmed) | No built-in method (unconfirmed) | 5 | M | R12 | [HF] [HK] |
| F06 | Call recording preset: local mic and remote app on two tracks | record | Call Recorder put Skype transmit and receive on two mono tracks; stopped with Skype 8 | No | No | 4 | S | R12 | [HM] [HT] |
| F07 | Punch-in recording | record | "Manually punch in to record" | Not documented (unconfirmed) | Autopunch with punch-in and punch-out locators | 3 | M | R7 | [HG] [LP] |
| F08 | Pre-roll, record at the playhead | record | Pre-roll with Cmd-P; records on the armed track at the playhead | Count-in (unconfirmed) | Pre-roll and count-in (unconfirmed) | 3 | S | R7 | [HM] |
| F09 | Retroactive capture of a take | record | No | No | Flashback Capture keeps up to one minute of audio | 2 | M | - | [LK] |
| F10 | Transport: play, stop, go to start or end | edit | Space plays and stops; Shift-Space stops at the start point; Home and End | Yes | Yes | 5 | S | R7 | [HM] |
| F11 | Select, cut, copy, paste, delete clip | edit | All edits in one view; Cut deletes the selection and closes the gap | Yes | Yes | 5 | S | R7 | [HM] |
| F12 | Split clip at the playhead or at the selection edges | edit | Cmd-B splits at the playhead or at the in and out points | Yes | Yes | 5 | S | R7 | [HM] |
| F13 | Move and trim clip | edit | Drag to move; drag end handles to trim | Yes | Yes | 5 | S | R7 | [HM] |
| F14 | Undo and redo | edit | Undo and redo of the last edit | Yes | Undo history | 5 | M | R7 | [HM] [LU] |
| F15 | Zoom and go to the previous or next clip | edit | Cmd-plus and Cmd-minus zoom; H zooms to selection; Shift-arrow goes to next or previous region | Yes (unconfirmed) | Yes (unconfirmed) | 5 | S | R7 | [HM] |
| F16 | Base keyboard shortcuts: each command has a menu item with a key | edit | Full default key set; see the table below | Key commands (unconfirmed) | Key commands (unconfirmed) | 5 | S | R7 | [HM] |
| F17 | JKL shuttle | edit | J and L play back and forward; Shift for slow; K+J and K+L for fast | No (unconfirmed) | No default JKL (unconfirmed) | 4 | M | R7 | [HM] |
| F18 | Vari-speed playback | edit | Period key toggles; Shift-period and Shift-comma change speed | No (unconfirmed) | Varispeed (unconfirmed) | 3 | S | R7 | [HM] |
| F19 | Markers: add, rename, go to | edit | Cmd-Return adds; keys 3-0 go to markers; imports cue points from field recorders | Arrangement markers for song sections only | Markers | 4 | S | R7 | [HM] |
| F20 | Ripple edit: cut closes the gap, insert pushes later clips | edit | Cut closes the gap; Insert (Cmd-I) moves the next regions forward | No (unconfirmed) | Shuffle drag mode (unconfirmed) | 5 | M | R7, R10 | [HM] |
| F21 | Replace, room-tone fill, duplicate | edit | Shift-Cmd-V replaces a selection and fills small gaps with room tone; Cmd-D duplicates | No | No (unconfirmed) | 3 | S | R7 | [HM] |
| F22 | Clipboard with groups (bins) | edit | Groups for interviews, music, ambience; copy a selection to it during recording | No | Project Audio Browser (unconfirmed) | 4 | M | R7, R10 | [HM] [HS] |
| F23 | Favorites: a clipboard shared by all sessions | edit | Jingles and station IDs; Opt-Cmd-0 adds, Cmd-0 pastes | No | No | 4 | S | R10 | [HM] |
| F24 | Group or link tracks; merge clips | edit | Link tracks; group regions; merge and un-merge smart regions | No (unconfirmed) | Track groups, join regions (unconfirmed) | 3 | M | R7 | [HG] [HS] |
| F25 | Split a stereo clip into two mono clips | edit | Tools / Split region; delete the empty side | No (unconfirmed) | Convert to mono files (unconfirmed) | 3 | S | R7 | [HM] |
| F26 | Silence removal | edit | Manual insert and delete of silence; automatic removal not documented (unconfirmed) | No (unconfirmed) | Remove Silence cuts passages below a threshold | 3 | M | R10 | [HM] [LS] |
| F27 | Transcript and text-based editing | edit | Local transcription, 99 languages; delete a word to cut the audio; SRT, VTT, TXT export | No | No | 4 | L | R7 | [HX] [HF] |
| F28 | Time stretch | edit | Time-stretch to fit a duration | No (unconfirmed) | Flex Time (unconfirmed) | 2 | L | R7 | [HF] |
| F30 | Auto level per clip on record and import | process | On import: narration -21 LUFS, music -23 LUFS (EU profile); Cmd-L re-analyzes | Auto Normalize at export only, peak based (unconfirmed) | Normalize Region Gain to peak or loudness (LUFS): each region, equally per track, or all equally (update 2026-09-27, [LG](logic-garageband-update.md)) | 5 | M | R9 | [HM] [HT] |
| F31 | Clip gain | process | No rubber bands; select a range and drag the top gain line | Track volume automation | Region gain and Gain tool | 5 | S | R7 | [HM] [LG] |
| F32 | Fade in and fade out | process | Drag clip corners, or Cmd-F on a selection or across many regions | Mix > Fade Out on the master track | Fades on regions | 5 | S | R7 | [HM] [GT] [LF] |
| F33 | Crossfades | process | Cmd-F at an edit; drag to change the point and length | Not documented (unconfirmed) | Crossfades on regions | 4 | M | R7 | [HM] [LF] |
| F34 | Ducking music under speech | process | "Duck" on a selection makes fade handles; Magic Levels ducks automatically | No (unconfirmed) | Compressor side chain; Legacy Ducker | 4 | M | R10 | [HM] [HF] [LC] |
| F35 | Noise reduction, one control | process | One-dial noise reduction | Noise Gate only | Noise Gate; Legacy Denoiser | 5 | L | R8 | [HF] [GG] [LD] |
| F36 | EQ and one-dial compressor per track | process | 3-band EQ; one-dial compressor | EQ and compressor Smart Controls (unconfirmed) | Channel EQ, Compressor | 4 | M | R7 | [HM] |
| F37 | Voice Profiler: learned EQ per voice | process | Learns an EQ from a good take; generic profile too | No | Match EQ (unconfirmed) | 3 | L | R10 | [HM] [HF] |
| F38 | Magic Levels: bleed, gain riding, auto duck | process | One click on selected regions; PRO only | No | No | 3 | L | R10 | [HF] [HC] |
| F39 | Audio Unit plug-ins | process | AU and VST | AU | AU | 2 | M | - | [HM] [HF] |
| F40 | Loudness meter (ITU-R BS.1770, EBU R128) | mix | On any track or the master; also QPPM, BBC PPM, VU | Level meters only (unconfirmed) | Loudness Meter; Mastering Assistant limits to -1 dBFS true peak | 4 | M | R10 | [HM] [LL] [LM] |
| F41 | Mono or stereo per track and for the mix | mix | Mono or stereo per export preset | Mono or stereo input per track | Mono or stereo per track and bounce | 4 | S | R11, R15 | [HM] |
| F42 | Remove remote-guest bleed from the local mic track, offline after the recording | process | Magic Levels cleans up microphone bleed on selected regions | No | No (unconfirmed) | 4 | L | R14 | [HS] [HF] |
| F43 | Headphone check: warn when the output is the built-in speakers during recording | record | No (unconfirmed) | No (unconfirmed) | No (unconfirmed) | 4 | S | R14 | - |
| F50 | Export mix to WAV | export | Yes, with saved presets | WAVE | WAV | 5 | S | R11 | [HF] [GE] [LB] |
| F51 | Export mix to AAC (.m4a) | export | Yes, 32 to 320 kbps | AAC | M4A: AAC | 5 | S | R11 | [HM] [GE] [LB] |
| F52 | Export mix to FLAC | export | Yes | No | No (unconfirmed) | 3 | S | R6, R11 | [HF] [FV] |
| F53 | Export mix to MP3 | export | Yes | MP3 | MP3 with ID3 tags | 5 | M | R11 | [HF] [GE] [L3] |
| F54 | Loudness normalization at export | export | Targets -23, -24, -16, -18, -14 LUFS per publish target | Auto Normalize (peak) (unconfirmed) | Bounce normalize to peak only | 5 | M | R10, R11 | [HF] [HL] [LB] |
| F55 | Episode metadata and artwork | publish | Title, author, image, explicit flag, and more; ID3 in MP3 | No (unconfirmed) | ID3 tags in MP3 | 4 | M | R10 | [HM] [HF] [L3] |
| F56 | Chapter markers with title, image, URL | publish | Shift-Cmd-Return adds; convert markers to chapters; AAC enhanced podcast | No (unconfirmed) | No (unconfirmed) | 4 | M | R10 | [HM] [HF] |
| F57 | Export presets: several targets in one step | publish | Publish targets with format, loudness, destination | No | Several file types in one bounce | 3 | S | R11 | [HF] [LB] |
| F58 | Upload to podcast hosts | publish | Libsyn, Buzzsprout, Podbean, RSS.com, SoundCloud, FTP, and more | No | No | 2 | L | - | [HG] [HR] |
| F60 | Session XML file and clips folder | project | `name.nhsx` file and a `name files` folder of audio; XML (unconfirmed) | Package project | Package project | 5 | M | R5, R6 | [HG] [TR] |
| F61 | Import audio files into a track | project | Drag and drop WAV, BWF, MP2, MP3, MP4; converts to 64-bit float WAV | Yes | Yes | 4 | S | R7 | [HF] |
| F62 | Autosave and session backups | project | Autosave was a request "under review" in 2014; state now unconfirmed | Not documented (unconfirmed) | Autosave; up to ten backups for each alternative | 4 | M | R5 | [HA] [LA] |
| F63 | Session templates | project | Session templates; "Save default session" | Project templates (unconfirmed) | Project templates (unconfirmed) | 3 | S | R10 | [HF] [HM] |
| F64 | User-defined keyboard shortcuts | project | Not documented (unconfirmed) | No (unconfirmed) | Key Commands editor (unconfirmed) | 3 | M | R7 | - |
| F65 | UI text in English and Spanish, follows macOS | project | English UI (unconfirmed) | Localized | Localized | 4 | S | R13 | - |
| F66 | Language preference in the app | project | No (unconfirmed) | No (unconfirmed) | No (unconfirmed) | 3 | S | R13 | - |
| F67 | Session interchange (AES31, AAF, FCPXML, Pro Tools) | project | Opens PTX, SESX, FCPXML; exports AAF and AES31 | No | AAF, FCPXML (unconfirmed) | 2 | L | R5 | [HF] |

## Features added 2026-09-27

The Release 2 planning run added these features from Final Cut Pro, Logic Pro, and GarageBand. The behavior, the Dirigible mapping, and the sources are in the linked research files. The value, the effort, and the release are our estimates. The release is the one of `docs/requirements/releases.md`. F79 is not used.

| ID | Feature | Area | From | Value | Effort | Req | Release | Source |
|---|---|---|---|---|---|---|---|---|
| F68 | Ripple trim: an edge drag with a modifier ripples the tracks | edit | FCP | 4 | S | R7 | 2 | [FCP](final-cut-pro.md) |
| F69 | Roll and slip trims | edit | FCP | 3 | S | R7 | 3 | [FCP](final-cut-pro.md) |
| F70 | Follow track: in a ripple, its clips move whole and never split | edit | FCP | 3 | S | R7 | 3 | [FCP](final-cut-pro.md) |
| F71 | Connected clips: a clip anchored to a clip on another track | edit | FCP | 3 | L | R7 | Later | [FCP](final-cut-pro.md) |
| F72 | Track role (dialogue, music, effects) with a color | project | FCP | 3 | S | R10 | 3 | [FCP](final-cut-pro.md) |
| F73 | Stem export: one file per track or per role, all from the same start | export | FCP | 3 | S | R11 | 3 | [FCP](final-cut-pro.md) |
| F74 | Sync a clip to another track by its audio waveform | edit | FCP | 4 | M | R7 | 3 | [FCP](final-cut-pro.md) |
| F75 | Gain envelope per clip; a range gain makes ramps | process | FCP | 4 | M | R7 | 3 | [FCP](final-cut-pro.md) |
| F76 | Session index: a list of clips, markers, and chapters with search | edit | FCP | 3 | S | R7 | 3 | [FCP](final-cut-pro.md) |
| F77 | Hum removal at 50 or 60 Hz | process | FCP | 3 | S | R8 | 3 | [FCP](final-cut-pro.md) |
| F78 | Waveform vertical zoom | edit | FCP | 3 | S | R7 | 3 | [FCP](final-cut-pro.md) |
| F80 | Drag mode: overlap, no overlap, auto crossfade, shuffle | edit | Logic | 4 | M | R7 | 3 | [LG](logic-garageband-update.md) |
| F81 | Close gaps between the selected clips | edit | Logic | 3 | S | R7 | 3 | [LG](logic-garageband-update.md) |
| F82 | Snap to clip edges with an alignment guide | edit | GarageBand, Logic | 4 | S | R7 | 3 | [LG](logic-garageband-update.md) |
| F83 | Zoom toggle and zoom history | edit | Logic | 3 | S | R1 | 2 | [LG](logic-garageband-update.md) |
| F84 | Clip inspector with numeric gain and fades | process | Logic | 3 | M | R7 | 2 | [LG](logic-garageband-update.md) |
| F85 | Width of the track headers; height of one track | edit | Logic | 2 | S | R1 | 2 (header width), Later (height of one track) | [LG](logic-garageband-update.md) |
| F86 | Help tags that show the key equivalent | project | Logic | 2 | S | R1 | Later | [LG](logic-garageband-update.md) |
| F87 | Remove unused clip files | project | GarageBand, Logic | 3 | S | R5 | 3 | [LG](logic-garageband-update.md) |
| F88 | Session alternatives | project | Logic | 2 | M | R5 | Later | [LG](logic-garageband-update.md) |
| F89 | Render a range through an effect | process | Logic | 3 | M | R8, R10 | 3 | [LG](logic-garageband-update.md) |
| F90 | Lock a track | edit | GarageBand | 2 | S | R7 | Later | [LG](logic-garageband-update.md) |
| F91 | Take folders and comps for punch-in | record | Logic | 2 | L | R7 | Later | [LG](logic-garageband-update.md) |
| F92 | Time display format and a large time window | edit | Logic | 2 | S | R7 | Later | [LG](logic-garageband-update.md) |
| F93 | Customizable toolbar | project | Logic | 2 | S | R1 | 2 | [LG](logic-garageband-update.md) |
| F94 | A track volume fader in the track header | process | Hindenburg PRO | 4 | S | R7 | 3 | [HM] |

## Hindenburg default shortcuts

These keys are the defaults in the Hindenburg Journalist 1.21 manual [HM]. Use them for the Release 1 key equivalents. Hindenburg PRO 2 can use different keys (unconfirmed). Hindenburg publishes a PRO 2 list at [HK2], but the page shows the keys only as script content, so this catalog does not quote it.

| Command | Key |
|---|---|
| Play and stop | Space |
| Stop and go back to the start point | Shift-Space |
| Record | Control-Space |
| Arm the track | R |
| Shuttle back, forward | J, L |
| Shuttle slow back, slow forward | Shift-J, Shift-L |
| Shuttle fast back, fast forward | K+J, K+L (hold K) |
| Set in point, out point | I, O |
| Go to in point, out point | 1, 2 |
| Split at the playhead or selection | Cmd-B |
| Cut (deletes and closes the gap) | Cmd-X |
| Copy, paste | Cmd-C, Cmd-V |
| Insert (moves the next regions forward) | Cmd-I |
| Replace | Shift-Cmd-V |
| Duplicate | Cmd-D |
| Fade or crossfade | Cmd-F |
| Auto level the selected regions | Cmd-L |
| Add marker | Cmd-Return |
| Add chapter | Shift-Cmd-Return |
| Zoom in, zoom out | Cmd-plus, Cmd-minus |
| Zoom to the selection | H |
| Next region, previous region | Shift-Right Arrow, Shift-Left Arrow |
| Go to the start, the end | Home, End |
| Clear the selection | Esc |
| Vari-speed on or off | Period |
| Undo, redo | Not in the manual; use Cmd-Z, Shift-Cmd-Z (unconfirmed) |

Note: macOS uses Control-Space by default to select the previous input source (unconfirmed on the target Mac). Test the Record key for this conflict before Release 1 ships.

## Ranking

The score is value divided by effort (S = 1, M = 2, L = 3). A higher score comes first. **R1** marks the thin first-release path "record -> edit -> export".

| Score | Features |
|---|---|
| 5.0 | **R1** F02, F10, F11, F12, F13, F15, F16, F50, F51; F31, F32 |
| 4.0 | **R1** F19, F41, F43, F65; F06, F23, F61 |
| 3.0 | **R1** F52; F08, F18, F21, F25, F57, F63, F66 |
| 2.5 | **R1** F04, F14, F60; F05, F20, F30, F53, F54 |
| 2.0 | **R1** F17; F22, F33, F34, F36, F40, F55, F56, F62 |
| 1.67 | **R1** F01, F03; F35 |
| 1.5 | F07, F24, F26, F64 |
| 1.33 | F27, F42 |
| 1.0 | F09, F37, F38, F39 |
| 0.67 | F28, F58, F67 |

F01 and F03 have a low score but they are the premise of the product (R3, R4). Release 1 must include them. Build them first.

## Proposed releases

### Release 1: record -> edit -> export

Goal: record two or more devices, make a rough edit, and export one file.

- Features: F01, F02, F03, F04, F10, F11, F12, F13, F14, F15, F16, F17, F19, F41, F43, F50, F51, F52, F60, F65.
- Brief: R2, R3, R4, R5, R6, R11 (WAV, AAC, FLAC), R13 (strings), R14 (mitigation only), R15.
- R14 in Release 1 is only a default: use headphones. F43 shows a warning when the output is the built-in speakers.
- Update 2026-09-24: `docs/requirements/releases.md` moves F43 to Release 2, because its trigger needs an app source (R12). Release 1 has no R14 work.
- Every Release 1 command has a menu item with a key equivalent: record, play and stop, JKL shuttle, split, delete, undo, add marker, zoom, previous and next clip.
- Delete leaves a gap in Release 1. Ripple edit comes in Release 2.
- F41 mono or stereo per track and for the mix export is in Release 1 (R15, user request 2026-09-23). The session schema must hold the channel layout from version 1.
- FLAC is cheap: AudioToolbox on this Mac already wrote a FLAC file ([FV]).
- R13 strings go in Release 1: the architecture rule forbids UI text only in code, and a later retrofit costs more.

### Release 2: a podcast-ready episode

Goal: record a remote guest, level the clips, and publish at the podcast loudness.

- Features: F05, F06, F20, F30, F31, F32, F33, F40, F53, F54, F61, F62, F66.
- Brief: R7 (part), R9, R10 (part), R11 (MP3), R12, R13 (preference).
- R12 comes here: process taps need macOS 14.2 and a permission, and they reuse the Release 1 writer.
- R9 comes here: one BS.1770 loudness engine serves F30, F40, and F54.
- MP3 needs an encoder decision record (brief open question), so it is not in Release 1.
- Loudness targets: -16 LUFS for stereo and -1 dBTP ([AP]). The -19 LUFS mono target is common practice (unconfirmed). Hindenburg recommends mono MP3 at -16 LUFS ([HL]).
- Update 2026-09-27: the Release 2 run order adds F68, F83, F84, F85 (header width), F93, and the `chapters.json` export (F56 part). See `docs/requirements/releases.md`.
- Update 2026-09-24: decision 0008 sets -19 LUFS for a mono export, from the BS.1770 channel rule. A Buzzsprout review says that Hindenburg PRO changes the loudness for mono at export, which contradicts the [HL] reading above.

### Release 3: Hindenburg-style production

Goal: match the Hindenburg tools that save time on each episode.

- Features: F07, F08, F18, F21, F22, F23, F25, F26, F34, F35, F36, F42, F55, F56, F57, F63.
- Brief: R7, R8, R10, R14.
- R14 comes here, not in Release 1 or 2: bleed removal needs the remote-guest track from Release 2 as its reference, and it shares the DSP work of R8.
- F42 is an offline step after the recording. Live voice processing (`AUVoiceProcessingIO`) is rejected: it builds its own aggregate device, ducks the call audio, and changes the raw signal.
- R8 comes here: it needs a method decision (spectral gating, RNNoise, or Apple voice processing) and more DSP work than R9.

### Later

- Features: F09, F24, F27, F28, F37, F38, F39, F58, F64, F67.
- Brief: R7 and R10 (rest), R5 (interchange formats).
- F27 transcripts and F37/F38 are large. Each needs its own design run.
- F64 custom shortcuts come after the Release 1 defaults are stable.

## Sources

[HM]: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
[HF]: https://hindenburg.com/products/radio-podcast/features/
[HC]: https://hindenburg.com/products/radio-podcast/comparison/
[HG]: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
[HT]: https://hindenburg.com/hindenburg-pro-features/tracking/
[HS]: https://hindenburg.com/hindenburg-pro-features/story-editing/
[HK]: https://hindenburg.uservoice.com/knowledgebase/articles/1982517-record-internal-sound-on-mac-zoom-skype-etc
[HK2]: https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
[HA]: https://hindenburg.uservoice.com/forums/224350-general/suggestions/5736450-autosave
[HL]: https://hindenburg.com/2025-dec-calendar-content-1/december-23/?sector=user
[HR]: https://hindenburg.com/support/release-notes/hindenburg-series/
[HX]: https://hindenburg.com/hindenburg-pro-2-features/transcription/
[TR]: https://transom.org/2010/hindenburg-review/
[GM]: https://support.apple.com/guide/garageband/record-to-multiple-audio-tracks-gbnd5f260581/mac
[GE]: https://support.apple.com/guide/garageband/export-songs-to-disk-gbnd7cbf5ed9/mac
[GT]: https://support.apple.com/guide/garageband/work-with-the-master-track-gbnd5e8076d0/mac
[GG]: https://support.apple.com/guide/garageband/glossary-gbnda1db69fd/mac
[AG]: https://support.apple.com/en-us/102171
[LB]: https://support.apple.com/guide/logicpro/bounce-a-project-to-an-audio-file-lgcp785a41c3/mac
[L3]: https://support.apple.com/guide/logicpro/mp3-bounce-options-lgcp8314da07/mac
[LL]: https://support.apple.com/guide/logicpro/loudness-meter-lgce12d9d256/mac
[LM]: https://support.apple.com/guide/logicpro/mastering-assistant-parameters-lgcpa4b810ba/mac
[LS]: https://support.apple.com/guide/logicpro/uses-for-remove-silence-lgcp5e08f225/mac
[LD]: https://support.apple.com/guide/logicpro/denoiser-overview-lgcef2cbe4bd/mac
[LC]: https://support.apple.com/guide/logicpro/compressor-side-chain-parameters-lgce0b2501de/mac
[LF]: https://support.apple.com/guide/logicpro/create-fades-on-audio-regions-lgcpf7c0ee6c/mac
[LG]: https://support.apple.com/guide/logicpro/change-gain-audio-regions-tracks-area-lgcp8e4c781d/mac
[LP]: https://support.apple.com/guide/logicpro/punch-in-and-out-of-audio-recordings-lgcpb19bfd0d/mac
[LK]: https://support.apple.com/guide/logicpro/overview-of-flashback-capture-lgcp8f89929b/mac
[LA]: https://support.apple.com/guide/logicpro/use-project-alternatives-and-backups-lgcpa158ef77/mac
[LU]: https://support.apple.com/guide/logicpro/undo-and-redo-edits-lgcp1dbd67ab/mac
[AP]: https://podcasters.apple.com/support/893-audio-requirements
[FV]: ../../.scratchpads/verify/flac-encode/

- [HM] Hindenburg Journalist 1.21 user guide (Hindenburg Systems), hosted by willyurman.com: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HF] Hindenburg PRO features: https://hindenburg.com/products/radio-podcast/features/
- [HC] Hindenburg product comparison: https://hindenburg.com/products/radio-podcast/comparison/
- [HG] Hindenburg PRO guides: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [HT] Hindenburg PRO tracking: https://hindenburg.com/hindenburg-pro-features/tracking/
- [HS] Hindenburg PRO story editing: https://hindenburg.com/hindenburg-pro-features/story-editing/
- [HK] Hindenburg support, record internal sound on Mac: https://hindenburg.uservoice.com/knowledgebase/articles/1982517-record-internal-sound-on-mac-zoom-skype-etc
- [HK2] Hindenburg PRO 2 shortcuts: https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [HA] Hindenburg autosave request: https://hindenburg.uservoice.com/forums/224350-general/suggestions/5736450-autosave
- [HL] Hindenburg, export and loudness standards: https://hindenburg.com/2025-dec-calendar-content-1/december-23/?sector=user
- [HR] Hindenburg PRO release notes: https://hindenburg.com/support/release-notes/hindenburg-series/
- [HX] Hindenburg PRO 2 transcription: https://hindenburg.com/hindenburg-pro-2-features/transcription/
- [TR] Transom review of Hindenburg (secondary source): https://transom.org/2010/hindenburg-review/
- [GM] GarageBand, record to multiple audio tracks: https://support.apple.com/guide/garageband/record-to-multiple-audio-tracks-gbnd5f260581/mac
- [GE] GarageBand, export songs to disk: https://support.apple.com/guide/garageband/export-songs-to-disk-gbnd7cbf5ed9/mac
- [GT] GarageBand, master track and fade out: https://support.apple.com/guide/garageband/work-with-the-master-track-gbnd5e8076d0/mac
- [GG] GarageBand glossary (Noise Gate): https://support.apple.com/guide/garageband/glossary-gbnda1db69fd/mac
- [AG] Apple, aggregate devices: https://support.apple.com/en-us/102171
- [LB], [L3], [LL], [LM], [LS], [LD], [LC], [LF], [LG], [LP], [LK], [LA], [LU] Logic Pro User Guide pages, as linked above.
- [AP] Apple Podcasts audio requirements: https://podcasters.apple.com/support/893-audio-requirements
- [FV] Local evidence: `.scratchpads/verify/flac-encode/s.flac`. `afinfo` reports "flac, 1 ch, 22050 Hz".
