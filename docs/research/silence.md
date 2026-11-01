# Research: silence tools

Date: 2026-10-28

No probe, build, or app test ran. Every claim comes from a vendor page, a vendor forum post, or a repo file. "unconfirmed" means no primary source was read for the claim. A source tag marked "(summary)" means the page itself returned HTTP 403 and only a search summary of the page was read. "Inference:" marks a rule taken by analogy.

## Hindenburg PRO (the base)

1. Hindenburg has "Insert silence" (Ctrl Right Arrow) and "Remove silence" (Ctrl Left Arrow, the menu name is "Edit - Remove silence", the description says "Delete Silence"). The description of "Remove silence" is: "'Delete Silence' is used to delete blank room in the edit." [S17]
2. The guide describes "Insert Silence" as: "used to insert blank room in the edit." [S16]
3. The Hindenburg sources do not say how long the removed or inserted time is. They also do not say if the command reads a selection or the playhead. Unconfirmed. Repo file hindenburg-edit-tools.md already treats both commands as manual, blank-time commands and not as detectors. [S1]
4. Automatic silence detection or pause removal: not found. Pages searched: the release-notes page (versions 2, 2.02, 2.03, 2.04, 2.05, builds 2540 to 2754, no date on the page), release note 2.05 build 2724 (16 January 2026), the PRO guides page, the PRO 2 shortcut page, and the Edit with words page. The words "silence", "pause", "gap", "strip", and "auto-edit" are absent from the release-notes page except through "Insert silence" in the guides. [S14, S15, S16, S17]
5. The release-notes page lists "New Clipboard" (build 2540), "Added undo in Clipboards" (2544), and "Transcription in Clipboard clips" (2580). The Clipboard is a place to organize clips. It is not an analysis tool. [S14, S16]
6. Hindenburg PRO 2 has a Manuscript (a transcript). The page says: "Select the text as you would in a word document and see you edits being done in the audio." Cut is Cmd/Ctrl+X. The page does not say how pauses appear in the Manuscript. It does not say what happens after a cut. [S18]
7. Build 2724 (16 January 2026) is the newest build read. It adds Automation > Reset, JKL and IO shortcuts in the Manuscript, and multi-click region selection. It adds no silence feature. [S15]
8. Hindenburg Cut (Ctrl X) removes the selection and closes the gap. Delete or Clear keeps the gap. This is from earlier repo research. [S1]

## Descript

9. Detection uses the transcript word times, not a level threshold. The Shorten word gaps help page describes a search over gaps. A feature request asks for a level threshold ("below -40db to be silence"), which shows that no such control exists. [S4, S7]
10. Open the tool from the AI Tools panel. Select "Shorten word gaps". A search bar appears at the top of the script editor. [S4]
11. Options: a condition ("more than" or "between"), duration fields that "define what qualifies as a gap", and a second field for the new target length. The help examples are 750 ms for the gap and 200 ms for the target. They are examples, not defaults. Default values and ranges: unconfirmed. [S4, S5]
12. Review: step through the found gaps with the arrows of the search panel, or click a result in the Properties panel. The button "Shorten" applies the change to the selected gap. The button "Shorten all" applies it to all found gaps. [S4]
13. Two settings exist: "Auto-advance" (go to the next result after a gap is shortened) and "Preview results" (play the audio around the selected result automatically). [S4]
14. The page documents no per-item "ignore" for gaps. The page documents no keys for the search flow. Undo behavior of "Shorten all": unconfirmed. [S4]
15. Manual gap edit: right-click in the script, choose "Edit word gap", then choose a preset, "Set manually...", or "Shorten all word gaps". Mac key Cmd-G adjusts the gap at the cursor. Cmd-Shift-G sets the gap at the cursor to the last used length. The page says adjusting word gaps on a selected range is not supported. The preset values are not listed. [S5]
16. A user report says the tool can cut whole phrases. A user report says a search for gaps above 0.3 s also finds gaps of a few seconds, and asks for an upper bound. Both are user reports, not vendor facts. [S7, S6b]
17. Filler-word flow (summary of the help page): a sidebar lists every found filler word with a time stamp and an audio preview. The option "Ignore" strikes the word through in the script and removes the audio. The option "Remove from transcript" deletes the word from the script only. A setting skips words that cannot be removed cleanly. The page does not name a "Remove all" button in the summary. [S6]
18. Where the kept gap sits (center, start, or end), and the effect on markers, captions, and other tracks: unconfirmed. Inference: Descript keeps one script timeline, so a gap change moves every later word. This was not checked against a Descript page.

