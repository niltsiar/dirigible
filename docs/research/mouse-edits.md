# Mouse edits on the lanes in Hindenburg PRO

Date: 2026-09-26

This document records how Hindenburg edits regions and markers with the mouse: select, move, trim, the cursor zones, the ruler, and snapping. It also records the AppKit facts for cursors and context menus. It adds to `docs/research/edit-commands.md` (sections 1 to 3, 8, 11, 12) and does not repeat its video frames. The source tags [HM], [HW], and [V-*] have the same meaning as there. A claim that no primary source confirms has the mark "(unconfirmed)". A sentence that starts with "Inference:" is our reading of the sources.

## 1. Cursor zones on a region

- "Editing in Hindenburg is all done in one view. You can move, trim, gain and make selection. The cursor will change depending on where you are on the region." The zones are Drag Selection, Move Region, Level/gain, Trim, and Fade [HM p. 24].
- Move: "The cursor becomes an 'Arrow' when moved to the middle section of the region". "While dragging the cursor will turn to a fist" [HM p. 25].
- Trim: "Trim > Drag End Handles" [HM p. 25].
- Selection: "The cursor-tool will become an 'i' bean when placed at the lower part of a region. When the cursor-tool becomes an 'i' beam, you can drag a selection" [HM p. 26].
- Gain: "Adjust level > Drag Top Handle" [HM p. 29 to 30]. Fade: "Fade > Drag Corner Handles" [HM p. 30].
- Inference: from top to bottom, a region has the gain handle, the move zone in the middle, and the selection zone in the lower part. The ends trim. The corners fade. Release 1 has no gain handle and no fades, so the top part can also move.
- No source gives the width of the trim handle or the heights of the zones in pixels (unconfirmed).

## 2. Select a region

- "Mouse > click region" selects a region [HM p. 25]. "Select a region to edit the entire region" [HG].
- The frames of the region videos show that a click on a region selects its track and does not move the playhead (edit-commands.md section 1).
- Shift-click "Expand track selection". Cmd-click "Add track to selection" [HM p. 27].
- A triple-click on a blank area sets the in and out markers to it [HM p. 27].

## 3. Move a region

- "Move > Drag" in the middle zone [HM p. 25]. The Pro guide lists "Moves the region between tracks" [HG]. The video of that page shows Cmd-Up and Cmd-Down (edit-commands.md section 2). No source says if a mouse drag can change the track (unconfirmed).
- Drop on other regions: no source says if the dropped region overwrites, pushes, or refuses the regions under it (unconfirmed). Paste "Places Selection ON TOP of existing audio" [HM p. 29]. Inference: a drop also goes on top.
- No source documents a drag constraint (a modifier that locks time or track) (unconfirmed).

## 4. Trim

- "Drag Trim Handle" [HG]. "Drag the Region ends" [HW p. 16].
- No source says what a trim does at the next region or at the end of the file (unconfirmed). Inference: a region shows only the audio of its file, so a trim stops at the file.
- Shuffle trim (Shift-Cmd-drag) moves "the edit point without breaking the edit apart" [HG]. Release 1 does not have it.

## 5. Snapping

- The Pro guide says "The Region snaps to the nearest event" for Region Snap [HG]. The keys are Shift-Cmd-Left and Shift-Cmd-Right [V-snap].
- No source says that a mouse drag snaps to region edges, the playhead, or markers (unconfirmed). View > Grid > Fine Grid aligns regions to the timeline [V-finegrid].

## 6. Selection with Shift

- In PRO 2, a Shift-drag from an empty area draws a marquee that selects the regions in its rectangle [V-marquee] [HG]. Inference: Hindenburg has two selection kinds (regions and a range). Dirigible has two kinds, a range and a clip set, and one is active at a time (decision 0038).
- Shift-click extends the selection [HM p. 27].

## 7. Markers and in and out points on the ruler

- Add a marker: "double-click in the area below the timeline and select Add Marker", or Cmd-Return at the cursor [NT]. Inference: a menu opens on the marker area of the ruler, and the marker goes at the click position.
- The right-click menu of the ruler has Delete Marker (edit-commands.md section 8, [V-marker]).
- The same source says "You can drag the marker if you need to re-position it in the timeline" [NT, search excerpt]. The fetched page did not show this sentence, so it stays unconfirmed. No Hindenburg page shows a marker drag (unconfirmed).
- "To set in/out markers to make a loop, make a selection on a region, and the green in-marker and red out-marker will automatically be added" [NT]. "In / Out markers are always 1 + 2" [HM p. 59]. In and out points drag on the ruler (edit-commands.md section 8).

## 8. AppKit facts

- The cursors `arrow`, `iBeam`, `openHand`, `closedHand`, `pointingHand`, and `resizeLeftRight` compile with no warning at the macOS 14 target. `columnResize(directions:)` is macOS 15 and later. `resizeLeftRight` is marked "to be deprecated" with no version [A-CUR] [P-C1].
- A tracking area with `NSTrackingCursorUpdate` sends `cursorUpdate(with:)` when the pointer enters the area. `NSTrackingActiveInKeyWindow` limits the events to the key window [A-TRK].
- `NSView.menu(for:)` gives the context menu of a right-click or Control-click [A-MENU].
- `NSView.autoscroll(with:)` scrolls the clip view when a drag leaves it [A-VIEW]. It needs a drag event to run, so a pointer that stays still outside the view does not scroll (inference).

## Sources

- [HM] Hindenburg Journalist 1.21 user guide for macOS, pages 24 to 30 and 59 to 60 (text read with PDFKit on 2026-09-26): https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HW] Hindenburg Journalist guide for Windows: http://hindenburgsystems.com/wordpress/wp-content/uploads/2010/07/Hindenburg-Journalist-Guide-Windows.pdf
- [HG] Hindenburg Pro complete overview (the guide page with one line per function video): https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [NT] Notetracks, "How to take notes and add markers in every DAW", Hindenburg section: https://www.notetracks.com/blog/how-to-add-notes-and-markers-in-every-daw
- [V-marker] https://www.youtube.com/watch?v=wd4SjWBdloM; [V-marquee], [V-snap], [V-finegrid]: see `docs/research/edit-commands.md`.
- [A-CUR] AppKit header `NSCursor.h` of the macOS 26.2 SDK (Xcode 26), lines 60 to 102 and 157 to 162.
- [A-TRK] AppKit header `NSTrackingArea.h`, lines 21 to 27; https://developer.apple.com/documentation/appkit/nstrackingarea
- [A-MENU] https://developer.apple.com/documentation/appkit/nsview/menu(for:)
- [A-VIEW] https://developer.apple.com/documentation/appkit/nsview/autoscroll(with:)
- [P-C1] Probe C1, `.scratchpads/runs/2026-09-26-mouse-edits/probe/c1/output.txt` (macOS 15.7.9, Swift 6.2.4, `swiftc -target x86_64-apple-macos14.0 -warnings-as-errors`).
