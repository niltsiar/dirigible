# Timeline playback and editing in Hindenburg PRO 2

Date: 2026-09-24

This document records how Hindenburg PRO 2 plays, selects, and edits audio on the timeline. It also records the Apple facts for a playback engine on AVAudioEngine. It adds to the key table in `docs/research/podcast-features.md` and does not repeat it.

The sources have three levels:

- The Hindenburg Journalist 1.21 manual for macOS [HM] and the Journalist guide for Windows [HW]. They are for version 1.
- The Hindenburg PRO 2 sources: the release notes [HR], the support knowledge base [KB-*], and the video descriptions of the official Hindenburg channel [V-*]. Each "Hindenburg PRO" function page on hindenburg.com shows one of these videos. The description gives the Apple key.
- The Apple developer documentation [A-*] and the AVFAudio headers of the macOS 26.2 SDK [A-H].

The PRO 2 shortcut page [SH] did not show its content on 2026-09-24. The page shows "Unable to render grid fragment". The Wayback Machine copies have an empty `<main>` element. A claim that no primary source confirms has the mark "(unconfirmed)". A sentence that starts with "Inference:" is our reading of the sources.

## PRO 2 keys that add to or change the 1.21 table

| Command | PRO 2 key | 1.21 key | Source |
|---|---|---|---|
| Play the selection | Shift-Space | Shift-Space is "stop at the start point" and also "loop selection" | [V-playsel] [HM] |
| Loop the selection (solos the track) | Shift-Space | Shift-Space | [V-loop] [HM] |
| Rehearse (play and skip the selection) | Control-Shift-Space | Control-Shift-Space | [V-rehearse] [HM] |
| Pre-roll | P | Cmd-P on p. 16, P on p. 94 | [V-preroll] [HM] |
| Record | Cmd-Space in four videos, Control-Space in one video | Control-Space | [V-rec] [V-record] [HM] |
| Arm the track | Shift-R | R (Shift-R in the Windows guide) | [KB-remote] [HM] [HW] |
| Rewind, forward the playhead | Left Arrow, Right Arrow | Same | [V-rew] [V-fwd] |
| Next or previous event (splice or marker) | Page Up, Page Down, or Tab, Shift-Tab | Page Down, Page Up, Tab | [V-event] [HM] |
| Select a range on the region | I and O, or Cmd-1 and Cmd-2 | Same | [V-inout] [HM] |
| Marquee selection of regions | Shift-drag | Not in the manual | [V-marquee] |
| Select the regions to the end, to the start (track) | Shift-End, Shift-Home | Same | [V-selend] [V-selhome] [HM] |
| Select the regions to the end (all tracks) | Shift-Option-End | Not in the manual | [V-selendall] |
| Trim the region start, end to the playhead | Q, W | Not in the manual | [V-top] [V-tail] |
| Redo | Shift-Cmd-Z | Cmd-Y | [V-redo] [HM] |
| Insert silence, delete silence | Cmd-Right Arrow, Cmd-Left Arrow | Same | [V-inssil] [HM] |
| Nudge a region | Cmd-arrow keys | Not in the manual | [V-nudge] |
| Snap a region to the nearest event | Shift-Cmd-Right Arrow, Shift-Cmd-Left Arrow | Not in the manual | [V-snap] |
| Set marker 3 to 0 | Cmd-3 to Cmd-0 | Cmd-1 to Cmd-0 in the "Alt 1" column | [V-set30] [HM] |
| Rename a marker | Shift-Return | Return | [V-mrename] [HM] |
| Add a cue point (locked to the audio) | Option-Cmd-Return | Not in the manual | [V-cue] |
| Select the right side after a split | Shift-Cmd-B | Not in the manual | [R2544] |

Note: macOS uses Cmd-Space for Spotlight by default (unconfirmed on the target Mac). The PRO 2 videos disagree on the Record key. Test Cmd-Space and Control-Space before a key is chosen. Settled on 2026-11-24: Record is Command-R (`MenuKeys.record`), and Play is Space (`MenuKeys.play`).

## 1. Transport

