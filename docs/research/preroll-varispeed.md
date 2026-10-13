# Pre-roll recording (F08) and vari-speed playback (F18)

Date: 2026-10-13

This document records how the reference apps do pre-roll recording and vari-speed playback, and the Apple facts for a design on AVAudioEngine. It adds to `docs/research/timeline-playback.md` (sections 1, 2, and 9), `docs/research/podcast-features.md` (rows F08 and F18), `docs/research/record-monitor.md`, `docs/research/final-cut-pro.md`, and `docs/research/logic-garageband-update.md`. It does not repeat them.

A claim that no primary source confirms has the mark "(unconfirmed)". A sentence that starts with "Inference:" is our reading of the sources. The official Hindenburg videos have no captions that a script can read, so only their descriptions are sources. The PRO 2 shortcut pages still show "Unable to render grid fragment" on 2026-10-13.

## 1. Hindenburg

### Pre-roll

- **Pre-roll playback is a separate command. Pre-roll recording has no key of its own.**
  - Pre-roll playback, key P: "Preroll will set the playhead back a few seconds and playback the audio from that point" [V-preroll]. The Windows guide says: "Pre-roll starts playback before the playhead position", with P or the comma of the numeric keypad [HW p. 11]. The 1.21 manual gives Cmd-P on page 16 and P on page 94 [HM].
  - Pre-roll recording uses Cmd-Space on macOS: "Auto Punch in at 'in' point after pre-roll in your session" [V-prerec]. The manual punch-in video gives the same key: "Manually punch in to record on a specific region" [V-punch]. Cmd-Space is also the Record key (`timeline-playback.md`, key table).
  - Inference: Record does a pre-roll punch when an in point is set, or when a "Record with Pre-Roll" preference is on. Only Narrator documents this preference [NP-rec]. Not checked against: Record with no in point and no such preference.
- **Narrator, a sister app, has the same model and more text.** Pre-roll recording is "Auto Punch in at in point after pre-roll" [V-nprerec]. "Set the playhead at the desired input time. The Pre-Roll will playback the previouse audio and punch in at the desired time" [V-npunch]. Narrator has two Interface preferences: "PreRoll Time" and "Record with Pre-Roll" [NP-time] [NP-rec]. Inference: in Narrator, "Record with Pre-Roll" makes the Record key do a pre-roll recording. No source shows this preference in PRO 2 (unconfirmed).
- **The punch point.** PRO 2 says the "in" point [V-prerec]. Narrator says the playhead [V-npunch]. Inference: the punch point is the in point when one is set, and otherwise the playhead.
- **The pre-roll length.** It is a preference: Preferences > Interface > "Pre-roll time", "the amount of milliseconds the playhead jumps back at pre-roll playback" [HM p. 76] [HW p. 29]. The unit is milliseconds. The default value and the range are not documented (unconfirmed). "A few seconds" is the only hint [V-preroll].
- **Latency.** Build 2604 fixed "missing audio playback when using pre roll with latency introducing plug-ins" [R2604]. Inference: PRO 2 compensates the pre-roll playback for plug-in latency.
- **Not documented** (unconfirmed for each item):
  - whether the armed track plays its old audio during the pre-roll;
  - whether the other tracks keep playing after the punch point;
  - whether the app keeps or drops the audio that it captures during the pre-roll;
  - where the playhead goes after a stop. Narrator has an Interface preference "Return on stop" [NP-ret].

### Vari-speed

- Period toggles vari-speed. Shift-Period speeds up. Shift-Comma slows down. The user can also "highlight the speed value and use the arrow keys" [HM p. 17]. Inference: the transport bar shows the speed as a value that the user can edit.
- The 1.21 transport bar holds the vari-speed controls [HM p. 10]. Narrator gives the same key: "Adjust the speed of the playback. Shortcut Apple: 'full stop'" [V-nvs].
- The use case: "When listening trough a radio segment, it can at times be useful to turn up the speed" [HM p. 17].
- **Not documented** (unconfirmed for each item): the speed steps, the range, the unit of the readout, whether the pitch stays the same, whether the speed persists between sessions, and whether the speed applies to JKL. The 2023 video "Painting By Ear" has a "Vari Speed" chapter at 18:46 [V-pbe]. Its captions did not download, so it is not a source here.

