# Raw recording files in Hindenburg PRO, REAPER, Audition, Logic Pro, and Audio Hijack

Date: 2026-11-03

Question: Does each app keep a second raw copy of a recording? Which format and folder does it record to? Does it delete or replace a recording after conversion or clean-up? Does it correct clock drift between two devices after the recording?

Tags: (P) primary source, (S) secondary source. "Not found" means no source says it. Dates of the pages: read 2026-11-03.

## Answers

Hindenburg PRO
1. Q1. Hindenburg records straight to disk: "Audio is always recorded directly to disk; the save process only stores the session file" [HV-RAP] (P, 2011 vendor reply, Journalist Pro, on a third-party page, read through Wayback).
2. Q1. For a session that is not saved, the auto-recover files move to the final place at first save: the app "will copy (or hardlink) the auto-recover recorded files to their final location" [HV-RAP] (P). The file is the same recording, not a converted second file.
3. Q2. A session is a `.nhsx` file plus a `<name> Files` folder that "contains the audio" [KB-blank] (P). Preferences > Audio has "Temp Folder > Storage for temporary session files" [HJ p. 76] (P, v1.21).
4. Q2. The format and name of a take on disk: not found. PRO converts imported audio to "uncompressed 64-bit floating point WAV" [HF] (P). A preference sets the default bit resolution, with 32-bit float as an option [KB-32] (P). Journalist 1.21 says "all sessions are 16 bit" [HJ p. 14] (P, old).
5. Q3. Sessions use 44.1 or 48 kHz [HJ p. 14] (P). Files with another rate "are automatically converted" to the session rate [TR10] (S, 2010). Whether the original file stays: not found.
6. Q3. Save As copies the session: "All associated files will be copied" [HJ p. 86] (P). A 2014 staff reply says Save As to another folder "will then only copy the files actually used", and the user can then delete the old session and folder [UV-bin] (P, UserVoice staff). So a Save As can drop unused takes, only if the user deletes the old folder.
7. Q3. PRO 2.05 (build 2724, January 2026) "Added 'Delete unused files' option" [HR] (P). The note gives no menu, scope, or text. Whether it deletes recorded takes: not found.
8. Q3. The PRO guide list has no Clean up or Consolidate function [HG] (P). "Clipboards - Delete Used" and "Clear All" act on clips only [HG] (P). A third-party Narrator book lists "Session Clean-up" in its contents [NB] (S, title only, Narrator).
9. Q4. Drift correction or two-device sync in Hindenburg: not found.
REAPER (user guide 7.80)
10. Q1. REAPER writes the recording to a media file. Preferences > Recording can "prompt to save/delete/rename files when recording is stopped" and "start recording to a new file after a specified number of megabytes" [RP s. 3.37, p. 76] (P). No second raw copy is documented.
11. Q2. Project Settings > Media sets a media sub-folder of the project folder; if blank, the project folder is used. The recording format is "typically WAV", with bit depth [RP p. 32] (P). A global "Default recording path" covers unsaved projects [RP p. 30] (P).
12. Q3. Save Project As > "Copy all media into project directory" can convert the format. "Move all media" moves the files, with an option to copy files from outside the old media path [RP s. 3.3, p. 58] (P).
13. Q3. Glue "creates a new media item: the original items are not damaged"; it renders to a new file [RP s. 7.33] (P).
14. Q3. File > Clean current project directory lists files in the project folder that the project does not use. The user deletes them for good or sends them to the Recycle Bin. The guide names "rejected tracks and overdubs" as targets [RP p. 449] (P). It can delete a recording.
15. Q4. The guide names only an aggregate device (Mac) for two devices [RP p. 22] (P). No post-recording drift correction: not found. Forum users say separate rigs need varispeed stretching [CF] (S).
Adobe Audition
16. Q1, Q2. In the Multitrack Editor, Audition "automatically saves each recorded clip directly to a WAV file" in the `[session name]_Recorded` folder inside the session folder, for example `Track 1_003.wav` [AA-rec] (P). No second raw copy is documented.
17. Q3. A punch-in record leaves "the original clip intact" [AA-rec] (P).
18. Q3. File > Export > Session with "Save Copies Of Associated Files" and "Convert Files" changes sample rate and bit depth. It writes copies; the guide does not say the old files go away [AA-save] (P).
19. Q3. File > Close Unused Media closes files; it does not delete them [AA-save] (P). A community answer says to export copies, then delete the old folder by hand [AC-forum] (S).
20. Q3. Import of a file with another sample rate: Audition "prompts you to resample them" [AA-open] (P). Whether the original stays: not found.
21. Q4. Drift correction between two devices in Audition: not found.
Logic Pro
22. Q1, Q2. The Recording settings give the file type (AIFF, WAVE (BWF), or CAF) and bit depth (16, 24, or 32-bit float). A change affects new files only [LP p. 1054] (P). The Audio Recording Path shows "Project" by default: new files go inside the project [LP p. 1082] (P).
23. Q2. The guide names the "project's Audio Files folder" only for Apple Loop copies [LP p. 514] (P). The folder name for recordings: not found.
24. Q1. No second raw copy is documented. Delete on a region keeps "the audio file", and Delete File(s) in the Project Audio Browser sends it to the Trash [LP p. 199] (P).
25. Q3. Copy/Convert File (sample rate, bit depth, format) makes a new file. "Change file reference in Project Audio" replaces the old file in the project; if off, both files show. Nothing is deleted [LP p. 280] (P). The Assets setting "Convert audio file sample rate when importing" is optional [LP p. 108] (P).
26. Q3. File > Project Management > Clean Up has "Delete Unused Audio Files" and "Delete Unreferenced Audio Files". Files "are deleted from the disk" after a list dialog that lets the user keep files [LP p. 106] (P). It can delete a recording that no region uses. Consolidate copies assets into the project Media folder [LP p. 108] (P).
27. Q4. With a different input device, Logic advises "a common Word Clock" [LP p. 1042] (P). Post-recording drift correction: not found.
Audio Hijack
28. Q1, Q2. The Recorder block saves audio to the file that the user sets. The default is MP3 in a `Music/Audio Hijack` sub-folder [AH-man] (P). Formats: MP3, AAC, Apple Lossless, FLAC, AIFF, WAV [AH-fmt] (P). The Recordings tab lists in-progress recordings as files on disk [AH-man] (P). A user may add two Recorder blocks to make two files [AH-man] (P).
29. Q3. The session rate is fixed at start. The app resamples sources live. A custom Recorder rate resamples again [AH-sr] (P). "Move to Trash" in the Recordings tab trashes a file; "Remove From List" keeps it [AH-man] (P). A clean-up command: not found.
30. Q4. Audio Hijack corrects drift while it captures. Release notes: "drift correction has been improved" (ACE 11.7, 2021-03-05) and "Clock synchronization and drift correction have been improved when device clocks experience discontinuities" (2022-10-19) [AH-rn] (P). It is not a post-recording step. The notes show no uncorrected copy.
Summary
31. No app records a raw file and then converts it to a second file. All five record into the final file. Hindenburg moves or hard-links its auto-recover recording at first save (item 2).
32. Only Audio Hijack corrects drift, and it does so live (item 30). No source shows a correction after the recording with the uncorrected file kept.
33. Only deletions that the user starts exist: REAPER Clean, Logic Clean Up, Hindenburg "Delete unused files". Two of them (REAPER, Logic) list files first.

