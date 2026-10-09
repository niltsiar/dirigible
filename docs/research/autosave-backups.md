# Autosave, session backups, and revert: other editors and macOS Versions

Date: 2026-10-09

Run `2026-10-09-autosave-backups` (F62, decision 0043). Scope: Hindenburg PRO 2, Logic Pro, GarageBand, Final Cut Pro, macOS Versions, the HIG File menu, and REAPER and Pro Tools.
This file confirms, corrects, and adds to the F62 lines in `docs/research/logic-garageband-update.md` and `docs/research/podcast-features.md`.
A claim with no primary source has the mark "(unconfirmed)". A conclusion of the research starts with "Inference:".

Inference: the guides are Logic Pro 12.3, Final Cut Pro 12.4, and GarageBand 10.4.14. In each page, this version occurs one more time than the other versions in the version selector. The REAPER guide is 7.81: the file name is `ReaperUserGuide781c.pdf`.

## 1. Hindenburg PRO 2

- No source found for an autosave, a session backup, or a revert command in Hindenburg PRO 2.
- Places searched:
  - The PRO 2 shortcut reference [HSC]. Its File items are Save ("Save the session"), Save As, Recent Session, and Properties / Defaults. It has no Revert and no backup item. It lists "Tools / Options / Audio / Temp Folder" with no description.
  - The Uservoice knowledge base article list [HKB]. No article is about save, backup, recovery, or a crash.
  - All 52 PRO 2 release notes, from build 2540 to build 2752 (4 September 2026) [HRN]. The words "backup", "autosave", and "revert" do not occur in them.
  - A web search for a PRO user guide PDF. No PDF was found.
- Release notes that touch the topic:
  - Build 2606 (26 March 2024): "Auto save during multi-part transcription" [HRN2606]. Inference: this saves transcription work, not a session backup.
  - Build 2610 (4 April 2024): "Ensured that session can be recovered if it crashes during recording" [HRN2610].
- User requests:
  - "Autosave" (6 April 2014, 28 votes). Its status is "under review" since 21 April 2014, with no later status change [HA]. A 2014 comment asks for autosave "as part of a versioning system, so that it is possible to revert back".
  - "Auto-save/Back-up Feature" (19 March 2019, 10 votes, no status) [HB2].
- A 2011 reply from Hindenburg Systems to a Journalist Pro review says that auto-recovery backs up every minute, also for an unsaved project, and does not back up during a recording (unconfirmed). The page returned 403 and only a search summary was available [RAP].
- The Hindenburg Journalist 1.21 manual: "Hindenburg Journalist has a Auto Save function. If the program should fail the last session will be recovered" [HJ] p. 86 (also in `docs/research/document-window.md`, source 24).
- Inference: Hindenburg recovers the last session after a crash, and gives no user-visible backup list and no revert command. Dirigible cannot copy a Hindenburg pattern for F62.

## 2. Logic Pro 12.3

Confirmed from the guide [LA] [LSV] [LPH] and the guide PDF [LPDF]:

- **Trigger.** "Each time you save a project using the File > Save menu item (or pressing Command-S), a version of the current project alternative is saved (up to ten backups per alternative)" [LA]. The Auto Backup menu sets "the maximum number of the most recent project backups that are saved with your project (whenever you used the Save command)" [LPH]. Inference: an autosave does not make a backup.
- **Menu text and order.** The guide spells the menu "File > Revert to" (lower-case "to"). "Backups for the current alternative are listed in descending order from newest to oldest" [LA]. To revert to the last save, "choose the last saved version (at the top of the list)" [LSV].
- **Confirmation.** "In the Revert to Backup dialog, click OK" [LA].
- **Place.** File > Project Management > Clean Up has "Delete Backups: Backups for all project alternatives are deleted from the project" [LPDF]. So the backups are inside the project.
- **Rename.** When you rename an audio file, "Any backup files on the same disk drive are also renamed" [LPDF].
- **Autosave.** "Logic Pro autosaves your work so that you don't lose important changes if the app quits unexpectedly. Logic Pro shows a dialog when you reopen the project, asking if you want to use the autosaved version. If you choose not to, Logic Pro opens the last manually saved version of the project" [LSV].
- **Undo.** "Save undo history with project" keeps all undo steps after a reopen [LPH]. The undo limit is "up to 200" steps [LPDF].

