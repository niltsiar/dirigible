# Gain envelope, track roles, and ducking in reference apps

Date: 2026-10-18

This file is reference material for the run `2026-10-18-envelope-ducking`. It records how reference apps do three things: a gain envelope on a clip (F75), a role on a track (F72), and ducking of music under speech (F34). It adds to `docs/research/podcast-features.md` (rows F31, F34, F38), `docs/research/final-cut-pro.md` (section 6), `docs/research/auto-level-reference-apps.md` (Magic Levels), and `docs/research/session-formats.md` (Hindenburg `<Fade>`). It does not repeat them.

## How to read this file

- **Grades.** **P** is a primary source: a vendor manual, a vendor help page, a vendor API page, or a standard. **S** is a secondary source: a blog, a tutorial, a reverse-engineering note. **U** is a user post.
- **"Unconfirmed"** means that no source answers. A sentence that starts with "Inference:" is our reading, not a source.
- **Quotes.** Inside a quote, a key arrow is written as the word "Up or Down arrow", the infinity sign as "-inf", and a Mac key symbol as its name. An inner quote mark in a vendor quote is a single quote. These are the only changes to quoted text.
- **Math.** Numbers marked "computed" come from the formula named next to them. No probe, build, or app run was done. Only web pages were read.
- **Versions.** The Apple guides now online are Final Cut Pro 12.4, Logic Pro 12.3, and GarageBand 10.4.14. The task named FCP 11.x and Logic 11. The text of the pages read here may differ from the 11.x text. The Hindenburg PRO 2 pages have no version in their text.
- **Fetch limits.** Adobe help pages refuse a direct fetch. The Adobe quotes come from dated Internet Archive copies. The Hindenburg PRO 2 shortcut page draws its table with script, so key-to-function pairs come from a fetch summary and are not fully certain.

## 1. Hindenburg PRO 2.x (and Journalist)

No Hindenburg PRO 2 user manual exists online as text or PDF. The Academy "Functions & Guides" page is a list of short descriptions and video links; the video pages have no text [HAG]. The only manuals with steps are the Journalist 1.21 guide for macOS [HJ121] and an older Journalist guide for Windows [HJW]. The numbers below that come from them are for old versions.

### 1.1 The model: no points, a gain line on the clip

- "Hindenburg does not operate with traditional 'rubber bands' for volume editing. Volume editing is done to the region it self. So to edit a specific area, just make a selection and drag the top (gain) line." [HJ121 p.31] (P, v1.21)
- "This can be used for 'Ducking' ambience or music under Narration - or to volume edit peaks in an interview." [HJ121 p.31] (P)
- The user cannot see or add free volume points in these guides. Unconfirmed for PRO 2: no PRO 2 source describes a point on the gain line.

### 1.2 Clip gain with the top handle

- Drag the top handle (the gain line) of a region. A tooltip shows the current level and the gain change, for example "-4.8 dB = current level" and "(-2,3) = gain change made by user" [HJ121 p.31] (P).
- "Reset the level > double-click on the Top line" [HJ121 p.31] (P).
- Key: "Gain: Shift Ctrl Up or Down arrow" [HJW p.18] (P, old). The PRO 2 shortcut page lists "Shift + Ctrl arrow up/down" for "Volume - Volume - Gain" [HSC] (P, key pairing from a fetch summary).
- A caption in the Windows guide says "Add gain (15 dB) to a selection by dragging the selection upwards" [HJW p.19] (P). It is an example. A gain limit is unconfirmed.

### 1.3 Range gesture: select, then drag the gain line

- Duck: "Creating a 'Duck' will automatically create fade 'Handles'. You can adjust the handles at any time. 1. Make a selection > set in/out markers 2. 'Duck' selection > Drag top 'Handle'" [HJ121 p.32] (P).
- Windows guide, Ducking: "Make a selection to a region. Drag the gain handle to alter the volume on the selection. Gain: Shift Ctrl Up or Down arrow (place playhead inside selection)" [HJW p.18] (P).
- Slope (the same guide): "Drag the gain handle OUTSIDE the selection to alter the volume on the selection. Gain: Shift Ctrl Up or Down arrow (place playhead OUTSIDE selection)" [HJW p.19] (P). The Journalist 1.21 guide calls the outside drag "Shelving": "fading down a region and keeping a continues level" [HJ121 p.32] (P).
- Result: the range gain is not a split. The region stays one region. Inference: the range gain becomes fade handles on the same region. This matches the stored form in finding 1.8, but no source says that the UI writes it. Not checked in the app.

### 1.4 Add, move, and delete

- A fade handle sits at each corner of a region. "Fade > Drag Corner Handles", "Slope fade > Shift Drag Corner Handles", and "Fade > Cmd F" fades a selection [HJ121 p.31, p.33] (P).
- "Hold Shift and drag" adjusts the slope handles [HJW p.20] (P). The Academy text says "Fade slope is used to make a more gradual fade" [HAG] (P).
- A duck is edited by its handles: "You can adjust the handles at any time" [HJ121 p.32] (P).
- Delete of a part of a duck: unconfirmed. The only reset in the sources is a double-click on the top line [HJ121 p.31] (P).

### 1.5 Curve between two levels

- Measured on PRO 2.05.2718: "The curve is a raised-cosine S, not a straight line." The fit: cosine 0.29 dB RMS error; a straight line 1.04 dB, up to 2.06 dB wrong mid-ramp. "Same shape up and down." [NHSX sec. 7] (S, reverse-engineering with renders from Hindenburg).
- Unconfirmed: whether the cosine is applied to the amplitude or to the dB value. The note measures in dB RMS and does not say.
- The vendor does not name the curve in any page read [HAG] [HFE] [HSE].

### 1.6 Ramp length at a range edge

- Unconfirmed. The vendor pages and the old guides say that the Duck creates handles. They do not give a length or a default.
- The sample in [NHSX sec. 7] uses `Length="01.666"` for both ramps. This is a test value that the note author chose. It is not a default.

