# Multi-range ripple delete in other editors

Date: 2026-10-13

## Summary

Audacity and REAPER merge the ranges before they cut. No checked app refuses overlapping ranges. Audacity sorts the regions, merges the overlapping ones, cuts from the last region to the first, and pushes one undo state [A1][A2][A3]. REAPER merges adjacent razor areas by default [R1]. Hindenburg PRO and the Audition time selection have one range only [H1][D2].

**Recommendation: merge overlapping and touching ranges.** Two apps merge, and no checked app refuses.

Inference: merge or refuse is necessary for correct audio, and is not only a style choice. Example: the ranges are [3,7] and [5,10]. A last-to-first cut removes [5,10] first. The later cut of [3,7] then removes original [3,5] and original [10,12]. Original [10,12] is wrong audio. Touching ranges are safe in last-to-first order, so a merge of touching ranges is harmless. REAPER merges them, but Audacity keeps them separate.

Open question: Whisper word ranges often touch or overlap by some milliseconds. This is the most common input of the new feature. This research did not check how an app handles an overlap that is smaller than a word.

## Audacity

The source is the `master` branch at commit `f216d051` [A1].

- **Merge.** A comment above `GetRegionsByLabel` says "overlapping regions are merged". The function sorts the regions. Then it merges a region into the region before it when its start is less than the end of that region (`cur.start < last.end`). This is a strict compare. Overlapping regions merge. Touching regions (end equal to start) stay separate [A1, lines 129-166].
- **Order.** `EditByLabel` applies the edit from `regions.rbegin()` to `regions.rend()`, that is, from the last region to the first. A comment says that this order is necessary for "actions like 'Delete' which collapse the track area" [A2, lines 202-230].
- **Undo.** `OnDeleteLabels` calls `EditByLabel` once and then calls `PushState` once, with the name "Delete Labeled Audio". `OnSplitDeleteLabels` does the same [A3, lines 476-498 and 530-559]. Thus, one command is one undo step.

## REAPER

- **Merge.** REAPER v7.40 (June 2025) adds "experimental option (reaper.ini areasel=2) to not merge adjacent selection regions" [R1]. Thus, the default merges adjacent razor areas. v7.18 fixes "consolidating small adjacent razor edits" [R1]. v6.43 changes the "behavior of overlapping razor edits on a single track" [R1].
- **Ripple.** The User Guide 7.81 says that the ripple settings change the behavior of razor edits [R2]. The guide does not describe overlap of razor areas.
- **Order.** No source. (U)
- **Undo.** The changelog fixes undo for razor delete with ripple-all [R1]. No source says that a delete of several areas is one undo point. (U)

## Adobe Audition

- **Ripple Delete (Multitrack).** Ripple Delete removes "the range" from clips. The options are Selected Clips, Time Selection in Selected Clips, Time Selection in All Tracks, and Time Selection in Selected Track [D2]. The time selection is one range. "Selected Clips" removes several clips. The page does not describe overlap.
- **Delete Silence (Waveform).** The Diagnostics panel scans and lists silent passages. "Delete All" addresses "all detected items" [D1]. The page does not describe overlap or order.
- **Undo.** No source gives the undo step count for "Delete All" or for a ripple delete of several clips. (U)

## Descript

- **Bulk removal.** "Remove filler words" opens a sidebar with all detected filler words. The user selects an action for each one: Delete, Delete and replace with gap, Ignore, or Remove from transcript [S1]. "Remove retakes" shows its edits as ignored text that the user can restore or delete [S2].
- **Undo.** Command+Z goes "back one step" [S3]. Underlord makes a checkpoint before it applies edits, and the user can revert one response [S3]. No source says that a bulk removal is one undo step. (U)
- **Overlap.** No source. Inference: a text selection in the script is one continuous span of words. Two adjacent word selections thus become one span.

## Hindenburg PRO

The guide says "To edit audio you need to select an area for editing" and "Drag a selection in the workspace" [H1]. "Cut selection" removes one selection. A multiple selection applies to regions (clips) only, with "Expand region selection" [H1]. The guide has no command that deletes several time ranges in one action.

## Apps that refuse overlapping ranges

None found.

## Sources

- [A1] Audacity, `GetRegionsByLabel`: https://github.com/audacity/audacity/blob/f216d051340c571027b03dc1377d8cb06c8fdca0/au3/src/menus/LabelMenus.cpp#L129-L166
- [A2] Audacity, `EditByLabel`: https://github.com/audacity/audacity/blob/f216d051340c571027b03dc1377d8cb06c8fdca0/au3/src/menus/LabelMenus.cpp#L202-L230
- [A3] Audacity, `OnDeleteLabels`: https://github.com/audacity/audacity/blob/f216d051340c571027b03dc1377d8cb06c8fdca0/au3/src/menus/LabelMenus.cpp#L476-L498
- [R1] REAPER changelog (v7.40, v7.18, v7.09, v6.43): https://www.reaper.fm/whatsnew.txt
- [R2] REAPER User Guide 7.81, section 18.38: https://www.reaper.fm/userguide/ReaperUserGuide781c.pdf
- [D1] Adobe, Diagnostics effects (Waveform Editor only): https://helpx.adobe.com/audition/desktop/effects-reference/diagnostics-effects-waveform-editor-only.html (read through the Wayback Machine; a direct fetch returns 403)
- [D2] Adobe, Arranging and editing multitrack clips: https://helpx.adobe.com/audition/using/arranging-editing-multitrack-clips.html (read through the Wayback Machine; a direct fetch returns 403)
- [S1] Descript, Filler words: https://help.descript.com/script-editing/filler-words
- [S2] Descript, Sound good tools: https://help.descript.com/descript-tour/sound-good-tools
- [S3] Descript, Revert Underlord changes: https://help.descript.com/ai-assistant/revert
- [H1] Hindenburg PRO guide: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