No source found in the guide pages or the full guide PDF for these items:

- The autosave interval.
- The folder names inside the package. Forum posts give `Alternatives/000/Project File Backups/` for backups and `Alternatives/000/Autosave` for the autosave (unconfirmed) [GS].
- What a revert does to audio files, and if a revert is undoable.

## 3. GarageBand 10.4.14

- The guide page "Create and save projects" has File > Save and File > Save As only [GB].
- The guide table of contents has no topic with "autosave", "revert", or "backup" (a text search of the guide index page) [GBTOC].
- No source found for a GarageBand autosave or a File > Revert To submenu. An Apple Community answer says that GarageBand does not support versions (unconfirmed).

## 4. Final Cut Pro 12.4

Confirmed from the guide [FCPR] [FCPS] [FCPPDF]:

- "Final Cut Pro automatically backs up the library at regular intervals. Backups include the database portion of libraries only, not the media files. Backups are saved with the time and date in the filename" [FCPR].
- **Correction.** The default folder is "the Final Cut Pro Backups folder in the Movies folder" [FCPR], not "Final Cut Backups".
- **Retention.** "Final Cut Pro automatically deletes library backups that are more than several days old" [FCPR]. No count is given.
- **Setting.** Library Properties > Modify Settings has a Backups pop-up menu. It sets the folder, or "Do Not Save" to turn backups off [FCPS].
- **Restore.** File > Open Library > From Backup. The "Restore from" pop-up menu lists backups by "a specific time and date". "Other" opens a file browser. "The backup is added as a library in the Libraries sidebar" [FCPR]. Inference: a restore does not replace the current library.
- The backups "are standard Final Cut Pro library files, so you can also open them by double-clicking them in the Finder" [FCPR].
- **Interval.** The guide says "regular intervals" only. The 15-minute interval comes from third-party articles (unconfirmed) [LJ].
- No source found for the sort order of the "Restore from" list.

## 5. macOS Versions and NSFileVersion

Confirmed from the developer documentation:

- `NSFileVersion` is "A snapshot of a file at a specific point in time". "Your application can also create versions explicitly at times that your application designates as appropriate" [NSFV]. It is available on macOS 10.7 and later.
- iCloud: "For files in the cloud, there is usually only one version of the file at any given time." Two computers that save at the same time make extra versions. The system chooses one as current and tags the others "as being in conflict" [NSFV].
- `addOfItem(at:withContentsOf:options:)` "Creates a version of the file at the specified location". "You should always add file versions as part of a coordinated write operation to a file", that is, in an `NSFileCoordinator` write block [NSFVA]. The page does not require an `NSDocument`.
- `isDiscardable`: "Marking a file version as discardable gives the system the flexibility to reclaim the space ... Do not, however, depend on the file being discarded" [NSFVD].
- `otherVersionsOfItem(at:)` returns all versions except the current one. `localizedName` is the name to show to the user [NSFVO] [NSFVN]. `replaceItem(at:options:)` writes a version back over the file [NSFVR].
- `NSDocument.autosavesInPlace` is `false` by default. `preservesVersions` defaults to `autosavesInPlace`. "Returning false from this method disables version browsing and revertToSaved(_:)". "Returning true from this method when autosavesInPlace returns false will result in undefined behavior" [NSDA] [NSDP].
- The archived Document-Based App Programming Guide: if the user restores a version, "the current document contents are preserved on disk, if necessary, and the file's contents are replaced with those of the selected version" [DBG].
- The Mac User Guide: "A version is saved automatically every hour, or more frequently when you're making many changes. A version is also saved when you open, save, duplicate, lock, rename, or revert a document." The user chooses File > Revert To > Browse All Versions, or File > Revert To > Last Opened, Last Saved, or Previous Save [MH].

