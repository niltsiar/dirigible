# Logic Pro and GarageBand: features the first catalog missed

Date: 2026-09-27

This document adds to `docs/research/podcast-features.md` (F01 to F67). It lists only the Logic Pro and GarageBand behavior that the first catalog, `edit-commands.md`, `mouse-edits.md`, and `timeline-view.md` do not record. The focus is Release 2: clip gain, fades, crossfades, ripple edit, snap, import, autosave, and the window layout. The local apps are Logic Pro 12.3.1 and GarageBand 10.4.14. The Logic Pro User Guide pages are for version 12.3. A claim that no primary source confirms has the mark "(unconfirmed)". A sentence that starts with "Inference:" is our reading of the sources. The value, effort, and release values are our estimates, on the scale of the first catalog.

New feature IDs start at F80. The Final Cut Pro research uses IDs from F68. The Release column gives the release of the Release 2 plan (2026-09-27, `docs/requirements/releases.md`).

## 1. Changes to existing catalog rows

These facts change or complete a row of the first catalog. They do not need a new ID.

- **F30 auto level.** Logic "Normalize Region Gain" (Control-Option-G) has a Method menu with "Peak or Loudness". The Target Level is in dB (Peak) or LUFS (Loudness). A Process menu processes "all regions … equally, regions … equally per track, or regions … individually". The command is nondestructive [LN]. The first catalog says "Normalize regions to peak". That is out of date. Dirigible: add the "equally per track" mode to F30. It keeps the level ratio between the clips of one speaker and levels each speaker to the target.
- **F31 clip gain.** The Gain tool shows the gain "as a yellow line across the region" with a dB readout. A marquee selection limits the change "only to the selection". Option-click resets to 0 dB [LG]. The Region inspector has a Gain field in dB [LRP]. Dirigible: keep the dB readout during the drag and a reset gesture.
- **F32 and F33 fades.** A fade has a length, a curve, and a type. The curve is positive, negative, or linear. The Fade Out types are "Out", "X (Crossfade)", "EqP (Equal Power Crossfade)", and "X S (S-Curved Crossfade)". EqP "minimizes volume dips between audio regions" [LFE]. The "Apply Last Fade or Fade Marquee Selection" command reads a marquee selection. It makes a fade out, a fade in, or an equal-power crossfade "with the crossfade pivot on the region junction" [LF]. Option-click with the Fade tool removes a fade [LFD]. Dirigible: use equal power as the default crossfade. It matches the Hindenburg Cmd-F on a selection (F32). The Shift-Control drag with the Pointer tool for a fade is not in the current guide (unconfirmed). The guide gives the Fade tool click zones instead (section 3).
- **F40 loudness meter.** The Logic Loudness Meter has M, S, and I values, an LU Range, and a "Target level line" from -30 to 0 LUFS. "A meter turns yellow when the measured loudness exceeds the target loudness line." Start and Pause measure the integrated value "for a portion or the full length" [LL]. Dirigible: show the export target as a line on the meter.
- **F54 loudness at export.** GarageBand has "Export projects at full volume": it exports "at the highest volume level (0 dBFS) at which no distortion occurs" [GAD]. This is a peak normalization. It confirms the "(unconfirmed)" GarageBand cell of F54.
- **F61 import.** Logic has a project setting "Convert audio file sample rate when importing" [LSR]. The Save dialog chooses to copy assets into the project or to reference them [LSV]. Copy/Convert sets "the sample rate, bit depth, file format, stereo conversion, and dither type" [LCC]. Dirigible: always copy an imported file into `Clips/` and convert it to the session rate. A reference to a file outside the package can go missing.
- **F62 autosave and backups.** Logic autosaves and asks at reopen if you want "the autosaved version" [LSV]. Each Cmd-S keeps a backup, "up to ten backups per alternative". File > Revert to lists the backups "from newest to oldest" [LA]. An "Auto Backup" setting sets the count. A "Save undo history with project" setting keeps the undo steps after a reopen [LPH]. Dirigible: show the backups in a "Revert to" submenu.
- **F63 templates.** GarageBand 10.4.14 on this Mac has six project templates. One is "Voice". None is a podcast template [GBL]. The audio patches have a "04 Voice" group with "Narration Vocal" [GBL]. Dirigible: a two-person interview template with the call preset (F06) fills this gap.
- **F64 shortcuts.** The Logic Key Commands window has presets, import, export, and filters that show "Conflicts" and "Unused" commands. Control with a menu command opens the window at that command [LKC] [LKS]. Dirigible: when F64 comes, a conflict filter is the most useful part.
- **F07 punch-in.** In Logic, a record after a marquee selection turns on Autopunch at the selection. "All tracks within the marquee selection are record-activated" [LMQ]. Dirigible: use this for F07 in Release 3. A range on one track re-records only that range on that track.

