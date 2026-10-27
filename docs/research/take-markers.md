# Markers during a take: Hindenburg and other editors

Date: 2026-10-27

This document records how Hindenburg PRO and three Apple apps add a marker while a recording runs. It adds to `docs/research/edit-commands.md` section 8 and `docs/research/podcast-features.md` row F19, and does not repeat them. A claim that no primary source confirms has the mark "(unconfirmed)". A sentence that starts with "Inference:" is our reading of the sources.

## Findings

1. **Hindenburg key, version 1.21.** The macOS guide gives "Add marker > ⌘ Enter" and "Rename > Enter" on page 59 [HM]. Record is "Ctrl+ Spacebar" on page 19 [HM]. The guide has no sentence about a marker during a recording [HM, all 97 pages searched for "marker" and "record"].
2. **Hindenburg key, version 2 PRO.** The shortcut page lists "Add marker: Ctrl Enter" ("Markers are used for quick navigation in the session"), "Add new chapter: Ctrl Shift + Enter" ("Place the playhead at the desired position and use the shortcut to set a chapter-marker"), and "Cue point: Option + Ctrl Enter" ("The Cue Point will be locked to the audio and not the timeline") [H2]. Record is "Ctrl + Spacebar" [H2]. No row says what a key does while a take records [H2]. Inference: "Ctrl" on that page is the Command key on a Mac, because the same page writes "Option" for a Mac modifier and the 1.21 macOS guide gives ⌘ Enter for the same command. No source confirms this.
3. **Hindenburg during a recording.** No primary source that we found says that Add Marker works while Hindenburg PRO records (unconfirmed). The Hindenburg Field Recorder app (iOS) lets the user "set markers at points of interest" during an interview [HFR]. The requirement of F107 comes from the user decision of 2026-10-14 (A14, backlog item 0059): "as Hindenburg users mark a mistake".
4. **Hindenburg and markers made during a call.** Cleanfeed writes markers during a recording, and Hindenburg imports them. The Cleanfeed guide says that Hindenburg keeps markers 1 and 2 for the session start and end [CF]. This comes from the search excerpt. The page was not fetched. Inference: podcasters use a marker made during the recording to find a mistake later.
5. **Logic Pro.** "You can use the Create Marker key commands to add markers during playback." A marker goes to the playhead when the playhead is on a bar, else to the next bar. Create Marker without rounding keeps the exact position [LP]. The page does not say if the key works during a recording [LP]. Logic Pro 9 marks a good take during a recording with "Select Previous Section for Realtime Comping": it "places a tag in the current take, at the position the key command was used" [LP9].
6. **GarageBand.** GarageBand has arrangement markers for song sections only [PF, row F19]. No source shows a marker during a recording.
7. **Final Cut Pro.** M adds a marker; the Chapter Marker button makes it a chapter [MK]. The Record Voiceover page gives Option-Shift-A to start and stop a recording, and says nothing about markers during the recording [VO].

## Open questions

- Hindenburg PRO behavior during a recording: does Command-Return add a marker at the record head, and does the marker show at once? A check needs Hindenburg PRO, which is not installed (unconfirmed).
- Logic Pro: does Create Marker work during a recording, and where does the marker go? The local Logic Pro 12.3.1 can answer it with a manual check; this run did not do it.

## Sources

- [HM] Hindenburg Journalist 1.21 user guide for macOS, pages 19 and 59 to 60 (text read with PDFKit on 2026-10-27): https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [H2] Hindenburg Academy, shortcuts of Hindenburg 2 PRO (read 2026-10-27): https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [HFR] Hindenburg Field Recorder, App Store page: https://apps.apple.com/gb/app/hindenburg-field-recorder/id346169165
- [CF] Cleanfeed, markers and notes, best practices for editors: https://cleanfeed.net/knowledge/markers-and-notes-best-practices-for-editors
- [LP] Logic Pro 10.1 help, create markers: https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcp564d6a94.html
- [LP9] Logic Pro 9.1.6 user manual, marking a good take while recording: https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_14_section_29.html
- [PF] `docs/research/podcast-features.md`, row F19.
- [MK] Final Cut Pro, add chapter markers: https://support.apple.com/guide/final-cut-pro/add-chapter-markers-verc9cacc031/mac
- [VO] Final Cut Pro, record voiceovers: https://support.apple.com/guide/final-cut-pro/record-voiceovers-verc1faa9c5/mac