### 1.7 The Duck command

- Menu: "Volume - Duck". The Academy text: "Lower the volume of music or Ambience under the Narration." and "'Duck' is typically used for 'ducking' music under narration. This can also be used for ambient beds or voice over." [HAG] (P).
- Key: "Shift + D" is listed for "Volume - Volume - Duck" and for "Edit - Copy & Duck" [HSC] (P, pairing unconfirmed). "Copy a 'Duck' from a Selection and paste the 'Duck' on to a new Selection." [HAG] [HSC] (P).
- Default depth in dB: unconfirmed. Default ramp lengths: unconfirmed.
- A 2018 forum request describes the manual work: "selecting many regions and dragging each level down while watching a small target-level window". The poster asks for a preset target level [UV34] (U). Inference: in 2018 the depth was set by the drag, with no preset. Not checked in PRO 2.

### 1.8 What Hindenburg stores

- Confirmed by [NHSX sec. 7] (S, measured on PRO 2.05.2718). A `<Fade Start Length Gain>` child of a `<Region>` is a ramp to a level, and it stays at that level.
  - "A fade is a ramp *to* the `Gain` level, and it stays there." A 2.5 s ramp to -11.2 dB held for 26 s; the body of the region rendered 12.02 dB quieter.
  - "Without `Gain`, the ramp returns to unity (gain 1.0)."
  - "`Start`/`Length` are region-relative seconds; `Gain` is in dB. Multiple `<Fade>` children follow one another and do not sum. A ramp longer than the region is cut at the region end, not slowed."
  - Example: `<Fade Start="02.500" Length="01.666" Gain="-10"/>` then `<Fade Start="10.834" Length="01.666"/>`. The first child ducks to -10 dB. The second returns to unity. This is the shape of a duck. This is the source that `session-formats.md` already cites. No second source exists, so it is not an independent confirmation.
- Region gain: "`Gain` ... region gain and track fader **stack**" [NHSX sec. 6] (S). The same note: "`ClipGain` wins and does not sum with `Gain`", and the UI action that writes `ClipGain` is unknown.
- The `session-formats.md` claim "raised-cosine ramps to a level" is confirmed by this source. The grade is S, not P. The vendor does not publish the format.

### 1.9 Magic Levels auto duck

- The vendor says: "Reduces microphone bleed", "Applies loudness-based gain riding", "Automatically ducks music under speech", "Designed for efficient dialogue mixing without manual automation passes." [HFE] (P). Also: "Just select the desired regions and click." and Magic Levels can "'duck' voice and music tracks, auto-mix multiple recordings seamlessly" [HSE] (P).
- How it knows music from voice: unconfirmed. The only related text is for Auto Level: "Speech and music are detected automatically." [HFE] (P). No page says that Magic Levels uses the same detector.
- A per-track type or role setting: unconfirmed. The Auto Level targets are per region type: Narration -21 LUFS and Music -23 LUFS in EU mode [HJ121 p.42, quoted in `auto-level-reference-apps.md`] (P, v1.21).
- Depth, attack, release: unconfirmed.
- Shortcut: "Shift Ctrl L" for Magic Levels [HSC] (P).
- Whether it writes fades, gain, or something else: unconfirmed.

## 2. Final Cut Pro

### 2.1 Range volume change

- Steps: select the clip; choose **Range Selection** (key R); drag across the area; "Drag the horizontal control in the timeline up or down" or choose **Modify > Adjust Volume > Silence (-inf)**. "Keyframes are automatically created along the adjustment points within the range." [VO] [KF] (P, FCP 12.4).
- The guide names the use: "This is useful for ducking audio (temporarily lowering the volume). Ducking is usually applied to one type of audio (such as music or effects) to give prominence to other audio playing at the same time (such as dialogue or narration)." [VO] (P).
- Where the keyframes sit: the Mac guide says only "along the adjustment points within the range". The iPad guide is more exact: "Keyframes are added at the beginning and end of the range, and the audio waveform and volume curve in the range become taller or shorter. You can adjust the keyframes individually, if necessary." [VOI] (P).
- The ramp length at the range edge: unconfirmed. Neither guide gives a length. A search excerpt from a third-party page said that four keyframes are added. A primary page did not confirm this. Unconfirmed: the keyframe count on the Mac.
- Modify > Adjust Volume > Absolute "sets the volume across the entire selection to one dB level, and any keyframe adjustments are deleted". Relative "adjusts the volume by the same amount throughout the selection, preserving any fades or other keyframe adjustments." [VO] (P).

### 2.2 Keyframes and interpolation

- Add: Option-click on the volume line, or Option-K (at the playhead position). Move: drag left or right. Delete: select the keyframe and press Option-Shift-Delete. Keyframes are "white diamonds" [KF] (P).
- Adjust all keyframes at once: Command-Option and drag [KF] (P).
- "If you adjust the volume between two keyframes, the volume line slopes to show the change in volume between the keyframes." [VO] (P). The iPad guide: "During playback, the volume ramps up or down as the playhead approaches the keyframe, then ramps up or down after the keyframe." [VOI] (P).
- Linear in dB or linear in amplitude: unconfirmed. No Apple page read states the domain or the curve. A third-party page says only that FCP "will automatically adjust the value from point A to point B across time" [KRO] (S).
- The volume line is in dB, and the readout shows dB while you drag [VO] (P).

### 2.3 Fades

- Handles in the top-left and top-right corners of the waveform. The default duration is "one half-second", set in the Editing settings [FA] (P).
- Shapes by Control-click on the handle: Linear, S-curve, +3dB, -3dB. "+3dB ... This is the default setting." [FA] (P). "Fades complement any volume adjustments you've already made" [FA] (P).

### 2.4 Roles