## 2. New features

| ID | Feature | Logic/GarageBand behavior | Dirigible use | Keep/Adapt/Skip | Why | Value | Effort | Release | Source |
|---|---|---|---|---|---|---|---|---|---|
| F80 | Drag mode per session: overlap, no overlap, auto crossfade, shuffle | A Drag menu in the Tracks area menu bar. Overlap "preserves the current region borders". No Overlap shortens the earlier region. X-Fade crossfades the overlap. Shuffle R and Shuffle L close the gap on move, resize, and delete; a drop on a region swaps the two | A drag that closes gaps is ripple edit with the mouse. An auto crossfade removes the click at a butt splice | Adapt | Two modes cover the podcast cases: the Release 1 overwrite, and Shuffle L (ripple). Auto crossfade can be a switch. Shuffle R and the region swap are music tools | 4 | M | 3 | [LDM] [LXF] |
| F81 | Close gaps between the selected clips | Edit > Move > Shuffle Left (Option-[): "The first selected region on each track remains unchanged, and all subsequent selected regions are moved to the left." Shuffle Right is Option-] | After many deletes with gaps (Release 1), one command closes all gaps in a track | Keep | Release 1 deletes leave gaps. This command repairs an edit made before ripple edit came | 3 | S | 3 | [LGP] [LKT] |
| F82 | Snap to clip edges with an alignment guide | GarageBand: yellow guides appear when a region edge aligns with another region, and the region snaps to it (Option-Command-G). Logic: a Snap menu (Smart, Bar, Beat, Frames, Samples, Off); Control-Shift drag snaps to samples | Butt a clip against the clip before it with no gap and no overlap | Adapt | Snap to clip edges, markers, and the playhead helps a podcaster. A bar or beat grid does not | 4 | S | 3 | [GAG] [GKS] [LSN] |
| F83 | Zoom toggle and zoom history | Z toggles "Zoom to Fit Selection or All Contents". Shift-Z stores a navigation snapshot. Option-Z and Option-Shift-Z go back and forward. The Zoom tool (Control-Option drag) zooms to a drawn area; a click on the background goes back a zoom step | Fit a selected answer, then go back to the full episode with one key | Adapt | Release 1 has fit zoom and zoom to selection. The toggle and "back" are cheap and save many key presses | 3 | S | 2 | [LKW] [LZW] [LCT] |
| F84 | Clip inspector with numeric gain and fades | The Region inspector has Gain in dB, Fade In, Fade Out, Curve, and the fade type. The values change with a vertical drag or a typed value. Many selected regions change together | Type -3 dB or a 500 ms fade on all selected clips | Adapt | Mouse gestures do not give exact values. A small panel or popover is enough; Dirigible does not need the full Logic inspector | 3 | M | 2 | [LRP] [LF] [LIN] |
| F85 | Height of one track and width of the track headers | Drag the lower-left corner of a track to zoom that track. Control-Z zooms the focused track. Drag the divider to resize all track headers | Make the host track tall for detailed edits and keep the music bed short | Adapt | Release 1 has one lane height for all tracks. Per-track height is useful but not needed for a first podcast release | 2 | S | 2 (header width), Later (height of one track) | [LZT] [LTH] |
| F86 | Help tags that show the key equivalent | Logic help tags show the key command of a command. Quick Help shows a short description in the inspector, a floating window, or bubbles at the pointer (Shift-/) | Teach the Hindenburg keys to a new user | Adapt | A macOS tooltip with the key is cheap. A Quick Help system is a large writing task in two languages (R13) | 2 | S | Later | [LKC] [LQH] [LKG] |
| F87 | Remove unused clip files | GarageBand: File > Clean Up Project deletes unused audio files. Logic: the Project Audio Browser shows unused regions in red, and Select Used finds the used files | Make a session package smaller after many retakes | Adapt | It deletes audio, so it needs a confirm step and an undo path. The no-data-loss rule makes it Release 3 at the earliest | 3 | S | 3 | [GCU] [LPA] [LCC] |
| F88 | Session alternatives | File > Project Alternatives: named snapshots of a project that share the same assets, for "different cuts or mixes". Each has its own backups | Keep a 30-minute cut and a 60-minute cut of one episode | Adapt | Useful for radio versions. Duplicate of the session package does most of it today | 2 | M | Later | [LA] |
| F89 | Render a range through an effect | Selection-based processing applies audio effects to selected regions or a marquee selection, with preview, and can make a new take | Remove noise or hum only in one bad range | Adapt | It fits R8 noise reduction on part of a clip. It needs the DSP of Release 3 | 3 | M | 3 | [LSP] |
| F90 | Lock a track | GarageBand: the Lock button prevents record and edits on the track; a swipe locks many tracks | Protect the finished music bed during the voice edit | Keep | A flag in the session and a guard in the edit commands | 2 | S | Later | [GLK] |
| F91 | Take folders and comps for punch-in | Cycle recording makes a take folder. Quick Swipe Comping selects the best parts of several takes into one comp | Keep the old version of a re-recorded intro | Adapt | Useful with F07 punch-in. For speech, one take per punch and undo is enough at first | 2 | L | Later | [LTK] [LCO] [LCS] [GTK] |
| F92 | Time display format and a large time window | The LCD shows Beats, Time, or Custom. A "giant time display" opens in a floating window. The time format can show milliseconds, frames, or samples | A large clock that the host can read across the room during a recording | Adapt | Only h:mm:ss matters for speech. A large clock during a take is a small, visible gain | 2 | S | Later | [LLCD] [LCB] |
| F93 | Customizable toolbar | Control-click the toolbar or control bar, then "Customize". "Save As Default" and "Restore Defaults" | Hide the buttons that a user does not use | Adapt | `NSToolbar` gives user customization almost free. It needs a fixed set of toolbar items first | 2 | S | 2 | [LTB] [LCB] |