## 2. Logic Pro

### Count-in and pre-roll

- One control-bar button, Count-in (Shift-K), starts playback before the playhead. "When reaching the playhead position, Logic Pro switches to record mode" [LRS].
- The length is in bars or beats (count-in) or in seconds (pre-roll). Recording project settings have a Count-in button with a pop-up menu (None, 1 to 6 bars, or x/4 beats) and a Pre-roll button with a slider. The slider sets "the playback time (up to 60 seconds) before recording starts" [LRS]. The default value is not given (unconfirmed).
- The metronome click needs the Metronome button (K) [LRS].

### Playback and capture around the punch

- **Quick Punch-In** (on by default): "recording occurs in the background from the moment you start playback" [LPU]. Thus Logic captures audio before the punch.
- **Autopunch**: "Any audio input received before the punch-in or after the punch-out point streams through Logic Pro as usual, but isn't recorded" [LPU].
- **Auto input monitoring** (on by default): "you hear the input signal only during the actual recording; before and afterward you'll hear the previously recorded audio on the track" [LPU]. Thus the armed track plays its old audio during the pre-roll, and the other tracks play during the whole pass.
- A punch "overwrite[s] a portion of a previously recorded track, during playback, without touching any of the recording before or after that portion" [LPU].
- Record Toggle without Quick Punch-In "causes a delay when you switch between playback and record modes, accompanied by a dropout of all audio tracks" [LPU].

### Latency

- **Recording Delay** slider (Audio settings > Devices): "Delays the recording of audio by a certain fixed value, helping you to compensate for any delays that are caused by the audio driver." "You should not normally need to touch this setting" [LDV].
- The Devices pane shows "Resulting Latency (Roundtrip/Output)" for the I/O buffer size [LDV].
- No Apple page that we read says how Logic places a recording against the playback, or that it compensates the latency that the driver reports (unconfirmed).

### Varispeed

- Range: "between −50% (half the original project tempo) and +100% (double the original tempo)" [LVS]. Logic 9.1.6 adds: "between 50% and 200% of the original tempo" and "Varispeed affects the entire project" [L9VS].
- Modes, chosen from the upper part of the Varispeed display [LVS]:
  - **Speed Only**: Logic pitch-shifts "the master output signal to balance the pitch change". "Only the speed changes, not the pitch."
  - **Varispeed (Speed and Pitch)**: classic tape varispeed.
  - **Varispeed and MIDI**: tape varispeed, and it transposes External MIDI tracks.
- Readout units, chosen from the lower part of the display: Percentage (%), Resulting Tempo (bpm), Detune (semitones and cents), Tuning Reference (Hz). "Drag vertically on the value to adjust it, or double-click and enter a new value" [LVS].
- The Varispeed button is in the control bar. If it does not show, add it with Customize Control Bar and Display [LVS]. Logic 9 names a "Toggle Varispeed" key command [L9VS]. No page gives a default key (unconfirmed).
- Use cases: check a project "at a faster or slower tempo", and "practicing or recording a performance at a lower speed" [LVS].

## 3. GarageBand

- Count-in: the Count-in button in the control bar plays "a one- or two-bar count-in before recording starts". Record > Count-in sets the number of bars [GMT]. The same page also says "a one-measure count-in" [GMT].
- GarageBand has no time-based pre-roll in the pages that we read (unconfirmed).
- The guide pages that we read have no vari-speed or playback-speed control (unconfirmed).

## 4. Final Cut Pro

### Record Voiceover

- Put the playhead where the recording starts, then choose Window > Record Voiceover. Option-Shift-A starts a recording with no settings change [FVO].
- "By default, Final Cut Pro includes an automatic countdown when you record." The "Countdown to record" checkbox turns it off [FVO]. The length of the countdown is not given (unconfirmed).
- "Mute project while recording" is a checkbox. To hear "a live mix of both microphone and project audio, set Monitor to On and deselect the 'Mute project while recording' checkbox" [FVO]. Inference: the project plays during the recording, and it is muted by default.
- "Your audio recordings are attached to the primary storyline at the playhead position." "When you stop recording, the playhead returns to the start point you set in step 1, ready for you to record additional takes" [FVO].
- Takes become an audition by default ("Create Audition from takes") [FVO].
- With the built-in microphone, the monitor Gain "automatically resets to zero to prevent feedback from the built-in speakers" [FVO].
- Space stops the recording [FVO].

