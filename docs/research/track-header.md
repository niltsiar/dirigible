# Track header controls at a tall lane, and the header of a recording track

Date: 2026-10-11

Question: where do Hindenburg PRO and Logic Pro put the header controls of a tall track (at the top or at the center)? Which controls show at which height? How does Hindenburg draw the header of an armed track and of a track that records? GarageBand and Final Cut Pro are added where they help.

Method: official guide pages and their figures, the Hindenburg Journalist 1.21 guide (vendor PDF, text and figures extracted with a Python script, no render), and frames of the official Hindenburg PRO videos (YouTube thumbnails). No app ran for the first pass: a flake loop ran on this Mac. Section 4 adds two on-screen checks in Logic 12.3.1. A sentence that starts with "Observed:" describes a figure or a frame. A sentence that starts with "Inference:" is our reading. "(unconfirmed)" marks a claim that no source shows.

## 1. Vertical place of the header controls in a tall track

| App | Place | Evidence |
|---|---|---|
| Hindenburg PRO | Top. The stack starts at the row top; the free space is below it. | [HJ] p. 8, 14, 19; [V-arm], [V-prep], [V-height] frames |
| Logic Pro | Top at a large zoom. At about 4 times, the name and the control row stay at the row top, and a large track icon fills the free space; the track number stays at the vertical center. At about 1.3 times the block looks centered. | [LZT] figure; [L-screen] |
| GarageBand | No per-track height in the guide. One header height, content centered. | [GZ], [GTH] figure |
| Final Cut Pro | No track header. The lane name is at the top-left of a tall audio lane. | [FL] figure |

### Hindenburg PRO

- Observed: the header is a fixed stack: name field, volume slider, pan slider, a button row (Rec, M, S, FX, a menu triangle), and in PRO also an input route pop-up ("Soundflower", "Built-in Microphone") [V-arm] [V-prep]. The stack is at the top of the row. The rest of the header is empty gray [HJ] p. 14, p. 19.
- Observed: the stack has the same layout at all the heights in the sources. [HJ] p. 8 shows short rows, and p. 14 and p. 19 show tall rows. The stack is at the top in each. In [V-height] (the "View - Increase track height" video) the rows are larger, and the stack stays at the top.
- The [V-prep] frame has the title "Hindenburg Broadcaster", and [V-arm] shows a Soundflower route. These frames show old builds. The header of PRO 2 is unconfirmed in these sources.
- Observed: no figure shows more controls at a larger height, or fewer controls at a smaller height. The behavior of a row that is shorter than the stack is unconfirmed.
- The guide lists the header controls: "Rename Track, Track Volume, Track Balance, Arm Rec, Monitor, Mute, Solo, Effects bin, Voice Profiler" [HJ] p. 44. "Zoom Track Height" makes the tracks larger or smaller [HP-guides] [HJ] p. 95 (keys).

### Logic Pro

- The guide: "move the pointer to the bottom-left corner of a track. ... Drag vertically. The individual track zoom factor ... is shown in the help tag" [LZT]. Control-Z zooms the focused track [LZT].
- Observed: in the [LZT] figure, track 2 is zoomed to about 1.3 times the other rows. Its icon, its name, and its M S R row stay at the vertical center of the row. The track number is also centered. The other rows are centered too.
- Observed: the header has one row of controls at each height in the figure (name above M, S, R, I; volume slider; pan knob) [LTH]. The guide gives no rule that adds or removes a control with the height. The choice of controls is a user setting: Track > Configure Track Header (Option-T) [LTH].
- The figure shows only a small zoom.
- Observed on screen (Logic 12.3.1, [L-screen] `04-zoom4x`): a track zoomed to about 4 times keeps its name, M, S, R, I, the volume slider, and the pan knob at the top of the row. A large track icon fills the space below. The track number stays at the vertical center of the row. The other rows do not change.

### GarageBand

- The Tracks area guide describes only the horizontal zoom sliders: "drag the horizontal zoom sliders, located in the ruler" [GZ]. It gives no per-track height.
- Observed: the [GTH] figure shows the header content (icon, name, buttons, volume, pan) at the vertical center of the row.

### Final Cut Pro

- Final Cut Pro has no track header. "A text label appears at the left side of each audio lane, identifying the role" [FL]. The Lane Headers checkbox keeps the lane names visible: "Always show lane names (so the names aren't obscured by clips)" [FCA].
- Observed: in the [FL] figure, the Dialogue lane holds two rows of clips. Its label is at the top-left of the lane, not at the center.
- The Clip Height slider sets the clip height [FCA].

