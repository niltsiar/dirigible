# Clipboard bins and Favorites in Hindenburg and other editors

Date: 2026-10-28

This file gives the reference behavior for F22 (a clipboard with named groups of clips in a session) and F23 (Favorites, a clipboard that all sessions share). It does not repeat `docs/research/clip-set-clipboard.md` (Paste position and collisions), `docs/research/hindenburg-edit-tools.md` (Replace, Paste in Selection), `docs/research/podcast-features.md` rows F22 and F23, or the Hindenburg `<Clipboard><Group/>` sample of `docs/research/session-formats.md`.

Grades: **P** is a primary vendor page or manual. **S** is a search summary or a secondary page. **U** is a user post. "Unconfirmed" means that no source answers. A sentence that starts with "Inference:" is our reading.

Method: the Hindenburg Journalist 1.21 guide [HM] was read as text with PDFKit (JXA, macOS 15.7) on 2026-10-28. The other pages were read with a web fetch on 2026-10-28.

## 1. The Clipboard panel

- **Open and key.** "Open clipboard > View / Clipboard", Option-Command-C [HM p. 11, p. 98] (P, 1.21). PRO 2 keeps View > Clipboard on Alt-Ctrl-C (Windows keys) [HK2] (P). Esc exits the clipboard, and `*` on the number pad jumps to it [HM p. 98] (P).
- **Purpose.** "Quickly organize the audio content", "Keep an overview of all material", "Import additional audio", "Assemble the radio package" [HM p. 11] (P).
- **Groups.** "It is possible to make as many Groups as wanted." Examples: Narration, Interview, Music, Background Sound [HM p. 55] (P). Rename a group: "double click on the group name" [HM p. 55] (P).
- **Add, delete, and order groups.** "File / Properties / Clipboard": `+` adds a group, `-` deletes it, Up and Down move it [HM p. 56] (P). PRO 2: "Add, remove, rename and rearrange groups" in the same Properties pane [HK2] (P).
- **Sub-groups.** PRO 2 lists "Groups and Sub-Groups": "Organise clipboard clips in groups and subgroups" [HK2] (P). A beta page also named sub-groups and the rename of clips, groups, and sub-groups [S-HB] (S; the page now returns 404).
- **Group numbers.** "Group numbers are found at the left corner of the group" [HM p. 57] (P). The keys use them (section 2 and 3).
- **Items.** Up and Down move between clips. Enter renames a clip. Delete deletes a clip. Option-Enter (Alt-Enter) shows the clip properties [HM p. 56, p. 98] [HK2] (P).
- **Clean-up.** "Delete Used": "Delete all the used clips in the group." (right-click). Clear All (Command-Delete): "Delete all clips in the clipboard" [HM p. 58] [HK2] (P).
- **Other.** "Copy Clipboard as Text": "Group clips titles exported as text". Export Selection (Shift-Ctrl-E): "Export the current entry in the clipboard" [HK2] (P).
- What one item shows (name, length, waveform): unconfirmed. No page describes the row layout.

## 2. Adding to the clipboard

- **Drag from the workspace.** "Move > ⌘ Drag", "Copy > ⌥ Drag" for clips, multiple regions, and region groups [HM p. 57] (P). PRO 2: "Drag soundbites from the workspace to the clipboard" and "Drag a region or multiple regions from the workspace to the clipboard" (Ctrl Drag) [HK2] (P). So a selection range and whole regions can go in.
- **Key with a group number.** "Move to clipboard > ⌥ ⌘ group number"; press it twice to rename the new clip [HM p. 57] (P). The 1.21 shortcut table calls the same key "Copy Clip to Clipboard" [HM p. 98] (P). PRO 2: "Alt + Ctrl 1,2,3,4...": "Move a region or multiple regions from the workspace to a clipboard group" [HK2] (P). Conflict: "Move" or "Copy". We did not resolve it.
- **During a recording.** "During a recording you can Copy a Selection to the clipboard" (Ctrl C, Ctrl V) [HK2] (P).
- **Import.** Command-T with the clipboard in focus, or a drag and drop: "import clips, multi clips and groups" [HM p. 56] (P). PRO 2: "Import audio, e.g music or interviews, directly to the clipboard" [HK2] (P).
- **Import from another session.** "Imported clipboards will be embedded into your current clipboard", Command-T, then choose a session [HM p. 58] (P).
- **Copy or reference.** No page says if a clip holds a copy of the audio or a reference to a range of the session audio (unconfirmed). Inference: a clip refers to the session audio, because the clipboard is part of the session file (section 4) and the audio of a session is in its "Files" folder [HMIG] (P). What happens to a clip when its source region is deleted from the workspace: unconfirmed. Inference: the clip stays, because "Move" removes the region from the workspace and the clip still plays.