- Roles are "metadata text and color labels that you assign to clips". On import, FCP "automatically assigns one of five default color-coded roles (Video, Titles, Dialogue, Music, and Effects) to each clip". Example: "a green Music role" for a file with a Music genre tag [RI] (P).
- The audio roles are Dialogue, Music, and Effects. Roles carry subroles. The assignment is on the audio component, as a subrole [RA] (P).
- The default for audio files with no metadata is Dialogue: "Final Cut Pro assigns the Dialogue role to natural sound recordings (with no additional metadata)" [RA] (P). The user can force one role for an import session in the Import settings.
- Assign: **Modify > Assign Audio Roles**, the shortcut menu, the Audio inspector (Audio Configuration), the browser Roles column, the Info inspector, or the timeline index [RV] (P).
- Color: the role editor has a Change Color button per role. "You can't rename the default roles (Titles, Video, Dialogue, Effects, Music, and Mixed Audio)." [RC] (P). The default hues are not listed in the pages read, except green for Music [RI]. Unconfirmed: the hues of Dialogue and Effects.
- Roles also give timeline "audio lanes" and stem export [RI] (P). No source says that FCP ducks by role. The ducking in FCP is a manual range edit.

### 2.5 Keyframes in a trimmed part

- Question of plan gate 1 (2026-10-18): does FCP keep the keyframes in the part that a trim removes, so that an extend plays them again? Unconfirmed. The Mac guide 12.4 trim pages [TR] [ES], "Adjust volume" [VO], and "Keyframe audio effects" [KF], the iPad guide 3.4 [ESI] [VOI], and the FCPXML reference [FXT] [FXK] do not say it.
- Closest Apple text, which does not decide it: "`start` The start of an element's local timeline used to schedule its contained and anchored items." [FXT] (P). The `keyframeAnimation` page gives "`time` The keyframe time" and does not name the timeline [FXK] (P).
- Inference: if a keyframe `time` is in the local time of the clip, a trim that changes `start` keeps the keyframes. Only a test in FCP can prove it; no test ran. Decision 0060 does not cite FCP for this rule.

## 3. Logic Pro and GarageBand

### 3.1 Logic Pro: volume automation points (guide for 12.3)

- Add: click the curve; double-click an empty area of the automation track; click with the Pencil tool. Click in an empty automation track: "adds an automation point at the project start position, using the current fader value." [LA3] (P).
- Move: drag a point up or down for the value, left or right for the time. Hold Control while dragging a group of points "to make finer adjustments" [LP] [LA2] (P).
- Delete: double-click the point; select it and press Delete; drag the Eraser tool across it. Several points: select with the Pointer, Automation Select, or Marquee tool, then press Delete [LD] (P).
- Range of points: drag across the automation track; the group shows as a gray bar. Dragging the group moves the times or the values together [LA2] (P).
- Add points at a range: with the Marquee tool, "drag across a region ... then click the marquee selection" adds points at the marquee borders [LA3] (P). Option-Shift while dragging a selection across a curve adds "one automation point at each selection border". Control-Option-Shift adds "two automation points at each selection border" [LA3] (P).
  - So one range with the two-point command gives four points: two at each border. The spacing of the two points at one border is unconfirmed.
- Curve between two points: "an automation curve between two automation points represents continuously changing parameter values". The default line is straight on screen; no page names the interpolation. Bend a curve with the Automation Curve tool, or Control-Shift drag with the Pointer. Option-click turns a segment into a step [LSEL] (P). Domain (dB or amplitude): unconfirmed.
- Ramp time: select two adjacent points and Option-Shift-drag to change "the ramp time" [LSEL] (P). Two points at the same time make a vertical line, an "instant on" or "instant off" type of effect [LSEL] (P).
- Automation settings has a "Ramp Time" slider for a moved region border. It sets the time for the value to return to the point that is there [LAS] (P). No default value is given.

### 3.2 Logic Pro: region gain versus automation

- Region gain: select the **Gain tool**, hold the pointer over a region or make a marquee selection in it. "A yellow line appears in the region or regions, and the gain is displayed numerically in dB. Drag the pointer vertically to increase or decrease the gain." Option-click resets to 0 dB [LG] (P). A marquee selection edits only that part. Inference: the Gain tool on a marquee splits the region. The page does not say so. Not checked.
- Automation is a separate layer. Track automation stays "tied to the initial point on the track"; region automation moves with the region [LVS] (P). The track Volume fader stays separate from the region gain [LG] (P, as in `auto-level-reference-apps.md`).

### 3.3 GarageBand for Mac 10.4.14: automation

- Add: click an empty automation track (a point at the project start with the fader value); click the curve or double-click an empty area to add a point. "Command-click, then drag along the automation lane" draws a curve. "Option-Command-click, then drag" draws steps [GBA] (P).
- Move: drag up or down, left or right. Control-drag for fine steps [GBA] (P).
- Select: click; Shift-click to add; "Drag in the background of the automation track" selects consecutive points. Delete: double-click a point, or select and press Delete [GBS] (P).
- No marquee range that adds points. No page names the curve between points. Unconfirmed.
- Track volume: a Volume slider in the track header; Option-click returns to 0 dB [GBV] (P).

### 3.4 GarageBand ducking

- The GarageBand 10.4.14 user guide has no ducking page. The table of contents on each guide page lists every page of the guide, and no entry has "duck" in it [GBS] (P, absence). Inference: GarageBand 10.4 has no ducking. Not checked in the installed app. See the open questions.
- GarageBand '09 had it. Steps from third-party guides: **Control > Ducking** adds a control with up and down arrows to each track header; the up arrow marks a lead track, the down arrow a backing track; "whenever there is sound on a lead track, the volume of the backing tracks is lowered"; the **Ducker** effect on the master track is edited in Track Info [WIN] [LIN] (S, search excerpts of the pages).
- The removal: "Many users were disappointed to learn the apps podcasting tools had been removed in the new version" (GarageBand 10) [MAC] (S). That page does not name ducking.

## 4. Adobe Audition, Premiere Pro, Descript, and others

### 4.1 Audio types

