# Remote transport control in DAWs and editors

Date: 2026-10-26

This file records how Logic Pro, Pro Tools, REAPER, and Hindenburg PRO treat transport commands from a remote controller. It supports the run 2026-10-26-agent-transport (MCP tools play, stop, locate). It adds to `docs/research/timeline-playback.md` and does not repeat it.

Marks: "(unconfirmed)" means that no source says it. "Inference:" starts our own reading. "[excerpt]" means that a search-result excerpt showed the text, but our fetch of the page failed (HTTP 403 or no render).

## Summary

| Question | Logic Pro | Pro Tools | REAPER | Hindenburg PRO |
|---|---|---|---|---|
| 1. Notice of a remote move | None documented. One connect alert only. | None documented. The Transport shows state. | None documented. | No remote interface found. |
| 2. Remote locate or play is an undo step | Not stated. Undo lists "edits". | Unconfirmed. | Not stated. Selections have undo points. | Not applicable. |
| 3. Stop and Play while recording | Stop ends the recording. Play: unconfirmed. | Unconfirmed (pages blocked). | Stop and Play both end it. | Not applicable. |
| 4. Play a range, then stop | Not in the transport list. | Not in the EUCON table. | Not built in (unconfirmed). | Shift-Space plays the selection. |

## 1. Logic Pro

**Control surface (Mackie Control).** The Mackie Control table maps buttons to the same transport functions as the UI: "STOP ... Stop PLAY ... Play SHIFT Pause RECORD ... Record" (the table has an empty modifier column). [LP-MC] Locate: "REWIND << ... MARKER Go to previous marker" and "CYCLE Engage Cycle mode and set left locator to playhead." [LP-MC]

**Logic Remote (iPad).** The control bar has Play, Stop, Record, Cycle, and Go to Beginning.
- "The Stop button stops playback or recording at the playhead position." [LR-BAR]
- "The Record button starts recording at the current playhead position or from the previous record position. To stop recording and stop the playhead, tap the Stop button." [LR-BAR]
- The Settings menu of Logic Remote has its own undo: "a menu where you can undo or redo edits". [LR-BAR]

**Notice to the user.** The pages above describe no banner, badge, or indicator for a transport command from a remote. The one notice is at connect time: "An alert appears in the application on the Mac, asking you to accept the connection." After that, "subsequent connections with the same device should happen automatically." [LR-CONN] Inference: the Mac shows only the normal transport state (play button, playhead).

**Undo.** "Logic Pro for Mac includes an Undo History window with a time-ordered list of all edits that can be undone." The page lists "moves, deletions, renaming, and parameter changes; and the creation of new events, regions, channel strips". [LP-UNDO] It does not name playhead moves or transport (unconfirmed). Inference: a locate or play is not an edit and is not an undo step.

**Stop while recording.** The Stop button "Stops playback or recording. Click a second time to move the playhead to the start of the project, or to the left locator position when in Cycle mode." [LP-TR] The Mackie Control STOP button has the same label. [LP-MC]
**Play while recording.** No source says what Play does during a recording (unconfirmed). The Record button "Starts or stops recording on record-enabled tracks." [LP-TR] Another mode: "Record/Record Toggle: Use to stop recording but to continue playback." [LP-REC]

**Play a range.** "Play from Selection button: Plays from the start point of the first selected region or event." [LP-TR] The text names no stop at the end. "Play from Left Locator" and "Play from Right Locator" also exist, and Cycle mode repeats the area. [LP-TR] Mackie Control has no play-selection button in its table. [LP-MC] Inference: Logic has no standard "play a range and stop at its end" command for a remote.

## 2. Pro Tools with EUCON

The Avid guide "Artist Series and Pro Tools" (EuControl v2.6, 2011) lists the transport controls. [PT-EUCON]
- "Stop: Stops playback." "Play: Starts playback." "Record: Toggles the Pro Tools Transport (master) record state on (armed) or off." (p. 14)
- "Loop: Toggles Loop Playback on and off." "RTZ (Return to Zero): Returns the play cursor to the beginning of the session." (p. 14)
- Computer-keyboard modifiers add modes: "Press Control + Play ... To toggle Loop Playback"; "Option + Play ... To toggle Pro Tools online or offline". (p. 15)
- Record only arms: "To record arm the Pro Tools Transport: Press Record." (p. 15)

