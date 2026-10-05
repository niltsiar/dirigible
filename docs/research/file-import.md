# File import: placement, track, conversion, and feedback

Date: 2026-10-05

Eight questions for run 13. Grades: P (primary doc), S (secondary or summary), U (forum post). Facts already in docs/research are not repeated.

## 1. Where the clip lands in time

- **Hindenburg, menu import.** "To import an audio file into a specific location, drag the playhead ... to the place you want your next clip to begin." [BZ] (S). This source changes the note in recovery-tools.md line 70: one source now says that an import lands at the playhead.
- **Hindenburg, Finder drop.** The 1.21 guide says only "Drag any Audio file from Finder to Hindenburg" [HJ p. 15] (P). Transom: "drag and drop audio files from your hard drive into a track" [TR10] (S). No source gives the time of a dropped clip.
- **Logic, menu.** "Click the Open button to add the file to the selected track, at the playhead position" [LAD] (P).
- **Logic, drop.** No page gives the time of a drop. A moved region snaps to the grid [LMR] (P). Inference: a drop snaps too.
- **Audition.** "Select a track, and then place the playhead at the desired time position. Choose Multitrack > Insert Files" [AUI] (P).
- **Final Cut Pro.** "Depending on where you drag the clips in the timeline, your actions may result in an append edit, an insert edit, a connect edit, or a replace edit" [FDD] (P).

## 2. Which track

- **Hindenburg.** No source says which track receives a menu import, or what a drop below the last track does. Mono and stereo files "can even exist on the same track – just drag any file into any track" [TR10] (S). A handout says File > Import takes "one audio file at a time"; the clipboard imports "multiple files all at once" [WY] (S).
- **Logic.** A drop "to the area below all existing tracks" adds a new track. For several files, "an Add Files to Tracks dialog appears ... select whether to create new tracks, use existing tracks, or place all files on one track" [LDD] (P). An older Logic book (search excerpt only) says that the one-track option places the files "end to end" [PP] (S). A compressed file dropped "into the empty workspace area below the existing tracks" makes "a new audio track" [LCA] (P).
- **GarageBand.** "Drag the audio file ... to an audio track or to the empty area below the existing tracks ... The audio file appears on the track" [GBI] (P).
- **Audition.** The file goes to the selected track. With several files, or no space, Audition uses the nearest empty track [AUI] (P).

## 3. Menu name and key

- **Hindenburg.** The repo already has File > Import, Cmd-T, the toolbar button, and the workspace context menu (recovery-tools.md line 47). New: the clipboard has its own import, "Import audio > ⌘ T", "Import audio > Drag & drop" [HJ p. 56] (P). The PRO 2 shortcuts page lists "Clipboards - Import" [HPS] (P). It shows Windows keys only (ripple-edit.md line 16).
- **Logic.** File > Import > Audio File. The "Import Audio File" key is Shift-Command-I [LKC] (P).
- **GarageBand.** The import page describes only drag from the Finder or the Music app [GBI] (P). No menu command was found.
- **Audition.** Multitrack > Insert Files [AUI] (P). File > Import > File exists [AUI] (P). No key was checked.
- **Final Cut Pro.** File > Import > Media (Command-I) [FIM] (P).

## 4. Auto level on import (Hindenburg)

- "Incoming audio is aligned using EBU loudness standards. Speech and music are detected automatically" [HFH] (P). Inference: the clip type comes from a detector, not from the track.
- The preference text is "Perform automatic leveling after import and record", in Preferences > Advanced [TL21] (S).
- "Leveling is automatically applied when a clip is imported into the timeline, or a recording is made" [TC15] (S). Inference: a clipboard import possibly does not level until the clip goes to the timeline. No source checks this.
- Conflict: [TL21] says US Mode sets "the target loudness to -24 LUFS". The 1.21 guide gives US Mode Narration -20 LUFS and Music -21 LUFS [HJ p. 42] (P). This can change export-and-dsp.md line 120.

## 5. Conversion and the copy

- **Hindenburg sample rate.** "Files with different sample rates are automatically converted to the session's default sample rate of 44.1 or 48 khz" [TR10] (S, 2010).
- **Hindenburg stereo.** Stereo and mono files share a track [TR10] (S). Tools > Split Stereo makes "two mono files" from a stereo region, for "a mono interview with a stereo recorder" [HJ p. 43] (P). No source says that Hindenburg folds stereo to mono on import.
- **Hindenburg copy.** "The session files folder will have the same name as your session" [HKB] (P). No source says if the copy keeps the original file name.
- **Hindenburg formats.** "Import BWF, WAV, MP2, MP3, MP4, polywav and more" [HFH] (P).
- **Logic.** Compressed files (AAC, MP3, Apple Lossless) stay compressed. Their regions show a symbol, and conversion is a separate command [LCA] (P). Assets are "copied into the project when the project is saved" [LPA] (P).
- **Audition.** "If you attempt to import files with different sample rates, Adobe Audition prompts you to resample them" [AUI] (P).
- **FLAC.** None of the format lists in [LCA], [GBI], or [HFH] names FLAC. This is not proof that FLAC is unsupported.

## 6. Progress and cancel