## 3. Using a clip

- **Keys in the workspace.** "Paste clip > ⌥ group number"; Shift-Option and the group number copy a clip to the workspace [HM p. 57, p. 98] (P).
- **Keys in the clipboard.** Paste to the workspace with Command-Enter; insert with Shift-Enter [HM p. 57, p. 98] [HK2] (P). Paste puts the audio on top; Insert pushes later audio (`docs/research/clip-set-clipboard.md` section 1, `docs/research/ripple-edit.md`).
- **Drag.** "Paste > Drag clip to workspace"; "Copy > ⌥ (+ drag clip to workspace)" [HM p. 57] (P). Where a drop below the last track lands: unconfirmed.
- **Preview.** Space starts and stops "Pre Listen" of the clip under the cursor, inside the clipboard [HM p. 56, p. 98] (P).
- **Play during a call.** "It is possible to playback any clip from any clipboard or session, so the interviewee can hear the clip." [HM p. 12, p. 22] (P).
- Which clip a used clip is ("Delete Used"): the app marks a clip that the workspace uses. How it shows the mark: unconfirmed.

## 4. Storage of the clipboard

- The session file holds the clipboard: a Hindenburg `.nhsx` file has `<Clipboard><Group/>...</Clipboard>` after `<Tracks>` (`docs/research/session-formats.md`).
- Each session has its own clipboard; the import of section 2 copies another session's clipboard into this one [HM p. 58] (P).
- The Call Recordings clipboard is the exception: "The Call recording clipboard is a Global clipboard. The Clipboard is not linked to the session." [HM p. 22] (P).

## 5. Favorites

- **What.** "The Favorite clipboard is used to contain clips that can be used in all session. Jingles, Station ID´s etc." "Favorites are accessible in all sessions" [HM p. 59] (P). PRO 2: "A clipboard that will follow acroos all sessions." and "Store audio across all sessions" [HK2] (P).
- **Open.** View > Favorites, Option-Command-F [HM p. 11, p. 59] (P); Alt-Ctrl-F in PRO 2 [HK2] (P).
- **Add.** "Add Favorite > ⌥ ⌘ 0" [HM p. 59] (P); the table lists Option-Command-0 as "Copy Clip to Clipboard" [HM p. 98] (P). So Favorites act as group 0 of the number keys. Inference.
- **Paste.** Page 59 says "Paste to workspace > ⌘ 0". The table on page 98 says "Paste Clip to Workspace ⌥ 0" and "Copy Clip to Workspace ⇧⌥ 0" [HM] (P). Conflict in one guide. Inference: Option-0 is right, because it follows the group-number rule of section 3. Inside the panel, Command-Enter and Shift-Enter work as in the clipboard [HM p. 98] (P).
- **Rename.** Enter [HM p. 59] (P).
- **Count.** No limit is documented (unconfirmed).
- **On disk.** On a Mac, the file `Favorites.xml` ("Favorites clipboard") and the folder `Favorites` ("audio for Favorites") are in `~/Library/Application Support/Hindenburg` [HMIG] (P). So a favorite keeps its own copy of the audio, apart from any session.
- **Use in a session.** No page says if a paste of a favorite copies the audio into the session "Files" folder or refers to the `Favorites` folder (unconfirmed). Inference: a session package that refers to a file outside it breaks on another Mac; [HMIG] tells the user to copy the session file and its "Files" folder only.
- **Phone transfer.** Favorites move between Hindenburg Field Recorder (iPhone) and the desktop app over Wi-Fi: right-click a clip, Send to iPhone [HM p. 90, p. 91] (P).