## Adobe Audition

Source read: the helpx pages for Audition (strip-silence, diagnostics-effects-waveform-editor-only, and the PDF reference) returned HTTP 403 in every locale tried (en, uk, hu, in, si, vn_vi). The Wayback Machine host is blocked in this tool. All Audition facts below are from search summaries of the Adobe pages and from Adobe Community posts. All are second-hand.

19. Diagnostics panel flow: choose an effect, click Scan, select one or more found items in the list, then click Repair, Delete, or Mark. The buttons Repair All, Delete All, and Mark All act on every found item. [S12 (summary)]
20. Delete Silence has "Define Silence As" and "Define Audio As" settings. Each is a level in dB plus a time in ms. "Find Levels" fills them from the file. The preset list has "Trim Long Silent Pauses". [S12 (summary), S13]
21. Defaults: unconfirmed. Two user reports give values: preset "Trim Long Silent Pauses" gave silence -74 dB for 1000 ms and audio -63 dB for 50 ms. A Find Levels run gave -49 dB for 1000 ms and -35 dB for 50 ms. A Community expert says "audio has to be above 0dB for 25ms before it's audio" (a user statement, not a default). [S13, S1]
22. "Fix By" has two choices. "Shortening Silence" cuts each silence to a number of ms. "Deleting Silence" is documented to mute silence and keep the file length. Two Community posts (2017 and 2023) report that "Deleting Silence" shortens the file, and that "Shortening Silence" with 0 ms gives the same result. The documented behavior is not confirmed. [S12 (summary), S13]
23. The new Multitrack Delete Silence (Effects > Diagnostics > Deleting Silence) lists found silences with Start, Duration, and Clip. Buttons: "Strip Silence" (cut and delete the silence) and "Split Silence" (cut the clip and leave the pieces selected, for a check). [S12 (summary)]
24. In Multitrack, a Community answer says Strip Silence "doesn't shorten the duration of the gaps, but it removes the empty portions of each participants clips". The user then needs Ripple Delete or "Select all clips forward" to close the gap. Inference: Strip Silence does not ripple. This is a user answer. [S13]
25. A reviewer asked for attack and release settings so that cuts keep more audio at sound edges. This shows that the Multitrack tool has no such padding setting. Another user says it cannot use a different threshold for each track. [S13]
26. Markers: "Mark Audio" writes markers in the Waveform editor. Which marker type, and the effect of Delete Silence on existing markers: unconfirmed. Undo as one step: unconfirmed.

## Logic Pro

Source read: Apple Logic Pro help (help.apple.com 10.4 and 10.1, 9.1.6) and a skydocu mirror of the older guide. The current support.apple.com pages returned only a table of contents.

27. In 10.x, the command is "Remove Silence" (older manuals: "Strip Silence"). Open it from the Project Audio Browser: Control-click an audio region, choose Remove Silence. A 2019 tutorial opens it in the Tracks area with Control-X on a selected region (third-party). [S8, S9, S10]
28. Threshold: "the amplitude level that a passage must exceed, in order to be defined as a region." A higher value gives more and shorter regions. [S8]
29. Minimum Time to accept as Silence: "the length of time that a section must be below the Threshold value, before it is considered a gap." [S8]
30. Pre Attack-Time adds pre-roll to the start of each new region. Overlap with the previous region is allowed only where the threshold is not exceeded. It does not move the anchor. [S8, S9]
31. Post Release-Time sets a release on each region end. Overlap is not allowed. A region end cannot pass the start of the next region. [S8, S9]
32. "Search Zero Crossings" snaps region starts and ends to the nearest zero crossing. [S8]
33. Units, ranges, and defaults: not in any Apple page read. Unconfirmed. A forum summary shows threshold in percent (1 percent), minimum time 0.1000 s, and pre and post 0.000 s. This is one user view, not a default. The 2019 tutorial says Logic remembers the last settings. [S10, S11]
34. Action: split into regions. Silent parts are not in any region. It does not shorten, delete with ripple, or mute. Click OK, then a dialog asks whether to replace the region in the Tracks area with the new regions. "Replace" keeps the relative timing of the segments, so later material does not move. "No" keeps the new regions in the Project Audio Browser only. [S8]
35. Review: the tutorial says grayed-out areas in the waveform show what the process removes while the user moves Threshold. Undo is Cmd-Z (tutorial). No list of found pauses. No per-pause accept. [S10]
36. Handling of markers, other tracks, and automation: not in any page read. Unconfirmed. Inference: the process works on one region, so other tracks stay unchanged. The page for uses says Strip Silence also serves as a noise gate and to split speech into segments. [S8, S11]

