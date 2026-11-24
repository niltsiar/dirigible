# Track volume fader in the track header (F94)

Date: 2026-10-11

This file answers six questions on a track volume control in the track header. It does not repeat `docs/research/mute-solo.md`, `docs/research/podcast-features.md`, or the `.nhsx` facts of `docs/research/session-formats.md`.

Grades: **P** is a primary vendor page, a vendor manual, vendor source code, or a file in the installed app bundle. **S** is a search summary or a secondary page. **U** is a user post on a forum. **O** is our observation of a vendor image or video frame. "Unconfirmed" means that no source answers. A sentence that starts with "Inference:" is our reading. No probe, build, or on-screen check ran. The installed apps are Logic Pro 12.3.1, GarageBand 10.4.14, and Final Cut Pro 12.3.

## 1. Hindenburg PRO 2 and Hindenburg Journalist

- **Control.** Each track header has a "Track Volume" control and a "Track Balance" control [HJ p44] (P). The Journalist 1.21 screenshots show a horizontal slider with a speaker icon, above a pan slider [HJ p45] (O). A frame of the vendor video "Hindenburg PRO: Tracks - Volume" shows the same horizontal slider in PRO 2 [HV] (O). The guide page lists "Tracks - Volume: Adjust the volume on the track" [HG] (P).
- **Reset.** "To reset the volume to 0dB, double-click on the Volume button" [HJ p45] (P). The pan reset is also a double-click: "To reset to center, double-click on the balance button" [HJ p45] (P). The Journalist region gain line also resets with a double-click [HJ p31] (P).
- **Readout.** The PRO video frame shows a green tag "+0.0 dB" next to the slider while the pointer is on the thumb [HV] (O). The tag shows the sign. The region gain tooltip of Journalist shows "-4.8 dB = current level" and "(-2,3) = gain change made by user" [HJ p31] (P).
- **Range.** No source states the minimum or the maximum (unconfirmed). Observation: at "+0.0 dB" the thumb is at approximately 80 % to 85 % of the slider travel, in the PRO frame [HV] (O) and in the Journalist screenshot [HJ p45] (O). A second PRO frame shows the thumb at the right end [HV] (O); its value is not visible. The `.nhsx` field guide measured `Volume="6"` as +6 dB on a render [NX] (S, a measured reverse-engineered guide). Inference: the maximum is above 0 dB, and +6 dB is consistent with the three data points. The minimum and a -inf end are unconfirmed.
- **Mix volume or input gain.** Journalist says "Adjust the overall volume for the track" [HJ p45] (P). Inference: it is the playback mix volume, not the record gain. No page says what it does to a take that records.
- **Saved in the session.** The `.nhsx` `Track` element has `Volume` in dB ("the track fader") [NX] (S, measured). The field guide also lists `Gain` as "older spelling of track gain, dB" on a `Track`, and asks whether both can coexist (its open question 6) [NX] (S). `session-formats.md` names the two spellings only for regions.
- **Keys and menus.** The Journalist key table lists no key for track volume [HJ p97] (P). Shift-Command-Up and Shift-Command-Down are region "Gain up" and "Gain Down", not track volume [HJ p97] (P). A track volume menu item: unconfirmed. The PRO 2 shortcut page returned a server error on fetch [HSC].
- **Change during a take.** Unconfirmed.

## 2. Logic Pro and GarageBand

