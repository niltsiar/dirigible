# Copy, Cut, and Paste of a clip set in other editors

Date: 2026-10-05

This file answers seven questions on Copy, Cut, and Paste of several regions that the user selects one by one (Cmd-click). The regions can be disjoint in time and on different tracks. It does not repeat `docs/research/edit-commands.md` section 6, `multi-clip-selection.md` section 5, or `ripple-edit.md`.

Grades: **P** is a primary vendor page or manual. **S** is a search summary or a secondary page. **U** is a user post on a forum. "Unconfirmed" means that no source answers. A sentence that starts with "Inference:" is our reading. The most common gesture was checked in no app: Cmd-click two regions on two tracks, Cmd-C, click a third track, move the playhead, Cmd-V.

## 1. Paste position: time offsets and track offsets

- **Hindenburg.** Paste: "Copy ⌘C / Place playhead / Paste ⌘V / Places Selection ON TOP of existing audio" [HM p. 29] (P). "the selection will be placed on top of existing audio on the track" [HJO p. 13] (P). Cmd-click selects regions for "Cut, Copy & Paste or move the regions around" [HSC] (P). One region goes to the selected track at the playhead (edit-commands.md section 6). No source says where a copy from several tracks goes (unconfirmed).
- **Logic Pro 12.3.** "select the track where you want to paste the region, move the playhead to the point where you want the region to start, then choose Edit > Paste" [LCP] (P). The page uses the singular only. Paste at Original Position pastes "into the selected track, at the same position as the source region" [LCP] (P).
- **Logic Pro 9.1.6 (old manual).** "The paste occurs on the selected track at the playhead position. If several regions are selected, their relative time and track positions are retained." [L9CP] (P, old).
- **Logic Pro 10.4.1 (forum).** A user selected regions on adjacent tracks, set the playhead, and selected another track. "the regions copy at the desired beat/location but instead of copying onto the desired new track, they copy on the same track." Paste at Original Position "pastes right over the original" [LUG] (U, 2018). Search summaries say the same: a paste from several tracks goes to the original tracks [S-L] (S).
- **Conflict.** [L9CP] puts the first region on the selected track. [LUG] puts each region on its source track. The 12.3 guide is silent. We did not resolve the conflict.
- **Logic for iPad.** "When pasting multiple regions, the regions keep the same relative positions as when you cut or copied them." [LIP] (P, iPad). It does not name tracks.
- **Final Cut Pro.** Cmd-V is "Paste Insert at Playhead": "Insert the Clipboard contents at the skimmer or playhead position". Option-V is "Paste as Connected" [FKS] (P). FCP has no tracks, so a track offset has no meaning. Inference: FCP is no reference for track offsets.
- **REAPER 7.81.** "To copy/paste selected item(s) Press Ctrl C. Re-position edit cursor, press Ctrl V." [RG p. 124] (P). A preference sets if a mouse click "Sets track as the target for insert/paste" [RG p. 446] (P). A search summary says that the topmost item goes to the selected lane [S-R] (S, no owner page found). Track offsets are unconfirmed.
- **Audition.** No primary page on a multi-clip paste (unconfirmed). Adobe help refused the fetch (403).

## 2. Too few target tracks

- **Hindenburg, Logic, FCP, REAPER.** No source (unconfirmed).
- **Audition.** A search summary says that a paste from two or more tracks puts the first track right and "will then open new tracks for the other clips" [S-A] (S). The owner post was not found. For Insert Files, Adobe says: "Adobe Audition inserts new clips on the nearest empty tracks" [AU p. 26] (P). That rule is for an import, not a paste. Inference: Audition makes or uses empty tracks; not checked for Paste.

## 3. Collisions