## 6. Other editors

- **Final Cut Pro.** A Keyword Collection appears in the event in the Libraries sidebar when the user applies a keyword to a clip. It holds pointers to the tagged clips, not copies [FKC] (P). Scope: one library. Add: the keyword (Command-K). Use: select the collection and drag from the browser.
- **Logic Pro.** The Project Audio Browser lists the audio files and regions of one project. Delete there removes a file from the project, not from the disk [LPAB] (P). Groups by View > Create Group, and a deleted group returns its files to the list [S-LG] (S, search summary of the 10.1 guide; the fetched page did not cover groups). Scope: one project. Use: drag to the Tracks area.
- **Adobe Audition.** Its Favorites are recorded effect actions, not audio [S-AU] (S). No reference for audio bins.
- **Descript.** The Media Library is a drive-level store where editors "upload, organize, and reuse media across projects". "Removing a file from Media Library does not delete it from projects where it's already in use." [DML] (P). Scope: all projects of a drive. So a project keeps its media after the library item goes.

## For the plan

1. A bin set belongs to one session and is saved in its session file, as Hindenburg [HM p. 58] (`session-formats.md`).
2. Bins are named, renamed in place, added, deleted, and ordered; PRO 2 adds sub-groups [HM p. 55, p. 56] [HK2].
3. Into a bin: drag of a region or a selection (copy and move variants), Option-Command-number, import of a file [HM p. 56, p. 57].
4. Out of a bin: Paste (Command-Enter, Option-number), Insert (Shift-Enter), drag to a track, preview with Space [HM p. 56, p. 57, p. 98].
5. (Built: decision 0081.) Favorites are one list for the user, outside sessions, with their own audio copies in Application Support [HMIG]. Option-Command-0 adds; Option-0 (or Command-0, conflict) pastes [HM p. 59, p. 98].
6. A project keeps its media after a library item goes (Descript [DML]); a pointer collection holds no media (FCP [FKC]).
7. Unconfirmed: the copy-or-reference rule of a session clip, the paste of a favorite into a session folder, the row layout, the count limit, and a drop below the last track.

## Sources

- [HM] Hindenburg Journalist 1.21 user guide for OS X, pages 11, 12, 22, 37 to 39, 55 to 59, 90, 91, 98 (text read with PDFKit on 2026-10-28): https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HK2] Hindenburg PRO 2 shortcuts (Windows keys): https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/ and the guide page https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [HMIG] Hindenburg support, "Migrating all settings to a new computer": https://hindenburg.uservoice.com/knowledgebase/articles/1947400-migrating-all-settings-to-a-new-computer
- [S-HB] Search summary of the Hindenburg PRO 2 beta clipboard page (404 at the fetch): https://hindenburg.com/products/hindenburgpro2beta/beta_clipboard
- [FKC] Final Cut Pro, "Keyword Collection": https://support.apple.com/en-kg/guide/final-cut-pro/aside/ver91709529/mac
- [LPAB] Logic Pro 10.1, "Add and delete audio files" (Project Audio Browser): https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcp1bb0ad7d.html
- [S-LG] Search summary of the Logic Pro 10.1 Project Audio Browser group pages: https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcp3d41ebdd.html
- [S-AU] Search summary of Audition favorites: https://helpx.adobe.com/audition/using/finding-customizing-shortcuts.html and https://community.adobe.com/questions-544/favourites-window-missing-165114
- [DML] Descript, "Media Library: organize and reuse content across projects": https://help.descript.com/hc/en-us/articles/43448763539213