- Essential Sound has four types: Dialogue, Music, Sound Effects, and Ambience. Clips with no type are "Un-tagged" [APD] [AAD] (P).
- Ducking is set on the clip that is ducked. Premiere: "You can duck clips tagged as Music and Ambience." [APD] (P, Jan 2026). Audition: assign "the Music audio type"; then a "Ducking" group appears [AAD] (P, 2017).

### 4.2 Auto-Duck parameters

| Parameter | Meaning in the vendor text | Default | Source |
|---|---|---|---|
| Duck Against | Icons for the types that trigger ducking: Dialogue, Music, Sound Effects, Ambience, Un-tagged clips. One or several. | Unconfirmed | [APD] [AAD] (P) |
| Sensitivity | "the threshold at which the ducking triggers". "Higher or lower sensitivity settings result in fewer adjustments"; middle values "trigger more adjustments where the music comes in and out quickly between pauses in speech". | Unconfirmed | [APD] [AAD] (P) |
| Duck Amount (Audition 2017: "Reduce By") | "how much to reduce the volume of your music clip". A slider; the unit is not stated in the vendor text. | Unconfirmed | [APD] [AAD] (P) |
| Fade Duration (Audition 2017: "Fades") | "how quickly the volume adjustment occurs". "Faster fades are ideal when mixing fast music with fast speech, while slower fades are more appropriate when ducking background music behind voiceover tracks." One value for the fade down and the fade up. | Unconfirmed | [APD] [AAD] (P) |
| Fade Position | "outside the dialogue, inside, or in the middle" | Unconfirmed | [APD] (P) |

- Two third-party tutorials say the duck amount is in dB and the fade length is in milliseconds [LJ] [CRU] (S). No default value appears in any page read.
- Audition analysis is on the audio, not on the clip edges: "Auto-Ducking analyzes the audio signal inside each clip and adjusts the music appropriately" [AAD] (P).

### 4.3 It writes keyframes that the user can edit

- Premiere: "When you enable ducking, Premiere adds an Amplify Effect to the clip. Keyframes computed by the Auto Ducking algorithm are added to this effect's gain parameter so that they can easily be changed or removed without interfering with your other sound design." Then: "You can manually change the keyframes after generation - however, selecting the Generate Keyframes button again overwrites all manual changes to the keyframes." [APD] (P). The older page: "Each time you click Generate Keyframes, existing keyframes are replaced" [APH] (P).
- Audition: a "dotted keyframe envelope" on the music clip while **Monitor clip changes** is on. "Uncheck this box, and you'll see the dotted volume keyframe switch to a standard keyframe envelope. This way, you can use Auto-Ducking to get the basic keyframes in place, then make manual adjustments" [AAD] (P). While the box is on, "the volume envelope will adjust by itself" when clips move.
- Audition clip envelope (CS6 page, 2013): "Hold", "Linear (the default)", and "Spline" transitions between keyframes. Right-click a keyframe and choose Hold Keyframe for an abrupt change. Delete: right-click the line and choose Delete Selected Keyframes, or drag a keyframe off the clip. "click and drag to add and adjust keyframes" [AAE] (P, old). The domain of the linear curve is unconfirmed.
- Audition fades: the drag handle sets the length; the shape is **Linear** or **Cosine**, an S-shaped fade "that starts slowly, then rapidly changes amplitude" [ACV] (P).

### 4.4 Descript and Riverside

- Descript: the effect is **Lower audio of other layers**. It is on the track that must stay in front. "Descript reduces the volume of all other audio layers whenever a clip exists on that track." It follows clip presence, not audio content. "Lower percentages apply stronger ducking." It is per layer, not per clip, and not in the Sequence Editor. When tracks differ, "Descript applies the strongest reduction." [DLO] (P). Attack and release are not given.
- Riverside: no primary source found. Unconfirmed.

### 4.5 Other tools with numbers

- Audacity Auto Duck (P): Duck Amount -12 dB, Maximum Pause 1 s, Fade Down Length 0.5 s, Fade Up Length 0.5 s, Threshold -30 dB RMS. "the first unselected track underneath the selected track(s) acts as the control track." The pause must be at least the fade down plus the fade up length. Audacity ramps the volume in two lengths, "outer" and "inner" [AUD].
- Auphonic (P): the page for intros and outros has "Ducking Gain (dB) ... The default is -18 dB" and "Ducking Fade Time ... fade down/up length (attack/release) for ducking segments in ms. The default value is 500ms." [AUP]. Its multitrack ducking "automatically reduces the level of a track if speakers in other tracks are active"; the track setting Fore/Background has Auto, Foreground, Background, and Ducking [AUM]. The multitrack depth is unconfirmed.
- Steinberg WaveLab Pro 10 (P): a ducking dialog with "Damp Factor", a Fall Region and a Rise Region (each with a Duration and a "Gap before Clip"), and the modulator track as the previous or next track. The ducking is set on the Volume/Fades envelope of the music clip. No numbers are given [WLD].

## 5. REAPER volume envelopes

- Point shapes: "Envelopes can be any of six shapes - Linear, Square, Slow Start/End, Fast Start, Fast End or Bezier." Change: right-click a point, then **Set Point Shape** [RUG sec. 18.17] (P, v7.81).
- Default shape: "Default envelope point shape: sets the shape for new envelopes (e.g. Linear)." Set in **Options > Preferences > Project > Track/Send Defaults** [RUG sec. 18.17 and ch. 22] (P). The text gives Linear as an example. The factory value is not stated. Unconfirmed.
- Scaling: "Right-click over a volume envelope for a context menu which includes Volume envelope scaling ... Options are amplitude scaling (the default) and fader scaling. With amplitude scaling, half as high, for example, is half as loud, whereas with fader scaling the envelope height corresponds to the track fader. Fader scaling makes editing envelopes at low volume easier." [RUG sec. 18.14] (P). "Changing your preference on an envelope with existing points will affect the volume produced by that envelope." The API reports "0=no scaling, 1=fader scaling" and says all functions deal with raw point values [RSD, GetEnvelopeScalingMode] (P).
  - Inference: with amplitude scaling and a Linear shape, the gain between two points is linear in amplitude. With fader scaling, the line is straight in the fader position. The guide does not give the formula. Not checked.
