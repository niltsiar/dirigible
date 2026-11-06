# Timeline edits: reference behavior

Date: 2026-10-28

Tags: (P) primary source. "Unconfirmed" means no source states it. "Inference" means the author derived it and no source checks it. All pages were read on 2026-10-28. The Logic Pro guide lists versions up to 12.3.

## Key facts

1. Logic drag modes: No Overlap shortens the left (earlier) region. X-Fade crossfades the overlap of two audio regions. Shuffle L closes gaps on move, resize, and delete. A drop on a region swaps the two. Crossfade length, paste, multi-select, and cross-track moves are unconfirmed.
2. Logic Shuffle Left (Edit > Move): the first selected region on each track stays. All later selected regions move left. An unselected region between two selected ones is unconfirmed.
3. FCP: comma and period nudge a slip by 1 frame (Shift: 10). Shift-X rolls an edit to the playhead. A roll stops at the media end of either clip. Keyframes and transitions under a slip are unconfirmed.
4. FCP ripple: connected clips move with their anchor clip. No lane or collision rule is documented.
5. Hindenburg: Shift-Ctrl-drag (Windows key) is both the shuffle trim and the slide inside a region. Q, W, Shift-Q, Shift-W trim to the playhead. No keyboard slip of audio exists.

## 1. Logic Pro drag modes

Source: [LDM] (P), current page. Text:

- Overlap: "Preserves the current region borders when you drag one region over another."
- No Overlap: "When two regions overlap, the overlapped area of the left (earlier) region is shortened."
- X-Fade: "When two audio regions overlap, the overlapped area is crossfaded."
- Shuffle L, Move: "Moving a region to the left aligns the start point of the region with the end point of the preceding region, so there is no space (gap) between them."
- Shuffle L, Resize: "When you resize the right edge of a region, the regions that follow move by the change in length."
- Shuffle L, Delete: "The remaining regions on the track move by the length of the deleted region."
- Shuffle R is the mirror. Move right: the end meets the start of the next region. Resize the left edge: the preceding regions move. Delete: same as Shuffle L.
- Both Shuffle modes: "when you drag one region over another, the regions switch positions."

The 9.1.6 page [L9DM] (P) says No Overlap "Shortens the region positioned earlier on the track by the overlap length". It says X-Fade works on audio and Apple Loops audio regions, not MIDI.

Answers:

- X-Fade length. [LDM] and [LXF] (P) do not say. [LSET] (P) has a "Crossfade Time slider" that "determines a default time value for all crossfade operations in the Tracks area". Inference: X-Fade fades the overlap area, and the preference sets the default. No source links them (unconfirmed).
- X-Fade on move, resize, paste. The text states a condition (two audio regions overlap), not an action. The 9.1.6 text says "moved to an overlapping position". Resize and paste are unconfirmed.
- No Overlap. The rule always names the earlier region. A region dropped over the end of an earlier region shortens that earlier region. A region dropped over the start of a later region is itself the earlier one. Inference: the dragged region loses its tail. No source shows this case (unconfirmed).
- Shuffle L, move on the same track. The text covers a move left against the preceding region. A move right, and the gap left at the old place, are unconfirmed.
- Shuffle L, move to another track. Unconfirmed. Every rule says "on the track".
- Shuffle L, delete. The regions that follow move left by the deleted length. The current text says "remaining regions on the track". It does not limit them to the later ones (unconfirmed).
- Several selected regions. Neither page addresses it (unconfirmed).

## 2. Logic Pro Edit > Move > Shuffle Left, Shuffle Right

Source: [LGP] (P), section "Remove gaps between regions". Select the regions, then:

- "Choose Edit > Move > Shuffle Left (or use the corresponding key command). The first selected region on each track remains unchanged, and all subsequent selected regions are moved to the left."
- "Choose Edit > Move > Shuffle Right (or use the corresponding key command). The first selected region on each track is moved to the right, and all subsequent regions remain unchanged."

Answers:

- Only selected regions move.
- It works per track. The text says "on each track", so one selection over many tracks works track by track.
- Unselected region between two selected ones: unconfirmed. Inference: it does not move, and the later selected region may overlap it.
- Exact butting: the title says "Remove gaps". Inference: each region butts the end of the one before.
- Keys Option-[ and Option-]: [LKT] (P), known in `ripple-edit.md`. Not read again.
- The Shuffle Right text is odd. Do not copy it as a rule.

## 3. Final Cut Pro roll and slip

Roll, [RO] (P):

- Trim tool (T). Click the centre of the edit point to select both sides.
- Drag, or type + or - and a timecode then Return. Or put the playhead or skimmer at the target and choose Trim > Extend Edit (Shift-X).
- "No clips move in the timeline as a result". The combined duration of the two clips stays the same.
- Limit: when one side "appears red, you've reached the end of the media for one of the two clips".

