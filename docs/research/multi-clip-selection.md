# Multi-region selection in other editors

Date: 2026-10-04

This file answers eight questions on how editors select and edit several regions at once. It does not repeat the Hindenburg facts. See `docs/research/edit-commands.md` sections 1, 2, 4, 5, 11, 12 and `docs/research/mouse-edits.md` sections 2, 3, 6. Tags like [L-select] point to `## Sources`.

## 1. Add or remove one region

- Logic: "Press and hold Shift as you click the regions in the Tracks area." [L-select] The page names no modifier to remove one region. A Shift-click on a selected region may toggle it (unconfirmed).
- Final Cut Pro (FCP): "Hold down the Command key as you click the clips you want to select." [F-select] A Command-click on a selected clip deselects it [F-select].
- Hindenburg: Cmd-click adds regions (edit-commands.md section 5).
- Audition: Ctrl-click (Windows) or Command-click (Mac) selects several clips with the Move or Time Selection tool [A-search].
- Reaper: Ctrl-click toggles item selection. Shift-click adds an item [R-search]. This comes from a search result. The full guide was not read.
- Plain click on a selected clip: no source says whether it keeps the multi-selection (unconfirmed). Inference: a plain click on a clip that is already selected must keep the group when the click starts a drag. If it did not, a drag could not move the group. Not checked against Hindenburg or Reaper.

## 2. Marquee (rubber band)

- Logic: "Drag around the regions to enclose them." [L-select] Inference: "enclose" means a region must be fully inside. The page does not say what happens to a region that is only touched (unconfirmed).
- FCP: "Drag a selection rectangle over the timeline or event clips you want to select." [F-select] The page does not say if a clip must be fully enclosed (unconfirmed).
- Hindenburg: Shift-drag (edit-commands.md section 11). Full or touch is unconfirmed there.
- Reaper: right-drag marquee. Shift-right-drag adds to the selection [R-search].
- Logic has a second marquee, the Marquee tool. It selects parts of regions, not whole regions [L-marquee]. See section 6.

## 3. Multi-move

- Logic, drag: "Drag an audio region up or down ... to another audio track." [L-move] The page does not say that a drag of one region moves all selected regions, or that the track offsets stay (unconfirmed).
- Logic, menu: Edit > Move > To Selected Track moves the selected regions to one track and keeps their time positions [L-move]. This is not a drag.
- Logic, type rule: "move them to another track of the same type ... an audio region to another audio track ... but not to a software instrument track" [L-move]. Mono and stereo are not named (unconfirmed).
- Logic, snap: a moved region "snaps to the nearest position on the Tracks area grid". Control while dragging moves by one division. Control-Shift moves by one tick or one sample [L-move].
- FCP: "select one or more clips. Drag the clips to a new location." The user sees "an outline of your selection at the new position" [F-arrange].
- No source says what happens when a group would go past the last track (unconfirmed).
- Nudge: Logic nudges all selected regions by the nudge value (Option-Left or Right Arrow) [L-move]. FCP nudges "one or more clips" with Comma and Period [F-arrange].

## 4. Collisions

- Logic Drag menu [L-drag]:
  - Overlap: "Preserves the current region borders when you drag one region over another."
  - No Overlap: "the overlapped area of the left (earlier) region is shortened."
  - X-Fade: audio overlap is crossfaded.
  - Shuffle R and Shuffle L: the regions "switch positions".
  - "When two audio regions on the same track overlap, only the later (right) region is heard."
- FCP default drag ripples: it "moves other clips to make room". The Position tool (P) overwrites: "the moved clip will overwrite any clips at the new position" and a gap clip fills the old place [F-arrange] [F-search]. The overwrite text comes from a search result of the Arrange page. The Overwrite page was not read.
- No source covers moved regions that collide with each other. Inference: a group that moves as one unit keeps its internal offsets, so this case cannot arise on the same track.

## 5. Edits on a multi-selection