- Gestures [RUG sec. 18.15 and 18.18] (P):
  - Add a point: Shift-click on the envelope. Shift-left-drag on a segment also inserts a point.
  - Delete a point: Alt-click on it, or Alt-left-drag.
  - Move: left drag. Shift-drag ignores snap. Ctrl-drag draws freehand.
  - Select all points in a time range: "Click and drag in envelope lane (not on envelope itself) to create time selection."
  - Range action: the Actions List has "Insert 4 envelope points at time selection" and "Delete all points in time selection". The guide does not describe the position of the four points. Unconfirmed.
  - The command "Reduce number of points" removes extra points after a freehand draw.

## 6. Audio engineering references

### 6.1 Linear in amplitude versus linear in dB

- The Web Audio specification (W3C) defines both ramps [WA sec. 1.6.2] (P):
  - Linear: `v(t) = V0 + (V1 - V0)(t - T0)/(T1 - T0)`.
  - Exponential: `v(t) = V0 (V1/V0)^((t - T0)/(T1 - T0))`.
  - "Parameters representing filter frequencies and playback rate are best changed exponentially because of the way humans perceive sound." The exponential form cannot start or end at 0: "an exponential ramp to 0 is not possible". The values cannot change sign.
- Computed from the exponential formula: 20*log10(v(t)) is a straight line in t. So an exponential amplitude ramp is a linear-in-dB ramp. Source: the formula above; the step is ours.
- Computed with the formulas for a duck from 0 dB to -18 dB (amplitude 0.126). Each cell is the level reached after the given part of the ramp time. "Raised cosine" uses the weight 0.5 - 0.5*cos(pi*x), on either the amplitude or the dB value:

| Part of the ramp time | Linear in amplitude | Linear in dB | Raised cosine on amplitude | Raised cosine on dB |
|---|---|---|---|---|
| 10 percent | -0.8 dB | -1.8 dB | -0.2 dB | -0.4 dB |
| 25 percent | -2.1 dB | -4.5 dB | -1.2 dB | -2.6 dB |
| 50 percent | -5.0 dB | -9.0 dB | -5.0 dB | -9.0 dB |
| 75 percent | -9.3 dB | -13.5 dB | -11.9 dB | -15.4 dB |
| 90 percent | -13.4 dB | -16.2 dB | -16.6 dB | -17.6 dB |

- Reading of the table: a linear-amplitude ramp to -18 dB reaches only -5 dB at the middle of the ramp time. Most of the audible change comes in the second half. A linear-dB ramp reaches -9 dB at the middle. Inference: the ear follows level in dB, so a linear-dB ramp sounds even. This rests on the Web Audio sentence above and on [TER] (S: "exponential ramps often sound better than linear ones"). No listening test was cited.
- A ramp to full silence: a linear-dB ramp cannot reach -inf dB, so a fade to silence needs a floor value or a different curve. Source: the exponential note in [WA]; the consequence is ours.
- The Apple AVFoundation `setVolumeRamp(fromStartVolume:toEndVolume:timeRange:)` takes volumes "between 0.0 and 1.0" and "the volume is interpolated between the start volume and end volume of the ramp" [AVP] [AVR] (P). The curve type is not named. Unconfirmed. It cannot boost above 1.0. The app has its own mixer (`Sources/DirigibleAudio/Render/MixReader.swift`), so this API is a reference only. Inference: the render path was not read in detail.

### 6.2 Minimum ramp length without a click

- No standard or paper found states a minimum. Unconfirmed in P.
- Web Audio tutorials: "a ramp duration of something like 30 milliseconds" removes pops and "still sounds instant" [TER] (S). Another: a `setTargetAtTime` time constant of 15 ms "gives the impression of being immediate but at the same time removes the click"; 30 ms for an exponential ramp [ALE] (S).
- A forum case: a 0.5 ms smoothing ramp still gave zipper noise, because the coefficients were updated in steps. A longer ramp removed the noise [JUC] (U). Inference: a short ramp needs a per-sample gain, not a per-block gain.
- Defaults for ducking fades in P sources: Auphonic 500 ms and Audacity 0.5 s (section 4.5). FCP uses 0.5 s as the default fade (section 2.3). No source gives a minimum below those defaults.

### 6.3 Ducking depth, attack, and release

| Source | Depth | Attack | Release | Grade |
|---|---|---|---|---|
| Audacity Auto Duck [AUD] | -12 dB | 0.5 s fade down | 0.5 s fade up | P |
| Auphonic intro and outro [AUP] | -18 dB | 500 ms | 500 ms | P |
| Hindenburg, Adobe, Descript, FCP, Logic | Unconfirmed | Unconfirmed | Unconfirmed | none |
| Creator guide [OCL] | 15 to 25 dB | 10 to 30 ms | 200 to 500 ms | S |
| Creator guide [ZEL] | about -18 to -25 dB below the voice | under about 300 ms | "release slower", no value | S |
| Game audio article [GDV] | -9 dB | 500 ms | 1000 ms | S |

- No AES paper, EBU document, or broadcaster guide with ducking numbers was found. "-12 to -20 dB" as a typical broadcast range is unconfirmed in P. The P values here are -12 dB and -18 dB (two tools).
- Inference: both P sources use a symmetric 0.5 s fade. A shorter attack and a longer release (S sources) is a common practice, but no vendor page gives it.

## 7. Summary table