- **Hindenburg.** Paste "is used when placing audio in on top of existing audio This can be used to replace sections of the current audio" [HSC] (P). The sources do not say if the audio under the paste is cut or only covered (unconfirmed). Inference: the audio under the pasted region is not heard, because the text says "replace". Paste in Selection (Cmd-V with a range) fills the range with copied audio [HM p. 29] (P). Replace (Shift-Cmd-V) replaces a selection, and "the difference between the copied are and the selection will automatically be edited" [HM p. 30] (P).
- **Logic.** A search summary says that Drag mode No Overlap deletes the part of the old region under a paste, and Overlap keeps it [S-LO] (S). The owner post refused the fetch. For a drag, Logic says: "When two audio regions on the same track overlap, only the later (right) region is heard." (multi-clip-selection.md section 4). Logic has a key command "Paste Replace", Shift-Command-V [LKT] (P). No page describes it (unconfirmed).
- **FCP.** Cmd-V inserts and moves later clips [FKS] (P). Inference: no collision occurs in the storyline.
- **REAPER.** With Trim content behind media items when editing, "existing material is effectively replaced by any new material that is placed over it". It is off by default [RG p. 137] (P). Inference: the option applies to a paste; the page shows a drag only.
- **Audition.** No source (unconfirmed).
- No source says if a paste clears the whole time span of the copy or only the audio under each region (unconfirmed in all apps).

## 4. Cut of several disjoint regions

- **Hindenburg.** Cut: "Deletes the Selection / Closes gap". Delete: "Deletes the Selection / Maintains gap" [HM p. 28-29] (P). "All following regions on the track will subsequently move to the left" [HJO p. 12] (P). Region Cut (Shift-Cmd-X) "will only affect the region - not the entire track" [HSC] (P). These texts describe one selection. No source covers Cut of disjoint regions on several tracks (unconfirmed). See ripple-edit.md section 6 for the scope inference.
- **Logic.** Cut has only the singular text [LCP] (P). Logic for iPad: "To cut multiple regions, select the regions, double-tap one of them, then choose Cut." [LIP] (P, iPad). Gap or ripple: unconfirmed. Inference: Cut leaves a gap, because no page says that later regions move.
- **FCP.** Delete: "any clips to the right of the selection ripple to close the resulting gap". Replace with Gap prevents the ripple [FRM] (P). For iPad: Cut "removes the selection from the timeline. Final Cut Pro ripples clips (and any connected clips) in the timeline to close the gap" [FIP] (P, iPad).
- **REAPER.** Cut follows the ripple mode: off, per track, or all tracks (ripple-edit.md section 6).
- **Audition.** Edit > Delete leaves a gap. Ripple Delete > Selected Clips "Removes selected clips, shifting remaining clips on the same tracks." [AU p. 149] (P).

## 5. Selection after Paste

- **Hindenburg.** The pasted region is selected, for one region (edit-commands.md section 6). For several regions: unconfirmed.
- **Logic, FCP, REAPER, Audition.** No source (unconfirmed).

## 6. Undo

- **Hindenburg.** "Undo the last action" [HSC] (P). Grouping: unconfirmed.
- **Logic.** Edit > Undo History lists "all edits that can be undone" [LUH] (S, search summary of the page). Grouping of a multi-region paste: unconfirmed.
- **FCP, REAPER, Audition.** No source (unconfirmed).

## 7. Mixed mono and stereo tracks

- No source covers a paste of a mono region to a stereo track, or the reverse (unconfirmed in all apps). Logic moves an audio region only to an audio track; mono and stereo are not named (multi-clip-selection.md section 3).
- Hindenburg can split a stereo region into two mono regions with Tools > Split region [HM p. 43] (P). This is not a paste rule.

## For the plan