**Notice.** The on-screen Transport is the state display: "On-screen, the Pro Tools Transport master Record switch shows the current mode (P indicates QuickPunch, a Loop arrow appears when in Loop Record mode...)" (p. 28). The guide names no remote-specific banner. Inference: only the normal Transport state shows.
**Undo.** No source read says if a remote locate or play is an undo step (unconfirmed). The Avid pages that could say it (avid.com user guide, Pro Tools Reference Guide pages) returned HTTP 403 to our fetch.
**Stop or Play while recording.** The EUCON guide gives "To stop playback: Press Stop" (p. 15) and no recording case (unconfirmed). [excerpt] The Avid loop-recording page says "To cancel all recorded takes during loop recording, press Command+Period (.)". This is a keyboard command, not a Stop button case.
**Play a range.** The EUCON table has no play-selection key. EuControl lets the user assign commands to Soft Keys in a "Soft Key Command Editor" with a "Transport" list (p. 12-13). Whether the list offers Play Edit Selection is unconfirmed. [excerpt] Sound on Sound: a Timeline selection with length "will play just the timeline selection and stop, unless the transport is set to loop". This is a secondary source.

## 3. REAPER (OSC, web remote, ReaScript)

**Remote input is the same as a key press.** "To use an OSC device for basic one-way control input, enable 'allow binding messages to REAPER actions and FX learn'. This will permit OSC messages from this device to be used as action shortcuts ... just like any keyboard or MIDI control input." [RP-OSC]
**Same button code.** The ReaScript API has "OnPlayButton ... direct way to simulate play button hit" and "OnStopButton ... direct way to simulate stop button hit". "GetPlayState ... &1=playing, &2=paused, &4=is recording". [RP-API]
**Notice.** The OSC page and the API page describe no remote notice (unconfirmed). The web-remote page was not found in a primary source (unconfirmed). Inference: only the transport bar and the cursor change.
**Undo.** Preferences list undo points for "item/track selection" and for "loop selection", on by default. [RP-GEN] The list has no entry for transport or edit cursor moves (unconfirmed). The API has "Undo_BeginBlock" and "Undo_EndBlock", so an undo point is something a command opts into. [RP-API] Inference.
**Stop while recording.** "By default, REAPER asks you if you want to save newly recorded media when a recording is ended by pressing the Stop button on the Transport. Clear this check box to make REAPER automatically save the files when Stop is pressed." [RP-REC]
**Play while recording.** The option "On punch-out/play" asks "if you want to save newly recorded media when ... recording is ended by pressing the Play button on the Transport". [RP-REC] So Play also ends a recording. OSC binds to the same actions as the keyboard (above), so a remote Play does the same. Inference.
**Play a range.** "By default, playback will stop playback at the end of the Project (the last Item), or will loop if the loop button is enabled." [RP-PLAY] No primary source names a built-in "play the time selection, then stop" action (unconfirmed). [excerpt] A forum answer names the SWS extension action "Toggle stop playback at end of time selection". SWS is third party.

## 4. Hindenburg PRO

**Remote or control surface.** The Hindenburg sitemap (fetched 2026-10-26) lists transport function pages and "remote interview" pages (call recording). It lists no page for MIDI, Mackie, OSC, or a control surface. [HB-MAP] A web search for such support returned no Hindenburg result. Support is unconfirmed; no source says it exists. The article [KB-remote] of the old file is about a remote editor (a person).
**Play Selection in PRO 2.**
- The official video "Transport - Play Selection": "Select a region in your session to listen back to. Apple Shortcut: Shift spacebar". [V-playsel]
- The official video "Transport - Loop Selection": "Solo the track and Loop the selection in your session. Apple Shortcut: Shift spacebar". [V-loop] Both give Shift-Space (the old file records this conflict).
- [excerpt] The PRO 2 shortcuts page lists "Transport - Play selection" as "Solo's the track and plays the selction". The page does not render in our fetch ("Unable to render grid fragment").
- Result: PRO 2 sources confirm that Shift-Space plays the selection. The shortcuts page adds that the track is solo [excerpt]. No PRO 2 source says "and stops at the end". The only "plays the selected area and stops" is in the Windows Journalist guide, version 1 [HW]. For PRO 2, the stop is unconfirmed.
- [excerpt] A "Loop on Play Selection" preference may exist in Narrator. It is unconfirmed for PRO 2.
- Stop: "Spacebar toggles Play & Stop." [V-stop]

