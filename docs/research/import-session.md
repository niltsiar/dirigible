# Research: reference behavior for Import Session (F151)

Date: 2026-10-28

Scope: how other apps merge another session into the open one. The .nhsx file facts are in `docs/research/session-formats.md` and are not repeated here.
Tags: [HG] Hindenburg, [PT] Pro Tools, [LP] Logic Pro, [RP] REAPER, [FCP] Final Cut Pro, [DS] Descript. A tag names the source in `## Sources`. "Unconfirmed" means no primary source states the claim.

## 1. Hindenburg PRO: Import Session Into Session

1. The PRO guide has an entry "Import Session Into Session - .nhsx". Its text is "Import an entire session into current session". [HG1]
2. The shortcut list shows no shortcut for this entry. [HG2]
3. The Narrator guide has a similar entry "Import formats - .nhsx": "Import a Hindenburg (.nhsx) file in your current session". [HG3]
4. The PRO guide links a 21 second video, "How to import an entire session into Hindenburg Pro". The video page has no text. The video content was not read. [HG1, HG4]
5. The release notes of the PRO 2 series have no entry for this command. [HG5]
6. A different command exists: "Import clipboard into another session". The user opens the clipboard, right-clicks a group, chooses Import, and picks the .nhsx file. The article says "This will only work for session with the same sample rate (44.1 KHz or 48 KHz)". [HG6]
7. Inference: the session import has the same sample rate limit as the clipboard import. No source confirms it.
8. Unconfirmed: the menu path, what the command imports (tracks, clips, markers, chapters, track settings, favorites), where it puts the material (playhead, 0, original positions), new or existing tracks, copy or reference of audio files, and the result at a different sample rate.
9. Secondary only: a Danish school handout (not the vendor) describes a manual way: select all in the other session, copy, open the target session, click where the material goes, and paste. [DM] This is not the command.

## 2. Pro Tools: Import Session Data

The primary source is the Pro Tools Reference Guide, version 10 (2011). Newer versions may differ. [PT1]

1. Menu path: File > Import > Session Data. The user can also drag the session file into the Edit window or the Track List. [PT1]
2. The Menus Guide says the command imports tracks and "the Tempo Meter Map, and any Key Signature Maps, Markers/Memory Locations, and Window Configurations". [PT2]
3. Track matching: each source track has a pop-up menu. The choices are Do Not Import, Import as New Track, or a destination track. Only a destination of the same type and channel format is listed. [PT1]
4. Match Tracks pairs source and destination tracks automatically. The tracks need the same name, type, and channel format. [PT1]
5. Track Data to Import is a list of attributes. It includes clip gain, volume, pan and mute automation, output and send assignments, plug-ins and their settings, track comments, track colors, and groups. Selected attributes replace the same attributes of a destination track. An attribute that is not selected stays unchanged. [PT1]
6. Markers: the option "Import Marker/Memory Locations" imports markers and memory locations. The destination markers are kept. The imported markers get "the next available Marker/Memory Location numbers". [PT1]
7. Main Playlist Options: "Import - Replace Existing Playlists" deletes the destination playlist. "Import - Overlay New On Existing Playlists" trims and replaces only the overlapped part of the destination playlist. [PT1]
8. Timecode Mapping Options set where the tracks go. [PT1]
   - Maintain Absolute Timecode Values: tracks go to their original locations.
   - Maintain Relative Timecode Values: tracks keep the same offset from the session start as in the source session.
   - Map Start Timecode To: the user types a new start for the source session.
   - Adjust Session Start Time to Match Source Start Time: the target session takes the source start time.
9. Track Offset Options add a user offset on top of the mapping. The user types minutes:seconds, bars and beats, samples, timecode, or feet and frames. [PT1]
10. A drag and drop import starts "wherever you drop the session in the Timeline". [PT1]
11. Sample rate: if the two session rates differ, the dialog shows Source Sample Rate, Destination Sample Rate (always the current session), and Conversion Quality. If the rates are equal, this part is unavailable. [PT1]
12. Audio Media Options: [PT1]
    - Link to Source Media: refer to the original files. Pro Tools copies the files instead if they need bit depth or sample rate conversion.
    - Copy from Source Media: copy all audio files of the imported tracks to a place that the user picks. It converts them to the session format if needed.
    - Consolidate from Source Media: copy only the used parts, with a handle in milliseconds.
    - Force to Target Session Format: convert and copy only the files that do not match.
13. An imported track becomes inactive if its source media is unavailable. [PT1]
14. Secondary check for a newer version: Sound on Sound confirms Match Tracks and the marker import in version 2024.6. [PT3]

## 3. Logic Pro: import from other projects

The pages are Logic Pro 10.1 and 9.1.6. They are old. The current page body did not load. [LP1, LP2]

1. Menu path: File > Import > Logic Projects. The user can also click All Files in the Browser, select the project, and click Import. [LP1]
2. The Track Import view lists what to import: "track content (regions and folders)", plug-ins with settings, sends (level, routing, destination), input and output assignments, automation, and track notes. [LP1, LP2]
3. Add puts the data on new tracks "below the selected track in the Tracks area". Replace overwrites the selected track, and works only when one row is selected. [LP1, LP2]
4. Project settings are a separate import: File > Project Settings > Import Project Settings. The list has screensets, sync, metronome, record, audio, MIDI, and video settings. [LP2]
5. Unconfirmed: the time position of the regions, markers, sample rate handling, and whether audio files are copied. The two pages say nothing on these points.