Nudge, [EX] (P): select the start or end point of a clip. Comma moves the edit point 1 frame left. Period moves it 1 frame right. Shift gives 10 frames. For a roll, [EX] says "select both sides of the edit point with the Trim tool". [RO] does not list comma or period. A comma roll is unconfirmed.

Slip, [SP] (P):

- It "doesn't change a clip's position or duration in the timeline, but instead changes what portion of the clip's media appears".
- Drag the clip in the Trim tool. Keyboard: "Press Comma (,) or Period (.) to nudge the start and end points one frame". Shift gives 10 frames. + or - and a timecode also works.
- The clip needs media handles on both sides. A red edge marks the media end. "Surrounding clips are not affected, and the overall duration of your project doesn't change."
- Keyframes under a slip: unconfirmed. Transitions at the clip ends: unconfirmed.

Transition at an edit, [TR] (P): "Moving a transition actually rolls the edit under the transition". It needs media handles. A Trim tool roll of an edit that has a transition is unconfirmed.

## 4. Final Cut Pro connected clips in a ripple delete

Sources: [CC] (P), [RM] (P).

- "When you rearrange, move, ripple, or delete clips in the primary storyline, any clips connected to them are moved or deleted along with the primary storyline clips."
- A connected clip attaches at its first frame by default. Command-Option-click moves the connection point. Inference: a connected clip follows one anchor, so it never splits.
- Delete of a whole clip: its connected clips "are also deleted". Later clips "ripple to close the resulting gap".
- Delete of a partial range that holds a connected clip: "the connected items are not deleted but are instead shifted to the closest primary storyline clip."
- Grave Accent key held during move, trim, or delete: the connected clips keep "exactly the same position".
- Replace with Gap (Shift-Delete): connected clips attach to the gap clip.
- Collision: no page states what happens when two connected clips land on the same time, or if they stack in lanes. Inference: all anchored clips shift by one amount, so their offsets stay. The partial-range case can bring two together (unconfirmed). The plan must pick its own collision rule.

## 5. Hindenburg PRO

Source: [HK2] (P), a Windows table. Rows, verbatim:

- "shift + Ctrl Mouse | Regions - Shuffle Trim (Slip Edit) | Move the edit point without breaking the edit apart"
- "Shift + Ctrl Mouse | Regions - Slide Audio Inside Region | Sliding the audio inside the region"
- "Q | Edit - Top | Trims the beginning of the region to the playhead"
- "Shift Q | Edit - Top Slip | ... without moving the following regions"
- "W | Edit - Tail | Trims end beginning of the region after the playhead"
- "Shift W | Edit - Tail Slip | ... without moving the following regions"

Answers:

- Confirmed: one chord names two actions. The page does not say how the app chooses. Inference: the drag position (edit point or region body) chooses.
- macOS key: the page shows Ctrl only. The repo videos show Shift-Cmd-drag [V-shuffle] [V-slide], known in `edit-commands.md`.
- Keyboard slip of audio inside a region: none on the page. "Slip" in Shift-Q and Shift-W means a trim with no ripple.
- Inference: Q and W move the following regions. The page states only the Shift case.

## Sources

- [LDM] https://support.apple.com/guide/logicpro/control-positioning-with-drag-modes-lgcpf7c0a2ec/mac
- [L9DM] https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_13_section_3.html
- [LXF] https://support.apple.com/guide/logicpro/create-automatic-crossfades-lgcp9260fa9c/mac
- [LSET] https://support.apple.com/guide/logicpro/editing-settings-lgcp0d6a4f6f/mac
- [LGP] https://support.apple.com/guide/logicpro/add-or-remove-gaps-lgcp21e2cb21/mac
- [LKT] https://support.apple.com/guide/logicpro/main-window-tracks-and-various-editors-lgcpe8314fe2/mac
- [RO] https://support.apple.com/guide/final-cut-pro/make-roll-edits-ver1632d9ae/mac
- [SP] https://support.apple.com/guide/final-cut-pro/make-slip-edits-ver1632d8e4/mac
- [EX] https://support.apple.com/guide/final-cut-pro/extend-or-shorten-clips-ver9847ec25/mac
- [TR] https://support.apple.com/guide/final-cut-pro/adjust-transitions-in-the-timeline-vercf3c662c/mac
- [CC] https://support.apple.com/guide/final-cut-pro/connect-clips-ver7a77ef9e/mac
- [RM] https://support.apple.com/guide/final-cut-pro/remove-clips-from-projects-verc5d34129/mac
- [HK2] https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [V-shuffle], [V-slide]: repo videos listed in `docs/research/edit-commands.md`.
