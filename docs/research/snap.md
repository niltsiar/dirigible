# Snap in the timeline (F82)

Date: 2026-10-11

This file answers seven questions on snap for a clip move, a clip edge trim, and a range drag. It does not repeat `docs/research/mouse-edits.md` section 5 (the Hindenburg Region Snap key and the Fine Grid) or row F82 of `docs/research/logic-garageband-update.md` (the GarageBand yellow guides, Option-Command-G, and the Logic Snap menu values). It cites them.

Grades: **P** is a primary vendor page, a vendor manual, vendor source code, or a file in the installed app bundle. **S** is a search summary, a secondary page, or a trade article. **U** is a user post on a forum. **O** is our observation of a vendor image or video frame. "Unconfirmed" means that no source answers. A sentence that starts with "Inference:" is our reading. No probe, build, or on-screen check ran. The installed apps are Final Cut Pro 12.3, Logic Pro 12.3.1, and GarageBand 10.4.14. None of the three app bundles holds a `.help` book, so the help text comes from support.apple.com.

## 1. Final Cut Pro

- **Targets.** "Several elements trigger snapping in the timeline: Clip boundaries (start and end points), The playhead and the skimmer, Markers, Keyframes, Range selections" [FS] (P).
- **Tools.** Snapping affects "the Select tool, the Trim tool, the Position tool, the Range Selection tool, and the Blade tool" [FS] (P). So a move, a trim, and a range drag all snap.
- **Toggle.** "Choose View > Snapping (or press N). A checkmark next to the menu item indicates that snapping is on." [FS] (P). The bundle names the command "Snapping" and describes it as "Turn snapping on or off" [FCS] (P). The default command set binds `ToggleSnapping` to `n` with no modifier [FCK] (P).
- **Toggle during a drag.** "You can turn snapping on or off, even while you're dragging a clip." [FS] (P). "To turn snapping on or off temporarily, hold down the N key. When you release the N key, snapping reverts to its previous state." [FS] (P).
- **Button.** "Click the Snapping button in the top-right corner of the timeline. When snapping is on, the Snapping button is highlighted." [FS] (P). In the bundle, the button is one segment of a segmented control (`LKPaneCapSegmentedControl`) with the tooltip "Snapping". The other segments are skimming, audio skimming, solo, and "Beat Grid" [FCN] (P). The accessibility description of the group is "Solo, Toggle Audio Waveforms, Toggle Snapping" [FCN] (P). The icon image: unconfirmed.
- **Indicator.** "The skimmer appears as a red vertical line … If you have snapping turned on, the skimmer turns orange when it snaps to a position." [FSK] (P). The playback overview page says "turns yellow" for the same event [FPL] (P). The two current pages disagree on the color.
- **Guide line during a clip drag.** No page describes a separate guide line for a clip move or a trim (unconfirmed). Only the skimmer color is documented.
- **Distance and zoom.** No page states a snap distance or a change with the zoom level (unconfirmed).

## 2. Logic Pro and GarageBand

- **Logic Snap menu.** The Snap pop-up menu sets the grid value. "By default, the Snap function is set to 'Snap Regions to Absolute Value.' When you move or edit an item, it snaps exactly to the nearest grid position." "Snap Regions to Relative Value" keeps "the same relative distance from their original grid positions" [LSN] (P). Snap off: "Click the On/Off button on the left side of the Snap pop-up menu" or "Choose the 'Snap to Grid' menu item when it is checked" [LSN] (P).
- **Logic snap actions.** Snap acts on "Moving and resizing regions", "Moving the playhead", "Adjusting the cycle region", "Dragging loops", and "Moving automation points" [LSN] (P).
- **Logic and the zoom.** "Smart: Edit operations snap to the nearest bar, beat, sub-beat, and so on, depending on the current ruler division value and the zoom level." When the zoom is far out, "the Snap pop-up menu is temporarily dimmed, and Smart snap is used instead" [LSN] (P).
- **Logic modifiers during a drag.** "press and hold Control while dragging": the division value sets the grid. "press and hold Control and Shift while dragging": the grid "switches to ticks" when zoomed out, and "to samples" when zoomed in. "Using Control-Shift breaks the 1:1 relationship between the pointer and region … Watch the help tag for an exact numerical indication." [LSN] (P). These modifiers make the grid finer. No Logic page gives a modifier that turns snap off for one drag (unconfirmed).
- **Logic alignment guides.** "Alignment guides appear when the edges of a region you are moving align with another region in the timeline and when automation points you are moving align with other items in the timeline. Alignment guides briefly appear …" Turn them on or off with "Snap > Alignment Guides in the Tracks area menu bar" [LAG] (P). The bundle Quick Help repeats the first sentence and links to the same anchor `lgcp999b2add` [LQH] (P). The key is "Toggle Alignment Guides: Option-Command-G" [LKT] (P). The Logic page states no guide color and does not say that the region snaps to the guide (unconfirmed). The Logic key for Snap to Grid: unconfirmed (the Main Window Tracks key page lists none).
- **GarageBand.** The yellow guides and the snap to a guide are in row F82 [GAG] (P). The menu is "Edit > Alignment Guides". "Turning on alignment guides also turns on snapping, if it's off." [GAG] (P). The shortcut page gives "Show/Hide yellow alignment guides: Option-Command-G" and "Turn Snap to Grid on/off: Command-G" [GKS] (P). Snap to Grid acts on "Moving and resizing regions", "Moving the playhead", "Adjusting the cycle range", and "Dragging loops". "The grid value depends on the current zoom setting." [GSG] (P).
- **Distance.** No Logic or GarageBand page states a snap distance in points or pixels (unconfirmed).