| App | Point gesture | Curve between points | Range gesture | Duck depth | Duck attack | Duck release | Role model | Source |
|---|---|---|---|---|---|---|---|---|
| Hindenburg PRO 2 | No free points. Top handle sets clip gain; corner handles set fades; double-click on top line resets | Raised cosine, measured (S); domain unconfirmed | Select a range, then drag the top handle; **Volume > Duck** (Shift+D listed, pairing unconfirmed); drag outside the range = slope | Unconfirmed; set by the drag | Unconfirmed | Unconfirmed | Auto Level detects speech and music itself; no user-set role found; Magic Levels role use unconfirmed | [HJ121] [HJW] [HSC] [NHSX] |
| Final Cut Pro 12.4 | Option-click or Option-K; drag; Option-Shift-Delete | Line slopes; domain unconfirmed | Range Selection tool (R), then drag the line or Silence; keyframes at range edges (iPad text) | Manual | Set by keyframe spacing | Set by keyframe spacing | Roles: Dialogue, Music, Effects (also Video, Titles); color-coded; subroles; no auto duck | [VO] [KF] [VOI] [RI] [RA] |
| Logic Pro 12.3 | Click or double-click the curve; Pencil; drag; double-click or Delete to remove | Straight by default, bendable, stepped option; domain unconfirmed | Marquee, then click it; Option-Shift or Control-Option-Shift drag adds 1 or 2 points per border; Gain tool on a marquee for region gain | Manual | Ramp time by point spacing | Same | None for ducking | [LA3] [LSEL] [LD] [LG] |
| GarageBand 10.4.14 | Click curve; double-click lane; Command-click draws; double-click point deletes | Unconfirmed | Drag in the lane background selects points; no range-add | No ducking in the 10.4 guide (GarageBand '09: yes) | n/a | n/a | n/a (the '09 lead and backing arrows) | [GBA] [GBS] [WIN] |
| Audition (2017+) | Click and drag on the envelope; Hold, Linear (default), Spline | Linear default | Auto-Duck on a Music clip | Duck amount, default unconfirmed | Fade length, default unconfirmed | Same value | Types: Dialogue, Music, Sound Effects, Ambience | [AAD] [AAE] |
| Premiere Pro | Keyframes on the Amplify effect gain | Unconfirmed | Essential Sound > Ducking > Generate Keyframes (overwrites edits) | Duck Amount, default unconfirmed | Fade Duration, default unconfirmed | Same value; Fade Position | Types: Dialogue, Music, Sound Effects, Ambience; Music and Ambience can be ducked | [APD] [APH] |
| Descript | Not an envelope feature | n/a | Effect "Lower audio of other layers" on a track | A percentage | Unconfirmed | Unconfirmed | None; on or off per track | [DLO] |
| REAPER 7.81 | Shift-click adds; Alt-click deletes; drag moves | Linear, Square, Slow Start/End, Fast Start, Fast End, Bezier; volume scaling amplitude (default) or fader | Time selection plus action "Insert 4 envelope points at time selection" | Manual | Point spacing | Point spacing | None | [RUG] |
| Audacity | Not read for this file | Unconfirmed | Auto Duck on selected tracks | -12 dB default | 0.5 s | 0.5 s | Control track = first unselected track below | [AUD] |
| Auphonic | n/a | n/a | Fore/Background = Ducking | -18 dB (intro/outro) | 500 ms | 500 ms | Fore/Background per track | [AUP] [AUM] |

## 8. What the sources fix, and what they leave open for the plan

Facts that two or more primary sources agree on:

1. A range volume edit creates edge points on the same clip: FCP [VOI], Logic marquee points [LA3], REAPER time selection [RUG]. Premiere and Audition write keyframes on the clip [APD] [AAD]. Hindenburg is likely the same (Inference, finding 1.3).
2. The user can edit generated ducking points by hand: Premiere and Audition. A new run replaces hand edits in Premiere. Audition keeps them once monitoring is off.
3. A default ramp of 0.5 s is common: FCP fade, Audacity Auto Duck, Auphonic. Depth defaults in P sources are -12 dB (Audacity) and -18 dB (Auphonic).
4. Ducking follows a role or a type of the track or clip: Premiere and Audition (Music and Ambience duck against Dialogue and others), Auphonic (Fore/Background), Descript (a track toggle). FCP has roles but no auto duck.
5. FCP has three audio roles with a color: Dialogue, Music, Effects. The default for untagged audio is Dialogue.

Inference: the most common Dirigible gesture is a range select followed by a drag of the gain, as in Hindenburg and FCP. For that gesture, the edge ramp length is unconfirmed in every app (open question 14). The plan must choose it.

## 9. Open questions

1. Hindenburg Duck: the edge ramp length and the default depth are unconfirmed. Probe for a later run, if allowed: in Hindenburg PRO, make a 4 s selection on a region at 0 dB, press Shift+D, save the `.nhsx`, read the `<Fade>` children, and render to WAV.
2. Hindenburg: is the raised cosine applied to the amplitude or to the dB value? Probe: render a ramp between two noise levels and fit both. The field guide measured in dB RMS only.
3. Hindenburg Magic Levels: detector, per-track type, depth, attack, and release are unconfirmed. Probe: a session with one speech track and one music track, run Magic Levels, and read the output.
4. FCP: the keyframe count and the ramp length of a range edit on the Mac (the iPad text says "beginning and end of the range"). Probe: export FCPXML of a range edit and read the `adjust-volume` `keyframeAnimation`.
5. FCP, Logic, and REAPER: the interpolation domain of volume points (dB or amplitude). No Apple page states it. The REAPER guide names the scaling but not the formula (Inference in section 5).
6. Logic: the spacing of the two points at one border from the Control-Option-Shift command. The Logic Pro 11 text may differ from the 12.3 text. Also: does the Gain tool on a marquee split the region (Inference in 3.2)? Probe: Logic Pro is installed, but it was not run here.
7. GarageBand 10.4.14: does the app have a ducking control? The guide has none. Probe: open the **Control** menu in the installed app. Not done here (web sources only).
8. Premiere and Audition: the defaults of Duck Amount, Sensitivity, and Fade Duration. The vendor pages give none.
9. Riverside: no primary source on ducking.
10. A minimum ramp length without a click, from a standard or an AES paper. Only tutorials (15 to 30 ms) were found.
11. Typical broadcast ducking numbers (for example -12 to -20 dB) from a broadcaster or standard. Only vendor defaults and creator guides were found.
12. Premiere's Essential Sound page before 2026 may list a different set of duckable types. The 2026 page says Music and Ambience.
13. The Audacity envelope-tool gestures were not read for this file. Only the Auto Duck page of Audacity was read.
14. The edge ramp length of a range gain is unconfirmed in every app read. The plan must choose it. Hindenburg and FCP are the closest models, and neither gives a length. No running app was checked.

