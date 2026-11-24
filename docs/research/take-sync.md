# Research: take-sync (reference behavior of editors and the SRT format)

Date: 2026-10-22

Question: how do Hindenburg PRO, Descript, REAPER, Logic Pro, Final Cut Pro, and the video editors keep or break the link between an edited timeline and the original recording? What does the SRT format need? Which time-map forms exist?

Rules in this file:
- A tag in brackets names the source in `## Sources`.
- "Inference:" marks my reading, with no source that states it.
- "(unconfirmed)" marks a claim with no primary source.
- Pages are the versions that I fetched on 2026-10-22. Search summaries, where I did not fetch the page, are marked "search only".

## 1. Hindenburg PRO 2.x

1. A Cue Point is locked to the audio, not to the timeline, and follows edits [HG]. Hindenburg support says a Cue Point moves, copies, and deletes with the audio, so a list of cue points is "a bit of a moving target" [HU2].
2. The guide describes a normal Marker only as "quick navigation in the session" [HG]. No Hindenburg page says whether a marker follows a cut, a delete, or an insert (unconfirmed).
3. A user request from 2020 says chapter markers do not move with the audio, so the user moves them by hand. It has 7 votes and no staff reply [HU1]. A comment from 2021 says the workaround is to put Cue Points on the audio and convert them to chapters before export [HU1]. Inference: in Hindenburg the user must choose the audio-locked kind (cue point) to keep sync, and the default kinds do not follow.
4. The edit commands are Cut, Region Cut, Clear/Delete, Insert, Insert silence, and Remove silence. The shortcut list has no ripple command [HS]. The repo file `docs/research/ripple-edit.md` records, from the Hindenburg manual (primary): Cut closes the gap, Insert pushes later regions, and Clear keeps the gap [RE].
5. The transcript is attached to the clips. After "Transcribe", the words show above each clip and line up with the waveform [PN]. A text delete in the Manuscript cuts the audio [HE][PN].
6. Export formats are TXT, SRT, VTT, JSON, and HTML. The FAQ limits export to the Plus, Premium, and Perpetual licenses [HF]. Release 2.02 build 2614 (2024-05-02) "Updated VTT export format" [HRN]. The October 2023 review says SRT, JSON, and TXT [PN].
7. No source states the time origin of the exported SRT or VTT (session zero or clip zero) (unconfirmed). Inference: the transcript lives on the clips, so the export is on the edited timeline. No source confirms it.
8. No page says that Hindenburg imports an SRT or VTT file. The transcription pages, the FAQ, and the release notes mention export only [HF][HRN][HT]. The earlier run research reached the same result: "No source for an external import" [TR1]. Not found, so import is unconfirmed.
9. No Hindenburg feature that shows or keeps the sync with the original recording was found [HG][HRN] (not found).

## 2. Descript

10. Delete removes the script text and its media. A deleted range is absent from text exports and from share-page transcripts. It can be restored at any time. Ignore keeps the text with a strikethrough and skips it in playback. Ignored text is absent from subtitles [DD].
11. Subtitle export has the formats `.srt` and `.vtt`, and settings for speaker labels, maximum characters per line, and lines per card. The page says nothing about timing after edits [DS]. Inference: because deleted and ignored ranges leave the subtitles, the subtitle times are the edited-timeline times.
12. Text export has a "Timecode offset" setting (`hh:mm:ss`) that moves the start time, an interval setting, and a setting to add or remove timecodes for markers [DT]. So the user can shift the time origin on export.
13. Import is "Import transcript" or "Replace transcript" on a file. The user pastes text and clicks Sync. The feature supports English only. Speaker lines use `Name: text`. Sync replaces the whole existing transcript [DI]. The page does not name SRT, and does not say whether times in the pasted text are used (unconfirmed). Inference: Descript aligns the text to the audio itself.
14. A marker is added with `#` in the script, with "Add marker", or with the AI chapters tool. The user drags it by hand. The page does not say whether a marker follows a deletion (unconfirmed). Local exports write markers as chapters only if the user turns on "Include markers as chapters" [DM].

## 3. REAPER 7.x