## Audacity

37. Truncate Silence (Effect > Special): the threshold range is -20 dB to -80 dB. The minimum duration is 0.001 s or more. The manual states no defaults. Source code defaults (repo finding 19): threshold -20 dB, detect 0.5 s, truncate to 0.5 s, compress 50 percent, independent off. Detection is per sample on all channels together. [S2, S1]
38. Truncate Detected Silence (default mode): every found silence is cut to one set length. The cut removes a section "from its middle", so the kept part sits at both ends of the pause. [S2]
39. Compress Excess Silence: only the part beyond the Duration shrinks to the set percentage. Example: duration 2 s, 50 percent, an 8 s silence becomes 2 + 3 = 5 s. [S2]
40. Multiple tracks: with "Truncate tracks independently" off (the default), silence is removed only where all selected tracks are silent. With it on, each track is processed alone, and the tracks can lose sync. [S2]
41. Sync-Lock groups: tracks in a group that are not selected lose the same time sections as the selected tracks. Labels in selected or sync-locked label tracks are truncated, deleted, or moved back. [S2]
42. Gaps between clips are not touched unless the preference "Editing a clip can move other clips" is on. Quiet fade-in and fade-out parts may be removed. The manual says to apply the effect before fades. [S2]
43. Review: none. Truncate Silence has no list and no preview of found pauses beyond the standard effect Preview. Undo: the manual does not say. [S2]
44. Label Sounds (Analyze menu) is a mark-only tool. It labels sounds or silences and does not change the audio. Defaults: threshold -30 dB, measurement Peak (Peak, Average, RMS), minimum silence 1 s (0.01 s to 1 hour), minimum label interval 1 s (0.01 s to 2 hours), label type "Region around sounds" (also point before, point after, region between sounds), leading and trailing silence 0 s. [S3]
45. Label Sounds processes the audio in 10 ms chunks, so label times can be off by up to 0.01 s. The maximum is 10000 labels. "Region between sounds" labels the silences. All labels from several tracks go to one label track. [S3]
46. The approach of both tools is a level threshold plus a minimum time. The source is GPLv3 and was not copied. Repo finding 19 holds the code facts. [S1]

## Final Cut Pro

47. FCP has four audio analysis options: "Fix audio problems", "Separate mono and group stereo audio", "Remove silent channels", and "Transcribe in English". Only "Remove silent channels" involves silence, and it works on whole channels, not on pauses. [S19]
48. A built-in pause or silence remover in FCP: not found in the Apple audio-analysis page. Vendor blogs of third-party tools say FCP has no native silence remover (secondary, sellers of alternatives). Third parties fill the gap with plug-ins and standalone apps. One tool exports an XML project to FCP. Auphonic exports cut lists in an FCP X EDL format. [S19, S20, S21]

## Riverside

Source read: support.riverside.com returned HTTP 403. Only search summaries of the help pages were read.