- **Logic track header.** "In the track header, drag the Volume slider left to lower the volume level, or drag it right to raise the volume level." "You might have to resize the track header in order to see the Volume slider." [LTV] (P). Track > Configure Track Header chooses the shown controls [LTH] (P, see `logic-garageband-update.md`).
- **Logic reset.** "Option-click the slider to return it to a neutral level (0 dB gain)." [LTV] (P). The channel strip fader resets the same way [LCV] (P).
- **Logic fine drag.** "Press and hold Shift while dragging the Volume fader to change the volume level in finer increments." [LCV] (P). This page is for the channel strip fader. Shift on the track header slider: unconfirmed.
- **Logic range and taper.** "The maximum boost is +6 dB." "You can reset the Volume fader to 0 dB (90) by Option-clicking it." [L9] (P, Logic 9.1.6 manual). So 0 dB is at the value 90 of 127, which is 0.709 of the travel. Logic 12.3 range: unconfirmed. User posts say that the top is +6.0 dB [LCU] (U). The minimum is -inf: unconfirmed in a vendor page.
- **Logic readout.** The track header slider holds a level meter: "The level meter in a track's Volume slider shows the output volume for the track as the project plays." [LTV] (P). Help tags show "parameter values" while you edit, when "Show Help Tags" is on [LHT] (S). A dB help tag on the track volume slider: unconfirmed.
- **GarageBand.** The page text is the same as Logic: drag left or right, "Option-click the slider to return it to a neutral level (0 dB gain)", and a level meter in the slider [GTV] (P). "You can watch the level meter as you record to the track to see if clipping occurs on the track." [GTV] (P). Range: a user post reports +6.0 dB [GCU] (U). Fine drag and readout: unconfirmed.
- **Keys.** A default key for track volume in Logic or GarageBand: unconfirmed.
- **Mix volume or input gain.** A user post says that the header slider sets the playback volume after the recording [GAV] (U). Inference: the same in Logic.

## 3. Final Cut Pro

- **Readout.** "As you drag, the volume level in dB appears, and the waveform changes shape to reflect your adjustments." [FV] (P).
- **Commands.** The app bundle names the commands "Raise Volume 1 dB", "Lower Volume 1 dB", "Reset Volume (0db)", "Set Volume to Silence (-∞)", "Adjust Volume Absolute…", and "Adjust Volume Relative…" [FCS] (P, `NSProCommandNames.strings`).
- **Keys.** The default command set binds `VolumeUp` to Control-= (and Control-= on the keypad) and `VolumeDown` to Control-minus [FCK] (P, `en.lproj/Default.commandset`). Reset and Silence have no default key in that file [FCK] (P). The user guide adds Control-Option-L for absolute and Control-L for relative [FV] (P).
- **Inspector.** "Drag the Volume slider right to increase the volume, or left to decrease it." [FV] (P). The iPad guide says that the inspector offset and the timeline volume add up [FVI] (P).
- **Range.** The user guide gives no minimum or maximum (unconfirmed). Forum posts of 2004 to 2011 say +12 dB [FCU] (U). Those posts are for Final Cut Pro 4 to 7, before Final Cut Pro X. The minimum is -inf through Silence [FCS] (P).
- **Fine drag.** Unconfirmed.

## 4. Adobe Audition and Reaper

- **Audition.** The Editor panel has a Volume knob on each track. Shift-drag changes it in large steps. Ctrl-drag (Windows) or Command-drag (macOS) changes it in small steps [AUB] (S, search summary of the Adobe page; the page refused the fetch with 403). "Alt-click or Option-click directly on a knob or fader returns it to unity gain" [AUB] (S). "Track volume can be set in the volume field on the left of the track" [AUK] (U, Community Expert). Range: unconfirmed.
- **Reaper.** Modifiers on the volume fader [RG §5.2] (P, 7.81 guide):
  - Ctrl: "Allows more precise control of fader level."
  - Double click: "Reset to zero (fader) or center (rotary)."
  - Alt: "When mouse is released, fader returns to its original position."
  - Ctrl-Shift: with more than one track selected, only the current track changes.
- **Reaper mix volume.** "the recording level cannot be controlled by adjusting the Track's volume fader: that controls only the playback level." [RG p59] (P).
- **Reaper range and taper.** The preferences can "restrict the adjustable range of your volume and/or pan faders. The top of the volume range can be set to 0dB or higher." A shape option exists: "set this to 1.0 and the fader becomes a log curve." [RG §22.7] (P). The default range: unconfirmed. The default gain of a new track is 0.0 dB [RG §22.3.2] (P).

## 5. Apple HIG, AppKit, and SwiftUI