## 5. Reading for the agent transport tools

- Inference: Logic, Pro Tools, and REAPER show a remote command only as normal transport state. No source shows a remote banner. No source tests "an agent moves the playhead while the user edits".
- Inference: play, stop, and locate need no undo step. Logic undo lists edits; REAPER undo points cover selections and edits.
- Stop while recording ends the recording in Logic and REAPER. Play also ends it in REAPER. An agent Play during a recording needs our own rule (unconfirmed for Logic and Pro Tools). Decided on 2026-11-24: an agent call during a take throws `.busy` and never stops the take (decision 0016, amended by 0046).
- "Play a range and stop" is not a standard remote command in Logic, EUCON, or REAPER. Hindenburg Shift-Space is the closest model, and its stop at the end is unconfirmed for PRO 2. Open question: probe the PRO 2 app, or set our own rule.

## Sources

Fetched on 2026-10-26 unless marked [excerpt].

- [LP-MC] Apple, Mackie Control transport buttons in Logic Pro: https://support.apple.com/guide/logicpro-css/ctls7222788e/mac
- [LR-BAR] Apple, Logic Remote on iPad control bar overview: https://support.apple.com/guide/logicremote-logicpro-ipad/control-bar-overview-chs60f9de4ad/ipados
- [LR-CONN] Apple, Connect Logic Remote on iPad: https://support.apple.com/guide/logicremote-logicpro-ipad/connect-logic-remote-chsa0054e974/ipados
- [LP-TR] Apple, Control playback in Logic Pro: https://support.apple.com/guide/logicpro/control-playback-with-the-transport-buttons-lgcp0b07c0c9/10.7/mac/11.6.1
- [LP-REC] Apple, Advanced recording commands in Logic Pro: https://support.apple.com/guide/logicpro/advanced-recording-commands-lgcpb19d5875/mac
- [LP-UNDO] Apple, Undo and redo edits in Logic Pro: https://support.apple.com/guide/logicpro/undo-and-redo-edits-lgcp1dbd67ab/mac
- [PT-EUCON] Avid, Artist Series and Pro Tools Guide, EuControl v2.6 (PDF hosted by De Montfort University): https://mat.our.dmu.ac.uk/wp-content/uploads/sites/8/2017/09/Artist_Series_and_Pro_Tools_v2_6.pdf
- [excerpt] Avid loop recording: https://www.avid.com/pro-tools/user-guide/loop-recording ; Sound on Sound: https://www.soundonsound.com/node/4932129
- [RP-OSC] Cockos, REAPER OSC: https://www.reaper.fm/sdk/osc/osc.php
- [RP-API] Cockos, ReaScript API: https://www.reaper.fm/sdk/reascript/reascripthelp.html
- [RP-REC] Cockos wiki, Preferences Audio Recording (Wayback copy): https://web.archive.org/web/2024/https://www.cockos.com/wiki/index.php/Preferences_Audio_Recording
- [RP-PLAY] Cockos wiki, Preferences Audio Playback (Wayback copy): https://web.archive.org/web/2024/https://www.cockos.com/wiki/index.php/Preferences_Audio_Playback
- [RP-GEN] Cockos wiki, Preferences General (Wayback copy): https://web.archive.org/web/2024/https://www.cockos.com/wiki/index.php/Preferences_General
- [excerpt] SWS action: a REAPER forum thread found by search; not fetched.
- [HB-MAP] Hindenburg sitemap: https://hindenburg.com/sitemap
- [V-playsel] https://www.youtube.com/watch?v=omRxhdChenc ; [V-loop] https://www.youtube.com/watch?v=X2O4uqz-8VI ; [V-stop] https://www.youtube.com/watch?v=umS5Io84ys0 (official Hindenburg channel, video descriptions)
- [excerpt] Hindenburg PRO shortcuts: https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [HW], [KB-remote]: as in `docs/research/timeline-playback.md`.