15. Ripple has three states: off, per track, all tracks. Alt+P cycles them. Both ripple modes are off by default [RG].
16. The guide says that "markers and automation are locked to the items that they relate to" in a ripple mode. The text sits after the paragraph on the three modes and does not name the mode [RG]. The change log is clearer: v7.62 (2026-02-28) "Ripple: add setting for ripple-all to affect regions/markers". v7.63 (2026-03-05) fixes editing of regions with ripple-all on and that setting off [RC]. Older entries: "marker/region lock obeyed during ripple edit all/insert time/delete time" and "ripple all mode moves markers too" [RC]. Inference: markers and regions move only in the all-tracks mode and only if that setting is on. The default value of the setting was not found (unconfirmed).
17. The guide v7.81 and the change log up to v7.82 contain no SRT, subtitle, or caption import or export feature (searched for "srt", "subtitle", "caption" in both) [RG][RC]. The Region/Marker Manager imports and exports `.csv`, `.txt`, and `.rpp` [RG]. A community ReaScript "Track to SRT" turns text items into SRT (search only) [RS]. Inference: REAPER has no native SRT; item notes are the usual carrier of text.
18. The item ruler can show "Source time" or "Source time H:M:S:F" for the selected items [RG]. This shows the take time of an item, not the take time of any project position. Inference: the user must select the item that covers the position.

## 4. Logic Pro

The current (11 or 12) page "Add or remove gaps" did not give its body text to my fetch tool. I used the 10.1 and 9.1.6 guides [LA][LA9].

19. Insert Silence Between Locators moves regions that began at the left locator to the right locator. Cut Section (Snip) deletes the section between the locators from the selected regions, and the regions to the right move left by the locator length [LA].
20. Markers and tempo changes shift only when the user selects everything first (Command-A or Shift-I). The guide gives this advice for Splice: "make sure you select everything beforehand" so that tempo, time signature changes, and markers shift too [LA][LA9]. Inference: with a partial selection, markers stay at their position.
21. I found no option named "Move markers" in the guide (unconfirmed).
22. "Lock SMPTE Position" keeps a region at its absolute time after a tempo change. A locked region shows a padlock. Copies lose the lock [LS]. A marker can be locked in the Marker List, and a locked marker "always" keeps its absolute time [LM]. This protects sync with video against tempo changes, not against Cut or Insert Time (Inference).
23. No source describes subtitle or SRT support in Logic Pro (unconfirmed; not found).

## 5. Final Cut Pro

24. Caption clips (closed captions and subtitles) "are always connected clips". A closed caption can also connect to another connected clip. The user can move a caption by drag, by a timecode value, or by nudge [FC1].
25. Connected clips move or delete with the primary storyline clip: "any clips connected to them are moved or deleted along with the primary storyline clips". The Grave Accent key keeps the connected clips in place [FC4].
26. Transcribe to Captions (the older text says "Generate Captions") connects each caption to the clip that it came from. Captions show in a lane at the top of the timeline. The format is iTT [FC5].
27. For hand-made captions, Apple warns that a later change to the dialogue clips "might cause the closed captions to go out of sync" and tells the user to lock the dialogue first [FC5]. Inference: this is a documented instruction, not an automatic warning.
28. Import: `File > Import > Closed Captions` in the current guide page that I fetched (the page does not name a version, and the brief says "Captions", so the menu text in 11.x is unconfirmed). Formats are `.scc`, `.itt`, `.srt`. The dialog asks for a role, a language subrole, and an Insertion Time. "Relative to Timeline" adds the project start time to each caption start. "Absolute" uses the caption start as it is [FC2]. The captions land in the caption lane.
29. Export: `File > Export Captions`. The dialog has one file for each language subrole, a Start Time option (Relative subtracts the project start time, Absolute does not), and for SRT an "Include Formatting" checkbox. Apple advises to clear that box [FC3].
30. A marker is inside a clip: "You can only drag a marker within a clip". To move it to another clip the user cuts and pastes it [FC6]. Inference: a clip marker rides with its clip in an edit.
31. `Window > Source Timecode` (or Option-click the timecode display) opens a window with the clip name and source timecode of every clip at the playhead. Clip skimming also shows the source timecode of the clip [FC7].

## 6. Sync warnings in video editors

