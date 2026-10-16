# Timeline clarity: ruler, in and out, clip header, clip edges, playhead, record-over notice

Date: 2026-10-16

This file cites the files in `docs/research/` by section and does not repeat them. "Inference:" marks our reading. "(unconfirmed)" marks a claim that no source states. A [T-*] tag is one low-resolution thumbnail of an official Hindenburg video, with the 1.x interface. The Audition pages are Wayback Machine copies, because helpx.adobe.com returned 403.

## Q1 Ruler click and drag

- Hindenburg: a right-click on the ruler opens the marker menu. The in and out triangles drag on the ruler (timeline-view.md section 2). No source says what a plain click or a drag on an empty part of the ruler does (unconfirmed).
- Logic: the ruler has zones. "click a position in the lower half of the ruler" sets the playhead [LP-play]. "drag left or right in the upper part of the ruler" sets the cycle area, a yellow strip, and turns on Cycle mode [LP-cycle]. The optional marquee ruler makes "a marquee selection across all tracks", and a Shift-click removes one track [LP-marquee]. The autopunch area is "a red stripe in the middle third of the ruler" [LP-punch].
- GarageBand: a click in the lower part sets the playhead [GB-play]. A drag in the top part sets the yellow cycle area [GB-cycle].
- FCP: "Move the playhead by clicking or dragging in the ruler at the top of the timeline, or by clicking the timeline background" [FCP-nav].
- Audition: "In the timeline, drag the indicator or click a specific time point" [AU-nav]. A range is a Time Selection drag in "an empty area of the track display" [AU-multi]. A left-drag in the ruler is not documented (unconfirmed).
- Scope: in Hindenburg the in and out lines cross all tracks, and the selection band shows only on the selected tracks (timeline-view.md section 6). The Logic marquee ruler spans all tracks [LP-marquee].

## Q2 In and out markers and a region click

- Hindenburg: an I-beam drag in the lower part of a region sets the green in and red out markers [HM p. 26]. A triple-click on a region or a gap also sets them (timeline-playback.md section 3). A plain click turns the region orange and does not move the playhead (edit-commands.md section 1). [T-region] shows an orange region and no in or out triangle. Inference: a plain click sets no in and out. Esc or a double-click on an empty area clears the selection, and faint "ghosted" lines stay [HM p. 26] (timeline-view.md section 6).
- Logic: selected regions "appear highlighted" [LP-select]. The cycle follows the selected region only when Auto Set Locators > By Region Selection is on [LP-cycle].
- GarageBand: "Selected regions appear brighter in the Tracks area than unselected regions" [GB-select].
- FCP: a selected clip gets a yellow border (multi-clip-selection.md section 7). A clip click moves the playhead: "To prevent the playhead from moving while you select a clip in the timeline, press Option as you click" [FCP-nav].
- Audition: a click selects a clip [AU-clips]. A Time Selection drag from "the center of a clip" selects a range and clips [AU-multi].

## Q3 Clip header bar

- Hindenburg: PRO 2.05 has a region header. "Double-click a region header to select all connected regions." "Triple-click a region header to select all regions on the track" [R2724]. No source shows its look or says that a drag on it moves the region (unconfirmed). The 1.x frames show the name at the bottom-left (timeline-view.md section 5).
- Logic: no source documents a name bar. The Fade tool is at the upper-left and upper-right edges, and the Marquee tool is in the lower half [LP-edit]. Resize is at the lower edges [LP-resize].
- GarageBand: resize is at the lower edges. The Junction pointer is at the upper edge where two regions meet [GB-resize]. Rename is in the shortcut menu [GB-rename].
- Audition: "You can also drag the clip header with any tool." Option-drag on the header copies the clip. A double-click on it opens the Waveform Editor [AU-clips]. For takes, "The header displays the track name, followed by take number" [AU-rec]. The height is unconfirmed.
- FCP: the Clip Names checkbox labels clips by name, and a Clip Height slider sets the height [FCP-look].

