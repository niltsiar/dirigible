# Recovery of recordings and sessions in Hindenburg PRO

Date: 2026-09-26

This document records how Hindenburg recovers a session or a recording after a crash, a device unplug, a full disk, or a write error. It also records how a user brings audio files that are on disk, but not in the session, back into the session. It ends with short comparisons to REAPER, Logic Pro, and Adobe Audition. A claim that no primary source confirms has the mark "(unconfirmed)". A sentence that starts with "Inference:" is our reading of the sources. A sentence that starts with "The frames of [V-x] show" reports still frames of an official video. The videos have no captions. The frames are in a local run folder, not in git.

## 1. Crash or power loss during a recording

- PRO 2 build 2610 (4 April 2024) has this fix: "Ensured that session can be recovered if it crashes during recording". The same build has "Fixed crash when switching display during recording" [R2610]. The release note list shows the build 2610 entries with the short titles "Crash after Recording" and "Recover Recording after Crash" [HR].
- No source says what the user sees at the next launch after a crash during a recording: a dialog, an automatic reopen, or a session with a "recovered" name (unconfirmed).
- No source says how much audio before the crash stays in the recovered session (unconfirmed).
- The 1.21 manual says: "N.B Hindenburg Journalist has a Auto Save function. If the program should fail the last session will be recovered. Never loose more than a minutes work." [HM p. 86].
- Inference: in 1.x, the recovery is an automatic reopen of an autosaved session. The words "Never loose more than a minutes work" suggest an autosave interval of about one minute.
- A third-party test found that Hindenburg Journalist imports WAV files with a wrong header (files from a recorder that lost power) "with no complaints". "The files appeared in the Hindenburg session at the correct length and played fine" [TR]. This is a secondary source. Inference: a raw recording file that a crash left on disk can go back into a session with a normal import.

## 2. Device unplug during a recording

- Build 2610 has "Fixed reconnecting audio device while "Device Change" is open" [R2610]. Build 2614 has "Improved audio device handling" [R2614]. Build 2626 reduced "excessive device popups" [R2626]. Build 2630 fixed "Don't Ask Again" in the device popups [R2630]. Build 2574 fixed "Don't ask again" for playback devices [R2574].
- Inference: when a device changes, PRO 2 shows a "Device Change" popup. The popup has a "Don't ask again" option. The popup can stay open while the device comes back.
- No source says what happens to the recording on the other tracks when one input device goes away mid-take (unconfirmed).
- No source says if the track of the lost device continues to record when the device comes back (unconfirmed).
- The release notes of builds 2544 to 2752 do not mention a recording that continues or stops after a device loss [HR].

## 3. Full disk and write errors

- No Hindenburg source documents a full disk or a write error during a recording (unconfirmed). The release notes of PRO 2 have no entry for these cases [HR].
- One support article describes a disk fault. On external disks with exFAT and macOS Big Sur, "The first few seconds have been missing" from recordings in Hindenburg. The advice is to format the disk as APFS [KB-exfat].
- Inference: Hindenburg does not document a check of free space before a recording or a message when a write fails.

## 4. Where Hindenburg keeps recorded audio

- A session has two parts. "1. Session File (session name. nhsx)" holds "the information about the session". "2. File Folder (session name.Files)" "contains the audio" [KB-blank].
- The frames of [V-relink] show a folder "Relink Files" next to "Relink.nhsx", with the file "interview.wav" in it. `docs/research/session-formats.md` records `AudioPool Path="h-test Files"`, relative to the session file.
- "The session file and the session folder should always be moved together." "The best way of moving a session is to use "save as" from within Hindenburg" [KB-missing]. Save As "Make a copy of the session". "All associated files will be copied" [HM p. 86] [KB-dropbox].
- Preferences, Audio has "Temp Folder > Storage for temporary session files" [HM p. 75].
- The official video "How to retrieve lost files in Hindenburg Pro" (32 s, 2021) has the description: "Set up a "temp folder" in Hindenburg to retrieve any lost files." and "Hindenburg PRO: Preferences - Audio - Temp Folder". Its captions say: "Here is how to set up the location of your temporary file folder. This helps to locate missing audio files." [V-temp].
- The frames of [V-temp] show Preferences (Cmd-comma), the Audio tab, and a "Temp. Folder" field with a button with three dots. That button opens a folder chooser.
- Inference: Hindenburg writes some audio, for example the recordings of a session that is not saved yet, to the temp folder. A user looks there for a recording that the session lost. No source says which files go to the temp folder, or when Hindenburg moves them to the Files folder (unconfirmed).