- **Space** toggles play and stop in 1.21 and PRO 2 [HM] [V-play] [V-stop].
- No source says where the playhead stays after Space stops playback (unconfirmed). 1.21 has a separate command "Stop playback at start-point" on Shift-Space [HM]. Inference: plain Space stops at the current position.
- **Shift-Space** has two meanings in the 1.21 manual: "stop at start point" and "loop selection" [HM]. The Windows guide calls it "Play Selection" and says it "plays the selected area and stops" [HW]. In PRO 2, two videos give Shift-Space for "play a selection" and "loop a selection" [V-playsel] [V-loop]. PRO 2 does not document "stop at the start point" (unconfirmed).
- **Home and End.** In PRO 2, Home "returns the playhead to the beginning of your session", and End goes to the end [V-home] [V-end]. The 1.21 manual is not consistent. Page 10 gives Home and End for the start and the end. The table on page 94 gives Home and End for the first and last splice, and Cmd-Delete (Backspace) for the start [HM]. On Windows, PRO 2 build 2624 moved "Return to Zero" to Control-Backspace [R2624].
- **Recording start.** Recording starts at the playhead: "Set the playhead where the recording will begin" [HW]. Space stops the recording [HW].
- **Playhead after a recording stops.** No source says if the playhead goes to the end or to the start of the new recording (unconfirmed).
- **Record while playing.** Pre-roll recording plays from before the in point, then punches in at the in point [V-prerec]. Build 2604 fixed "missing audio playback when using pre roll" [R2604]. Punch-in recording "manually punch in to record on a specific region" [V-punch]. No source says if the other tracks play during a recording (unconfirmed). In 1.21, the user can play clips and session audio during a Skype call recording [HM p. 21]. Page 23 says that, when the call records to the workspace, only clipboard clips play [HM].
- **Edit while playing.** No source says if the user can edit during playback (unconfirmed).
- PRO 2 saves the playhead time in the session file (build 2610) [R2610].
- PRO 2 can recover a session that crashed during a recording (build 2610) [R2610].

## 2. JKL shuttle

- 1.21 keys: J rewinds at normal speed, L goes forward at normal speed. Shift-J and Shift-L are slow. K+J and K+L are fast: hold K down [HM p. 17]. The numeric keypad gives the same six speeds: 1 and 3 slow, 4 and 6 normal, 7 and 9 fast [HM].
- PRO 2 keeps JKL "at different speeds" and the numeric keypad keys [V-jkl] [V-num]. Since build 2724, JKL also works in the Manuscript [R2724]. Cmd with the mouse scrubs [V-mouse] [HM].
- The manual calls J "Rew" in the "Scrub" section [HM]. No primary source says if J plays the audio backward or skips back (unconfirmed). A teaching tip sheet says "J (reverse) and L (forward) ... Hold them down to play the audio" [TS]. This is a secondary source.
- Repeated presses of J or L: no source describes speed steps (unconfirmed). The documented speeds come from modifiers (Shift for slow, K for fast), not from repeated presses.
- Build 2572 "Ignored auto-repeating keyboard shortcuts" [R2572]. Inference: JKL is a hold-to-scrub control, not a latched shuttle.
- K alone: no documented command (unconfirmed). No source describes a pause that differs from stop (unconfirmed).
- Vari-speed: Period toggles it, Shift-Period speeds up, Shift-Comma slows down [HM]. The PRO 2 page "Transport - Vari-speed" exists but has no video text [SH].

## 3. Selection

- **Drag.** The cursor becomes an I-beam on the lower half of a region. Drag to select a range [HM p. 26] [V-drag].
- **In and out points.** I and O set the in point and the out point at the playhead. Cmd-1 and Cmd-2 do the same. Keys 1 and 2 go to the in point and the out point [HM] [V-inout].
- **Several tracks.** A selection spans tracks. Cmd-click adds a track to the selection. Shift-click extends the track selection. Cmd-A selects all tracks [HM p. 27] [HW].
- **Cmd-A differs in PRO 2.** A PRO 2 video says Cmd-A selects "all the regions on one track" [V-selall]. The 1.21 table gives Cmd-A for "All Track" and for "All Regions in Track", and Option-Cmd-A for all regions in the session [HM p. 95].
- **Regions.** Click a region to select it. Cmd-click adds a region. Shift-click extends the region selection [V-region] [V-cmdclick] [V-shiftclick].
- **Triple-click.** A triple-click on the blank area between regions selects it and sets the in and out points [HM p. 27] [V-between]. Since build 2644, a triple-click on a region sets the in and out points around it. A double-click selects the silence between words [R2644].
- **Region header** (build 2724): a double-click selects all connected regions. A triple-click selects all regions on the track [R2724].
- **Esc** clears the selection. A double-click on an empty area of the workspace also clears it [V-esc] [HM]. In 1.21, a triple-click between the "ghosted" in and out lines selects the range again [HM p. 26].