- **HIG.** "Use familiar slider directions": the minimum is on the leading side [HIG] (P). For macOS: "provide a tooltip that displays the value of the thumb when people hold their pointer over it", and "Consider giving live feedback as the value of a slider changes." [HIG] (P). "Consider supplementing a slider with a corresponding text field" for exact values [HIG] (P). The rule "Don't use a slider to adjust audio volume" is in the **iOS, iPadOS** section, and is about the system volume view. It is not a macOS rule [HIG] (P).
- **Small size.** `ControlSize.small` is "for controls that can't be resized in one direction, such as … sliders". "Use a small system font with a small control." [CS] (P).
- **NSSlider.** `altIncrementValue` is "The amount by which the slider changes its value when the user Option-drags the slider knob." [NSS] (P). `neutralValue` (the fill origin) is macOS 26.0 and later [NSN] (P), so it is not available on macOS 14.
- **NSSlider double-click.** No AppKit page gives a double-click behavior for `NSSlider` (unconfirmed). A Cocoa-dev reply says to read `clickCount` in an override of `mouseDown(with:)`. It also says that `NSSlider` tracks the drag inside `mouseDown`, so `mouseUp` can fail to arrive [CD] (U). Inference: a double-click reset in AppKit needs a subclass.
- **Accessibility.** `NSSlider` conforms to `NSAccessibilitySlider` [NSS] (P). That protocol has `accessibilityLabel()`, `accessibilityValue()`, `accessibilityPerformIncrement()`, and `accessibilityPerformDecrement()` [NAS] (P). `accessibilityValueDescription()` gives "the human-readable description of the accessibility element's value" [NAV] (P). In SwiftUI, `accessibilityAdjustableAction(_:)` (macOS 10.15) adds the increment and decrement action to a custom view [SAA] (P). A SwiftUI `Slider` "uses the `step` to increase or decrease the value when a VoiceOver user adjusts the slider" [SS] (P).
- **SwiftUI `Slider`.** "The slider calls `onEditingChanged` when editing begins and ends. For example, on iOS, editing begins when the user starts to drag the thumb along the slider's track." [SSE] (P). The page gives the iOS case only; the macOS mouse-down and mouse-up timing is unconfirmed. `Slider` maps the value linearly ("a bounded linear range of values") [SS] (P). Inference: a dB taper needs a slider over a position (0 to 1) and a map from the position to dB. The `neutralValue` initializers are macOS 26.0 and later [SNV] (P).
- **SwiftUI double-click.** No source covers a double-click on a `Slider` (unconfirmed). On a macOS `List`, a `TapGesture(count: 2)` breaks the single-click selection [AF] (U). That is an analogy only.

## 6. Taper for a 60 to 120 pt slider

- **Ardour source.** Ardour maps the gain coefficient `g` (0 to 2, so the top is +6 dB) to a position `p` (0 to 1) [AR] (P, `libs/pbd/pbd/control_math.h`):

```c
return pow ((6.0 * log (g) / log (2.0) + 192.0) / 198.0, 8.0);
```

- Positions from this formula (our arithmetic): +6 dB 1.00; 0 dB 0.78; -3 dB 0.69; -6 dB 0.61; -12 dB 0.47; -20 dB 0.32; -40 dB 0.12; -60 dB 0.04. `g == 0` (-inf) is position 0.
- **Logic data point.** 0 dB at 90 of 127, which is 0.71 [L9] (P). Hindenburg: 0 dB at approximately 0.80 to 0.85 [HV] (O). Inference: the three apps put 0 dB at 70 % to 85 % of the travel.
- **Linear in dB.** Over -60 to +6 dB (66 dB) the scale is constant: 0.91 pt per dB at 60 pt, 1.5 pt per dB at 100 pt, 1.8 pt per dB at 120 pt. 0 dB is at 0.91 of the travel. The last few points at the left must snap to -inf.
- **Ardour curve, 100 pt.** From -6 to 0 dB it gives 17.5 pt (2.9 pt per dB). From -40 to -20 dB it gives 20 pt (1 pt per dB). From -60 dB to the left end it gives 4 pt.
- **Tradeoff.** The curve gives more travel near 0 dB, where a podcaster sets a speaker level (0 to -12 dB). Linear in dB is simpler to test and to read, but at 60 pt one point is more than 1 dB. At 60 to 120 pt, one mouse point is 0.3 to 1.1 dB near 0 dB with either scale. Inference: a fine drag modifier and a typed or keyed step matter more than the curve at this width.

## Open questions for the plan