32. DaVinci Resolve 20 manual: if Linked Selection is off and the user moves a clip's audio or video alone, red "out-of-sync" indicators show at the left of the clip name bar. They show "the timecode offset" by which the pair is out of sync. A right-click on the indicator gives Slip into place, Move into place, Slip others into place, and Move others into place [RM20]. The Fairlight page has a "Sync Offset Indicator" for audio that left its linked video [RM20]. With Auto Select off on a track, a ripple delete leaves its clips in place and they go "out of sync" [RM20].
33. Avid Media Composer (excerpt of the Avid manual on a slide host; primary Avid page not fetched): sync breaks show in the Timeline as white numbers at the break points. The number is a positive or negative offset in frames from zero. The default shows them on the affected tracks. A match-frame edit shows "=". The Timeline Fast menu changes the display. The fix is a trim by the shown number of frames [AV]. The number is the offset between a segment and its source timecode alignment on other tracks (a book excerpt; search only) [AVB].
34. Premiere Pro: red numbers in the corner of a clip show the frames out of sync, for audio and video that were imported together. They do not show for clips that the user linked by hand. A right-click offers "move into sync" or "slip into sync" [PVC]. The Adobe help pages returned HTTP 403, so Adobe's own wording is not confirmed (unconfirmed). Sync Lock decides which tracks an insert, a ripple delete, or a ripple trim moves (search only, Adobe help summary) [PSL].
35. Pattern. All three are passive: each shows a per-clip number in frames or timecode, and none opens a dialog. The user fixes the break with a slip or a move. Inference: the indicators update after each edit (no source states it). In all three the pair is two parts of one clip. The take-sync case differs, because the pair is an edited timeline and an external recording with no clip link. Inference.

## 7. SRT and WebVTT format facts

36. SRT has no formal specification. The Library of Congress entry says "Little to no information on SRT formal documentation" and "SRT subtitle files do not have a character encoding standard" [LOC]. The Matroska page lists four parts and gives one example, and states no timestamp rule [MK]. Best de facto description: the Matroska page for the shape, the ffmpeg parser `srtdec.c` for what a reader accepts [FS], and the Whisper writer for what a common producer writes [WH].
37. Cue shape [MK][WH]: an index line (1-based in Whisper), a line `HH:MM:SS,mmm --> HH:MM:SS,mmm`, one or more text lines, a blank line.
38. Hours. Whisper always writes two-digit hours for SRT [WH]. ffmpeg reads `%d:%d:%d` so any digit count parses, and it needs all of hours, minutes, and seconds in the pattern [FS]. WebVTT hours are optional, but required if non-zero, and have two or more digits [W3C].
39. Decimal separator. SRT uses a comma in [MK][LOC][YT][WH]. ffmpeg accepts a comma or a dot, and the start and end may differ [FS]. WebVTT allows only a dot [W3C].
40. Milliseconds. ffmpeg reads the fraction as an integer, so `00:00:01,5` gives 5 ms, not 500 ms [FS]. WebVTT needs exactly three digits [W3C]. Inference: always write three digits.
41. Encoding. YouTube: "The file must be in plain UTF-8" [YT]. ffmpeg skips a UTF-8 BOM and decodes UTF-16 with a BOM [FSU]. WebVTT allows an optional BOM [W3C]. Whether YouTube or Apple accepts a BOM is not stated (unconfirmed). Inference: write UTF-8 with no BOM.
42. Line ends. ffmpeg accepts CR, LF, and CRLF [FSU]. WebVTT accepts CRLF, LF, and CR [W3C]. Both leave the choice to the writer. Inference: write LF.
43. Order and overlap. ffmpeg does not check order in the SRT demuxer; later code may sort by time [FS][FSU]. It does not check that the end is after the start [FS]. WebVTT needs each start to be at or after all earlier starts, and an end after its start (so a zero-length cue is invalid). Cues may overlap [W3C]. Inference: write cues sorted by start, with end greater than start.
44. Empty cues. ffmpeg makes no event for a timing line with no text [FS]. WebVTT syntax allows an empty payload [W3C]. Inference: do not write empty cues.
45. Text. Whisper replaces `-->` in the text with `->` so that a reader does not take it as a timing line [WH]. WebVTT does not allow `-->` in an identifier [W3C].
46. Apple Podcasts: accepts VTT or SRT. It lists no timestamp rule and no size limit. A file that fails "quality standards" is not shown, and the page does not define those standards [AP]. YouTube lists `.srt` among the basic formats, with no style markup [YT]. What these two services refuse in detail is not documented (unconfirmed).