## Open questions
- Inference: Dirigible has no reference for "record to a raw file, convert at stop, then delete the raw file". No source shows that sequence in any of the five apps.
- Hindenburg: the path and format of a take during recording, and whether the temp copy is deleted after a hard link or copy, are unknown.
- Hindenburg "Delete unused files": menu, scope, and effect on takes are unknown. Source to find: PRO 2.05 manual text.
- Hindenburg and Audition: is the original file kept after a sample-rate conversion on import?
- Inference: Logic records into the project `Audio Files` folder. The guide does not name it for recordings. Adobe pages gave HTTP 403, so the Audition text comes from 2025 Wayback copies.

## Sources
- [HV-RAP] Hindenburg Systems reply, Journalist Pro review: https://rapmag.com/a/11/oct11/journalist-pro-review-corrections-comments (read at https://web.archive.org/web/2020/https://rapmag.com/a/11/oct11/journalist-pro-review-corrections-comments)
- [KB-blank] https://hindenburg.uservoice.com/knowledgebase/articles/1882393-blank-regions
- [HJ] Hindenburg Journalist 1.21 guide: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HF] https://hindenburg.com/products/radio-podcast/features/
- [KB-32] https://hindenburg.uservoice.com/knowledgebase/articles/2004118-32-bit-support-in-hindenburg-pro-2
- [TR10] Transom, as cited in `docs/research/file-import.md`
- [UV-bin] https://hindenburg.uservoice.com/forums/224350-general/suggestions/6333235-empty-bin
- [HR] https://hindenburg.com/support/release-notes/hindenburg-series/
- [HG] https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [NB] https://bestanden.boeken.cafe/winkelbestanden/67/9789463562867_fragm.pdf
- [RP] REAPER User Guide 7.80: https://www.reaper.fm/userguide/ReaperUserGuide780.pdf
- [CF] https://forum.cockos.com/archive/index.php/t-280481.html
- [AA-rec], [AA-save], [AA-open] (Wayback 2025 copies): https://helpx.adobe.com/audition/using/recording-audio.html, https://helpx.adobe.com/audition/using/saving-exporting-files1.html, https://helpx.adobe.com/audition/using/creating-opening-files.html
- [AC-forum] https://community.adobe.com/t5/audition-discussions/how-do-i-easily-remove-unused-files-from-my-session-folders-i-need-to-clear-space/m-p/10997831
- [LP] Logic Pro User Guide for Mac (PDF): https://help.apple.com/pdf/logicpromac/en_US/logic-pro-mac-user-guide.pdf
- [AH-man] https://rogueamoeba.com/support/manuals/audiohijack?print=true
- [AH-fmt] https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-SupportedAudioFormats&product=Audio+Hijack
- [AH-sr] https://www.rogueamoeba.com/support/knowledgebase/?showArticle=SampleRateInfo-AH
- [AH-rn] https://rogueamoeba.com/audiohijack/releasenotes.php
