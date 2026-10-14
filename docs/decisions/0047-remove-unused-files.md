# 0047. Remove unused clip files: the Trash, and the files that a backup or an undo entry uses

- Status: accepted
- Date: 2026-10-12
- Accepted: 2026-10-12, after plan gates 1 and 2 of run `2026-10-12-remove-unused-files`.
- Amends: 0043 (a clip of a backup keeps its file in `Clips/`), 0024 (Only a clip holds a top-level `Clips/` WAV: a clip of `session.xml`, or of a readable backup, or of the app clipboard. A pool entry with no clip does not hold it. A new holder raises the `session.xml` version or keeps its audio out of `Clips/`), 0021 (the WAV that an undo of a placement or a revert leaves in `Clips/` is a stray WAV that the prune can move, unless an undo or redo entry uses it), 0046 (`file_prune` on a package that the app has open gives the "open in Dirigible" error).
- Amended: 2026-10-14, run `2026-10-13-transcript-1` (see 0055). `Session.removeFile` also removes the transcript words of the file, and a transcript with no word left, so the prune and the strip of the undo entries remove them too. The scan also lists each file in `Transcripts/` that no holder names, with the same holders as a clip file.

## Context

F87 (R5) asks for a command that removes the clip files that the session does not use. `dirigible file remove` removes one pool entry, and the WAV stays in `Clips/`. An import that stopped, an undo of a placement (0021), and a revert to a backup (0043) leave WAV files in `Clips/` that the pool does not name. Logic and GarageBand delete unused files after a dialog. Logic keeps a file that any project alternative uses. REAPER lists the unused files and can only delete them. Hindenburg PRO has a "Delete unused files" option with no documented details (`docs/research/paste-across-packages.md` section 5, `recovery-tools.md`).

Four holders name clip files: the session (in memory and on the disk), the backups in `Backups/` (0043, up to 20 copies of an old `session.xml`), and, in the app, the undo and redo entries of `History` and the app clipboard. `checkMedia` checks each pool file, used or not, and a missing one shows a red banner.

## Decision

**D1. The Trash, never a delete.** The prune moves each file with `FileManager.trashItem`. A file that does not move (a volume with no Trash, a permission fault) stays in `Clips/`, and the report names it with the error. No code path deletes it, and no option asks for a delete. The text of the sheet and of the CLI says that the space comes back only when the user empties the Trash.

**D2. A clip of a backup keeps its file.** The scan reads each backup that `Backup.all` lists with the `session.xml` reader. A file that a clip of a backup uses is not in the list. The scan gives the count and the bytes of these kept files. A file that only the pool of a backup names, with no clip, is in the list. A backup of a newer version, or a backup whose read fails with an errno, stops the scan with an error that names it: the scan cannot know its clips, and the block stays until that backup goes. A damaged backup (malformed XML) keeps no file and the scan names it, because `readForRevert` refuses it too. The `session.xml` on the disk before the prune is a keeper too, because the prune save can make it a backup. When it does not read, the scan stops.

**D3. A clip of an undo or a redo entry keeps its file.** In the app, each entry of `History` is a keeper, as a backup is. So is the app clipboard when its origin is the same package, because a paste can still use its files. The CLI and the MCP tool cannot see the app clipboard, which lives after its window closes. The prune is not an undo entry: Undo cannot bring a file back from the Trash. `History.removeUnusedFiles(_:)` removes the pool entries of the moved files from the session and from each entry, with no new entry. So an undo never brings back a pool entry of a moved file. The CLI has no history. It cannot see the history of an app window, but the package lock refuses the CLI while a window has the package open (0014).

**Scan.** A candidate is a pool entry that no clip of the session uses, or a regular file at the top level of `Clips/` with the extension `wav` in any case, whose name does not start with `.`, and that no pool path names. A pool path whose folder, with its links resolved, is not `Clips/` or a folder in it is never a candidate. The session reader already refuses an absolute path and a `..` part. A candidate is kept when any of these name the same file: a pool entry that a clip of the session or of a keeper uses. Two names are the same file when the `lstat` or the `stat` identity (device and inode) is the same, so a symbolic link to a used file is kept, or when the names are the same after the removal of `./` parts, Unicode canonical mapping, and case folding. When the two tests disagree, the file is kept.

An unused pool entry whose file is not on the disk loses its entry and moves nothing; it is not a failure.

**Order.** `UnusedFiles.prune` holds the order: a sync form for the CLI and the MCP tool, and an async form for the save of `Studio`. The two forms call the same two steps. The prune removes the pool entries, writes `session.xml` with the durable write of 0003 (with the due backup of 0043), and only then moves the files. A crash between the two steps leaves stray WAVs that the next scan finds. When the write fails, no file moves.

**Confirmation.** The app shows the list first. At the confirmation, the prune scans again in its turn of the write chain, and it moves only the files that are in both lists. `Studio` refuses the scan and the prune with `.busy` during a take, a finalize, a placement, a level, and an import. The CLI refuses a pending take, as every edit.

**Commands.** File > Remove Unused Files… (the app, no key; Cancel is the default button), `dirigible file prune [--dry-run]`, and the MCP tool `file_prune` with `dry_run`. `--dry-run` writes nothing. `file prune` and `file_prune` run the same body and give the same lines. On a package that the app has open, `file_prune` gives the "open in Dirigible" error of 0046, as `backup_revert` does: the window holds the undo entries and the clipboard that keep files, and File > Remove Unused Files sees them.

**No version change.** The prune adds no data to `session.xml` (0024).

## Consequences

- A file of a retake that the user deleted stays in `Clips/` while a clip of one of the 20 backups or of an undo entry uses it. The kept count tells the user why.
- After a prune, a revert to a backup whose pool (not its clips) names a moved file shows the missing-media banner for that file. No audio is lost: no clip uses it.
- The space of a package goes down only after the user empties the Trash.
- A copy, a delete, a window close, and then `dirigible file prune` can move the files of the app clipboard. A later paste then refuses with `sourceMissing`; A drag from the Trash back into `Clips/` brings the files back. macOS gives Finder Put Back only to the first file that a process moves to the Trash (`trashItem` and `NSWorkspace.recycle` both, macOS 15). The guide entry of `file prune` says so.
- An undo step whose only change was a pool entry of a moved file becomes a step that changes nothing.

## Alternatives considered

- **D1: a delete** (Logic, GarageBand, REAPER). It frees the space at once, but the confirmation is the only guard, and No data loss forbids a way with no way back.
- **D1: the Trash, then a delete after a second confirmation on a volume with no Trash.** Two flows and two texts for a rare case. The user can move the file by hand.
- **D2: a backup pool keeps its files.** A pool entry stays in each later backup, so the prune removes almost nothing for 20 backups.
- **D2: ignore the backups.** A revert then gives clips with missing audio.
- **D2: delete the backups that use a moved file.** It removes the recovery path of 0043 to save space.
- **D3: the prune as an undo entry.** An undo brings back pool entries of files in the Trash, and the red missing-media banner shows.
- **Scan by the name only** (`removeTemporaryFiles` lowercases). A pool path in NFC and a disk name in NFD (HFS+, or a copied package) would list a used file.