## 3. Behavior that confirms Dirigible choices

- **Click zones.** Logic has "Fade Tool Click Zones": the pointer over "the upper-left and upper-right edges of a region" gives the Fade pointer. "Marquee Tool Click Zones": the pointer over "the lower half of a region" gives the Marquee pointer [LAT] [LES]. This is the same layout as Hindenburg (fade corners, selection in the lower part, mouse-edits.md section 1). Decision 0020 has a range in the lower third. Put the fade handles in the upper corners in Release 2.
- **Marquee.** The Marquee tool selects "only the part of the region inside the marquee". After an edit, the selected area becomes a new region. Playback after a marquee selection starts at its left edge and stops at its right edge. A "marquee ruler" under the ruler selects across all tracks. Shift-click on a track removes it from the selection [LMQ]. Dirigible has a range selection (decision 0018). Consider the stop at the range end for play.
- **Delete.** Logic has "Delete and Move" and "Delete and Select Next Region/Event" [LDR]. The first is ripple delete (F20). Logic asks before it deletes the audio file of a region recorded in this session, and never for an imported file [LDR]. Dirigible never deletes a captured file with a clip delete. Keep that rule.
- **Cut and insert time.** "Cut Section Between Locators" and "Insert Silence Between Locators" change all tracks, or only the selected regions [LGP]. This is the all-tracks ripple of F20.
- **Zoom anchor.** "When you zoom with a mouse or trackpad, the zoom centers on the pointer, except when the pointer is in close proximity to the playhead, in which case the zoom centers on the playhead." A pinch zooms [LSZ] [LZW]. Timeline-view.md section 3 leaves the anchor open. Use this rule.
- **Auto zoom.** Vertical Auto Zoom resizes the tracks "so that all tracks are visible, with no blank space" when you add or delete tracks [LAZ]. It matches the Hindenburg Narrator "Automatic track height" (timeline-view.md section 1).
- **Tracks area layout.** The Tracks area menu bar holds the tool menus, a Catch Playhead button, the Snap and Drag menus, a Waveform Zoom button, and the zoom sliders [LTA]. GarageBand puts the zoom slider in the ruler and has a Catch button for each editor [GSZ] [GCA]. Inference: the Snap and Drag menus sit next to the lanes, not in the main toolbar.
- **Track header.** Track > Configure Track Header (Option-T) chooses the buttons, volume and pan, track numbers, color bars, and icons [LTH]. Dirigible: fixed headers are enough until the header has more than arm, mute, solo, and a meter.
- **Overview strip.** Logic for Mac has no mini timeline in the Tracks area (unconfirmed absence). The only "Overview" is a Touch Bar screen: regions as thin lines, a view rectangle, and the playhead [LTBS].

## 4. Skipped