No Apple source found for these items:

- If `addOfItem` works on a file inside a package folder, or only on the whole document. Inference: the API takes any file URL and the page states no limit. A probe must check it (open question below).
- The version store location. Third-party sources give a hidden `.DocumentRevisions-V100` folder at the root of each APFS or HFS+ volume, run by the root daemon `revisiond` (unconfirmed) [EL].
- Which volumes support versions (network, FAT, exFAT) (unconfirmed).
- Time Machine: a third-party source says that Time Machine does not back up `.DocumentRevisions-V100` from Big Sur on (unconfirmed) [EL].
- Inference: versions stay on the volume of the session and do not move with the package. A copy of the package to another disk, a zip, or an upload loses them.

The probes of section 9 answer the question: `addOfItem` works on a file inside a package, and a copy of the package has no versions.

## 6. HIG File menu

- The HIG lists "Revert To" only: "When people turn on autosaving, displays a submenu that lists recent document versions and an option to display the version browser. After people choose a version to restore, it replaces the current document" [HIG].
- The HIG File menu order: New Item, Open, Open Recent, Close, Close Tab, Close File, Save, Save All, Duplicate, Rename…, Move To…, Export As…, Revert To, Page Setup…, Print… [HIG]. "Revert To" goes after Export As… and before Page Setup….
- The HIG text has no "Revert to Saved" item and no "Browse All Versions…" item. "Browse All Versions" is the item name in the Mac User Guide [MH].
- The HIG Save row says: "Automatically save changes periodically as people work so they don't need to keep choosing File > Save" [HIG].
- Spelling: the HIG and the Mac User Guide write "Revert To". The Logic guide writes "Revert to".

## 7. Other apps

- **REAPER 7.81** [RUG]: "By default, when you first install REAPER these options are all set to off."
  - Save backups: "Preserve previous saved version as rpp-bak file", "all previously saved versions ... in one large rpp-bak file", or "as timestamped rpp-bak file". "Save timestamped backups to Backups project subdirectory". "Limit [number of] backups to most recent n copies or unique days".
  - Timer backups: "Auto-save to timestamped file in project directory", "Save auto-saved project backups to Auto-Saves project subdirectory", "Limit auto-saved backups to most recent nn copies or unique days". "Set auto save interval to nn minutes when not recording, or when stopped, or any time".
  - Restore: "opening the RPP-BAK file will cause a Choose version from backup file dialog to be displayed".
- **Pro Tools**: Preferences > Operation > Auto Backup keeps copies in a "Session File Backups" subfolder of the session folder, with names that end in `.bak00.ptx`, with a number that increases. The default is 10 copies every 5 minutes (unconfirmed) [PE].
  - The Pro Tools Reference Guide 2024.10 (the UI panel of the run) confirms "Enable Session File Auto Backup", a "Backup Every" interval, and "Keep n Most Recent Session Backups" [PT] p. 135. The user opens a backup copy from the Session File Backups folder. File > Revert to Saved goes to the last save only [PT].
- Audition, Descript, Ferrite: not searched (the brief said "only when it is quick").

## 8. Spanish menu names

- AppKit names the File item "Revert To" as "Volver a" (`MenuCommands.loctable` of AppKit on macOS 15, read with `plutil -convert json`) [AK]. The Spanish Mac User Guide writes "Archivo > Volver a" [MH-ES].
- The Spanish Logic guide writes "Archivo > Restaurar a" and "Revertir a copia de seguridad" [LA-ES].

## 9. Probes of the run (macOS 15.7.9, APFS)

