# 0043. Session backups: copies of session.xml in the package, no macOS Versions

- Status: accepted
- Date: 2026-10-09
- Accepted: 2026-10-09, after plan gates 1 and 2 of run `2026-10-09-autosave-backups`.
- Amends: 0003 (the layout has `Backups/`), 0014 (Versions is decided: it takes no part), 0024 (the formats table has the backup files), 0041 (the tools `backup_list` and `backup_revert`).

## Context

F62 (R10 part) asks for backups of `session.xml` and a revert that is one undo entry and keeps `<recording>` (0014). Dirigible saves after each edit and has no Save command, so the Logic rule "one backup per save" would fill its limit in seconds. Hindenburg recovers the last session after a crash and has no documented backup list or revert ([research](../research/autosave-backups.md)).

Probes P1 to P5 (2026-10-09, macOS 15.7.9, APFS): `NSFileVersion.addOfItem` works with no `NSDocument`, on a file in a package and on the package. A version stays after the `rename(2)` save. But a copy of the package has 0 versions (P5), and the store is per volume and per user, outside the package. 0014 P1 and P2: the `NSDocument` save path swaps the package, and a Versions restore of the package deletes newer takes.

## Decision

- **Place and name.** A backup is a byte copy of an old `session.xml` in `Backups/` of the package, named `session-<UTC time of its mtime, yyyyMMdd'T'HHmmss.SSS>Z.xml`. The name has no colon, so exFAT and SMB accept it. On a volume with a coarse mtime (HFS+ 1 s, exFAT 10 ms), two states can have one mtime: when a file has the name, the name gets 1 ms more until it is free, so no copy replaces a backup. The `version` attribute of the copy is its version marker. A name that does not parse is not a backup.
- **Due save.** Before a lock holder (the app, the CLI, the MCP server) replaces `session.xml`, it copies the old file when a backup is due: the mtime of that file minus the newest backup name that is not after it is 600 s or more, or no name is at or before it. Both values are file times, so one clock decides, also on a server with a skewed clock.
- **Close.** The close of a session window copies `session.xml` with no due check, so the state that the user hands to the CLI or an agent is in a backup.
- **Take start.** The take-start save keeps no backup (`BackupPolicy.none`): a due backup made the start 43 ms slower on the median. The finalize save of the take replaces the take-start file, which holds the state before the take and its `<recording>`. It keeps that file as a backup only when a backup is due.
- **Copy.** The copy uses the durable write of 0003 (temporary file, `F_FULLFSYNC`, rename, folder flush). No copy is written when one of the 19 newest backups (the ones that the next prune keeps) has the same bytes. When an older backup has them, it moves to the new name: the next prune keeps the state, and `Backups/` holds it once. This applies to the due save, the close, and the revert. A fault in the backup step never fails the save, and the window shows no note. A due save keeps no copy when the volume has less free space than the old `session.xml` and the new data of the save together, so the copy does not take the space that the save needs. The close keeps no copy with less than twice the size of `session.xml` free, because the next lock holder saves next.
- **Prune.** After a new copy of a due save or a close, the 20 newest backups whose names are not after the new name stay. A name after it (a clock fault) is not counted. A prune never deletes a name that does not parse (0024 P10), a backup of a newer version (0024 P4), or a backup that it cannot read.
- **Revert.** A revert reads a backup with the `session.xml` reader. Then it keeps a copy of the current file, with no due check and no prune. When that copy fails, the revert is refused: the CLI and MCP have no undo, so the copy is their only way back. The CLI and MCP text names the file that failed: `session.xml` for a read, `Backups` for a write. It replaces only the session value with the backup, with the current `<recording>` (`Session.reverted(to:)`, the undo rule of 0012). A backup that removes an armed track, or changes its route or layout, is refused.
- **App.** In the app, a revert is one undo entry through `Studio.edit`. It is refused during a take, a finalize, a placement, a level, and an import, and while the last save failed. No audio file is deleted: the clips of a later take show as unplaced segments (0021), and Undo brings them back. File > Revert To lists the backups newest first, with the date and time to the second, and to the millisecond when two items would have one title. With no backup, it shows one item No Backups that is off.
- **CLI and MCP.** `dirigible backup list` and `dirigible backup revert --name`; the MCP tools `backup_list` and `backup_revert`. A revert of a pending take is refused, as every edit (0012).
- **No Versions.** macOS Versions takes no part: its versions stay with the old path and volume (P5), and the `NSDocument` path that offers its UI writes the package (0014 P1).

## Consequences

- A package grows by up to 20 copies of `session.xml`.
- A due save or a close reads the old file and each backup of the same size for the byte check, and flushes twice more when it writes a copy.
- After a long pause, a CLI edit and the next one can each keep a backup: the first copies the old state, the second the state after the first edit.
- The state before a take is a backup only when the finalize save of the take is due.
- A backup fault is silent; the dates in File > Revert To show a stale list.
- A package delete deletes its backups. A build before F62 ignores `Backups/`.

## Alternatives considered

- **macOS Versions.** A copy of the package loses them (P5), tests cannot isolate the store, and the app would have two ways to do one task.
- **Backups outside the package** (Final Cut Pro). The key breaks at a copy, and the CLI on another Mac sees none.
- **A timer in Studio.** The CLI and MCP get no backups.
- **A copy of the new data after the replace.** It loses the state at open.
- **An undo journal on disk.** A new format; F62 asks only for backups.