## 4. REAPER

1. REAPER has subprojects. The release notes of version 5.11 say "support embedding projects within projects" and add an action to move tracks to a subproject. [RP1]
2. The release notes say a subproject writes a rendered proxy file, `.rpp-prox`, and write the start time into it as the BWF preferred start position. [RP1]
3. Moving a track to a subproject copies markers and regions (5.75). [RP1]
4. Version 7.66 added "importing regions/markers from REAPER project file (.RPP)". [RP1]
5. Secondary: Sound on Sound says a user drags an .RPP file onto the timeline and picks "Insert project as media item". [RP2]
6. Unconfirmed: a REAPER command named "Import tracks from project". The release notes have no such entry. The user guide PDF (version 7.83) was downloaded but its text did not extract, so it was not read.

## 5. Waveform alignment after import

1. Final Cut Pro: Clip > Synchronize Clips. The option "Use audio for synchronization" "makes precision sync adjustments using audio waveforms". [FCP1]
2. FCP "analyzes the clips for sync points such as" markers, timecode, file creation date, and audio content. If it finds none, "the clips are synced at their respective starting points". [FCP1]
3. FCP warns that "Some audio recordings are not suited for use with this feature" and that the option can mean long processing times. [FCP1]
4. This matches the F151 plan: a rough start first, then a waveform fit that refines it. A Dirigible package has no clock in common with another package, so its rough start is the position on its own timeline plus an offset (run U1).
5. Unconfirmed: whether FCP corrects clock drift. The page says nothing on drift.
6. Descript: its help page for syncing a recording session says to align tracks by dragging them in the Sequence editor, and only when a recorder started late, paused, or stopped early. [DS1] A search snippet from the help center names a "Multi-Track Autosync" button and a limit of 14 tracks. [DS2] Unconfirmed: that Autosync uses the waveform, and any drift handling. The fetched pages do not say it.
7. Hindenburg has no waveform alignment in the sources read. Unconfirmed.

## 6. What this means for the F151 defaults

All items here are inference. The owner sources are in the findings above.

1. Pro Tools gives the user three placements: original positions, relative to the session start, or a typed start. For two Dirigible sessions on one conversation, "original positions" (the positions of the source timeline, plus an offset) is the closest match. A package stores no clock in common with another package (run U1). The Map Start option and the Track Offset cover a shifted start. [PT1]
2. Pro Tools and Logic both let the user pick a destination track or a new track. F151 adds new tracks only, so it needs no matching step. [PT1, LP1]
3. Pro Tools keeps destination markers and renumbers the imported ones. A marker option fits the plan. [PT1]
4. Pro Tools converts the sample rate on request. Hindenburg refuses a different rate for the clipboard import. [PT1, HG6]
5. No source covers the main F151 gesture: two people record one conversation on two clocks. Only FCP names the pattern "rough start, then waveform refine". No source confirms a drift fit.

## Sources

- [HG1] Hindenburg PRO guide, entry "Import Session Into Session - .nhsx": https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [HG2] Hindenburg PRO shortcuts: https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [HG3] Hindenburg Narrator guide, "Import formats - .nhsx": https://hindenburg.com/academy/guides/guides-narrator/
- [HG4] Video page: https://hindenburg.com/data/youtube/videos/how-to-import-an-entire-session-into-hindenburg-pro-hindenburg/
- [HG5] Hindenburg release notes: https://hindenburg.com/support/release-notes/hindenburg-series/
- [HG6] Hindenburg support, "Import clipboard into another session": https://hindenburg.uservoice.com/knowledgebase/articles/341036-import-clipboard-into-another-session
- [DM] DMJX handout (secondary, Danish): https://faq.dmjx.dk/wp-content/uploads/2018/02/Hindenburg_manual_Mac_baerbar.pdf
- [PT1] Avid Pro Tools Reference Guide 10.0, chapter 17, "Importing Session Data": https://resources.avid.com/SupportFiles/attach/Pro_Tools/10.0/ENGLISH/Pro_Tools_Reference_Guide.pdf
- [PT2] Avid Pro Tools Menus Guide 10.0, "Import Session Data": https://resources.avid.com/SupportFiles/attach/Pro_Tools/10.0/ENGLISH/Menus_Guide.pdf
- [PT3] Sound on Sound, Pro Tools Importing Session Data (secondary): https://www.soundonsound.com/techniques/pro-tools-importing-session-data
- [LP1] Apple Logic Pro 10.1 guide: https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcpce085447.html
- [LP2] Apple Logic Pro 9.1.6 manual: https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_7_section_6.html
- [RP1] REAPER release notes: https://www.reaper.fm/whatsnew.txt
- [RP2] Sound on Sound, REAPER subprojects (secondary): https://www.soundonsound.com/techniques/reaper-subprojects
- [FCP1] Apple, Sync audio and video in Final Cut Pro: https://support.apple.com/guide/final-cut-pro/sync-audio-and-video-verc1fabc30/mac
- [DS1] Descript, sync multiple audio and video files: https://help.descript.com/hc/en-us/articles/16049556759693-Sync-multiple-audio-and-video-files-from-a-recording-session
- [DS2] Descript, Sequence overview (search snippet only): https://help.descript.com/hc/en-us/articles/10256430454925-Sequence-overview