- P1 to P3. `NSFileVersion.addOfItem` works in a process with no `NSDocument`, on `session.xml` inside a package and on the package. `otherVersionsOfItem` lists 1 version, and `replaceItem` restores it. In the `scripts/probe.sh` sandbox, `addOfItem` gives `EPERM`, because the store is `/System/Volumes/Data/.DocumentRevisions-V100`.
- P4. A version of `session.xml` stays listed after the Dirigible save (`rename(2)` of a temporary file) and after `replaceItemAt`.
- P5. A copy of the package (`FileManager.copyItem`, as a Finder duplicate) has 0 versions of its `session.xml`. The versions stay with the old path.
- The probes are in the run folder (`probe/versions.swift`, `rename.swift`, `copy.swift`). The run folder is not in git.

## Facts that change a Dirigible design choice

- **Trigger.** Logic makes a backup on each explicit Save, never on autosave. Final Cut Pro and REAPER use a timer. Dirigible has no Save, so a backup on each edit fills a cap of ten in seconds. Decision 0043 chose a 10-minute rule on file times and a backup at the close of a window.
- **Recording.** REAPER can limit the timer to "when not recording". Hindenburg (2011, unconfirmed) does not back up during a recording. Inference: skip a timed backup during a take.
- **Place.** Logic and REAPER keep backups inside the project (a Clean Up command deletes them). Final Cut Pro keeps them outside, in `~/Movies/Final Cut Pro Backups`. macOS Versions keeps them in a per-volume store that does not move with the package (unconfirmed).
- **Count.** Logic: a count setting, ten per alternative. Final Cut Pro: deletes by age ("several days"). REAPER: "n copies or unique days".
- **Restore UI.** Logic: File > Revert to, newest first, then a confirmation dialog. Final Cut Pro: opens a backup as a new library and keeps the current one. macOS: File > Revert To with Last Opened, Last Saved, Previous Save, and Browse All Versions.
- **Versions.** `NSFileVersion` needs a coordinated write, may discard versions, and has no Apple statement for a file inside a package. The Revert To menu and the version browser come from `NSDocument`, which Dirigible does not use. Inference: plain backup files that Dirigible owns are simpler and easier to test than macOS Versions.

## Sources

Primary sources (read for this file):