### Pre-roll and review speed

- Settings > Playback has "Pre-Roll Duration" and "Post-Roll Duration": the time to play before and after the skimmer or the playhead "when using the Play Around command" [FPS]. Play Around is View > Playback > Play Around, Shift-? [FPS].
- JKL: "play a project or clip at up to 32x normal speed". Press L or J twice to double the speed. Hold K with J or L for 1/2x speed [FPM]. No page says if the audio keeps its pitch at these speeds (unconfirmed).

## 5. Apple facts

### AVAudioUnitTimePitch

- "An AVAudioUnitTimeEffect that provides good quality time stretching and pitch shifting." "The playback rate and pitch parameters function independently of each other" [A-H-TP].
- `rate`: range 1/32 to 32.0, default 1.0 [A-H-TP] [A-TP]. `pitch`: range −2400 to 2400 cents, default 0 [A-H-TP].
- `overlap`: range 3.0 to 32.0, default 8.0. "A higher value results in fewer artifacts in the output signal. This parameter also impacts the amount of CPU used" [A-H-TP] [A-OV]. In AudioToolbox the parameter is `kNewTimePitchParam_Smoothness` (`kNewTimePitchParam_Overlap` is deprecated): "The value is directly proportional to the CPU cost. When slowing down percussive audio, lower values may be better" [A-H-AUP].
- Two more parameters, on by default: `kNewTimePitchParam_EnableSpectralCoherence` gives "a less 'phasey' or reverberant sound" at "some computation cost". `kNewTimePitchParam_EnableTransientPreservation` "sets the stretch factor to 1" at transients [A-H-AUP].
- The unit is `kAudioUnitSubType_NewTimePitch` ('nutp'): "good quality time stretching and pitch shifting", "computationally less expensive than kAudioUnitSubType_TimePitch" [A-H-AUC].
- **Latency.** The headers give no latency value for the unit. `AVAudioNode.latency` is "the processing latency of the node". "A value of zero indicates either no latency or an unknown latency" [A-H-N]. The real value is unconfirmed: see open question 1.
- **Bypass.** `AVAudioUnitTimeEffect.bypass` is the "bypass state of the audio unit" [A-H-TE]. "If true, the audio unit bypasses audio processing" [A-BYP]. No source says if a bypassed time effect still changes the rate (unconfirmed).
- **A speech algorithm.** `kAudioUnitSubType_AUiPodTimeOther` ('ipto') "provides time domain time stretching" [A-H-AUC]. `auval` on this Mac (macOS 15) lists it as "AUNotQuiteSoSimpleTime", with one parameter, rate, range 0.5 to 2.0. AVFoundation calls the time-domain algorithm "Modest quality, less expensive. Suitable for voice", and the spectral one "Highest quality, most computationally expensive. Suitable for music" [A-H-APS]. Since macOS 12, AVFoundation playback uses the time-domain algorithm by default [A-H-APS]. `AVAudioUnitTimeEffect(audioComponentDescription:)` takes a unit of type `kAudioUnitType_FormatConverter` [A-H-TE]. Whether it hosts 'ipto' in an engine is unconfirmed: see open question 1.
- For comparison: `AVAudioUnitVarispeed` ('vari') changes the pitch with the rate ("as the rate is faster, the pitch is higher") [A-H-AUC]. `timeline-playback.md` section 9 gives its range.

### Output latency and render times