## 4. Edit commands on a selection

- **Cut (Cmd-X)** deletes the selection and closes the gap [HM p. 28]. "All following regions on the track will subsequently move to the left." The guide warns about the sync between tracks [HW]. Inference: Cut ripples only the tracks in the selection.
- **Clear (Delete or Backspace)** deletes the selection and keeps the gap [HM p. 29]. "No other regions are affected" [HW]. PRO 2 keeps Backspace for this command [V-clear]. On Windows, build 2624 changed Backspace to Delete [R2624].
- **Region Cut** (PRO 2) makes "a cut to a region without affecting the following regions" [V-regcut].
- **Reverse Cut** (PRO 2) moves the audio "from the left to the right" and keeps the script timecode [V-revcut].
- To close a gap, triple-click it and use Cut [KB-gap].
- **Copy (Cmd-C)** puts the selection in memory [V-copy].
- **Paste (Cmd-V)**: put the playhead, then paste. Paste "places selection ON TOP of existing audio" [HM p. 29]. It overwrites, and it does not push audio [HW] [V-paste]. The target is "the track" [HW]. No source says how Hindenburg chooses the track (unconfirmed).
- **Paste in selection (Cmd-V with a selection)** fills the selection from the copied audio, for example with room tone [HM] [V-pastesel].
- **Insert (Cmd-I)** pushes the later audio on the track to the right [HM p. 30] [HW] [V-insert].
- **Split (Cmd-B)** splits at the playhead. With in and out points, it splits at both points [HM p. 28] [HW] [V-split]. No source says if Split acts on the selected track only or on all tracks (unconfirmed).
- **Undo** is Cmd-Z in both versions [HM] [V-undo]. Redo is Cmd-Y in 1.21 and Shift-Cmd-Z in PRO 2 [HM] [V-redo].

## 5. Navigation, zoom, markers, chapters

- **Previous and next region:** Shift-Left Arrow and Shift-Right Arrow. In PRO 2 this "will also highlight the region under the playhead" [V-nextreg] [HM].
- **Previous and next event** (splice or marker): Page Up and Page Down, or Tab and Shift-Tab [V-event].
- **Zoom:** Cmd-plus zooms in, Cmd-minus zooms out, and Cmd with the mouse wheel zooms too [V-zoomin] [V-zoomout] [HM]. H zooms to the selection in 1.21 [HM]. A tip sheet says H zooms "to selection (and back)" [TS]. The PRO 2 page "View - Zoom selection" has no video text (unconfirmed for PRO 2).
- **Zoom to fit** in 1.21: Cmd-Apostrophe centers, Shift-Apostrophe fits the session [HM p. 96]. The Windows guide gives Shift-Asterisk for "fit to screen" and Control-Asterisk for "center playhead" [HW]. Track height: Shift-Cmd-plus and Shift-Cmd-minus [HM].
- **Add a marker:** Cmd-Return in both versions [HM] [V-marker].
- **Go to a marker:** keys 3 to 0. A double-click on a marker in the Markers list moves the playhead to it [V-goto] [HM]. In and out points are always markers 1 and 2 [HM].
- **Set marker 3 to 0:** Cmd-3 to Cmd-0 in PRO 2 [V-set30].
- **Rename, delete:** Shift-Return renames and renumbers in PRO 2 [V-mrename] [V-renumber]. Return renames in 1.21 [HM]. Delete removes a marker [V-mdelete].
- **Markers view:** Option-Cmd-M [V-markers].
- **Cue points** (PRO 2, Option-Cmd-Return) are "locked to the audio and not the timeline" and follow the edits [V-cue]. Build 2604 added "Convert Markers to Cue Points" [R2604].
- **Markers on the timeline:** markers go "to the Timeline in Workspace" [HM]. They show "above a region" [R2604]. Other visual details are unconfirmed.
- **Chapters:** Shift-Cmd-Return adds a chapter at the playhead in both versions [HM p. 61] [V-chapter]. Option-Cmd-H opens the Chapters view [V-chapters]. A chapter has a time, a title, an image, and a URL [HM]. A right-click on a marker converts it to a chapter [HM p. 62].