## 8. Time map forms: EDL and OTIO

47. A CMX3600 event is one source-to-record operation: a source roll (reel), source timecode in and out, record timecode in and out, a transition, and channels. This is the description of the pycmx parser [PY]. Autodesk lists the CMX3600 features: cuts, dissolves, wipes, speed changes, comments [AD]. The scanned CMX 3600 document at xmil.biz is an image, and my tool could not read it, so the column layout is not confirmed from the original (unconfirmed).
48. In OpenTimelineIO a Clip has `source_range` (the trim on its media) and `range_in_parent()` (where it sits in the track). Each range says which time frame it uses: the clip frame or the parent frame [OT][OTA]. A Marker has a `marked_range` relative to the item that holds it [OTS]. Times are `RationalTime(value, rate)` [OTS]. I did not read the semantics of `transformed_time` from a primary page (unconfirmed).
49. Inference: a list of segments `{source_in, source_out, record_in}` carries the same data as CMX3600 events and OTIO clips. A tool output with the pycmx or OTIO names (`source_in`, `source_out`, `record_in`, `record_out`) would be familiar to an agent that knows those formats. A podcast session has no tape, so no reel field is needed, and a time unit with an explicit rate (seconds or frames) is the sensible choice.

## 9. Candidate defaults for the plan (Inference)

50. Imported times of an external file (SRT, chapters, notes) are on the original take. Map them with the time map to the edited timeline; a cue whose whole range was deleted has no edited time and needs a stated rule (drop, or report). Descript drops deleted text from subtitles [DD]; FCP deletes connected captions with their clip [FC4]. Both match "drop and report".
51. Every reference app shows sync state as a passive indicator with a number, not as a dialog [RM20][AV][PVC]. A warning from a tool call should return the offset as data, in the unit of the time map.
52. Markers follow edits only when they are tied to the audio (Hindenburg cue points, FCP clip markers, REAPER ripple-all with the option on). Apps with free markers leave them in place after a ripple (Hindenburg chapters, Logic with a partial selection). The plan must pick one, and the tester's case (notes and chapters from the original) points to "follow the audio". Inference.
53. FCP and Descript give the user a time-origin choice on export (Relative or Absolute; timecode offset) [FC3][DT]. SRT export from Dirigible needs the same choice if the episode has a start offset or a video. Inference.

## Claims with no confirming source

- Hindenburg: marker behavior on ripple; import of SRT or VTT; time origin of the exported SRT or VTT.
- Descript: whether the pasted text may hold SRT times; marker behavior on deletion.
- REAPER: default of the ripple-all marker setting; native SRT (not found, so probably absent).
- Logic Pro: a "Move markers" option; subtitle support; the current 11/12 page text.
- Final Cut Pro: the exact 11.x menu text for caption import.
- Premiere Pro and Avid: Adobe and Avid primary pages (403, or not found); the data come from secondary or excerpt sources.
- YouTube and Apple Podcasts: BOM acceptance and the detail of what they refuse.
- CMX3600 column layout and OTIO `transformed_time`.

## Sources