## 3. Hindenburg PRO 2 and Hindenburg Journalist

- **Region Snap.** The PRO guide says "The Region snaps to the nearest event" [HG] (P), as `mouse-edits.md` section 5 records. The PRO 2 shortcut page answered on 2026-10-11. It lists "Regions - Snap Regions: shift + ctrl + right arrow (left arrow)" [HSC] (P). `mouse-edits.md` section 5 gives Shift-Cmd-Left and Shift-Cmd-Right from a vendor video. The two sources disagree on Ctrl or Cmd. Inference: the page uses the Windows names.
- **Snap targets.** A 2015 article on Journalist 1.51 says: "Snap regions to a point of interest; playhead, markers, end lines" [PVC] (S). It does not say if a drag or a key does the snap.
- **Drag snap.** The Journalist 1.21 user guide has no snap of a drag. Its only "snap" text is about the clip level ("let it snap" to the Auto level) and the voice profiler "Snap shot" [HJ] (P, full text search). The PRO guide page has no entry for a drag that snaps to a region edge, the playhead, or a marker [HG] (P). A drag snap is unconfirmed.
- **Grid.** View > Grid > Enabled and View > Grid > Fine Grid have no key on the PRO 2 shortcut page [HSC] (P).

## 4. Other references

- **Adobe Audition.** "If snapping is enabled, both dragged clips and the current-time indicator snap to selected items. While you drag a clip, a white line appears in the Editor panel when snapping points meet." Toggle: "click the Toggle Snapping icon at the top of the Editor panel" or "Edit > Snapping > Snap To Clips" [AUA] (P, archived copy). Other targets are markers, ruler ticks (coarse or fine), zero crossings, and frames [AUS] (P, archived copy). The archived default shortcuts page lists no snap command [AUK] (P). The S key: unconfirmed. A modifier for one drag: unconfirmed.
- **Pro Tools.** "Grid Mode snaps your clips to a predefined grid". "Hold the Command key (Mac) or Ctrl key (Windows) while dragging or trimming a clip to momentarily toggle between Grid and Slip Modes" [PT] (P). F1 to F4 select the four edit modes [PT] (P).
- **Reaper.** "Alt S toggle snapping on and off" [RG p46] (P). Item table: "Move item/items, ignore snap and time selection: Select items and Shift drag." "Shift Ctrl drag to ignore snap" for a copy [RG pp124-125] (P). A loop selection edge drag: "Holding Ctrl while you do this cause any snap settings to be ignored" [RG p46] (P). Reaper names Windows keys. Inference: Ctrl is Command on macOS.
- **Ableton Live.** "Clips snap to the editing grid, as well as various objects in the Arrangement including the edges of other clips, locators and time signature changes." "Cmd 4 (Mac) turns grid snapping on or off." "You can hold down the Alt (Win) / Cmd (Mac) modifier while performing an action to bypass grid snapping. If the grid is switched off, using the modifier will temporarily enable it." [ABL] (P).
- **Premiere Pro.** "make sure the Snap in Timeline (S) icon is turned on (highlighted)". "Drag the edge of a clip close to the edge of another clip or marker, or the playhead. When the clip is close enough, it will automatically snap into alignment, and a vertical line will appear to indicate the adjusted alignment." [PR] (P, archived copy; the live page returned 403). A modifier for one drag: unconfirmed.
- **Ardour (source code).** The default snap targets are on for marks, the playhead, the region start, and the region end (`snap-to-marks`, `snap-to-playhead`, `snap-to-region-start`, `snap-to-region-end` all `true`) [ARU] (P).