- `AVAudioIONode.presentationLatency`: "The presentation or hardware latency, applicable when the engine is rendering to/from an audio device. This corresponds to kAudioDevicePropertyLatency and kAudioStreamPropertyLatency" [A-H-IO] [A-PL]. The total latency of a stream is "the device latency summed with the stream latency" [A-H-HB]. The safety offset (`kAudioDevicePropertySafetyOffset`) and the buffer size are separate properties [A-H-HB]. Inference: `presentationLatency` does not include them.
- `AVAudioNode.outputPresentationLatency`: "The maximum render pipeline latency downstream of the node". For the output node, it is the device presentation latency. For a node connected directly to the output node, it is that value "plus the output node's processing latency". "This latency value can change as the engine is reconfigured ... it is recommended not to cache this value" [A-H-N]. Inference: read `outputPresentationLatency` of the player node, not `presentationLatency` of the output node, when a time-pitch node sits between them.
- `AudioDeviceIOProc`: `inOutputTime` is "the time at which the first frame in the data will be passed to the hardware". `inInputTime` is "the time at which the first frame in the data was acquired from the hardware" [A-H-HW]. Inference: the time when a frame is heard is the output time stamp plus the presentation latency.
- `AVAudioNode.lastRenderTime`: "the time for which the node most recently rendered". It is nil when the engine is not running or the node is not connected [A-H-N] [A-LRT]. No source says which moment its host time marks: the start of the cycle, or the output time of the first frame (unconfirmed). See open question 2.
- `AVAudioTime` holds a host time (`mach_absolute_time()`), a sample time, or both. `extrapolateTimeFromAnchor(_:)` fills the missing one from an anchor [A-H-T].

### AVAudioPlayerNode time with a time-pitch node downstream

- "The usual AVAudioNode sample times (as observed by lastRenderTime) have an arbitrary zero point. AVAudioPlayerNode superimposes a second 'player timeline' on top of this, to reflect when the player was started, and intervals during which it was paused." `playerTime(forNodeTime:)` and `nodeTime(forPlayerTime:)` convert between the two. They return nil when the player does not play [A-H-PN] [A-PT].
- No source says what the player timeline counts when a time effect pulls frames downstream (unconfirmed). Inference: the player renders the frames that the time-pitch unit pulls, about `rate` × the output frames, plus a look-ahead. Then the player sample time counts source frames, not output frames. See open question 1.
- Dirigible today: `Player.frame(_:played:)` multiplies the played output frames by the shuttle rate. `heardFrames()` subtracts the output `presentationLatency` from `nodeFrames()`, which reads the player time (`Sources/DirigibleAudio/Render/Player.swift`). Inference: if the inference above is true, a time-pitch node between the player and the mixer makes this code count the rate two times, and the code must also subtract the latency of the time-pitch node.

## Facts that change a design choice

1. **Capture before the punch, or not.** Logic Quick Punch-In records "in the background from the moment you start playback". Autopunch drops the input before the punch-in point [LPU]. Hindenburg does not say what it keeps (unconfirmed). Dirigible records each source to a crash-safe file (decision 0004). Inference: it is safe and cheap to capture from the start of the pre-roll and to put the region start at the punch point. The audio before the punch stays in the file, and a trim can show it.
2. **The latency to subtract.** `presentationLatency` is the device latency plus the stream latency only [A-H-IO] [A-H-HB]. A time-pitch node adds its own `latency`, and the header says not to cache `outputPresentationLatency` [A-H-N]. Hindenburg fixed pre-roll playback with latency plug-ins [R2604]. Inference: a punch aligns the recording to the time when the punch frame is heard: the output time stamp plus `outputPresentationLatency` of the player node. This is the "take start host time" of the take anchor in decision 0004 **Timing**.
3. **The playhead math under vari-speed.** If the player time counts source frames (open question 1), the playhead is `anchor + playerFrames`, with no multiplication by the rate. The current shuttle code multiplies by the rate. The latency that `heardFrames()` subtracts is in output frames, so it also needs a scale by the rate before it is subtracted from source frames.

Other facts with design value:

- Logic Speed Only keeps the pitch with a pitch shift on the master output [LVS]. Inference: one time-pitch node after the mix is enough. A node for each track is not necessary.
- Logic shows the speed in %, bpm, semitones, or Hz, with the range 50% to 200% [LVS]. Hindenburg shows an editable value and steps with Shift-Period and Shift-Comma [HM p. 17]. FCP doubles the JKL speed with each press, up to 32x [FPM].
- The time-domain unit 'ipto' is "suitable for voice" and has the range 0.5 to 2.0 [A-H-APS]. This range covers the Logic range.