## 5. Missing files, relink, and import by hand

- At open, when the audio is missing, "you will be prompted to point to the Files Folder again". "If you press cancel, then the session will open with blank regions with red outlines" [KB-blank].
- The frames of [V-relink] show the dialog "Missing Audio Files" with the text "Locate missing audio files. 1 files belonging to the session could not be located." It has three choices: "Locate Folder" ("Locate the folder containing the missing files."), "Locate Files" ("Locate individual files manually."), and Cancel. "Locate Folder" opens a folder chooser with the title "Locate "Relink Files"".
- Relink one region: "right-click on a region and choose permission - and from here you can point to the correct audio file" [KB-blank]. Inference: "permission" is a typo for "Properties". The frames of [V-relink] show the region context menu item "Properties...". The Region Properties window shows Name, File, Resolution, Length, Original, Date, and Originator, and a button with three dots next to File. That button opens a file chooser with the title "Relink interview.wav". After the relink, the region shows its waveform again.
- The frames of [V-relink] also show a "Hindenburg Warning": "Failed to open file: ... Code: 00000002".
- The PRO guide list has "Regions - Relink Audio" and "Import Session Into Session - .nhsx" [HG].
- Import by hand: File > Import (Cmd-T), the toolbar Import button, or right-click in the workspace > Import. A drag from Finder or copy and paste from Finder also imports a file [HM p. 14 to 15].
- No source says that an import of a file that is already in the Files folder reuses the file or makes a copy (unconfirmed).
- The PRO guide list has no function with the name Consolidate, Clean Up, Reveal in Finder, Recover, or Unused Files [HG]. Inference: Hindenburg has no tool that lists audio files in the Files folder that no region uses. Relink finds files for regions that exist. An import makes a new region from a file.
- A support article about iCloud says: "Open the File Folder associated with your session file. In the Folder, you will see all your audio files." [KB-icloud]. Inference: the user browses the Files folder in Finder. Hindenburg has no view of it.

## 6. Autosave and backups

- 1.x: see section 1. The 1.21 manual gives no location for the autosave file (unconfirmed).
- PRO 2 build 2606 (26 March 2024) added "Auto save during multi-part transcription" [R2606].
- A user request "Autosave" ("Save an open session automatically.") has the status "under review" since 2014. A comment from 11 February 2020 says: "Just lost 3 hours of work because I hit Ctrl N by accident" [UV-autosave]. A request from 19 March 2019 says that a crash during Save lost the work of a day. It has no official answer [UV-backup].
- Inference: PRO 2 has no documented general autosave with backup files. The only documented cases are the crash recovery of a recording (build 2610) and the autosave during transcription (build 2606).
- No source gives a location for backup or autosave files of PRO 2 (unconfirmed).

## 7. Other applications

- **REAPER.** The Project preferences can keep earlier saves as `.RPP-bak` files and "automatically save to a timestamped file at intervals". This protects "from the consequences of an unforeseen circumstance such as a power outage or a computer crash" [RP p. 57]. File > Clean current project directory lists "all the files present in the project directory but not belonging to the current project" in a Project Directory Cleanup window. The window can only delete them [RP p. 449]. The audio device preferences have "an option to Stop processing audio in the event of disk failure/disk full" [RP p. 432].
- **Logic Pro.** "Logic Pro autosaves your work so that you don't lose important changes if the app quits unexpectedly. Logic Pro shows a dialog when you reopen the project, asking if you want to use the autosaved version." [LP-save]. File > Project Management > Clean Up can "Delete Unreferenced Audio Files": "Audio files not referenced in any project alternative are deleted from the disk." A dialog lists the files first [LP-clean].
- **Adobe Audition.** Preferences > Auto Save has "Backup Multitrack Session Files Automatically" with a backup location (text from a search index; the page refused the fetch, unconfirmed) [AU].
- Inference: REAPER and Logic show the files that a project does not use, but only to delete them. No source found shows a tool in these applications that puts such a file back on the timeline at its recorded position.

## Consequences for Dirigible