49. The editor has an AI Tools entry "Remove pauses". Click Apply next to it. A slider sets "the amount of pauses included". "Revert to original" restores all pauses. The slider unit, range, and default: unconfirmed. [S22 (summary)]
50. In the transcript, a pause shows as a symbol: a dot, two dots, or three dots, for different pause lengths. The user double-clicks a symbol to delete that pause. A deleted pause shows gray with a strikethrough, and the user can restore it. The length for each symbol: unconfirmed. [S22 (summary)]
51. "Magic Audio" is a sound enhancement feature (noise, level). It is not a pause remover. The name "Smooth pauses" was not found. [S22 (summary)]

## Optional: Premiere Pro and Auphonic

52. Premiere Pro text-based editing: open the filter icon of the Transcript panel, choose Pauses, then "Delete" (one pause) or "Delete all". The official page (HTTP 403) was read as a summary only. [S23 (summary)]
53. Pause length: the menu item "Set pause length" in the overflow menu of the Transcript panel. The Adobe Community beta post says pauses "can be as short as 0.1s or as long as 2.5s". The default is not stated. Premiere applies a ripple edit in the sequence (third-party report). [S23, S23b]
54. Auphonic Cut Silence uses voice activity detection, not a user threshold. "No further settings are required." Intended breaks between sentences stay. Each silence is cut to a length that "still sounds natural" (the value is not stated). Joins are crossfaded. The settings, minimum length, and defaults: not published. [S24]
55. Auphonic cut modes: "Apply Cuts" removes the segments. "Set Cuts To Silence" fades them to silence. "Export Uncut Audio" only reports the cuts. "Chapter marks and speech recognition transcripts are adapted accordingly." [S24]
56. Auphonic review: cut regions show as grey areas in the Audio Inspector. The master track skips them, and the input track plays them. The user can move, deactivate, or add cut regions. A cut list exports as regions (Audacity, Audition, Reaper) or as an EDL (Reaper, DaVinci Resolve, Final Cut Pro). [S24]

## Comparison

| App | Detection rule | Threshold default | Minimum length default | Shorten-to default | Action kinds | Review UI | Effect on markers, transcript, other tracks |
|---|---|---|---|---|---|---|---|
| Hindenburg PRO | none (manual Remove silence) | not found | not found | not found | delete or insert blank time | none | not documented |
| Descript | transcript word gaps | none (not level based) | unconfirmed (example 750 ms) | unconfirmed (example 200 ms) | shorten one or all | search panel with arrows, preview, auto-advance | one script timeline (Inference) |
| Audition | level and time, Find Levels | unconfirmed (user: -49 to -74 dB) | unconfirmed (user: 1000 ms) | set in ms, unconfirmed | shorten, delete (mute?), mark, strip, split | list, Repair/Delete/Mark and All | Strip does not ripple (user) |
| Logic Pro | level and time | unconfirmed | unconfirmed | none (split only) | split into regions | gray preview in waveform, Replace dialog | relative timing kept |
| Audacity Truncate | per sample, all channels | -20 dB (range -80 to -20) | 0.5 s | 0.5 s or 50 percent | truncate, compress | none | sync-lock, labels move |
| Audacity Label Sounds | peak per 10 ms | -30 dB | 1 s | none | mark only (labels) | label track | audio unchanged |
| Final Cut Pro | none for pauses | not found | not found | not found | silent channel removal only | none | not applicable |
| Riverside | transcript pauses (assumed) | unconfirmed | unconfirmed | unconfirmed | delete, revert | slider, symbols in transcript | unconfirmed |
| Premiere Pro | transcript pauses | none | 0.1 to 2.5 s (slider) | none | delete, delete all | filter in Transcript panel | ripple (third-party) |
| Auphonic | voice activity detection | not exposed | not exposed | "natural" (not stated) | cut, fade to silence, report | Inspector grey regions, editable | chapters and transcript adapted |

## Open questions

