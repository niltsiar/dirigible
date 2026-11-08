# Drag modes: reference behavior in REAPER, Final Cut Pro, Logic Pro, and Hindenburg PRO

Date: 2026-11-07

This document records what a drag does to the clips under it and around it in four editors. The Logic Pro texts for Overlap, No Overlap, X-Fade, Shuffle L, and Shuffle R are in `docs/research/timeline-edits.md` section 1. This document does not repeat them. The mark "(P)" means a primary source. "Unconfirmed" means no source states the claim. A sentence that starts with "Inference:" is our reading of the sources, and no source checks it. All pages were read on 2026-11-07.

## Key facts

1. REAPER default: a dropped item overlaps the item under it. Both items stay and both play. (P) [RUG]
2. REAPER "Trim content behind media items when editing" replaces the material under the dropped item. It works only when auto-crossfade is off. (P) [RUG]
3. REAPER auto-crossfade makes a crossfade when one item is dragged over the end or start of another. (P) [RUG]
4. REAPER per-track ripple applies to the selected track(s) only. A move to another track and the markers in per-track mode: Unconfirmed. [RUG]
5. Final Cut Pro: a drag in the primary storyline ripples clips to make room and closes the old gap. (P) [FA] A drop inside a clip: Unconfirmed.
6. The Final Cut Pro Position tool (P key) overwrites and leaves a gap clip. This suspends the magnetic behavior. (P) [FA] [FM]
7. Logic Pro: drag modes act on moving, resizing, and deleting by drag. The nudge page does not name them. Nudge with a drag mode: Unconfirmed. [LDM] [LMV]
8. Hindenburg PRO: no source states what a region move does to the regions under it. No drag mode or magnetic setting appears in the guide index. [HG]

## 1. REAPER overlap options

Source: [RUG] v7.85, sections 7.11, 7.13, 7.15, 7.28, and the Preferences summary.

- 7.11: "Media items can be overlapped by dragging and dropping one over the other." (P)
- 7.11: "Automatic cross fades (shown here) are enabled by enabling auto-crossfades on the toolbar." (P)
- 7.11: "Offset overlapping media items vertically: This option (Options menu) does what it says." (P) So overlap shows in stacked lanes only if this option is on. The guide does not state the default.
- 7.15, default: "This is how REAPER behaves with trim behind disabled (the default setting)." The guide then shows the dropped item over the first, and "we can see both the original and the new item stored in this track". (P)
- 7.15, enabled: "this time, when we allow free item positioning and drag the new item down, there is nothing behind it! The new item has replaced the original." (P)
- 7.15: "trim behind when editing cannot work unless auto-crossfade is disabled." (P)
- 7.15: "you do not have to use free item positioning in order to work with 'trim behind' enabled." (P)
- 7.13: "Disabling auto-crosssfade (on the toolbar) will stop the crossfade, but both items will still be heard. Enabling Trim content behind media items when editing (Options menu) will ensure that only the slip-edited item (the item on top) will be heard during the overlap." (P)
- 7.28: free item positioning "enables you to move your media items around freely within a track or tracks. This allows, for example, two or more items to play simultaneously or to overlap on the same track". It is off by default. (P)
- 7.28 note: "If auto-crossfade is enabled, media items that overlap vertically will crossfade. Otherwise, the vertical positioning of media items does not affect playback." (P)
- Preferences summary: "Whether to enable trim content behind media edits and/or razor edits." For razor edits, trim is on by default ("disable Always trim content behind razor edits"). (P)

What the sources say about each question:

- Overwrite: "Trim content behind". The item under is "replaced". (P)
- Crossfade: auto-crossfade (toolbar, Alt X). (P) The crossfade length comes from the Item Fade Defaults page. (P)
- Earlier item shortens: the guide never says "shorten". It says "replaced" and "only the item on top will be heard". Inference: the item behind loses the overlapped part, so an earlier item loses its tail. A drop inside a longer item (split into two) is not shown. Unconfirmed.
- The exact label "Auto-crossfade media items when editing" is not in the guide. The guide names the toolbar option "auto-crossfade". The label: Unconfirmed.
- A later item that shortens, or lengths that stay under a crossfade: Unconfirmed.

## 2. REAPER ripple editing

Source: [RUG] section 7.20.

- "Both off: In this default mode items will not shift when you edit a track." (P)
- "Ripple edit per track: With this enabled, ripple editing will be applied when you are editing the currently selected track(s) but not to any other." (P)
- Ripple edit all tracks: "any editing you do to any of the items on any track will also be applied to all other tracks." (P)
- "In this mode, markers and automation are locked to the items that they relate to, so as you move items the associated markers and automation move too." (P) The PDF text puts this after the toolbar paragraph. It does not say which mode. Per-track: Unconfirmed.
- "All items to the right of the dragged item will stay together: markers and automation will also move." (P) This sits beside the all-tracks example. The text does not name the mode for this line.
- "Ripple edit all affects tempo map" is a separate toolbar option, off by default. (P)
- 7.20 Tip: mouse modifiers decide what a drag does, "including applying any of the three ripple editing states". (P)

What the sources say about each question:

- Later items on the source track move with the dragged item when per-track ripple is on. (P, "All items to the right of the dragged item")
- The destination track on a move to another track: Unconfirmed. A Cockos forum thread says that per-track ripple "brakes the track media edit group rules" on cross-track drags. It is a user post, not vendor text. (https://forums.cockos.com/showthread.php?t=275324) It is not used as a source.
- Markers: the guide says they move in ripple. It does not name the mode. Per-track: Unconfirmed.
- Inference: the guide shows only the "selected track(s)" rule. It does not say if the drop track is selected.

## 3. Final Cut Pro magnetic timeline

Sources: [FA] "Arrange clips in the timeline", [FM] "Intro to the Magnetic Timeline", [FI] "Insert clips".

- [FA]: "If you add or move a clip in the timeline by dragging, Final Cut Pro moves other clips to make room for it." (P)
- [FA]: "Final Cut Pro ripples clips (and any connected clips) in the timeline to make room for the repositioned clips and to close the gap left by the clips that were repositioned." (P)
- [FA], Position tool: "The moved clip overwrites any clips at the new position. A gap clip fills in the vacated part of the timeline." (P)
- [FM]: "surrounding clips automatically move out of the way or snap together to avoid unwanted gaps and collisions." (P)
- [FM]: the Position tool lets you "temporarily suspend the magnetic behavior of the timeline". (P)
- [FI]: "Drag the clip you want to insert to an edit point (between two clips) in the timeline." Result: "all clips after the insertion point are rippled forward". (P)
- [FI]: for Edit > Insert (W), a clip under the playhead "is cut at the insertion point, and the second half is moved to the end of the newly inserted clip". This is a menu command, not a drag. (P)

What the sources say about each question:

- The hole at the old place closes. (P, [FA])
- Where a drop inside another clip lands (the nearest edit point, or a split): Unconfirmed. [FA] and [FI] name only "an edit point" for a drag. Inference: a drag does not split, and the clip lands at an edit point. No source states it. Check this case in the app.
- An overwrite by drag needs the Position tool. (P)

## 4. Logic Pro drag modes

Sources: [LDM] "Use drag modes", [LMV] "Move regions".

- [LDM]: "Using drag modes, you can control the results of moving, resizing, or deleting regions in the Tracks area." (P)
- [LDM]: "Only one audio region at a time can be played on each track. When two audio regions on the same track overlap, only the later (right) region is heard." (P)
- [LDM]: "For both Shuffle R and Shuffle L, when you drag one region over another, the regions switch positions." (P)
- [LMV]: "You can nudge regions (move them in small increments) left or right using key commands." To nudge: "select the regions you want to move. Press and hold Option and press the Left or Right Arrow key." (P)
- [LMV]: "When you move a region, it snaps to the nearest position on the Tracks area grid". (P) The page says you can move regions to another track of the same type. (P)
- [LMV]: for Move Region/Event to Playhead Position, "If more than one region is selected, all subsequent regions are moved." (P)

What the sources say about each question:

- Drag mode and Nudge Region Position: Unconfirmed. The drag mode text says "drag". The nudge text does not name a drag mode. Inference: nudge does not apply a drag mode. No source states it.
- A drag of several selected regions: Unconfirmed. Neither page addresses it.
- Shuffle and a region dragged to another track: Unconfirmed. Every Shuffle rule says "on the track". The "regions switch positions" rule is stated for one drag over another region, with no track limit.

## 5. Hindenburg PRO

Source: [HG] Hindenburg Academy PRO guide index (video titles with one line of text each).

- "Snap Regions": "The Region snaps to the nearest event". (P)
- "Cross Fade": "'Cross Fade' is used for making a transition from one sound to another on the same track." (P) It is a separate command.
- "Top Slip" and "Tail Slip": trim to the playhead "without moving the following regions". (P)
- "Shuffle Trim (Slip Edit)": "Move the edit point without breaking the edit apart". (P)

What the sources say about each question:

- Overlap, trim, or push on a region move: Unconfirmed. No page states it. The index has no entry for it.
- A drag mode or a magnetic setting: none in the index. The index has no entry titled drag mode, magnetic, or ripple. This is an absence in a short index, not proof. The manual PDF was not found, so the claim is Unconfirmed.
- Inference: "Snap Regions" is a snap to events, not a magnetic mode.

## Sources

- [RUG] REAPER User Guide v7.85: https://www.reaper.fm/userguide/ReaperUserGuide785c.pdf (linked from https://www.reaper.fm/userguide.php)
- [FA] https://support.apple.com/guide/final-cut-pro/arrange-clips-in-the-timeline-verc147f195/mac
- [FM] https://support.apple.com/guide/final-cut-pro/intro-to-the-magnetic-timeline-verb8fcfc133/mac
- [FI] https://support.apple.com/guide/final-cut-pro/insert-clips-ver4e2eff6/mac
- [LDM] https://support.apple.com/guide/logicpro/control-positioning-with-drag-modes-lgcpf7c0a2ec/mac
- [LMV] https://support.apple.com/guide/logicpro/move-regions-lgcpf7c0d489/mac
- [HG] https://hindenburg.com/academy/guides/guides-hindenburg-pro/