## 2. The header of an armed or recording track

### Hindenburg PRO

- Arm: "Prepare (Arm) the track for recording. The small meter will show input levels. Arm track > Click 'Arm Rec' in track" [HJ] p. 19. The key is R [HJ] p. 45. Monitor on and off is in the context menu of the Rec button [HJ] p. 46.
- Observed: the Rec button of an armed track has a bright red dot. The dot of a track that is not armed is pale pink [HJ] p. 14, p. 19.
- Observed: on the armed track, the thumb of the volume slider is red. On the other tracks it is white [HJ] p. 19; the same in [V-arm] and [V-prep]. The meaning of the red thumb is unconfirmed.
- Observed: a vertical green meter strip at the edge between the header and the lane shows the input of the armed track [HJ] p. 19.
- Observed: during a take, the new region in the lane is red ("Speak 1"). A finished region is blue [HJ] p. 19 (second figure), p. 14.
- Observed: during a take, the header does not change. The name field, the sliders, and the buttons keep their normal look; nothing is gray. The selected track name has a blue fill, armed or not. No colored bar is at the row edge [HJ] p. 19.
- Whether the route pop-up and the sliders accept a change during a take is unconfirmed.

### Logic Pro

- The Record Enable button has four states: "Off (gray)", "Record-ready (blinking red)", "Recording (solid red)", and "Single track, ready to record (gray with red letter R; appears on the focused track if no tracks are manually record enabled)" [LRE].
- "If Input is set to No Input, the R button is hidden" [LRE].
- Observed: the [LZT] figure shows an armed track with a red R button. The rest of the header keeps its normal look.
- Observed on screen ([L-screen] `05-armed`, `06-recording`): an armed track has a solid red R and a green level inside its volume slider. During a 3 s take the header keeps its normal look: nothing is gray, and no bar is at the row edge. The new region in the lane is dark red while it records, as in Hindenburg.

### GarageBand

- "The Record Enable buttons include a circle that lights red when the track is record-enabled" [GRE].
- Observed: in the [GTH] figure, the volume slider shows a green level bar inside its track.

### Final Cut Pro

- Final Cut Pro records in the Record Voiceover window, not in a track header. The window has the input gain, the meter, the input, and the monitor [FVO].

## 3. What this changes for the header of Dirigible

- Line 1 at the row top from 80 pt: Hindenburg, Logic, and Final Cut Pro support it. The [LZT] figure at about 1.3 times looked centered, but the on-screen check at about 4 times shows the controls at the row top ([L-screen]).
- Inference: Hindenburg puts the stack at the top at every height. Dirigible keeps the center under 80 pt. This is our choice, not a reference behavior: at 80 pt or less, the two lines fill most of the row.
- The take look: Hindenburg and Logic keep the header at its normal look during a take. This supports "no gray row" and "the name keeps the primary color". No source shows a red bar at the row edge. The reference apps show the state on the arm button: Hindenburg lights the dot red, and Logic blinks the R red when ready and makes it solid red during a take.
- Inference: a 3 pt red bar repeats the red R. Hindenburg and Logic draw the live region red in the lane during the take ([HJ] p. 19, [L-screen] `06-recording`). No source shows the bar.
- Open question: the plain route text during a take has no reference. Hindenburg shows the route pop-up; its state during a take is unconfirmed.

## 4. On-screen checks in Logic 12.3.1 (2026-10-11)

1. A track zoomed to about 4 times (a drag at the bottom-left corner of the track header): the controls are at the row top.
2. One armed track, a 3 s take from the built-in microphone: the header keeps its normal look, the R is solid red, and the live region is red. Logic quit with Don't Save; no project or audio file stayed.

## 5. Facts of the UI expert panel

A UI expert panel (one agent each for Hindenburg PRO, Logic Pro, GarageBand, and Final Cut Pro) quoted these pages on 2026-10-11. This file did not fetch them again.