- Audition exact defaults for Define Silence As and Define Audio As, and whether Mark Audio writes cue markers or range markers. Probe needs the app. Read the Adobe PDF or Wayback copy later.
- Logic Remove Silence units and defaults. Probe: open the window in Logic Pro and read the fields.
- Descript: default gap and target values, a per-item skip, and the undo step of "Shorten all". Probe: run the tool in the app.
- Hindenburg "Remove silence" (Ctrl Left Arrow): the removed length and the selection rule. Probe: run the command in the app.
- Descript, Riverside, Audition: the place of the kept part in a shortened pause (center, start, or end). Only Audacity (middle removed) is confirmed.
- Inference: a Dirigible silence tool can use a level threshold plus a minimum length, as Audacity and Logic do. No source checked the most common podcast gesture (shorten every pause above a length to a fixed length, then undo it). Descript and Premiere are the closest precedents.
- Inference: a review list with Shorten, Mute, and Mark per row matches the Audition Diagnostics list. Per-row accept and reject exists in Audition (list selection) and Descript (arrows). Keys for the flow are documented in no app read.

## Sources

- S1 Repo: docs/research/read-by-time.md (findings 19, 24, 26 to 29, 33), docs/research/hindenburg-edit-tools.md, docs/research/podcast-features.md (row F26)
- S2 https://manual.audacityteam.org/man/truncate_silence.html
- S3 https://manual.audacityteam.org/man/label_sounds.html
- S4 https://help.descript.com/script-editing/shorten-word-gaps (and the .md copy)
- S5 https://help.descript.com/script-editing/word-gaps
- S6 https://help.descript.com/script-editing/filler-words (search summary; direct fetch of a guessed URL gave 404)
- S6b https://feedback.descript.com/feature-requests/p/shorten-word-gaps-with-an-upper-bound-and-or-time-multiplier (search summary)
- S7 https://feedback.descript.com/feature-requests/p/select-silence-threshold
- S8 https://help.apple.com/logicpro/mac/10.4/en.lproj/lgcp86ee7672.html
- S9 https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_19_section_2.html and https://logicpro.skydocu.com/en/create-a-song-arrangement/remove-silent-passages-from-audio-files/remove-silent-passages-in-the-strip-silence-window/
- S10 https://9to5mac.com/2019/09/15/remove-silence-in-logic-noise/
- S11 https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcp5e08f225.html and https://www.logicprohelp.com/forums/topic/162832-strip-silence-minimum-time-to-accept-as-silence-parameter-being-ignored-logic-pro-1122/ (search summary only, HTTP 403)
- S12 https://helpx.adobe.com/audition/desktop/importing-recording-and-playing/strip-silence.html and https://helpx.adobe.com/audition/using/diagnostics-effects-waveform-editor-only.html (HTTP 403, search summaries only)
- S13 https://community.adobe.com/questions-544/shorten-silence-between-talkers-in-multitrack-157321, https://community.adobe.com/questions-549/initial-feedback-and-a-request-on-delete-silence-in-multitrack-314804, https://community.adobe.com/t5/audition-discussions/issue-with-delete-silence-but-retain-file-length/td-p/9580918, https://community.adobe.com/feature-requests-545/use-diagnostics-to-quickly-select-mute-silence-as-documented-1436093, https://community.adobe.com/t5/audition-discussions/deleting-silence-help-needed/m-p/9158191/highlight/true
- S14 https://hindenburg.com/support/release-notes/hindenburg-series/
- S15 https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_05-build-2724/
- S16 https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- S17 https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- S18 https://hindenburg.com/hindenburg-pro-2-features/edit-with-words/
- S19 https://support.apple.com/guide/final-cut-pro/audio-analysis-options-verb6acaf60/mac
- S20 https://cutback.video/blog/how-to-remove-silence-in-final-cut-pro (search summary, secondary)
- S21 https://auphonic.com/help/algorithms/singletrack.html (FCP X EDL cut list)
- S22 https://support.riverside.com/hc/en-us/articles/13993078729245 and https://support.riverside.com/hc/en-us/articles/12245776523677 (HTTP 403, search summaries only)
- S23 https://helpx.adobe.com/premiere/desktop/edit-projects/edit-video-using-text-based-editing/detect-and-delete-pauses-in-transcripts.html (HTTP 403, search summary only)
- S23b https://community.adobe.com/t5/premiere-pro-beta-discussions/text-based-editing-update-change-the-length-of-pauses/td-p/13692557
- S24 https://auphonic.com/help/algorithms/singletrack.html and https://auphonic.com/blog/2023/05/09/automatic-silence-cutting/