## Q4 Clip boundaries

- Hindenburg: [T-region] and [T-drag] show unselected regions as separate light blue boxes. Two adjacent regions show a thin vertical line at the shared edge, also with no selection.
- Logic and GarageBand: "Regions appear as rounded rectangles in the Tracks area" [LP-regions] [GB-regions]. The Junction pointer at the shared upper edge resizes both regions [LP-resize] [GB-resize].
- FCP: a cut with continuous media shows a dotted "through edit" line (final-cut-pro.md section 3).
- Audition: with overlapping clips, "only the top-most clip plays" [AU-clips]. The edge look is unconfirmed.

## Q5 Playhead look

- Hindenburg: [T-region], [T-inout], and [T-drag] show the playhead as a thin light grey line across all tracks. The in point is a green triangle and line, and the out point is red (timeline-view.md section 4). No playhead head is visible at this resolution (unconfirmed).
- Logic and GarageBand: the playhead is "the vertical line showing the current playback position" [LP-play] [GB-play]. The cycle is yellow, and the Logic autopunch area is red [LP-cycle] [LP-punch]. The playhead color is unconfirmed.
- FCP: "The playhead appears as a light gray vertical line." The skimmer is "a red vertical line" that turns yellow [FCP-play] or orange [FCP-skim] when it snaps.
- Audition: the current-time indicator is "In the timeline near the top of the panel" [AU-nav]. Its color is unconfirmed.

## Q6 Record-over warnings

- No page that we read documents a warning before a recording replaces audio.
- Hindenburg: "Punch in Recording: Manually punch in to record" [HG]. A 2021 user post says that a punch-in "overwrites anything following it" [UV-punch]. Paste "Places Selection ON TOP of existing audio" [HM p. 29].
- Logic: by default, a recording over an audio region makes a take folder, a track, or a track alternative [LP-recset]. In Replace mode, "any audio regions from when you start recording until the end of recording will be erased, even if nothing is played" [LP-replace]. With Quick Punch-In, the new region "replaces the previously recorded region" [LP-punch].
- GarageBand: cycle recording makes a take folder [GB-takes]. A plain record over a region is unconfirmed.
- FCP: voiceovers land "as connected clips in the timeline" [FCP-vo]. Inference: a voiceover never replaces a clip.
- Audition: "Each recording becomes a new audio clip on a track." A punch-in leaves "the original clip intact" [AU-rec].
- HIG: "Warn people when they initiate a task that can cause data loss that's unexpected and irreversible", but not when loss "is the expected result" [HIG-fb]. Avoid alerts "for common, undoable actions, even when they're destructive" [HIG-alert].

## Q7 HIG: in-window notices and ranges

- "display status information in a passive way", but "a warning about possible data loss needs to interrupt people" [HIG-fb].
- "Consider integrating status feedback into your interface", near the items that it describes [HIG-fb].
- "Avoid using an alert merely to provide information." Use "an alternative way to communicate it within the relevant context", like the Mail indicator [HIG-alert].
- "Avoid using a popover to show a warning", use an alert. A popover must not cover "any essential content". A Close button is "for confirmation and guidance only" [HIG-pop].
- We found no macOS HIG page for an in-window banner, and no rule for its close control (unconfirmed absence).
- No HIG rule covers a timeline range. The I-beam means "Selection and insertion of text" [HIG-ptr].

## Open questions

- Hindenburg: does a plain ruler click move the playhead? Does a drag on an empty ruler make a range?
- Hindenburg PRO 2.05 region header: look, height, and drag to move.
- Playhead color in Logic, GarageBand, and Audition, and the Hindenburg playhead head.
- GarageBand record over a region with Cycle off.
- The inference that a Hindenburg region click sets no in and out rests on one thumbnail. It was not checked against a click on the PRO 2 region header.

## Sources