- [LA] Logic Pro, Use project alternatives and backups: https://support.apple.com/guide/logicpro/use-project-alternatives-and-backups-lgcpa158ef77/mac
- [LSV] Logic Pro, Save projects: https://support.apple.com/guide/logicpro/save-projects-lgcpce128e82/mac
- [LPH] Logic Pro, Project Handling settings: https://support.apple.com/guide/logicpro/project-handling-settings-lgcp43defb63/mac
- [LPDF] Logic Pro User Guide PDF: https://help.apple.com/pdf/logicpromac/en_US/logic-pro-mac-user-guide.pdf
- [GB] GarageBand, Create and save projects: https://support.apple.com/guide/garageband/create-save-and-delete-projects-gbndd0893c9b/mac
- [GBTOC] GarageBand User Guide index: https://support.apple.com/guide/garageband/welcome/mac
- [FCPR] Final Cut Pro, Restore a library: https://support.apple.com/guide/final-cut-pro/ver85d95b8a9/mac
- [FCPS] Final Cut Pro, Set storage locations: https://support.apple.com/guide/final-cut-pro/set-storage-locations-ver7db6ffe77/mac
- [FCPPDF] Final Cut Pro User Guide PDF: https://help.apple.com/pdf/final-cut-pro/en_US/final-cut-pro-user-guide.pdf
- [NSFV] NSFileVersion: https://developer.apple.com/documentation/foundation/nsfileversion
- [NSFVA] addOfItem(at:withContentsOf:options:): https://developer.apple.com/documentation/foundation/nsfileversion/addofitem(at:withcontentsof:options:)
- [NSFVD] isDiscardable: https://developer.apple.com/documentation/foundation/nsfileversion/isdiscardable
- [NSFVO] otherVersionsOfItem(at:): https://developer.apple.com/documentation/foundation/nsfileversion/otherversionsofitem(at:)
- [NSFVN] localizedName: https://developer.apple.com/documentation/foundation/nsfileversion/localizedname
- [NSFVR] replaceItem(at:options:): https://developer.apple.com/documentation/foundation/nsfileversion/replaceitem(at:options:)
- [NSDA] NSDocument.autosavesInPlace: https://developer.apple.com/documentation/appkit/nsdocument/autosavesinplace
- [NSDP] NSDocument.preservesVersions: https://developer.apple.com/documentation/appkit/nsdocument/preservesversions
- [DBG] Document-Based App Programming Guide for Mac, Core App Behaviors (archive): https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocBasedAppProgrammingGuideForOSX/StandardBehaviors/StandardBehaviors.html
- [MH] Mac User Guide, View and restore past versions of documents: https://support.apple.com/guide/mac-help/view-and-restore-past-versions-of-documents-mh40710/mac
- [HIG] Human Interface Guidelines, The menu bar: https://developer.apple.com/design/human-interface-guidelines/the-menu-bar
- [RUG] REAPER User Guide 7.81 PDF: https://www.reaper.fm/userguide/ReaperUserGuide781c.pdf
- [HA] Hindenburg Uservoice, Autosave: https://hindenburg.uservoice.com/forums/224350-general/suggestions/5736450-autosave
- [HB2] Hindenburg Uservoice, Auto-save/Back-up Feature: https://hindenburg.uservoice.com/forums/224350-general/suggestions/37142674-auto-save-back-up-feature
- [HKB] Hindenburg Uservoice knowledge base, all articles: https://hindenburg.uservoice.com/knowledgebase/articles/all
- [HSC] Hindenburg PRO 2 shortcuts: https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [HRN] Hindenburg release notes index: https://hindenburg.com/support/release-notes/hindenburg-series/
- [HRN2606] Hindenburg PRO 2.02 build 2606: https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_02-build-2606/
- [HRN2610] Hindenburg PRO 2.02 build 2610: https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_02-build-2610/
- [HJ] Hindenburg Journalist 1.21 user guide (Hindenburg Systems), hosted by willyurman.com: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [PT] Avid, Pro Tools Reference Guide 2024.10: https://resources.avid.com/SupportFiles/PT/Pro_Tools_Reference_Guide_2024.10.pdf
- [AK] AppKit localized menu texts on macOS 15: `/System/Library/Frameworks/AppKit.framework/Resources/MenuCommands.loctable`
- [MH-ES] Manual de uso del Mac, Visualizar y restaurar versiones anteriores de documentos: https://support.apple.com/es-es/guide/mac-help/mh40710/mac
- [LA-ES] Manual de uso de Logic Pro, the project alternatives and backups page in Spanish: https://support.apple.com/es-es/guide/logicpro/lgcpa158ef77/mac

Secondary sources (each claim from them is marked unconfirmed):

- [RAP] RAP magazine, Journalist Pro review comments (page returned 403): https://rapmag.com/a/11/oct11/journalist-pro-review-corrections-comments
- [GS] Gearspace, Logic not saving backups: https://gearspace.com/threads/logic-not-saving-back-ups.1114303/
- [LJ] Larry Jordan, FCP X 10.1 Backup and Restore: https://larryjordan.com/articles/fcp-x-10-1-backup-and-restore/
- [EL] Eclectic Light, Managing macOS versioning and the .DocumentRevisions-V100 folder: https://eclecticlight.co/2025/09/08/managing-macos-versioning-and-the-documentrevisions-v100-folder/
- [PE] Production Expert, Pro Tools backup basics: https://www.production-expert.com/home-page/2018/5/4/getting-to-grips-with-pro-tools-part-8-backup-basics