## 5. Snap distance

- **Reaper.** A user setting in pixels. Example: "with grid spacing at 50 pixels and snap distance at 5 pixels … snapping to grid will occur only within 5 pixels of any grid line." A second example uses "a snap distance of 10 pixels": "if you drag the selection to within 10 pixels of the marker position, the selection will automatically snap to the marker" [RG pp142, 177] (P). The default value: unconfirmed.
- **Ardour.** `snap_threshold` default `25`, shown as "Snap Threshold (pixels)", range 10 to 200 [ARU] [ARO] (P).
- **Final Cut Pro, Logic, GarageBand, Hindenburg, Audition, Pro Tools, Ableton, Premiere.** No page states a distance (unconfirmed). Premiere says only "When the clip is close enough" [PR] (P).
- **Apple HIG and AppKit.** The HIG pages Playing haptics, Drag and drop, and Feedback give no snap distance and no guide look [HH] [HDD] [HFB] (P). Keynote (an Apple app) shows guides "as you drag an object on a slide in alignment with, or equidistant to, another object", with a user color in Settings > Rulers [KN] (P). It gives no distance. An NSView or Interface Builder guide distance: unconfirmed.
- Inference: where a source states a distance, it is in screen pixels, not in time. So the time range of a snap gets smaller as the zoom goes in.

## 6. A modifier during the drag

- **Pressed after the mouse-down.** Final Cut Pro: N "even while you're dragging a clip", and hold N for a temporary change [FS] (P). Ableton: Cmd "while performing an action" [ABL] (P). Pro Tools: Command "while dragging or trimming" [PT] (P). Ardour reads the modifier state from the event of the drag (`ArdourKeyboard::indicates_snap (event->button.state)`) [ARE] (P). Inference: Ardour reads it on each event. The Ardour macOS default snap modifier is Option-Shift, with the source comment "XXX this is probably completely wrong" [ARK] (P).
- **Held from the mouse-down only.** Reaper says "Shift drag" [RG p124] (P). It does not say if Shift pressed later works (unconfirmed).
- **Finer, not off.** Logic Control and Control-Shift [LSN] (P).
- **None documented.** GarageBand, Hindenburg, Audition, Premiere (unconfirmed).

## 7. Haptic feedback at a snap

- **`NSHapticFeedbackManager`.** "An object that provides access to the haptic feedback management attributes on a system with a Force Touch trackpad." (macOS 10.11) [NHM] (P).
- **`.alignment`.** "A haptic feedback pattern to be used in response to the alignment of an object the user is dragging around." The examples include "positioning an object at a preferred location, or reaching the beginning/minimum or end/maximum of something, such as a track view in an audio/video app." [NHA] (P).
- **`defaultPerformer`.** It returns a performer "based on the current input device, accessibility settings, and user preferences". "you should request the default performer whenever you need to provide haptic feedback" [NHD] (P).
- **`perform(_:performanceTime:)`.** "a Force Touch trackpad won't provide haptic feedback if the user isn't touching the trackpad." "Call this method only in response to user-initiated actions. Ideally, visual feedback, such as a highlight or appearance of an alignment guide, should accompany the feedback." [NHP] (P). `PerformanceTime.default` is "the next time the screen is updated" [NHT] (P).
- **`NSHapticFeedbackPerformer`.** "Excessive or unnecessary haptic feedback could be interpreted by the user as a malfunction" [NHF] (P).
- **HIG.** "On a Mac that's equipped with a Force Touch trackpad, an app can play haptics while people drag content". The Alignment pattern "Indicates the alignment of a dragged item" [HH] (P). The Feedback page asks for feedback by "color, text, sound, and haptics" so that people get it in more than one way [HFB] (P).
- **Hardware.** The AppKit pages name only a Force Touch trackpad; the HIG says "When a Magic Trackpad is available" [HH] (P). A mouse gets no haptic. Inference: the haptic is an addition to the guide line, never the only signal.
- **Vendor apps.** No audio or video vendor page says that its snap plays a haptic (unconfirmed).