## Open questions

1. **Probe: player time, latency, and bypass with a time-pitch node.** Run it with `scripts/with-lock.sh scripts/probe.sh <folder> swift <file>` after the build loop. It renders offline, so it needs no device. Check: `playerFrames` against `outputFrames` × 2; `pitch.latency`; the output frame of the click against 24 000 (48 000 / 2). Run it again with `pitch.bypass = true`, and with the 'ipto' unit.

   ```swift
   import AVFAudio
   import AudioToolbox

   let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
   let engine = AVAudioEngine()
   let player = AVAudioPlayerNode()
   let pitch = AVAudioUnitTimePitch()  // or the 'ipto' unit below
   // let ipto = AudioComponentDescription(componentType: kAudioUnitType_FormatConverter,
   //     componentSubType: 0x6970_746F, componentManufacturer: kAudioUnitManufacturer_Apple,
   //     componentFlags: 0, componentFlagsMask: 0)
   // let voice = AVAudioUnitTimeEffect(audioComponentDescription: ipto)
   // voice.auAudioUnit.parameterTree?.parameter(withAddress: 0)?.value = 2
   pitch.rate = 2
   engine.attach(player)
   engine.attach(pitch)
   engine.connect(player, to: pitch, format: format)
   engine.connect(pitch, to: engine.mainMixerNode, format: format)
   try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
   let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000)!
   source.frameLength = 480_000
   source.floatChannelData![0][48_000] = 1  // a click at 1 s of source time
   player.scheduleBuffer(source)
   try engine.start()
   player.play()
   let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
   var outputFrames = 0
   var click = -1
   for _ in 0..<200 {
       _ = try engine.renderOffline(512, to: out)
       for i in 0..<Int(out.frameLength) where click < 0 && abs(out.floatChannelData![0][i]) > 0.05 {
           click = outputFrames + i
       }
       outputFrames += Int(out.frameLength)
   }
   let playerFrames = player.playerTime(forNodeTime: player.lastRenderTime!)!.sampleTime
   print("output", outputFrames, "player", playerFrames, "latency", pitch.latency,
         "player outputPresentationLatency", player.outputPresentationLatency, "click", click)
   ```

2. **Probe: the moment of `lastRenderTime`.** While the engine plays to a device, log `player.lastRenderTime!.hostTime` against `mach_absolute_time()` and `presentationLatency`. A host time later than now means the output time stamp of the next cycle. A host time earlier than now means the start of the last cycle. This needs a device, so it runs in an on-screen check.
3. **Hindenburg behavior.** Record one pre-roll recording in a PRO 2 trial and check: the default pre-roll time; whether the armed track plays its old audio in the pre-roll; whether the other tracks play after the punch; what the new region holds; the vari-speed steps, range, readout, and pitch.
4. **FCP countdown length and JKL pitch.** Check in the app.

## Sources

Hindenburg:

- [HM] Hindenburg Journalist 1.21 user guide for macOS, pages 10, 16, 17, 76, 94: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HW] Hindenburg Journalist guide for Windows, pages 11 and 29: http://hindenburgsystems.com/wordpress/wp-content/uploads/2010/07/Hindenburg-Journalist-Guide-Windows.pdf
- [R2604] PRO 2 release notes, build 2604: https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_02-build-2604/ (list: https://hindenburg.com/support/release-notes/hindenburg-series/)
- [NP-time] Narrator: Preferences - Interface - PreRoll Time: https://hindenburg.com/data/functions/narrator-preferences-interface-preroll-time/ (video XZBLvLwhnI8)
- [NP-rec] Narrator: Preferences - Interface - Record with Pre-Roll: https://hindenburg.com/data/functions/narrator-preferences-interface-record-with-pre-roll/
- [NP-ret] Narrator: Preferences - Interface - Return on stop: https://hindenburg.com/data/functions/narrator-preferences-interface-return-on-stop/

Official Hindenburg video descriptions (https://www.youtube.com/watch?v=<id>):

- [V-preroll] DlosiGi0vXU "How to use preroll in Hindenburg Pro" (2021-03-24)
- [V-prerec] hPlhV0thILo "How to activate pre roll recording in Hindenburg Pro" (2021-02-25)
- [V-punch] YMEf8BsRM-o "How to punch in record in Hindenburg Pro" (2021-02-25)
- [V-nprerec] 6LoR1Kpdw7g "How to activate pre roll recording in Narrator Studio" (2021-11-11)
- [V-npunch] yXgzBvGgZ5Y "How to set a specific place in the audio to start recording in Narrator" (2021-11-18)
- [V-nvs] PYoL8rWOuUc "How to adjust the speed of playback in Narrator" (2021-11-17)
- [V-pbe] Q5iIi9gmke0 "Painting By Ear" (2023-11-02), chapter "Vari Speed" at 18:46

Apple Support (Logic Pro 12.3, GarageBand, Final Cut Pro):

- [LRS] Recording project settings in Logic Pro for Mac: https://support.apple.com/guide/logicpro/lgcpbc10f1ea/mac
- [LPU] Punch in and out of audio recordings in Logic Pro for Mac: https://support.apple.com/guide/logicpro/lgcpb19bfd0d/mac
- [LDV] Audio Devices settings in Logic Pro for Mac: https://support.apple.com/guide/logicpro/lgcpbb81aca5/mac
- [LVS] Use Varispeed in Logic Pro for Mac: https://support.apple.com/guide/logicpro/varispeed-alter-speed-pitch-audio-lgcp1cc678a7/mac
- [L9VS] Logic Pro 9.1.6 manual, Using Varispeed: https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_16_section_11.html
- [GMT] Use the metronome in GarageBand on Mac: https://support.apple.com/guide/garageband/gbnda8165874/mac
- [FVO] Record voiceovers in Final Cut Pro for Mac: https://support.apple.com/guide/final-cut-pro/verc1faa9c5/mac
- [FPS] Playback settings in Final Cut Pro for Mac: https://support.apple.com/guide/final-cut-pro/verb8e60ab7/mac
- [FPM] Play media in Final Cut Pro for Mac: https://support.apple.com/guide/final-cut-pro/ver90ba4ef0/mac

Apple developer documentation (https://developer.apple.com/documentation/avfaudio/<path>):

- [A-TP] avaudiounittimepitch/rate
- [A-OV] avaudiounittimepitch/overlap
- [A-BYP] avaudiounittimeeffect/bypass
- [A-PL] avaudioionode/presentationlatency
- [A-LRT] avaudionode/lastrendertime
- [A-PT] avaudioplayernode/playertime(fornodetime:)

SDK headers in `MacOSX.sdk` of Xcode 26 (`xcrun --show-sdk-path`):

- [A-H-TP] `AVFAudio.framework/Headers/AVAudioUnitTimePitch.h`
- [A-H-TE] `AVFAudio.framework/Headers/AVAudioUnitTimeEffect.h`
- [A-H-N] `AVFAudio.framework/Headers/AVAudioNode.h` (`latency`, `outputPresentationLatency`, `lastRenderTime`)
- [A-H-IO] `AVFAudio.framework/Headers/AVAudioIONode.h`
- [A-H-PN] `AVFAudio.framework/Headers/AVAudioPlayerNode.h` (TIMELINES)
- [A-H-T] `AVFAudio.framework/Headers/AVAudioTime.h`
- [A-H-AUP] `AudioToolbox.framework/Headers/AudioUnitParameters.h` (AUNewTimePitch parameters)
- [A-H-AUC] `AudioToolbox.framework/Headers/AUComponent.h` (converter subtypes)
- [A-H-APS] `AVFoundation.framework/Headers/AVAudioProcessingSettings.h`
- [A-H-HB] `CoreAudio.framework/Headers/AudioHardwareBase.h` (`kAudioDevicePropertyLatency`, `kAudioStreamPropertyLatency`, `kAudioDevicePropertySafetyOffset`)
- [A-H-HW] `CoreAudio.framework/Headers/AudioHardware.h` (`AudioDeviceIOProc`)
- `auval -v aufc ipto appl` and `auval -a` on this Mac, macOS 15, 2026-10-13
