# 0024. File-format versioning: one integer version per file, and an older build never changes a newer file

- Status: accepted
- Date: 2026-09-27
- Accepted: 2026-09-27, after plan gates 1 and 2 of the format-versioning run. The gates made a newer anchor a per-segment fault, made a finalize keep a newer anchor and end the take, made an anchor read fault keep the take pending before any WAV, and made the next take number count every take file.
- Changed: 2026-09-27, by code gate 1 of the format-versioning run: P1 freezes the root element, the namespace, and the version attribute of `session.xml`; P8 asks for the lock before a write, not before a read.
- Amended: 2026-10-02. `session.xml` is version 2 when a track has an app route, else 1 (see 0029).
- Amends: 0003 (the sweep after the version check), 0012 (a newer sidecar), 0013 (the take number of a take with no segment), 0017 (a newer cache file), 0021 (a newer anchor and the anchor name in the take number).
- Amended: 2026-10-03, run 11a. `session.xml` is version 3 with a fade (see 0035).
- Amended: 2026-10-04, run 11c-1. `session.xml` is version 4 with a crossfade (see 0036).
- Amended: 2026-10-05, run `2026-10-05-mute-solo`. `session.xml` is version 5 with a muted or soloed track (see 0039).

## Context

The user asked on 2026-09-27: "on disk file must be versioned so we can track of different versions and support updates to the format in the future if needed".

Each file format of Dirigible has its own rule today, in its own decision:

- 0003: "The reader refuses a version higher than it knows, with a clear error. Each new element or attribute that carries user data raises the version. An old app that skips an unknown element and saves would delete that data."
- 0012: "The reader refuses the sidecar when the magic, the version, or the header is bad."
- 0017: "The reader refuses a file whose fields do not match the WAV, and a refusal is a miss."
- 0021 writes the take anchor with the sidecar framing and the magic `DRGANCH1`.
- releases.md: "The writer writes the lowest version that holds the data of the session [...] Rollback limit: an older app refuses a session that uses newer data ("unsupported version") and does not change the file."

The audit of the run (`.scratchpads/runs/2026-09-27-format-versioning/analysis.md`) found these gaps, with probes:

- The CLI edit path and the package open of the app delete a `.session.xml.<UUID>.tmp` file before the version check. So an older build changes a newer package.
- A sidecar with the magic `DRGSIDE2` reads as "missing or damaged". The older build ends the take without that segment and gives the wrong reason.
- An anchor with the magic `DRGANCH2` reads as "no anchor".
- The app shows one message for a damaged session file and a newer session file.

Release 2 run 6 writes `session.xml` version 2. The policy must be in place before that run.

## Decision

**Policy.**

| Rule | Text |
|---|---|
| P1. One version per file | Each file format that Dirigible owns has one integer version. The version is in the file: an XML attribute, or the last byte of the magic. The peak cache keeps its 8-byte magic `DIRPEAKS` and a UInt32 version field. The root element `session` of `session.xml`, its namespace `https://github.com/niltsiar/dirigible/session`, and its `version` attribute never change: the reader checks them before the version, so a change makes a newer file read as damaged. |
| P2. Read older | A reader accepts each version from 1 to its current version. It upgrades an older version in memory. |
| P3. Refuse newer | A reader refuses a version higher than its current version with a named error "made by a newer version of Dirigible (version N)". This error is not the error of a damaged file. The CLI and the app (English and Spanish) say that a newer version of Dirigible made the file. |
| P4. Never change a newer file | An older build never writes, moves, deletes, or repairs a file that it refuses as newer. It also makes no change to a package whose `session.xml` is newer, other than the `.lock` file (P8). A sweep of leftover files runs only after the version check. |
| P5. Caches are the exception | A cache file of a newer version is a miss. An older build can write over it or remove it. A cache format bump also changes the file name, so two builds do not overwrite each other. |
| P6. Write the lowest version | A writer writes the lowest version that holds the data. A file with no new data keeps the old version, so an older build can open it. |
| P7. Bump for each change an older reader would lose | Each new element, attribute, record kind, or field that an older reader would skip, drop, or misread raises the version. |
| P8. Frozen cross-version files | `.lock` (its name, its `flock` protocol, and its empty content) and `recovery-attempt` (its name and its presence) never change. Every version takes the lock before it writes the package, and keeps it until the write ends. A command that only reads can read without the lock, because each save is one atomic rename. |
| P9. Magic parse | A binary magic is a 7-byte prefix and one ASCII digit `1` to `9`, the version. A reader parses the prefix and the digit. Another prefix, a digit `0`, a byte that is not a digit, or a file shorter than 8 bytes is a damaged file, not a newer file. Version 10 needs a new prefix. The peak cache keeps its 8-byte magic `DIRPEAKS` and a UInt32 version field. |
| P10. Unknown package files | An older build ignores a package file that it does not know. It never deletes it. A file name pattern (for example `take<n>-<arm>-<seg>.caf`) never changes its meaning. The next take number counts every `Capture/` and `Clips/` name that matches `take([1-9][0-9]{0,8})` followed by a non-digit or the end, so a newer file keeps its take number. |
| P11. Files with no marker | A UserDefaults key never changes its meaning or its value type. A new meaning gets a new key. `active-recordings.plist` keeps its shape (a plist array of path strings). A newer build that needs more data uses a new file name. |

