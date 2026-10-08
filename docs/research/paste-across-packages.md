# Paste of clips into another session: other editors and Apple clone facts

Date: 2026-10-08

It does not repeat `docs/research/edit-commands.md`, `clip-set-clipboard.md`, or `file-import.md`. [HM] is the Hindenburg 1.21 manual that they use. Page numbers are PDF pages.

Grades: **P** primary, **S** secondary or forum. No probe ran.

## 1. Paste into another project; clipboard after a close of the source

- **Hindenburg.** No PRO source says that two sessions can be open at the same time (not documented). A school handout (S, 2014, version 1.x) gives this procedure: select all, Cmd-C, "Skift til nuværende session: File>Recent sessions", click, Cmd-V [DK]. Inference: one session is open at a time, and the copy survives the switch. Field Recorder for iOS lists "Copy and paste audio between sessions" [HFR] (P, iOS app).
- **Logic Pro 12.3.** "You can also open several projects simultaneously, allowing you to copy or move data between them" [LOP] (P). The default closes the current project. The user must set "Keep current Project open" [LOP] (P). The clipboard after a close of the source: not documented.
- **REAPER 7.81.** Project tabs let the user "move or copy media items (audio and/or MIDI) from one project to another" [RG p. 54] (P).
- **Audition.** Not documented. A forum thread gives only workarounds [AC1] (S).

## 2. Copy of the audio file or a reference to the source

- **Hindenburg.** Save As: "Make a copy of the session … All associated files will be copied" [HM p. 86] (P). "the session file and the session folder should always be moved together". No source says if a paste copies the file into the session folder (not documented). No setting "copy files to session folder" was found.
- **Logic.** "Copy audio files into project" applies to imported files. "This setting is only needed when using the Add an audio file or Import an audio file command" [LAS] (P). "Files are copied into the project when the project is saved" [LPA] (P). No page names a paste (not documented). File > Project Management > Consolidate copies external assets "to the Media folder inside the project" [LCO] (P). A user (S, Logic 9) reports that copied regions "are still somehow married to that original one hour region" [LUG] (S). Inference: a pasted region refers to the source file until a Consolidate or a Save As with assets.
- **REAPER.** The preference "Copy imported media items to project media directory" applies to an import [RG p. 448] (P). Save offers "Copy all media into project directory" [RG p. 58] (P). Paste: not documented.

## 3. Different sample rate

- **Hindenburg.** Paste: not documented. Import converts (file-import.md section 5).
- **Logic.** "A mismatch in sample rates between an audio file and the project can result in the audio file playing back at a different pitch" [LSR] (P). The option "Convert audio file sample rate when importing" covers imports. A Finder drag always converts [LAS] (P). Paste: not documented.
- **Audition.** A user got "the sample rate of one or more clips does not match the sample rate of the session. These clips will not be inserted." A community expert says that Insert makes "a copy of the clip at the session's sample rate", with a save prompt at close [AC2] (S, 2022).
- **REAPER.** Not documented in the guide.

## 4. Source file missing or moved at paste time

- Not documented in all four apps.
- **Hindenburg.** A separated session gives "missing audio" and a relink [HKB] (P).
- **Logic.** Delete File(s) moves a file to the Trash when the project closes. "Be aware that other projects using the file may be affected" [LAD] (P).

## 5. Undo of the paste and clean-up of unused files

- Undo of a cross-project paste: not documented in all apps.
- **Hindenburg.** The release-notes index lists "Added 'Delete unused files' option" under build 2724 [HRN] (P). The build 2724 page does not list it [HR2724] (P). Its menu place is not documented.
- **Logic.** File > Project Management > Clean Up. "Delete Unused Audio Files: Audio files not used in any project alternative are removed from the Project Audio Browser and deleted from the disk." "Delete Unreferenced Audio Files" deletes files that no alternative references. [LCU] (P). A file deleted in the browser stays "in the project's Audio Files folder" [LAD] (P).
- **REAPER.** File > Clean current project directory lists "all the files present in the project directory but not belonging to the current project". [RG p. 451] (P).

## 6. Used part or whole file

- **Hindenburg, REAPER, Audition.** Not documented.
- **Logic.** The forum report says that the new region "contains all the media from the original one hour take" [LUG] (S). Optimize File(s) deletes the file parts that no region uses. It is destructive and "can't be undone" [LAD] (P). Convert > Audio Region to New Audio Files makes a file from a region [LMC] (P).

## Hindenburg Clipboard panel

- **Per session.** "Import Clipboards from other session … Imported clipboards will be embedded into your current clipboard", Cmd-T, "Choose a session icon to import from" [HM p. 58] (P). Inference: the Clipboard is stored in the session.
- **Global panels.** "The Favorite Clipboard follows all session" [HM p. 11]. "Favorites are accessible in all sessions" [HM p. 59] (P). "The Call recording clipboard is a Global clipboard. The Clipboard is not linked to the session" [HM p. 22] (P).
- Whether a clip from Favorites or an imported clipboard copies its file into the session folder: not documented.

## Apple clone facts