## 6. Missing media

- A session is a `name.nhsx` file and a `name Files` folder that holds the audio [KB-blank] [KB-migrate].
- If the folder moves, Hindenburg asks the user to "locate missing audio files" [KB-missing]. It asks the user to point to the Files folder again [KB-blank].
- If the user cancels, "the session will open with blank regions with red outlines" [KB-blank].
- The user can right-click one region and point it to the correct file [KB-blank]. PRO 2 shows a "Locate file" dialog (build 2558) [R2558]. A relink keeps the transcription when the new file has the same length (build 2552) [R2552].
- iCloud "Optimize Mac Storage" can also cause blank regions. The fix is to download the files [KB-icloud].
- PRO 2 build 2724 added a "Delete unused files" option [HR].

## 7. Waveforms

- No primary source says if Hindenburg stores waveform or peak cache files, or where (unconfirmed).
- The documented user files are the `.nhsx` file and the Files folder of audio [KB-blank]. The documented settings in `~/Library/Application Support/Hindenburg` are `Profiles`, `Publish.xml`, `Favorites.xml`, `Favorites`, `Audio Files`, and `Config.xml` [KB-migrate]. The list has no peak cache.
- A "Temp Folder" preference holds "temporary session files" [HM p. 75], or "the temporary audio" [HW].
- The waveform is rectified: only the top half shows. Light tops show the peaks. The dark middle shows the RMS value [KB-wave].
- View > Waveforms has "Enable" and "Peaks Only" [HM p. 18] [V-wave] [V-peaks]. The manual says to turn waveforms off on older computers "to free up CPU power" [HM p. 18].

## 8. Transport bar

- 1.21 transport bar (View > Toolbars > Transport): Play, Stop, Record, Forward, Rewind, Beginning, End, and the vari-speed controls [HM p. 10].
- PRO 2 keeps View > Toolbars > Transport "for playback, recording and toggling" [V-transport]. It has loop and pre-roll icons: build 2572 fixed them in Light mode [R2572]. The full button list is unconfirmed.
- The counter shows the playhead time and the selection time. Option-G goes to a time [HM p. 10] [V-counter]. The Windows counter also shows the in point time and the out point time [HW]. The time format is unconfirmed.
- A separate Clock toolbar shows the time of day [HM] [V-clock].
- No source documents a remaining record time for the disk (unconfirmed). The 1.21 Call Recorder shows "Running Time", the length of the current recording [HM p. 22].

## 9. Apple facts for AVAudioEngine

- **No reverse on AVAudioPlayerNode.** The class has no rate or direction property of its own [A-PN]. The inherited `rate` of `AVAudio3DMixing` has the range 0.5 to 2.0, and "only the AVAudioEnvironmentNode class implements this property" [A-3D]. No Apple page or header mentions reverse play or a negative rate [A-PN] [A-H]. Scheduling fails if "a segment's start frame or frame count is a negative value" [A-PN]. Inference: to play backward, schedule buffers with the samples in reverse order.
- **AVAudioUnitVarispeed.rate:** default 1.0, range 0.25 to 4.0. It resamples, so the pitch changes with the rate [A-VS]. For comparison, `AVAudioUnitTimePitch.rate` has the range 1/32 to 32.0 [A-TP].
- **Manual rendering for tests.** `enableManualRenderingMode(.offline, format:maximumFrameCount:)` disconnects the engine from audio devices. The app drives the rendering [A-ENG] [A-MR]. Stop the engine before the call. The format must be PCM [A-MR]. `.offline` operates "without any realtime constraints" [A-H]. `renderOffline(_:to:)` needs the engine in offline mode and started. The buffer format must match the render format. On exit, `frameLength` gives the rendered frames [A-RO] [A-H]. The manual-rendering timeline starts at sample time 0 [A-H]. With a player node, use the completion handlers and `lastRenderTime` to track the rendered data [A-PN].
- **AVAudioEngineConfigurationChange** (Swift `Notification.Name.AVAudioEngineConfigurationChange`). The engine posts it when its I/O unit sees a change to the input or output hardware channel count or sample rate [A-CC]. Before the post, the engine stops [A-H]. The web page adds that it uninitializes itself [A-CC]. The nodes stay attached and connected with the old formats. The app must reconnect if a format must change [A-CC]. The handler runs on an internal dispatch queue. Do not deallocate the engine in the handler, because it can deadlock [A-CC].
- **Completion callback types** [A-CB] [A-H]:
  - `.dataConsumed`: the player consumed the data. The old `scheduleBuffer(_:completionHandler:)` is equal to this type [A-H].
  - `.dataRendered`: the player rendered the data. It does not include downstream latency.
  - `.dataPlayedBack`: the data finished playing. It includes the engine latency and the device latency. It applies only when the engine renders to or from a device.