| Feature | Logic/GarageBand behavior | Keep/Adapt/Skip | Why | Source |
|---|---|---|---|---|
| Tool menu (Pointer, Scissors, Glue, Mute, Solo tools) | A Left-click and a Command-click tool; T shows the Tool menu; each tool has a letter key | Skip | Hindenburg edits in one view with cursor zones. Modes add errors for a speech editor | [LAT] [LKM] [LCT] |
| Snap to zero crossings | "Snap Edits to Zero Crossings" in the Audio Track Editor prevents a click at an edit | Skip | A short fade at each split (F32) removes the click and does not move the edit | [LZC] |
| Speed Up and Slow Down fades | A fade that changes the playback speed | Skip | A tape effect for music | [LFE] |
| Slip and Rotate tools | Move the content inside a fixed region | Skip | A trim at each end does the same for speech | [LCT] |
| Mastering Assistant | Character presets, Auto EQ, a Loudness knob with the center "around –14 LUFS-I", a limit at "–1 dBFS True Peak" | Skip | Music mastering. F54 already exports at a podcast target and a true-peak limit | [LM] |
| Stem Splitter | Extracts "vocals, drums, bass, guitar, piano, and other" stems. Apple silicon only | Skip | Built for music mixes. R14 bleed removal needs a different method | [LSS] |
| Session Players, Smart Controls | Virtual players; screen controls for a patch | Skip | Music tools. Dirigible has one-dial controls per track (F35, F36) | [LCT] [GSC] |
| Track stacks | Folder stacks (a VCA master) and summing stacks (a bus) | Skip | F24 track groups covers the need. Few podcast sessions have more than eight tracks | [LST] |
| 32-bit float recording | GarageBand: "you can remove any digital clipping that occurred during the recording by simply lowering the gain" | Skip | The converter of the device clips before the app. Release 1 records 24-bit (R6). An app source (R12) can deliver float over 0 dBFS (unconfirmed); probe it in the R12 run | [GAD] |
| Force Touch gestures | A force click adds an audio file to a track | Skip | Not discoverable; menus and drag and drop do it | [LES] |

## Sources