- [HM] Hindenburg Journalist 1.21 user guide for macOS, pages 26 and 29: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HG] https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [R2724] https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_05-build-2724/
- [UV-punch] https://hindenburg.uservoice.com/forums/224350-general/suggestions/42480820-punch-in-recording-for-part-of-a-region
- [T-region] https://i.ytimg.com/vi/47ExzZPf1ZU/maxresdefault.jpg
- [T-inout] https://i.ytimg.com/vi/sx-JseHItFU/maxresdefault.jpg
- [T-drag] https://i.ytimg.com/vi/P8YW91vfCH8/maxresdefault.jpg
- [LP-play] https://support.apple.com/guide/logicpro/set-the-playhead-position-lgcp0f34ca7a/mac
- [LP-cycle] https://support.apple.com/guide/logicpro/use-the-cycle-area-lgcp59e41e86/mac
- [LP-marquee] https://support.apple.com/guide/logicpro/select-parts-of-regions-lgcpf7c0ae21/mac
- [LP-punch] https://support.apple.com/guide/logicpro/punch-in-and-out-of-audio-recordings-lgcpb19bfd0d/mac
- [LP-replace] https://support.apple.com/guide/logicpro/replace-audio-recordings-lgcpb19d42b3/mac
- [LP-recset] https://support.apple.com/guide/logicpro/recording-preferences-lgcp411dd5c8/mac
- [LP-select] https://support.apple.com/guide/logicpro/select-regions-lgcpf7c0e62a/mac
- [LP-regions] https://support.apple.com/guide/logicpro/regions-overview-lgcpf7c0d0bb/mac
- [LP-resize] https://support.apple.com/guide/logicpro/resize-regions-lgcpf7c0c964/mac
- [LP-edit] https://support.apple.com/guide/logicpro/editing-preferences-lgcp35dc6d37/mac
- [GB-play] https://support.apple.com/guide/garageband/move-the-playhead-gbnd912c61f4/mac
- [GB-cycle] https://support.apple.com/guide/garageband/use-the-cycle-area-gbndac973a7d/mac
- [GB-select] https://support.apple.com/guide/garageband/select-regions-gbnd6c1f8df4/mac
- [GB-regions] https://support.apple.com/guide/garageband/what-are-regions-gbndf0ef0221/mac
- [GB-resize] https://support.apple.com/guide/garageband/resize-regions-gbnd29c6925e/mac
- [GB-rename] https://support.apple.com/guide/garageband/rename-regions-gbnd3b0f4c81/mac
- [GB-takes] https://support.apple.com/guide/garageband/record-multiple-audio-takes-gbndf80e7097/mac
- [FCP-nav] https://support.apple.com/guide/final-cut-pro/navigate-your-project-ver1632c98e/mac
- [FCP-play] https://support.apple.com/guide/final-cut-pro/intro-to-playback-veradb8241c/mac
- [FCP-skim] https://support.apple.com/guide/final-cut-pro/skimmer-ver8e3f32f0/mac
- [FCP-look] https://support.apple.com/guide/final-cut-pro/adjust-timeline-clip-appearance-verb8e5d346/mac
- [FCP-vo] https://support.apple.com/guide/final-cut-pro/verc1faa9c5/mac
- [AU-nav] https://web.archive.org/web/20251205025547/https://helpx.adobe.com/audition/using/navigating-time-playing-audio.html
- [AU-multi] https://web.archive.org/web/20260116000627/https://helpx.adobe.com/audition/using/multitrack-editor-overview.html
- [AU-clips] https://web.archive.org/web/20260115195752/https://helpx.adobe.com/audition/using/arranging-editing-multitrack-clips.html
- [AU-rec] https://web.archive.org/web/20251206171543/https://helpx.adobe.com/audition/using/recording-audio.html
- [HIG-fb] https://developer.apple.com/design/human-interface-guidelines/feedback
- [HIG-alert] https://developer.apple.com/design/human-interface-guidelines/alerts
- [HIG-pop] https://developer.apple.com/design/human-interface-guidelines/popovers
- [HIG-ptr] https://developer.apple.com/design/human-interface-guidelines/pointing-devices