- **Logic.** No Apple page. Users report an "Importing large audio file" progress bar, then "Could not open source file", for an MP3 in 10.0.5 [ACT] (U).
- **Final Cut Pro.** Import runs in the background. The Background Tasks window (Command-9) "shows the tasks being performed and the percentage of completion", with Pause, Resume, and Cancel buttons [FBT] (P).
- **HIG.** "Provide feedback when dropped content needs time to transfer ... display a progress indicator ... display a placeholder at the drop location so people know where to find the content after it finishes transferring" [HIG] (P).

## 7. Drop feedback

- **HIG.** "Display an insertion point or highlight a containing view only when the destination can accept a dragged item", and show no cue or a "not allowed" image when it cannot. On a failed drop, show feedback. Keep dropped content selected, allow undo, and offer a menu command too [HIG] (P).
- **Audition.** "While you drag a clip, a white line appears in the Editor panel when snapping points meet" [AUA] (P).
- **Hindenburg, GarageBand, Final Cut Pro, Logic.** No source describes drop feedback. No Hindenburg source describes import progress or cancel.

## 8. Failure cases

- **Hindenburg.** "M4p (Protected) files can not be imported" [HJ p. 15] (P). A moved session gives "locate missing audio files" [HKB] (P).
- **GarageBand.** Supported formats exclude "protected AAC files" [GBI] (P).
- **Logic.** "Could not open source file" [ACT] (U).
- **Full disk.** No source for any app. No Hindenburg message for a corrupt file.

## Open questions for the plan

- Inference: a Finder drop onto a Hindenburg lane lands at the drop point on that lane. No source checks it. This is the most common gesture of run 13.
- Inference: a Hindenburg menu import goes to the selected track. [BZ] says "import the file onto the music track" but does not say how the track is chosen.
- Hindenburg behavior for several files in one drop, or a drop below the last track, is unknown.
- Inference: a clipboard import in Hindenburg does not auto-level until placed [TC15]. Not checked.
- The US Mode target (-20/-21 LUFS against -24 LUFS) needs one owner source.
- Probe idea (not run): open an MP3, M4A, and FLAC with AVAudioFile on macOS 14 and log the `processingFormat` and any `OSStatus`, to check FLAC support and the error code for a corrupt file.

## Sources

- [HJ] Hindenburg Journalist PRO 1.21 user guide, vendor PDF on a third-party host: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf (P)
- [HPS] Hindenburg PRO shortcuts: https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/ (P)
- [HFH] Hindenburg PRO feature highlights: https://hindenburg.com/academy/lessons/feature-highlights/ (P)
- [HKB] Hindenburg KB, missing audio files: https://hindenburg.uservoice.com/knowledgebase/articles/680065-missing-audio-files-or-no-sound (P)
- [TR10] https://transom.org/2010/hindenburg-review/ (S)
- [TC15] Transom key command sheet: https://transom.org/wp-content/uploads/2015/10/PT_Hindy_Commands_Mac.pdf (S)
- [TL21] Transom loudness guide: https://transom.org/2021/the-audio-producers-guide-to-loudness/ (S)
- [BZ] https://www.buzzsprout.com/blog/hindenburg-journalist-review-and-walkthrough (S)
- [WY] Teaching handout: https://www.willyurman.com/teaching/handouts/Hindenburg_Audio_Tips.pdf (S)
- [LAD] https://support.apple.com/guide/logicpro/add-and-delete-audio-files-lgcp1bb0ad7d/mac (P)
- [LDD] https://support.apple.com/guide/logicpro/create-tracks-using-drag-and-drop-lgcpd1e675e5/mac (P)
- [LCA] https://support.apple.com/guide/logicpro/import-compressed-audio-files-lgcp4f68cbe3/mac (P)
- [LMR] https://support.apple.com/guide/logicpro/move-regions-lgcpf7c0d489/mac (P)
- [LPA] https://support.apple.com/guide/logicpro/manage-project-assets-lgcpce0d70e7/mac (P)
- [LKC] https://support.apple.com/guide/logicpro/main-window-tracks-and-various-editors-lgcpe8314fe2/mac (P)
- [PP] Peachpit Logic book, search excerpt only (fetch failed): https://www.peachpit.com/articles/article.aspx?p=598654&seqNum=2 (S)
- [ACT] Apple Community user thread, Logic Pro X 10.0.5: https://discussions.apple.com/thread/5681759 (U)
- [GBI] https://support.apple.com/guide/garageband/import-audio-and-midi-files-gbndd01649ed/mac (P)
- [FDD] https://support.apple.com/guide/final-cut-pro/drag-clips-to-the-timeline-ver4e30143/mac (P)
- [FIM] https://support.apple.com/guide/final-cut-pro/import-from-your-mac-or-storage-device-ver418155a4/mac (P)
- [FBT] https://support.apple.com/guide/final-cut-pro/view-background-tasks-ver64e71609/mac (P)
- [AUI] Audition, create, open, or import files, archived copy: https://web.archive.org/web/2025/https://helpx.adobe.com/audition/using/creating-opening-files.html (P)
- [AUA] Audition, arrange multitrack clips, archived copy: https://web.archive.org/web/2025/https://helpx.adobe.com/audition/desktop/mixing-multitrack-sessions/arranging-editing-multitrack-clips.html (P)
- [HIG] https://developer.apple.com/design/human-interface-guidelines/drag-and-drop (P)