- [HG] https://hindenburg.com/academy/guides/guides-hindenburg-pro/ (Cue Point, Markers, Chapters, Cut/Delete/Insert)
- [HS] https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [HU1] https://hindenburg.uservoice.com/forums/224350-general/suggestions/41213986-ability-to-lock-chapter-markers-to-audio
- [HU2] https://hindenburg.uservoice.com/forums/224350-general/suggestions/33099493-view-cue-points
- [HE] https://hindenburg.com/hindenburg-pro-2-features/edit-with-words/
- [HT] https://hindenburg.com/hindenburg-pro-2-features/transcription/
- [HF] https://hindenburg.uservoice.com/knowledgebase/articles/2004043-transcription-faqs ; https://hindenburg.com/academy/features/features-hindenburg-pro/
- [HRN] https://hindenburg.com/support/release-notes/hindenburg-series/ ; https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_02-build-2614/
- [RE] docs/research/ripple-edit.md (Hindenburg manual pages 28 and 30, tagged primary there)
- [TR1] A local research file, not in git (line 16)
- [PN] https://podnews.net/article/hindenburg-pro-v2-review
- [DD] https://help.descript.com/script-editing/delete-vs-ignore.md
- [DS] https://help.descript.com/export-and-share/subtitles.md
- [DT] https://help.descript.com/export-and-share/transcript.md
- [DI] https://help.descript.com/script-editing/import-transcript.md
- [DM] https://help.descript.com/script-editing/markers-chapters.md (and the search summary of the same page for export options)
- [RG] REAPER User Guide v7.81, https://www.reaper.fm/userguide/ReaperUserGuide781c.pdf (section 7.20, 7.23, Region/Marker Manager)
- [RC] REAPER change log, https://www.reaper.fm/whatsnew.txt (v7.82 header 2026-10-04; ripple entries; no srt/subtitle/caption entries)
- [RS] https://github.com/chkhld/reascript (search only)
- [LA] https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcp21e2cb21.html
- [LA9] https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_13_section_16.html
- [LS] https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcpfffcaf81.html
- [LM] https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_6_section_8.html
- [FC1] https://support.apple.com/guide/final-cut-pro/verf8d5b6e49/mac
- [FC2] https://support.apple.com/en-gb/guide/final-cut-pro/ver4185ef95a/mac
- [FC3] https://support.apple.com/ro-md/guide/final-cut-pro/export-captions-ver245c7581b/10.6.6/mac/12.6
- [FC4] https://support.apple.com/guide/final-cut-pro/connect-clips-ver7a77ef9e/mac ; docs/research/final-cut-pro.md section 2
- [FC5] https://support.apple.com/guide/final-cut-pro/vere399dab5e/mac
- [FC6] https://support.apple.com/en-ge/guide/final-cut-pro/ver39727e41/mac
- [FC7] https://support.apple.com/en-az/guide/final-cut-pro/ver98e9bf26a/mac
- [RM20] DaVinci Resolve 20 Reference Manual, https://documents.blackmagicdesign.com/UserManuals/DaVinci_Resolve_20_Reference_Manual.pdf (Chapter 36, "Dealing with Audio Video Sync Offsets", p. 770; Chapter 175, "Sync Offset Indicator")
- [AV] https://www.slideshare.net/slideshow/creating-and-editing-sequences-avid-media-composer/84518041 (Avid manual excerpt)
- [AVB] https://subscription.packtpub.com/book/all_books/9781849693004/5/ch05lvl1sec71/sync-break-indicators--understanding-them-and-making-your-own (search only; page returned 403)
- [PVC] https://www.provideocoalition.com/tool-tip-tuesday-for-adobe-premiere-pro-sync-indicators/
- [PSL] https://helpx.adobe.com/premiere-pro-next/edit-project/change-clip-sequence/sync-lock-to-prevent-changes.html (search only; fetch returned 403)
- [MK] https://www.matroska.org/technical/subtitles.html
- [LOC] https://www.loc.gov/preservation/digital/formats/fdd/fdd000569.shtml
- [FS] https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/srtdec.c
- [FSU] https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/subtitles.c
- [WH] https://raw.githubusercontent.com/openai/whisper/main/whisper/utils.py
- [W3C] https://www.w3.org/TR/webvtt1/ (cue timings, timestamp, file body, parser sections 6.1 and 6.3)
- [YT] https://support.google.com/youtube/answer/2734698
- [AP] https://podcasters.apple.com/support/5316-transcripts-on-apple-podcasts
- [PY] https://pycmx.readthedocs.io/en/latest/classes.html
- [AD] https://help.autodesk.com/cloudhelp/2017/ENU/Flame/files/GUID-8EE69716-5DA9-4E7E-8CDD-110781C0275E.htm
- [OT] https://opentimelineio.readthedocs.io/en/latest/tutorials/time-ranges.html
- [OTA] https://opentimelineio.readthedocs.io/en/v0.15/tutorials/time-ranges.html (search only)
- [OTS] https://opentimelineio.readthedocs.io/en/latest/api/python/opentimelineio.schema.html
- xmil.biz scan (unreadable by my tools): https://xmil.biz/EDL-X/CMX3600.pdf