- Logic Pro: "The level meter in a track's Volume slider shows the output volume for the track as the project plays". In the track list, "During playback, each track number is replaced with a small level meter showing the output level" [LTH-10].
- Logic Pro: Vertical Auto Zoom resizes the tracks "so that all tracks are visible, with no blank space" (`docs/research/logic-garageband-update.md`).
- GarageBand: Quick Help shows a short description of the control under the pointer in a yellow bubble, and links to longer help [GQH].
- Final Cut Pro: the Clip Appearance pop-up holds Clip Height, the waveform size, and a Zoom slider [FCA]. View > Vertical Zoom to Fit has the key Option-Shift-Z (`docs/research/macos-ui-shell.md`).
- Final Cut Pro: roles are color labels, and all clips of a role show the role color in the timeline (`docs/research/final-cut-pro.md`).

## Sources

- [HJ] Hindenburg Journalist 1.21 user guide for OS X, pages 8, 14, 19, 44 to 46, 95 (text and figures extracted on 2026-10-11): https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HP-guides] Hindenburg PRO functions and guides: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [V-arm] Hindenburg PRO, "Tracks - Arm Track" video (frame: maxresdefault): https://hindenburg.com/data/youtube/videos/how-to-arm-a-track-in-hindenburg-pro-hindenburg/ (YouTube zglwxhxLa-w)
- [V-prep] Hindenburg PRO, "Record - Arm track" video (frame: maxresdefault): https://hindenburg.com/data/youtube/videos/how-to-prepare-a-track-for-recording-in-hindenburg-pro-hindenburg/ (YouTube a7uHvokmFjE); also the "Record" video frame hq2: https://hindenburg.com/data/youtube/videos/how-to-begin-recording-on-a-track-in-hindenburg-pro-hindenburg/ (YouTube dQl7BuV9-Rk)
- [V-height] Hindenburg PRO, "View - Increase track height" video (frame: hq2): https://hindenburg.com/data/youtube/videos/how-to-make-a-track-larger-in-hindenburg-pro-hindenburg/ (YouTube 00CSEJ7ieWM)
- [LZT] Logic Pro 12.3 User Guide, Zoom tracks, with the figure "Zooming a track in the track header": https://support.apple.com/guide/logicpro/zoom-tracks-lgcpc79f5bcd/mac (figure: https://help.apple.com/assets/697921A0B89A6DAE620D667A/697921A59331DF6F330EFA33/en_US/32e83b2dfbf5f44467d89f5af8c8c119.png)
- [LTH] Logic Pro 12.3 User Guide, Track header overview: https://support.apple.com/guide/logicpro/track-header-overview-lgcpe53c68af/mac
- [LRE] Logic Pro 12.3 User Guide, Make tracks ready for recording: https://support.apple.com/guide/logicpro/make-tracks-ready-for-recording-lgcp0c445ccf/mac
- [GTH] GarageBand User Guide, Intro to track headers: https://support.apple.com/guide/garageband/intro-to-track-headers-gbnd6143101c/mac
- [GRE] GarageBand User Guide, Enable tracks for recording (figure: https://help.apple.com/assets/6837A0663D97F08D11030E14/6837A070079DA7265609910C/en_US/c7aded2971f62a0bcce29a0d081f34a6.png): https://support.apple.com/guide/garageband/enable-tracks-for-recording-gbnd9e804dab/mac
- [GZ] GarageBand User Guide, Scroll and zoom in the Tracks area: https://support.apple.com/guide/garageband/scroll-and-zoom-in-the-tracks-area-gbndd75e5c48/mac
- [FL] Final Cut Pro User Guide, Organize the timeline with audio lanes (figure: https://help.apple.com/assets/6A29F5537442EFE69C0CD4F3/6A29F558FEEBDB01270C8EF2/en_US/e6c0d4ded6a7fc7b2e8bf9795d358148.png): https://support.apple.com/guide/final-cut-pro/organize-the-timeline-with-audio-lanes-verb71cb913/mac
- [FCA] Final Cut Pro User Guide, Adjust timeline clip appearance: https://support.apple.com/guide/final-cut-pro/adjust-timeline-clip-appearance-verb8e5d346/mac
- [L-screen] Logic Pro 12.3.1 on this Mac, 2026-10-11: run folder `logic/04-zoom4x.png`, `logic/05-armed.png`, `logic/06-recording.png` (not in git).
- [FVO] Final Cut Pro User Guide, Record voiceovers: https://support.apple.com/guide/final-cut-pro/record-voiceovers-verc1faa9c5/mac
- [LTH-10] Logic Pro 10.1 help, Track header overview (quoted by the panel): https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcpe53c68af.html
- [GQH] GarageBand User Guide, Quick Help (quoted by the panel): https://support.apple.com/en-mt/guide/garageband/gbnde4c4dcd6/mac