## Sources

- [HAG] Hindenburg, Academy, "Hindenburg Pro" guides: https://hindenburg.com/academy/guides/guides-hindenburg-pro/ (P)
- [HSC] Hindenburg, "Hindenburg Pro Shortcuts": https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/ (P, script-rendered table, read through a fetch summary)
- [HFE] Hindenburg PRO features: https://hindenburg.com/products/radio-podcast/features/ (P)
- [HSE] Hindenburg, "Story Editing": https://hindenburg.com/hindenburg-pro-features/story-editing/ (P)
- [HJ121] Hindenburg Journalist 1.21 user guide for OS X (pages 31 to 33), hosted by willyurman.com: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf (P, old)
- [HJW] Hindenburg Journalist Guide for Windows (pages 18 to 20), 2010: http://hindenburgsystems.com/wordpress/wp-content/uploads/2010/07/Hindenburg-Journalist-Guide-Windows.pdf (P, old; the HTTPS certificate fails)
- [UV34] Hindenburg UserVoice, "Kind of Ducking", 2018: https://hindenburg.uservoice.com/forums/224350-general/suggestions/34109959-kind-of-ducking (U)
- [NHSX] ollisulopuisto/podcast, "The Hindenburg Session File (.nhsx) - A Field Guide", measured against Hindenburg PRO 2.05.2718: https://github.com/ollisulopuisto/podcast/blob/main/docs/hindenburg-nhsx-format.md (S)
- [VO] Apple, Final Cut Pro, "Adjust volume": https://support.apple.com/guide/final-cut-pro/adjust-volume-verc1fabb77/mac (P, FCP 12.4)
- [KF] Apple, Final Cut Pro, "Keyframe audio effects": https://support.apple.com/guide/final-cut-pro/keyframe-audio-effects-ver717f5914/mac (P)
- [FA] Apple, Final Cut Pro, "Fade audio in and out": https://support.apple.com/guide/final-cut-pro/fade-audio-in-and-out-ver39580fed/mac (P)
- [VOI] Apple, Final Cut Pro for iPad, "Adjust volume": https://support.apple.com/guide/final-cut-pro-ipad/adjust-volume-dev9ffc54d16/ipados (P)
- [TR] Apple, Final Cut Pro, "Intro to trimming": https://support.apple.com/guide/final-cut-pro/intro-to-trimming-ver1632d3c8/mac (P, FCP 12.4)
- [ES] Apple, Final Cut Pro, "Extend or shorten clips": https://support.apple.com/guide/final-cut-pro/extend-or-shorten-clips-ver9847ec25/mac (P, FCP 12.4)
- [ESI] Apple, Final Cut Pro for iPad, "Extend or shorten timeline clips": https://support.apple.com/guide/final-cut-pro-ipad/extend-or-shorten-clips-deveddea57f8/ipados (P, 3.4)
- [FXT] Apple, FCPXML, "Timing Attributes": https://developer.apple.com/documentation/professional-video-applications/timing-attributes (P)
- [FXK] Apple, FCPXML, "keyframeAnimation": https://developer.apple.com/documentation/professional-video-applications/keyframeanimation (P)
- [RI] Apple, Final Cut Pro, "Intro to roles": https://support.apple.com/guide/final-cut-pro/intro-to-roles-verb71cbcbe/mac (P)
- [RA] Apple, Final Cut Pro, "Assign audio roles during import": https://support.apple.com/guide/final-cut-pro/assign-audio-roles-during-import-verb21791812/mac (P)
- [RV] Apple, Final Cut Pro, "View and reassign roles": https://support.apple.com/guide/final-cut-pro/view-and-reassign-roles-verb71cbb80/mac (P)
- [RC] Apple, Final Cut Pro, "Change role colors or names": https://support.apple.com/guide/final-cut-pro/change-role-colors-or-names-verbd20e0664/mac (P)
- [KRO] Krotos, "Working with Audio in Final Cut Pro": https://krotos.studio/blog/working-with-audio-in-final-cut-pro (S)
- [LA3] Apple, Logic Pro, "Add automation points to tracks": https://support.apple.com/guide/logicpro/add-automation-points-lgcpb1a3327b/mac (P, 12.3)
- [LA2] Apple, Logic Pro, "Adjust a range of automation points": https://support.apple.com/guide/logicpro/adjust-a-range-of-automation-points-lgcpb1a31d82/mac (P)
- [LP] Apple, Logic Pro, "Adjust automation points": https://support.apple.com/guide/logicpro/adjust-automation-points-track-lgcp5d5e5427/mac (P)
- [LSEL] Apple, Logic Pro, "Select, copy, and move automation": https://support.apple.com/guide/logicpro/select-copy-and-move-automation-lgcpb1a5aad6/mac (P)
- [LD] Apple, Logic Pro, "Delete automation": https://support.apple.com/guide/logicpro/delete-automation-lgcpb1a5cb14/mac (P)
- [LAS] Apple, Logic Pro, "Automation settings": https://support.apple.com/guide/logicpro/automation-settings-lgcp8aa8f24b/mac (P)
- [LVS] Apple, Logic Pro, "Track automation vs. region automation": https://support.apple.com/guide/logicpro/track-automation-vs-region-automation-lgcp967649d0/mac (P)
- [LG] Apple, Logic Pro, "Change the gain of audio regions in the Tracks area": https://support.apple.com/guide/logicpro/change-gain-audio-regions-tracks-area-lgcp8e4c781d/mac (P)
- [GBA] Apple, GarageBand for Mac, "Add and edit automation points": https://support.apple.com/guide/garageband/add-and-edit-automation-points-gbnd65471e12/mac (P, 10.4.14)
- [GBS] Apple, GarageBand for Mac, "Copy and move automation" (the page index lists every page of the guide): https://support.apple.com/guide/garageband/select-and-move-automation-gbnd010a7072/mac (P)
- [GBV] Apple, GarageBand for Mac, "Set track volume levels": https://support.apple.com/guide/garageband/set-track-volume-levels-gbnd79295c4f/mac (P)
- [WIN] Winona State University wiki, "GarageBand (Mac)/Mixing": https://learn.winona.edu/wiki/GarageBand/Mixing (S, search excerpt)
- [LIN] Linfield College, "How to Make a Podcast Using GarageBand on Macintosh": https://inside.linfield.edu/teaching-learning-support/resources/how-to-documents/garageband.html (S, search excerpt)
- [MAC] MacTrast, "Apple Releases GarageBand for Mac 10.0.1 Update", 2013: https://www.mactrast.com/2013/11/apple-releases-garageband-mac-10-0-1-update-fixes-minor-issues/ (S)
- [APD] Adobe, Premiere, "Automatically duck audio", updated 2026-01-07, archived copy of 2026-03-08: http://web.archive.org/web/20260308041125/https://helpx.adobe.com/premiere/desktop/add-audio-effects/adjust-volume-and-levels/automatically-duck-audio.html (P)
- [APH] Adobe, Premiere Pro, "Automatic audio ducking", archived copy of 2023-06-23: https://web.archive.org/web/20230623131819/https://helpx.adobe.com/premiere-pro/how-to/automatic-audio-ducking.html (P)
- [AAD] Adobe, Audition blog, "Audition Deep Dive: Auto-Ducking music", 2017: https://blog.adobe.com/en/publish/2017/11/02/audition-deep-dive-auto-ducking-music (P)
- [AAE] Adobe, Audition, "Automating mixes with envelopes" (CS6 text), archived copy of 2013-06-09: http://web.archive.org/web/20130609001543/http://helpx.adobe.com/audition/using/automating-mixes-envelopes.html (P, old)
- [ACV] Adobe, Audition, "Match, fade, and mix clip volume", archived copy of 2026-06-09: https://web.archive.org/web/20260609225604/https://helpx.adobe.com/audition/desktop/mixing-multitrack-sessions/clip-volume-matching-fading-mixing.html (P)
- [LJ] Larry Jordan, "How to Auto-Duck Audio in Adobe Premiere Pro CC": https://larryjordan.com/articles/how-to-auto-duck-audio-in-adobe-premiere-pro-cc/ (S)
- [CRU] CrumplePop, "Audio Ducking in Premiere Pro": https://crumplepop.com/audio-ducking-in-premiere-pro-tips-and-advices/ (S)
- [DLO] Descript Help, "Lower audio of other layers": https://help.descript.com/hc/en-us/articles/4404610008461 (P)
- [AUD] Audacity Manual, "Auto Duck": https://manual.audacityteam.org/man/auto_duck.html (P)
- [AUP] Auphonic Help, "Production" (intro and outro ducking settings): https://auphonic.com/help/web/production.html (P)
- [AUM] Auphonic Help, "Multitrack Algorithms": https://auphonic.com/help/algorithms/multitrack.html (P)
- [WLD] Steinberg WaveLab Pro 10, "Ducking Settings Dialog" and "Creating a ducking effect": https://archive.steinberg.help/wavelab_pro/v10/en/wavelab/topics/audio_montage/audio_montage_ducking_settings_dialog_r.html and https://archive.steinberg.help/wavelab_pro/v10/en/wavelab/topics/audio_montage/clips_ducking_effect_creating_t.html (P)
- [RUG] Cockos, "Up and Running: A REAPER User Guide v 7.81": https://www.reaper.fm/userguide/ReaperUserGuide781c.pdf (P)
- [RSD] Cockos, ReaScript API, `GetEnvelopeScalingMode`: https://www.reaper.fm/sdk/reascript/reascripthelp.html (P)
- [WA] W3C, "Web Audio API 1.1", `AudioParam` ramps: https://www.w3.org/TR/webaudio-1.1/ (P)
- [AVP] Apple, `AVAudioMixInputParameters`: https://developer.apple.com/documentation/avfoundation/avaudiomixinputparameters (P)
- [AVR] Apple, `AVMutableAudioMixInputParameters.setVolumeRamp(fromStartVolume:toEndVolume:timeRange:)`: https://developer.apple.com/documentation/avfoundation/avmutableaudiomixinputparameters/setvolumeramp(fromstartvolume:toendvolume:timerange:) (P)
- [TER] Tero Parviainen, "Controlling Amplitude and Loudness": https://teropa.info/blog/2016/08/30/amplitude-and-loudness.html (S)
- [ALE] Alejandro Mangui, "Web Audio: the ugly click and the human ear": http://alemangui.github.io/ramp-to-value (S)
- [JUC] JUCE forum, "dsp::IIR::Filter: noise/glitches when automating frequency via (slow) LFO": https://forum.juce.com/t/dsp-noise-glitches-when-automating-frequency-via-slow-lfo/63949 (U, search excerpt)
- [OCL] OpenClip, "Audio ducking": https://openclip.app/learn/audio-ducking (S)
- [ZEL] Zella, "Audio Ducking: How to Lower Music Under a Voiceover": https://zellahq.com/blog/music-ducking-explained/ (S)
- [GDV] Game Developer, "Game Audio Theory: Ducking": https://www.gamedeveloper.com/audio/game-audio-theory-ducking (S)