- Logic Region inspector: the title bar shows the number of regions. "If you alter any region parameter, all selected regions are affected." A differing value shows "*". A change keeps the differences (relative). Option-Shift sets the same value for all (absolute) [L-inspector].
- Logic Cut, Copy, Paste: the page uses the singular "the region" [L-copy]. Paste goes to the selected track at the playhead [L-copy]. The page does not say where disjoint regions go. A search summary said that they keep their relative positions. The page text does not say it (unconfirmed).
- Logic Delete: not read (unconfirmed).
- FCP: actions apply to "one or more clips" for move and nudge [F-arrange]. Other edits were not read.
- Hindenburg: Cut, Copy, Paste, move, and nudge (edit-commands.md sections 4, 5).

## 6. Region selection and range selection

- Logic: a marquee selection selects "only the part of the region inside the marquee". Edits "such as moving, cutting, copying, and deleting" act on that area. "After editing, the selected area becomes a new, separate region." [L-marquee] The page does not say if a marquee and a region selection exist together (unconfirmed).
- Logic: with a marquee, recording replaces the marquee by punch locators [L-marquee].
- FCP: a range is a selection inside a clip. Pressing X sets the range to a clip, and "converts a full clip selection into a range selection" [F-range]. Inference: FCP holds one kind at a time. No source says it outright.
- Hindenburg: no source (edit-commands.md section 12).

## 7. Selection look

- Logic: "regions appear highlighted in the Tracks area" [L-select]. No color is named.
- FCP: "A yellow border appears around the clip". A range also has "a yellow border and range handles" [F-select] [F-range].
- Hindenburg: selected regions turn orange (edit-commands.md section 1, 11).
- Inference: a range band and a region selection need two clear looks. FCP uses the same color for both, with handles for the range.

## 8. Undo

- No source says whether a multi-move is one undo step (unconfirmed). Hindenburg shows "Undo Move: <region>" (edit-commands.md section 2). Inference: one drag is one command, so one step.

## Open questions

- Plain click on a selected clip: keep or reduce.
- Marquee: fully inside or touch (Logic, FCP, Hindenburg).
- Multi-move past the last track, and mono to stereo.
- Paste of disjoint regions.
- Region selection with a range at the same time.
- Undo grouping of a multi-move.
- Logic and FCP guides give no Delete text for several regions.

## Sources

- [L-select] Apple, Logic Pro User Guide, "Select regions in the Tracks area". https://support.apple.com/guide/logicpro/select-regions-lgcpf7c0e62a/mac
- [L-move] Apple, "Move regions". https://support.apple.com/guide/logicpro/move-regions-lgcpf7c0d489/mac
- [L-drag] Apple, "Use drag modes". https://support.apple.com/guide/logicpro/control-positioning-with-drag-modes-lgcpf7c0a2ec/mac
- [L-marquee] Apple, "Select parts of regions". https://support.apple.com/guide/logicpro/select-parts-of-regions-lgcpf7c0ae21/mac
- [L-copy] Apple, "Cut, copy, and paste regions". https://support.apple.com/guide/logicpro/cut-copy-and-paste-regions-lgcpf7c0d424/mac
- [L-inspector] Apple, "Use the Region inspector". https://support.apple.com/guide/logicpro/use-the-region-inspector-lgcpd8a8780c/mac
- [F-select] Apple, Final Cut Pro User Guide, "Select clips" (via fetch summary). https://support.apple.com/guide/final-cut-pro/select-clips-ver28912fd/mac
- [F-range] Apple, "Select ranges" (via fetch summary). https://support.apple.com/guide/final-cut-pro/select-ranges-ver28cca92/mac
- [F-arrange] Apple, "Arrange clips in the timeline". https://support.apple.com/guide/final-cut-pro/arrange-clips-in-the-timeline-verc147f195/mac
- [F-search] Apple, "Overwrite clips", search result only. https://support.apple.com/guide/final-cut-pro/overwrite-clips-ver4e30026/mac
- [A-search] Adobe, "Arrange and edit multitrack clips", search result only. helpx.adobe.com refused the fetch (403). https://helpx.adobe.com/audition/using/arranging-editing-multitrack-clips.html
- [R-search] Reaper user guide PDFs, search result only, not read in full. https://dlz.reaper.fm/userguide/WhatsNewReaper7Summary_r2.pdf
- Hindenburg facts: `docs/research/edit-commands.md` and `docs/research/mouse-edits.md`.