- **Callbacks at stop().** The handler is called "after the player schedules the buffer for playback on the render thread, or the player stops" [A-SB]. The header adds: "It is possible for the completionHandler to be called before rendering begins or before the buffer is played completely" [A-H]. Thus `stop()` calls the handlers of the buffers that did not play. No source says which callback type value these handlers get (unconfirmed).
- `stop()` clears all scheduled events and resets the player sample time to 0 [A-STOP]. `pause()` stops the player sample time but keeps the events [A-PAUSE].
- Do not call `stop()` in a completion handler, because it can deadlock [A-PN]. The callbacks arrive on a thread that is not the main thread [A-H].
- Buffer options: `.interrupts` stops the buffer that plays. `.loops` loops the buffer [A-OPT].

## Sources

Hindenburg manuals and knowledge base:

- [HM] Hindenburg Journalist 1.21 user guide for macOS (Hindenburg Systems), hosted by willyurman.com: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HW] Hindenburg Journalist guide for Windows (Hindenburg Systems): http://hindenburgsystems.com/wordpress/wp-content/uploads/2010/07/Hindenburg-Journalist-Guide-Windows.pdf
- [SH] Hindenburg PRO 2 shortcuts (empty on 2026-09-24): https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/ ; function pages from https://hindenburg.com/sitemap
- [KB-blank] Blank regions: https://hindenburg.uservoice.com/knowledgebase/articles/1882393-blank-regions
- [KB-missing] Missing audio files or no sound: https://hindenburg.uservoice.com/knowledgebase/articles/680065-missing-audio-files-or-no-sound
- [KB-icloud] Blank regions and no audio, Mac: https://hindenburg.uservoice.com/knowledgebase/articles/1835575-blank-regions-and-no-audio-mac
- [KB-wave] Why do the waveforms look the way they do: https://hindenburg.uservoice.com/knowledgebase/articles/1958584-why-do-the-waveforms-look-the-way-they-do-in-hinde
- [KB-gap] Delete the gray space between regions: https://hindenburg.uservoice.com/knowledgebase/articles/290757-i-can-t-figure-out-how-to-best-delete-the-gray-spa
- [KB-remote] Working with a remote editor: https://hindenburg.uservoice.com/knowledgebase/articles/2021958-working-with-a-remote-editor
- [KB-migrate] Migrating all settings to a new computer: https://hindenburg.uservoice.com/knowledgebase/articles/1947400-migrating-all-settings-to-a-new-computer
- [TS] Hindenburg tip sheet for audio editing, Will Yurman (secondary source): https://www.willyurman.com/teaching/handouts/Hindenburg_Audio_Tips.pdf

Hindenburg PRO 2 release notes ([HR] is the list; [Rnnnn] is build nnnn at `https://hindenburg.com/release-notes-hindenburg-pro_version-2/<page>/`):

- [HR] https://hindenburg.com/support/release-notes/hindenburg-series/
- [R2544] pro-v2_build-2544, [R2552] pro-v2_build-2552, [R2558] pro-v2_build-2558, [R2572] pro-v2_02-build-2572, [R2604] pro-v2_02-build-2604, [R2610] pro-v2_02-build-2610, [R2624] pro-v2_03-build-2624, [R2644] pro-v2_04-build-2644, [R2724] pro-v2_05-build-2724