[LDM]: https://support.apple.com/guide/logicpro/control-positioning-with-drag-modes-lgcpf7c0a2ec/mac
[LF]: https://support.apple.com/guide/logicpro/create-fades-on-audio-regions-lgcpf7c0ee6c/mac
[LFE]: https://support.apple.com/guide/logicpro/edit-fades-lgcpf7c0cd53/mac
[LXF]: https://support.apple.com/guide/logicpro/create-automatic-crossfades-lgcp9260fa9c/mac
[LFD]: https://support.apple.com/guide/logicpro/delete-fades-lgcpf7c0d973/mac
[LG]: https://support.apple.com/guide/logicpro/change-gain-audio-regions-tracks-area-lgcp8e4c781d/mac
[LN]: https://support.apple.com/guide/logicpro/normalize-audio-regions-in-the-tracks-area-lgcp663fdd13/mac
[LRP]: https://support.apple.com/guide/logicpro/audio-region-parameters-lgcpf7c0af60/mac
[LMQ]: https://support.apple.com/guide/logicpro/select-parts-of-regions-lgcpf7c0ae21/mac
[LSN]: https://support.apple.com/guide/logicpro/snap-items-to-the-grid-lgcpf7c0f66a/mac
[LZC]: https://support.apple.com/guide/logicpro/snap-edits-to-zero-crossings-lgcp76a73399/mac
[LSZ]: https://support.apple.com/guide/logicpro/scroll-and-zoom-in-the-tracks-area-lgcpf7c0b924/mac
[LAZ]: https://support.apple.com/guide/logicpro/automatically-zoom-the-tracks-area-lgcpf0ff2737/mac
[LZW]: https://support.apple.com/guide/logicpro/zoom-windows-lgcp5cbf2096/mac
[LZT]: https://support.apple.com/guide/logicpro/zoom-tracks-lgcpc79f5bcd/mac
[LKW]: https://support.apple.com/guide/logicpro/various-windows-lgcp665bbccc/mac
[LKT]: https://support.apple.com/guide/logicpro/main-window-tracks-and-various-editors-lgcpe8314fe2/mac
[LKG]: https://support.apple.com/guide/logicpro/global-commands-lgcp02bf31b6/mac
[LKM]: https://support.apple.com/guide/logicpro/tool-menu-lgcp0182c4e5/mac
[LKC]: https://support.apple.com/guide/logicpro/key-commands-overview-lgcp32e85cd9/mac
[LKS]: https://support.apple.com/guide/logicpro/browse-import-and-save-key-commands-lgcp68d9ced1/mac
[LCB]: https://support.apple.com/guide/logicpro/customize-the-control-bar-lgcp5bdd6d9d/mac
[LLCD]: https://support.apple.com/guide/logicpro/change-lcd-display-mode-logic-pro-mac-lgcp127f51bc/mac
[LTB]: https://support.apple.com/guide/logicpro/customize-the-toolbar-lgcp0591f74d/mac
[LTH]: https://support.apple.com/guide/logicpro/track-header-overview-lgcpe53c68af/mac
[LIN]: https://support.apple.com/guide/logicpro/inspector-interface-lgcpe9cc3b1d/mac
[LTA]: https://support.apple.com/guide/logicpro/tracks-area-interface-lgcpe9cc3f60/mac
[LAT]: https://support.apple.com/guide/logicpro/assign-tools-lgcp5b365bf4/mac
[LCT]: https://support.apple.com/guide/logicpro/common-tools-lgcp8b7459e4/mac
[LES]: https://support.apple.com/guide/logicpro/editing-settings-lgcp35dc6d37/mac
[LA]: https://support.apple.com/guide/logicpro/use-project-alternatives-and-backups-lgcpa158ef77/mac
[LSV]: https://support.apple.com/guide/logicpro/save-projects-lgcpce128e82/mac
[LPH]: https://support.apple.com/guide/logicpro/project-handling-settings-lgcp43defb63/mac
[LCC]: https://support.apple.com/guide/logicpro/move-copy-and-convert-audio-files-lgcp757ec334/mac
[LSR]: https://support.apple.com/guide/logicpro/set-the-project-sample-rate-lgcpce0958b8/mac
[LGP]: https://support.apple.com/guide/logicpro/add-or-remove-gaps-lgcp21e2cb21/mac
[LDR]: https://support.apple.com/guide/logicpro/delete-regions-lgcpf7c0bd98/mac
[LQH]: https://support.apple.com/guide/logicpro/how-to-get-help-lgcpa0902aeb/mac
[LL]: https://support.apple.com/guide/logicpro/loudness-meter-lgce12d9d256/mac
[LM]: https://support.apple.com/guide/logicpro/mastering-assistant-parameters-lgcpa4b810ba/mac
[LTK]: https://support.apple.com/guide/logicpro/record-multiple-audio-takes-lgcpb19806af/mac
[LCO]: https://support.apple.com/guide/logicpro/comping-overview-lgcp317d758e/mac
[LCS]: https://support.apple.com/guide/logicpro/create-and-save-comps-lgcpb193382e/mac
[LST]: https://support.apple.com/guide/logicpro/track-stacks-overview-lgcp9bc4b63d/mac
[LSS]: https://support.apple.com/guide/logicpro/extract-vocal-instrumental-stems-stem-lgcp61bae908/mac
[LSP]: https://support.apple.com/guide/logicpro/use-selection-based-processing-lgcp58245be1/mac
[LPA]: https://support.apple.com/guide/logicpro/project-audio-browser-overview-lgcp4d74f378/mac
[LTBS]: https://support.apple.com/guide/logicpro/touch-bar-shortcuts-lgcp94a1c475/mac
[GAG]: https://support.apple.com/guide/garageband/position-items-using-alignment-guides-gbnd5456b51d/mac
[GKS]: https://support.apple.com/guide/garageband/main-window-shortcuts-gbnd58362a62/mac
[GSZ]: https://support.apple.com/guide/garageband/scroll-and-zoom-in-the-tracks-area-gbndd75e5c48/mac
[GCA]: https://support.apple.com/guide/garageband/keep-the-playhead-visible-gbnd8dd71c1a/mac
[GLK]: https://support.apple.com/guide/garageband/lock-tracks-gbnd912c7f78/mac
[GCU]: https://support.apple.com/guide/garageband/clean-up-projects-gbndde92315b/mac
[GAD]: https://support.apple.com/guide/garageband/change-advanced-settings-gbnded6e79bc/mac
[GTK]: https://support.apple.com/guide/garageband/choose-and-delete-takes-gbnd5fa82adf/mac
[GSC]: https://support.apple.com/guide/garageband/smart-controls-overview-gbndfd8fa312/mac

- All [L*] pages are the Logic Pro User Guide for Mac, version 12.3, read on 2026-09-27. All [G*] pages are the GarageBand User Guide for Mac, read on 2026-09-27. The URLs are above.
- [GBL] Local evidence, read-only: `/Applications/GarageBand.app/Contents/Resources/Project Templates/NewProject/` holds `01 Keyboard Collection.band`, `02 Amp Collection.band`, `03 Voice.band`, `05 Hip Hop.band`, `06 Electronic.band`, and `07 Songwriter.band`. `/Applications/GarageBand.app/Contents/Resources/Patches/Audio/04 Voice/` holds `Narration Vocal.patch` and 14 other voice patches. GarageBand 10.4.14, Logic Pro 12.3.1 (`CFBundleShortVersionString`).