State on 2026-11-24: F94 is done (Release 3 run 2). Decision 0039 (amended 2026-10-11) holds the fader rules, and the guide section "Set the volume of a track" describes it. The questions below are the list of 2026-10-11.

1. The Hindenburg PRO 2 minimum and maximum. Check the readout at both ends in a trial copy.
2. A probe for SwiftUI on macOS 14 (run after the loop, in a probe folder). The question: does a drag still start, and when does `onEditingChanged` fire?

```swift
import SwiftUI
struct Probe: View {
    @State var position = 0.78
    var body: some View {
        Slider(value: $position, in: 0...1) { editing in print("editing", editing, Date()) }
            .controlSize(.small)
            .frame(width: 100)
            .simultaneousGesture(TapGesture(count: 2).onEnded { position = 0.78; print("double") })
    }
}
```

   Run it again with `.onTapGesture(count: 2)` in place of `.simultaneousGesture`.
3. The reset gesture: double-click (Hindenburg, Reaper) or Option-click (Logic, GarageBand, Audition). Option-click also conflicts with the AppKit Option-drag of `altIncrementValue` if the control uses AppKit. This is a plan decision.

## Inputs for the run

- **Range.** No agreement. The sources agree only that 0 dB is unity and that the top is above 0 dB. Logic +6 dB [L9] (P, Logic 9). Hindenburg +6 dB is consistent but not stated [NX] [HV]. Final Cut Pro +12 dB in legacy versions [FCU] (U). Reaper is configurable [RG]. A -inf bottom: Final Cut Pro Silence [FCS] (P); others unconfirmed.
- **Taper.** 0 dB sits at 70 % to 85 % of the travel in Logic [L9] (P), Ardour [AR] (P), and Hindenburg [HV] (O). Ardour publishes its curve. Linear in dB is not seen in these references.
- **Reset.** Two groups. Double-click: Hindenburg [HJ] (P), Reaper [RG] (P). Option-click: Logic [LTV] (P), GarageBand [GTV] (P), Audition [AUB] (S). The target is 0 dB in all of them.
- **Fine drag.** No agreement. Shift: Logic channel strip [LCV] (P). Command: Audition [AUB] (S). Ctrl: Reaper [RG] (P). AppKit gives Option-drag steps [NSS] (P).
- **Keys.** Only Final Cut Pro has owner-source keys: Control-= and Control-minus for 1 dB steps [FCK] (P). Track volume keys in Hindenburg, Logic, GarageBand, and Audition: unconfirmed. Hindenburg Shift-Command-Up and Shift-Command-Down are region gain [HJ] (P).
- **Readout.** Agreement: a dB value shows during the drag. Hindenburg "+0.0 dB" tag with the sign and one decimal [HV] (O). Final Cut Pro "the volume level in dB appears" [FV] (P). Logic help tags show parameter values [LHT] (S). HIG asks for a value tooltip [HIG] (P).
- **Mix volume, not record gain.** Reaper states it [RG] (P). Hindenburg and GarageBand: Inference and U only.

## Sources