- `clonefile(2)`: the clone "shares its data blocks with the src file". Later writes are "copy-on-write". `dst` "must not exist" [CF] (P).
- Errors: "[EXDEV] src and dst are not on the same filesystem." "[ENOTSUP] The underlying filesystem does not support this call." [CF] (P).
- "Not all volumes support clonefile()". Test `VOL_CAP_INT_CLONE` in `ATTR_VOL_CAPABILITIES` with `getattrlist(2)` [CF] (P).
- A clone can later return ENOSPC on an overwrite, because it "might not allocate new storage" [CF] (P).
- The calls "are expected to be atomic" [CF] (P).
- `copyfile(3)` `COPYFILE_CLONE`: "a best try flag i.e. if cloning fails, fallback to copying the file" [CPF] (P).
- `COPYFILE_CLONE_FORCE`: "if cloning fails, an error is returned". The error list has "[ENOTSUP] COPYFILE_CLONE_FORCE was specified and file cloning is not supported" [CPF] (P). The errno for a cross-volume `CLONE_FORCE` is not documented.
- Both flags imply `COPYFILE_EXCL`. A successful clone invokes no progress callback. `COPYFILE_STATE_WAS_CLONED` tells if a clone occurred [CPF] (P).
- `FileManager.copyItem(at:to:)` "automatically create[s] a clone for Apple File System volumes". The sample says it "makes a copy immediately for other file systems". Clones are "on the same volume" [APFS] (P).

## Implications for Dirigible

- Inference: no reference app documents a paste that copies the file into the target. Logic and Hindenburg rely on Save As or Consolidate. A Dirigible package must stay self-contained (No data loss), so a paste must copy or clone the file into the target package.
- Inference: use `copyfile` with `COPYFILE_CLONE`. It clones on one APFS volume and copies across volumes or on HFS+. Read `COPYFILE_STATE_WAS_CLONED` to log which one occurred.
- Inference: a copy of the whole file is the simplest choice. Logic copies whole files and trims later with Optimize.
- Inference: Logic plays a wrong pitch on a rate mismatch. Dirigible must convert or refuse, never play at the wrong speed.
- Inference: a missing source file must stop the paste with an error and change nothing in the target.
- Inference: an undone paste leaves an orphan file. Logic, REAPER, and Hindenburg handle this with a separate clean-up command, not with undo.
- Probe P1 of run `2026-10-08-paste-across-packages` answered it: `COPYFILE_CLONE_FORCE` gives ENOTSUP to an HFS+ volume, and `COPYFILE_CLONE` copies there with a progress callback each 1 MB. A callback that continues at `COPYFILE_ERR` retries a full disk with no end. Decision 0042 follows.

## Sources

- [HM] Hindenburg Journalist 1.21 user guide for macOS, PDF pages 11, 22, 58, 59, 86: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HKB] Hindenburg KB, missing audio files: https://hindenburg.uservoice.com/knowledgebase/articles/680065-missing-audio-files-or-no-sound
- [HFR] Hindenburg Field Recorder, App Store: https://apps.apple.com/us/app/hindenburg-field-recorder/id346169165
- [HRN] Hindenburg PRO release notes index: https://hindenburg.com/support/release-notes/hindenburg-series/
- [HR2724] https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_05-build-2724/
- [DK] DMJX school handout, Hindenburg on Mac, 2014 (S): https://faq.dmjx.dk/wp-content/uploads/2018/02/Hindenburg_manual_Mac_baerbar.pdf
- [LOP] Logic Pro 12.3, Open projects: https://support.apple.com/guide/logicpro/open-projects-lgcpce1280f1/mac
- [LPA] Manage project assets: https://support.apple.com/guide/logicpro/manage-project-assets-lgcpce0d70e7/mac
- [LAS] Assets project settings: https://support.apple.com/guide/logicpro/assets-project-settings-lgcp58b54e81/mac
- [LCO] Consolidate assets in a project: https://support.apple.com/guide/logicpro/consolidate-assets-in-a-project-lgcpce09b9d8/mac
- [LCU] Clean up projects: https://support.apple.com/guide/logicpro/clean-up-projects-lgcpce0efc05/mac
- [LSR] Set the project sample rate: https://support.apple.com/guide/logicpro/set-the-project-sample-rate-lgcpce0958b8/mac
- [LAD] Add and delete audio files: https://support.apple.com/guide/logicpro/add-delete-audio-files-project-browser-lgcp1bb0ad7d/mac
- [LMC] Move, copy, and convert audio files: https://support.apple.com/guide/logicpro/move-copy-and-convert-audio-files-lgcp757ec334/mac
- [LUG] Logic Users Group, Logic 9 (S): https://logic-users-group.com/threads/copy-regions-to-another-project-set-handles.6903/
- [RG] Up and Running: A REAPER User Guide v7.81, PDF pages 54, 58, 448, 451: https://www.reaper.fm/userguide/ReaperUserGuide781c.pdf
- [AC1] Adobe Community (S): https://community.adobe.com/questions-544/paste-clips-at-their-correct-time-positions-from-former-project-164943
- [AC2] Adobe Community, 2022-11-22 (S): https://community.adobe.com/questions-544/sample-rate-does-not-match-sample-rate-of-session-162424
- [CF] `clonefile(2)` man page, macOS 15 (Darwin 24.6), local `man 2 clonefile`
- [CPF] `copyfile(3)` man page, macOS 15 (Darwin 24.6), local `man 3 copyfile`
- [APFS] About Apple File System: https://developer.apple.com/documentation/foundation/about-apple-file-system