## Inputs for the run

- **Targets.** Agreement on clip edges, the playhead, and markers: Final Cut Pro [FS], Audition [AUA] [AUS], Ableton [ABL], Premiere [PR], Ardour [ARU] (all P). Hindenburg Region Snap names the same targets [PVC] (S). Final Cut Pro adds range selections and keyframes [FS] (P).
- **Toggle.** View > Snapping with N in Final Cut Pro [FS] (P). Edit > Snap to Grid with Command-G in GarageBand [GKS] (P). The Snap pop-up in Logic [LSN] (P). Alt-S in Reaper [RG] (P). Cmd-4 in Ableton [ABL] (P). S in Premiere [PR] (P). A toolbar or timeline button that is highlighted when on: Final Cut Pro [FS], Premiere [PR], Audition [AUA] (P).
- **Look.** A vertical line: white in Audition [AUA] (P), no stated color in Premiere [PR] (P), yellow guides in GarageBand [GAG] (P), an orange or yellow skimmer in Final Cut Pro [FSK] [FPL] (P). Keynote guides use a user color [KN] (P).
- **One-drag override.** Mid-drag is documented in Final Cut Pro (N), Ableton (Cmd), and Pro Tools (Command). Command is the most common modifier: Ableton and Pro Tools (P), Reaper Ctrl on Windows (Inference: Command on macOS).
- **Distance.** Pixels where stated: Reaper 5 or 10 px examples [RG] (P), Ardour 25 px default [ARU] (P).

## Open questions for the plan

1. A clip edge that snaps to a clip edge on another track is the most common gesture. Only Ableton ("the edges of other clips") and Audition ("align clips with other clips") state it. Final Cut Pro says "Clip boundaries" with no track scope. Decide whether the targets include all tracks or only the dragged clip's track.
2. The modifier conflicts with this repo. Shift-drag draws a marquee in Hindenburg (`mouse-edits.md` section 6). Shift-Cmd-drag is the Hindenburg shuffle trim (`mouse-edits.md` section 4). Command is the Logic Command-click tool (`ripple-edit.md`). Control and Control-Shift are Logic finer snap (`ripple-edit.md`, [LSN]). Check the modifiers that the timeline already uses before the plan picks one.
3. The key: N (Final Cut Pro), S (Premiere), Command-G (GarageBand), or Option-Command-G (Logic and GarageBand guides). Check the keys that Dirigible already uses.
4. The snap distance in points, and whether the distance stays fixed when the zoom changes. No Apple source gives a value.
5. The Final Cut Pro skimmer color: orange [FSK] or yellow [FPL]. An on-screen check of Final Cut Pro 12.3 can settle it.

## Sources