1. Paste position: Logic 9 manual keeps time and track offsets, first region on the selected track, at the playhead [L9CP]. Logic 10.4.1 (forum) pastes to the source tracks [LUG]. Hindenburg: playhead and selected track for one region only.
2. Too few tracks: no reference. Audition opens new tracks (search summary only) [S-A].
3. Collisions: Hindenburg pastes "on top" and "replace" [HSC] [HM]; overwrite or cover is unconfirmed. REAPER trim-behind is an option, off by default [RG].
4. Cut: Hindenburg Cut closes the gap and Delete keeps it [HM]. Audition Ripple Delete shifts clips "on the same tracks" [AU]. FCP Delete ripples [FRM]. No reference for disjoint regions on several tracks.
5. Selection after Paste: Hindenburg selects the pasted region (one region). No reference for several.
6. Undo: no reference.
7. Mono and stereo: no reference.

## Sources

- [HM] Hindenburg Journalist 1.21 user guide for macOS, pages 28 to 30, 37, 43 (text read with PDFKit on 2026-10-05): https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HJO] Hindenburg Journalist Guide for OS X, pages 12 to 15: http://hindenburgsystems.com/wordpress/wp-content/uploads/2010/07/Hindenburg-Journalist-Guide-OSX.pdf
- [HSC] Hindenburg Pro Shortcuts: https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/ and the guide page https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [LCP] Logic Pro 12.3, "Cut, copy, and paste regions": https://support.apple.com/guide/logicpro/cut-copy-and-paste-regions-lgcpf7c0d424/mac
- [L9CP] Logic Pro 9.1.6 manual, "Cutting, Copying, and Pasting Regions": https://help.apple.com/logicpro/mac/9.1.6/help/English.lproj/en/logicpro/usermanual/chapter_13_section_15.html
- [LIP] Logic Pro for iPad, "Cut, copy, and paste regions": https://support.apple.com/guide/logicpro-ipad/cut-copy-and-paste-regions-lpip6381dd59/ipados
- [LKT] Logic Pro key commands, Main Window Tracks and Various Editors: https://support.apple.com/guide/logicpro/main-window-tracks-and-various-editors-lgcpe8314fe2/mac
- [LUH] Logic Pro, "Undo and redo edits" (search summary): https://support.apple.com/guide/logicpro/undo-and-redo-edits-lgcp1dbd67ab/mac
- [LUG] Logic Users Group, "Multiple Regions not copying to different tracks", M57, 2018-08-21: https://logic-users-group.com/threads/multiple-regions-not-copying-to-different-tracks.10750/
- [S-L] Search summary of https://www.logicprohelp.com/forums/topic/160069-copy-and-paste-multiple-regions-into-new-tracks/ (403, not read)
- [S-LO] Search summary of https://www.logicprohelp.com/forums/topic/123488-logic-x-paste-without-deleting-overlapped-regions/ (403, not read)
- [FKS] Final Cut Pro keyboard shortcuts: https://support.apple.com/guide/final-cut-pro/keyboard-shortcuts-ver90ba5929/mac
- [FRM] Final Cut Pro, "Remove clips from projects": https://support.apple.com/guide/final-cut-pro/remove-clips-from-projects-verc5d34129/mac
- [FIP] Final Cut Pro for iPad, "Arrange clips in the timeline": https://support.apple.com/guide/final-cut-pro-ipad/arrange-clips-in-the-timeline-dev5ba3d4f0b/ipados
- [RG] Up and Running: A REAPER User Guide v7.81, pages 124, 137, 446 (text read with PDFKit): https://www.reaper.fm/userguide/ReaperUserGuide781c.pdf
- [S-R] Search summary, no owner page; the REAPER accessibility wiki did not contain it: https://www.reaperaccessibility.com/wiki/Special:MyLanguage/Basic_editing
- [AU] Adobe Audition CC Help (2016 PDF), pages 26 and 149: https://myturn-prod-attachments.s3.amazonaws.com/2/832/item/198610/file_attachment/audition_reference-CF2921D0-3E98-7732-D4AC-406E96FA5239.pdf
- [S-A] Search summary; the owner post was not found in https://community.adobe.com/questions-544/how-can-i-copy-paste-multiple-tracks-at-once-164372 or https://community.adobe.com/questions-544/editing-multiple-tracks-at-once-in-audition-160667