- Hindenburg does not document a tool that finds unplaced recordings and puts them back. Its tools are the crash recovery of build 2610, relink of existing regions, and a manual import. A Dirigible tool that places an unplaced segment back on the timeline goes further than Hindenburg. No Hindenburg behaviour constrains its design.
- No source says where a Hindenburg import puts a file on the timeline (unconfirmed). Inference: it goes to the playhead or to the drop point, not to its recorded time. Dirigible stores the capture timing of each segment. Thus the placement tool can put a segment at its recorded time on its own track. Do not copy the import behaviour for this tool.
- Hindenburg keeps all audio in the `<name> Files` folder and relinks by folder or by file. Dirigible keeps its clips folder next to the session. The unplaced list can come from a scan of that folder against the session. This matches the user model of "the Files folder has all your audio".
- REAPER and Logic show unused files only to delete them. A Dirigible list of unplaced segments must not delete anything. Offer "place on timeline" and "reveal in Finder", not "delete", as the main actions.
- Hindenburg documents no behaviour for a full disk or a write error. A Dirigible track that starts a new segment file after one write error goes beyond the documented behaviour of Hindenburg. Mark the gap in the timeline and tell the user. No Hindenburg source shows such feedback.
- Hindenburg does not document what happens to the other tracks when one device goes away. Dirigible can keep the other tracks recording. The lost track then has a gap between two segments. The placement tool and the unplaced list must handle more than one segment for each track and take.
- The Hindenburg user sees a missing-file dialog at open with three clear choices (Locate Folder, Locate Files, Cancel). If Dirigible finds unplaced segments at open, a similar short dialog with a clear default ("Place all at their recorded time") fits the user model of Hindenburg users.

## Sources

- [HM] Hindenburg Journalist 1.21 user guide for macOS, pages 14, 15, 75, and 86 (text read with PDFKit on 2026-09-26). Same file as source 24 of `docs/research/document-window.md`: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HR] Hindenburg PRO release notes (the list): https://hindenburg.com/support/release-notes/hindenburg-series/
- [Rnnnn] build nnnn at `https://hindenburg.com/release-notes-hindenburg-pro_version-2/<page>/`: [R2574] pro-v2_02-build-2574, [R2606] pro-v2_02-build-2606, [R2610] pro-v2_02-build-2610, [R2614] pro-v2_02-build-2614, [R2626] pro-v2_03-build-2626, [R2630] pro-v2_03-build-2630. Example: https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_02-build-2610/
- [HG] Hindenburg Pro complete overview (list of the function guides): https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [KB-blank] Hindenburg support, Blank regions: https://hindenburg.uservoice.com/knowledgebase/articles/1882393-blank-regions
- [KB-missing] Hindenburg support, Missing audio files or no sound: https://hindenburg.uservoice.com/knowledgebase/articles/680065-missing-audio-files-or-no-sound
- [KB-icloud] Hindenburg support, Blank regions and no audio - Mac: https://hindenburg.uservoice.com/knowledgebase/articles/1835575-blank-regions-and-no-audio-mac
- [KB-dropbox] Hindenburg support, Can I share sessions on Dropbox?: https://hindenburg.uservoice.com/knowledgebase/articles/331599-can-i-share-sessions-on-dropbox
- [KB-exfat] Hindenburg support, Missing audio - recording on external disk: https://hindenburg.uservoice.com/knowledgebase/articles/1967379-missing-audio-recording-on-external-disk
- [UV-autosave] Hindenburg support forum, Autosave (source 28 of `docs/research/document-window.md`): https://hindenburg.uservoice.com/forums/224350-general/suggestions/5736450-autosave
- [UV-backup] Hindenburg support forum, Auto-save/Back-up Feature: https://hindenburg.uservoice.com/forums/224350-general/suggestions/37142674-auto-save-back-up-feature
- [V-temp] Hindenburg Systems, "How to retrieve lost files in Hindenburg Pro" (2021-02-26): https://www.youtube.com/watch?v=SxXAngdYUQk (page: https://hindenburg.com/data/youtube/videos/how-to-retrieve-lost-files-in-hindenburg-pro/)
- [V-relink] Hindenburg Systems, "Relink Audio": https://www.youtube.com/watch?v=XKA5xFf8Uso (page: https://hindenburg.com/data/youtube/videos/relink-audio/)
- [TR] Transom, "Lost and Found Files" (2013, third-party test): https://transom.org/2013/lost-and-found-files/
- [RP] Up and Running: A REAPER User Guide v 7.80, pages 57, 432, and 449: https://www.reaper.fm/userguide/ReaperUserGuide780.pdf
- [LP-save] Logic Pro User Guide for Mac, Save projects: https://support.apple.com/guide/logicpro/save-projects-lgcpce128e82/mac
- [LP-clean] Logic Pro User Guide for Mac, Clean up projects: https://support.apple.com/guide/logicpro/clean-up-projects-lgcpce0efc05/mac
- [AU] Adobe Audition User Guide, Save and export audio files: https://helpx.adobe.com/audition/using/saving-exporting-files1.html