- [FS] Final Cut Pro for Mac, snap to items in the timeline: https://support.apple.com/guide/final-cut-pro/ver9f7888dc3/mac
- [FSK] Final Cut Pro for Mac, skimmer: https://support.apple.com/guide/final-cut-pro/ver8e3f32f0/mac
- [FPL] Final Cut Pro for Mac, intro to playback: https://support.apple.com/guide/final-cut-pro/veradb8241c/mac
- [FCS] Final Cut Pro 12.3 app bundle, `Contents/Resources/en.lproj/NSProCommandNames.strings` and `NSProCommandDescriptions.strings` (read with `plutil -p` on 2026-10-11)
- [FCK] Final Cut Pro 12.3 app bundle, `Contents/Resources/en.lproj/Default.commandset` (read with `plutil -p` on 2026-10-11)
- [FCN] Final Cut Pro 12.3 app bundle, `Contents/Resources/Base.lproj/PEEditorContainerModule.nib` and `MainMenu.nib` (read with `strings` on 2026-10-11)
- [LSN] Logic Pro for Mac, snap items to the grid: https://support.apple.com/guide/logicpro/snap-items-to-the-grid-lgcpf7c0f66a/mac
- [LAG] Logic Pro for Mac, use alignment guides: https://support.apple.com/guide/logicpro/lgcp999b2add/mac
- [LQH] Logic Pro 12.3.1 app bundle, `Contents/Resources/en.lproj/QuickHelp.plist`, keys `ARR_067_AlignmentGuides` and `ARR_005_SnapPopupMenu` (read on 2026-10-11)
- [LKT] Logic Pro for Mac, key commands for Main Window Tracks: https://support.apple.com/guide/logicpro/lgcpb99be9c5/mac
- [GAG] GarageBand for Mac, use alignment guides: https://support.apple.com/guide/garageband/gbnd5456b51d/mac
- [GKS] GarageBand for Mac, main window shortcuts: https://support.apple.com/guide/garageband/main-window-shortcuts-gbnd58362a62/mac
- [GSG] GarageBand for Mac, snap items to the grid: https://support.apple.com/guide/garageband/gbnd18b085e9/mac
- [HG] Hindenburg PRO guides page: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [HSC] Hindenburg PRO 2 shortcuts (answered on 2026-10-11): https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [HJ] Hindenburg Journalist 1.21 user guide for OS X (full text read with PDFKit on 2026-10-11): https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [PVC] ProVideo Coalition, "Hindenburg Journalist 1.51 adds new features", 2015-11-27: https://www.provideocoalition.com/hindenburg-journalist-1-51-adds-new-features/
- [AUA] Adobe Audition, arrange and edit multitrack clips, archived copy: https://web.archive.org/web/2025/https://helpx.adobe.com/audition/desktop/mixing-multitrack-sessions/arranging-editing-multitrack-clips.html
- [AUS] Adobe Audition, selecting audio (snap to markers, rulers, frames, and zero crossings), archived copy: https://web.archive.org/web/2025/https://helpx.adobe.com/audition/desktop/editing-audio-files/selecting-audio.html
- [AUK] Adobe Audition, default keyboard shortcuts, archived copy: https://web.archive.org/web/2025/https://helpx.adobe.com/audition/desktop/keyboard-shortcuts/default-keyboard-shortcuts.html
- [PT] Avid, edit modes in Pro Tools: https://www.avid.com/pro-tools/user-guide/edit-modes
- [RG] REAPER User Guide 7.81 (text read with PDFKit on 2026-10-11), pages 46, 124, 125, 141, 142, 177: https://www.reaper.fm/userguide/ReaperUserGuide781c.pdf
- [ABL] Ableton Live manual, Arrangement View (sections 6.7 and 6.10): https://www.ableton.com/en/manual/arrangement-view/
- [PR] Adobe Premiere, snap clips, archived copy of 2026-04-15 (the live page returned 403): https://web.archive.org/web/20260415030521/https://helpx.adobe.com/premiere/desktop/edit-projects/change-clip-sequence/snap-clips.html
- [ARU] Ardour source, `gtk2_ardour/ui_config_vars.inc.h`: https://github.com/Ardour/ardour/blob/master/gtk2_ardour/ui_config_vars.inc.h
- [ARO] Ardour source, `gtk2_ardour/rc_option_editor.cc` ("Snap Threshold (pixels)"): https://github.com/Ardour/ardour/blob/master/gtk2_ardour/rc_option_editor.cc
- [ARE] Ardour source, `gtk2_ardour/editor_drag.cc`: https://github.com/Ardour/ardour/blob/master/gtk2_ardour/editor_drag.cc
- [ARK] Ardour source, `libs/gtkmm2ext/keyboard.cc`: https://github.com/Ardour/ardour/blob/master/libs/gtkmm2ext/keyboard.cc
- [KN] Keynote for Mac, use alignment guides: https://support.apple.com/guide/keynote/tan738df74cb/mac
- [HH] Human Interface Guidelines, Playing haptics: https://developer.apple.com/design/human-interface-guidelines/playing-haptics
- [HDD] Human Interface Guidelines, Drag and drop: https://developer.apple.com/design/human-interface-guidelines/drag-and-drop
- [HFB] Human Interface Guidelines, Feedback: https://developer.apple.com/design/human-interface-guidelines/feedback
- [NHM] AppKit, `NSHapticFeedbackManager`: https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager
- [NHA] AppKit, `NSHapticFeedbackManager.FeedbackPattern.alignment`: https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager/feedbackpattern/alignment
- [NHD] AppKit, `NSHapticFeedbackManager.defaultPerformer`: https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager/defaultperformer
- [NHT] AppKit, `NSHapticFeedbackManager.PerformanceTime`: https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager/performancetime
- [NHF] AppKit, `NSHapticFeedbackPerformer`: https://developer.apple.com/documentation/appkit/nshapticfeedbackperformer
- [NHP] AppKit, `perform(_:performanceTime:)`: https://developer.apple.com/documentation/appkit/nshapticfeedbackperformer/perform(_:performancetime:)