- [HJ] Hindenburg Journalist 1.21 user guide for OS X, pages 31, 44, 45, 97 (text and images read with PDFKit on 2026-10-11): https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HV] Hindenburg vendor video "Hindenburg PRO: Tracks - Volume" (21 s), frames `maxres1` to `maxres3`: https://hindenburg.com/data/youtube/videos/how-to-adjust-the-volume-on-a-track-in-hindenburg-pro-hindenburg/ and https://www.youtube.com/watch?v=cAiJ6LQ_UXg
- [HG] Hindenburg PRO guides page: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [HSC] Hindenburg PRO 2 shortcuts (server error on 2026-10-11): https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [NX] `.nhsx` field guide, section 5, measured against Hindenburg PRO 2.05.2718: https://github.com/ollisulopuisto/podcast/blob/main/docs/hindenburg-nhsx-format.md
- [LTV] Logic Pro, track volume in the track header: https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcp86b5c092.html
- [LTH] Logic Pro, track header overview: https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcpe53c68af.html
- [LCV] Logic Pro, set channel strip volume: https://help.apple.com/logicpro/mac/10.4.5/en.lproj/lgcp8ec34eec.html
- [L9] Logic Pro 9.1.6 manual, setting channel strip levels: https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_27_section_9.html
- [LHT] Logic Pro 9.1.6, display preferences (search summary): https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_44_section_6.html
- [LCU] Apple Community, "Logic Pro X max volume on mixer only goes…": https://discussions.apple.com/thread/251378765
- [GTV] GarageBand for Mac, track volume: https://help.apple.com/garageband/mac/10.1.5/en.lproj/gbnd79295c4f.html
- [GCU] Apple Community, "GarageBand - Volume on track Glitches": https://discussions.apple.com/thread/251446572
- [GAV] Ask.Video forum, header slider versus record level (search summary): https://test.ask.video/forums/audio/garageband/thread/9669-different-recording/3
- [FV] Final Cut Pro for Mac, adjust volume: https://support.apple.com/guide/final-cut-pro/verc1fabb77/mac
- [FVI] Final Cut Pro for iPad, adjust volume: https://support.apple.com/guide/final-cut-pro-ipad/dev9ffc54d16/ipados
- [FCS] Final Cut Pro 12.3 app bundle, `Contents/Resources/en.lproj/NSProCommandNames.strings` and `NSProCommandDescriptions.strings` (read on 2026-10-11)
- [FCK] Final Cut Pro 12.3 app bundle, `Contents/Resources/en.lproj/Default.commandset` (read with `plutil -p` on 2026-10-11)
- [FCU] Legacy Final Cut Pro forum posts on +12 dB: https://www.dvinfo.net/forum/final-cut-suite/50432-boosting-volume.html and https://creativecow.net/?p=513747
- [AUB] Adobe Audition, basic multitrack controls (403 on fetch; search summary): https://helpx.adobe.com/audition/desktop/mixing-multitrack-sessions/basic-multitrack-controls.html
- [AUK] Adobe Community, "multitrack change volume of track with keyboard": https://community.adobe.com/t5/audition-discussions/multitrack-change-volume-of-track-with-keyboard/m-p/14936737
- [RG] REAPER User Guide 7.81 (text read with PDFKit on 2026-10-11), section 5.2, page 59, sections 22.3.2 and 22.7: https://www.reaper.fm/userguide/ReaperUserGuide781c.pdf
- [AR] Ardour source, `libs/pbd/pbd/control_math.h`: https://github.com/Ardour/ardour/blob/master/libs/pbd/pbd/control_math.h
- [HIG] Human Interface Guidelines, Sliders: https://developer.apple.com/design/human-interface-guidelines/sliders
- [CS] AppKit, `NSControl.ControlSize.small`: https://developer.apple.com/documentation/appkit/nscontrol/controlsize-swift.enum/small
- [NSS] AppKit, `NSSlider` (members and conformances): https://developer.apple.com/documentation/appkit/nsslider
- [NSN] AppKit, `NSSlider.neutralValue`: https://developer.apple.com/documentation/appkit/nsslider/neutralvalue
- [NAS] AppKit, `NSAccessibilitySlider`: https://developer.apple.com/documentation/appkit/nsaccessibilityslider
- [NAV] AppKit, `accessibilityValueDescription()`: https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol/accessibilityvaluedescription()
- [SS] SwiftUI, `Slider`: https://developer.apple.com/documentation/swiftui/slider
- [SSE] SwiftUI, `Slider.init(value:in:onEditingChanged:)`: https://developer.apple.com/documentation/swiftui/slider/init(value:in:oneditingchanged:)
- [SNV] SwiftUI, `Slider` initializer with `neutralValue`: https://developer.apple.com/documentation/swiftui/slider/init(value:in:neutralvalue:enabledbounds:label:currentvaluelabel:minimumvaluelabel:maximumvaluelabel:oneditingchanged:)
- [SAA] SwiftUI, `accessibilityAdjustableAction(_:)`: https://developer.apple.com/documentation/swiftui/view/accessibilityadjustableaction(_:)
- [CD] Cocoa-dev, double-click on an `NSSlider`: https://lists.apple.com/archives/Cocoa-dev/2007/Mar/msg00767.html and https://lists.apple.com/archives/Cocoa-dev/2007/Apr/msg00550.html
- [AF] Apple Developer Forums, double tap on a macOS `List` item: https://developer.apple.com/forums/thread/654154