**The formats today.** This decision changes no byte of a current format.

| File | Version marker | Current | Newer version in an older build |
|---|---|---|---|
| `session.xml` | `version` attribute | 5 with a muted or soloed track (0039), else 4 with a crossfade (0036), else 3 with a fade (0035), else 2 with an app route (0029), else 1 | Refused (P3). No change to the package (P4). |
| `Capture/<stem>.sidecar` | magic `DRGSIDE` + digit | 1 | A per-segment "newer version" fault, not "missing or damaged". The take ends and the segment stays unplaced; "leave unreadable" does not treat it as unreadable. The sidecar and the CAF are never written, moved, or deleted. The anchor keeps the recorded time, so a newer build places the segment with `capture place`. A placement in the older build is refused. |
| `Capture/take<n>.anchor` | magic `DRGANCH` + digit | 1 | A placement that needs the anchor gives a per-segment "newer version" fault. A placement with a track and a start does not read the anchor. A finalize of that take keeps the anchor bytes, writes no anchor, places the segments from `<recording>`, and ends the take. No newer file keeps a take pending. An anchor that the finalize cannot read (an errno other than ENOENT) keeps the take pending with a read error that names the file, before any WAV is written: the build does not write over a file that it cannot identify (P4). |
| Peak cache `*.peaks` | magic `DIRPEAKS` + UInt32 version | 1 | A miss (P5). |
| `.lock`, `recovery-attempt` | none (frozen, P8) | - | - |
| Package layout, CAF and WAV names | none (P10) | - | - |
| `active-recordings.plist`, UserDefaults keys, toolbar autosave | none (P11; AppKit owns the toolbar format) | - | - |

**Amendments.** 0003, 0012, 0013, 0017, 0021, and the releases.md rule point at this record. 0012 gets one change: a newer sidecar is not a bad sidecar. It gives a per-segment newer-version fault, and the take ends. 0013 and 0021 get one change: the anchor name counts for the next take number, so a take with no segment no longer gives its number to the next take.

## Consequences

- A user who opens a package in an older build gets a clear message, and the package stays as the newer build left it.
- A take that a newer build recorded with a newer sidecar format ends in an older build without those segments. They stay unplaced in `Capture/`, and the newer build places them at their recorded time.
- Each version bump (run 6 first) adds: the reader of the new version, a test that a file without the new data writes the old version (P6), and a test that the previous build refuses the new version. The last test is the one that this run adds for version 2 of each format.
- One digit limits a binary format to 9 versions per prefix.
- A take with no audio uses its number. The next take has the next number.

## Alternatives considered

- **A version number for the whole package** (a `version` file in the package root). Rejected: a sidecar and an anchor are written before any save, by other code, and can change on their own. One number would bump for a change that most files do not have.
- **A newer sidecar as a take-wide refusal** (the take stays pending until a newer build ends it). Rejected by the orchestrator under the user's delegation (2026-09-27): the older build could then never end the take, and recording and edits in that package stay blocked.
- **A migration framework now.** Rejected: no version 2 exists yet. Run 6 adds the first upgrade in memory.
- **A newer anchor as a take-wide refusal at finalize** (the anchor writer throws and the take stays pending). Rejected at plan gate 1: it brings back the block of the take-wide sidecar refusal.
- **Restrict the peak cache prune to known names.** Rejected: the folder is a cache (P5), and a newer build prunes its own files.