Official Hindenburg video descriptions (https://www.youtube.com/watch?v=<id>), shown on the hindenburg.com function pages:

- Transport: [V-play] RRvWjBGfUyE, [V-stop] umS5Io84ys0, [V-playsel] omRxhdChenc, [V-loop] X2O4uqz-8VI, [V-rehearse] 4hfLrmcPOKk, [V-preroll] DlosiGi0vXU, [V-home] Zjy6wuliYzw, [V-end] GGU-spElQCw, [V-rew] UDOj9Noy5ns, [V-fwd] j_pxufK3iPI, [V-transport] rxxT2NrYJps, [V-counter] f6ByWR2YAGc, [V-clock] qrYswsH-anc
- Record: [V-record] dQl7BuV9-Rk, [V-rec] 0hSqtR4H8uY, [V-punch] YMEf8BsRM-o, [V-prerec] hPlhV0thILo
- Scrub: [V-jkl] bgq_HM4IATg, [V-num] QgN67uctglY, [V-mouse] 2LYqBFFrkZY
- Selection: [V-drag] P8YW91vfCH8, [V-inout] sx-JseHItFU, [V-marquee] VRmxSBgB8XM, [V-between] T1XCGa50_E0, [V-esc] yCQOGO7gUME, [V-selall] bsRWLrWqJCY, [V-region] 47ExzZPf1ZU, [V-cmdclick] WdeTWfpnKBY, [V-shiftclick] ZjNVRss8hm8, [V-selend] sX3HVRQzhcE, [V-selhome] tVPBaOW2ZBw, [V-selendall] Gm4fd4aL-48
- Edit: [V-copy] TWkLl4FaAqc, [V-paste] l76NLrkHIZo, [V-pastesel] 8ymtzwA2EG0, [V-insert] JtqonU8FRIw, [V-clear] eaALdtdc1bw, [V-regcut] capnM9CNBHs, [V-revcut] NY4H95e6eQM, [V-split] LgX_53lS27E, [V-undo] RXqlZZsxiiE, [V-redo] r0yK39jqTC4, [V-top] Y5Rjnf0DGNk, [V-tail] pwa_R4UtyT0, [V-inssil] YrvtabRPCGQ, [V-nudge] L0jW1X95rQA, [V-snap] O4pvSwPF5Qo
- Navigation and view: [V-nextreg] epwl3FLuoW0, [V-event] K55VYJ2YL4s, [V-zoomin] Nsnt3yF2FUk, [V-zoomout] AvAtqWWL1qk, [V-wave] WEm8PBOB0FQ, [V-peaks] C45ZhqutWv8
- Markers and chapters: [V-marker] wd4SjWBdloM, [V-set30] JWBjvJ9L0Eo, [V-goto] QQFSIAzHYf0, [V-mrename] _WZeKsFj_1g, [V-renumber] LuhZf1wXPLA, [V-mdelete] JFz6EDEBKso, [V-markers] f4f-DI995fg, [V-cue] xKtpbRSWIUY, [V-chapter] KCh_qgwUBH0, [V-chapters] _inn9JToMGU

Apple (https://developer.apple.com/documentation/avfaudio/<path>):

- [A-PN] avaudioplayernode
- [A-STOP] avaudioplayernode/stop()
- [A-PAUSE] avaudioplayernode/pause()
- [A-SB] avaudioplayernode/schedulebuffer(_:at:options:completioncallbacktype:completionhandler:)
- [A-CB] avaudioplayernodecompletioncallbacktype
- [A-OPT] avaudioplayernodebufferoptions
- [A-3D] avaudio3dmixing/rate
- [A-VS] avaudiounitvarispeed/rate
- [A-TP] avaudiounittimepitch/rate
- [A-ENG] avaudioengine
- [A-MR] avaudioengine/enablemanualrenderingmode(_:format:maximumframecount:)
- [A-RO] avaudioengine/renderoffline(_:to:)
- [A-CC] avaudioengineconfigurationchangenotification
- [A-H] Local headers `AVAudioPlayerNode.h` and `AVAudioEngine.h` in `MacOSX.sdk` 26.2 (Xcode 26), `System/Library/Frameworks/AVFAudio.framework/Headers/`
