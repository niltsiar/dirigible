# 0067. Export one file for each chapter or marker: parts in DirigibleCore, one export job for the set, and a split argument of export

- Status: accepted
- Date: 2026-10-28
- Accepted: 2026-11-02, after the code gate and the Phase 7 checks of run `2026-10-28-chapter-export-files`.
- Amends: 0019 (one export job holds a set of files; the target check covers each file of the set), 0045 (the title tag of a part file is the part title), 0011 (`dirigible export --split`), 0041 (the `split` argument of the `export` tool).
- Amended: 2026-11-20, run `2026-10-28-stem-export` (see 0078). The target check and the loop of `exportParts` are the internal item loop `exportItems` of `Render/ExportSet.swift`; `exportParts` keeps its API, its types, and its behavior. The stem export runs on the same loop in the same `ExportJob`, with its own stop rule: a stop keeps no stem. In code and in text, the name in front of `-<NN>-<title>` is the prefix ("older file of this prefix"); a stem is one file of a stem export.

## Context

F95 (R11) asks for one audio file for each chapter or each marker of the mix. Audition and Audacity have it (`docs/research/chapter-export.md`). Today `exportMix` (0019) writes one file for one `ExportSource`, with its own loudness search (0032), its own tags and chapters (0045), and an atomic move with no replace or over a confirmed item. `Studio.export` runs one `ExportJob`; a take start and `settle()` end it (capture comes first, 0019).

Facts that constrain the design (main e9e9274a):

- `endExport` acts only on `exportJob` (`Studio+Export.swift:74`). Between two jobs of a caller loop, a take start finds no job, so the loop starts the next file during the take.
- `exportMix` adds 46 bytes to the target name for its `.tag.tmp` file (`Export.swift`). A name over 209 bytes fails on APFS (255 bytes). The limit depends on that private temporary-name code, so it lives beside it.
- `StudioError.exportYielded` has no payload, and the stop texts of the live tool say "No file was written." (`LiveJob.swift` `stopMessage`). A set that stops after part 1 has files on disk, so it needs its own error.
- The callers read the session before awaits (the media check, the save panel, the replace sheet), and the job renders the Studio session of the job start (`Studio+Export.swift:50`).
- `Session.chapterList(in:)` drops a chapter at the millisecond of the chapter before it. The MP3, the M4A, and chapters.json use it.
- The `export` tool kind is in three hand-synced lists (backlog 0245). The agent manual core has 1 free character (run `2026-10-23-read-by-time`, P1).

Rubric: (R1) a take start or a close stops the whole set; (R2) one owner of the split rule for the app, the CLI, and the tool; (R3) no change of the behavior of `exportMix` or of the tag writers in the risk floor (`Export.swift` gets only the `exportNameLimit` constant and the `.tag.tmp` suffix constant that it reads); (R4) the CLI and the tool keep their kind and their texts when there is no split; (R5) a refusal (an existing file, a media fault, no split point) comes before the first file.

## Decision

**Parts (DirigibleCore, `ExportParts.swift`).**

```swift
public enum SplitKind: String, Sendable, CaseIterable { case chapters, markers }

public struct ExportPart: Hashable, Sendable {
    public enum Start: Hashable, Sendable {
        case rangeStart                      // the part before the first split point: number 00
        case point(Marker, number: Int)      // the number from 1
    }
    public let range: Range<Frames>
    public let start: Start
    public let title: EpisodeLine?           // a line break or a tab is a space; nil keeps the episode title
}

public struct ExportParts: Hashable, Sendable {
    public let parts: [ExportPart]   // empty when the range has no split point
    public let dropped: [Marker]     // at the millisecond of the point before, or of the range end
}

extension Session {
    public func exportParts(in range: Range<Frames>, by kind: SplitKind, introTitle: String) -> ExportParts
    /// The session of a part file: `episode.title` is the part title, or the episode title for nil.
    public func forPart(_ part: ExportPart) -> Session
    /// `limit` is the byte limit of DirigibleAudio (`exportNameLimit`).
    public static func partFileName(
        _ part: ExportPart, digits: Int, prefix: String, pathExtension: String, limit: Int) -> String
    public static func isPartFileName(_ name: String, prefix: String, pathExtension: String) -> Bool
}
```

- The split points are the markers of `kind` in the range (`.chapters`: kind `.chapter`; `.markers`: every marker), by position, then ID. A point whose rounded millisecond (`milliseconds()`, half up, the rule of `chapterList`) equals that of the point before it, or that of the range end, is dropped. The rule compares rounded values, so a part can be one frame long (48 kHz: points at 480023 and 480024 round to 10000 and 10001 ms).
- Part k runs from point k to point k + 1; the last part ends at the range end. When the rounded millisecond of the first point is after that of the range start, a first part runs from the range start to it; else the part of the first point starts at the range start. Its title is the name of the last point before the range start, else the episode title, else the show, else `introTitle`.
- File name: `<prefix>-<NN>-<title>.<ext>`, the Audacity rule `NN-<label>` (`%02d`, `00` for the part before the first label) with the prefix in front. `NN` has the digits of the highest number of the set, at least 2, so 3 digits over 99 parts from 01. The title is cleaned: each character that macOS, exFAT, FAT32, or SMB refuses (`/ \ : * ? " < > |` and the control characters) becomes `-`, and the spaces at the ends and a leading dot go; an empty result gives `<prefix>-<NN>.<ext>`. A name longer than `limit` UTF-8 bytes with its extension is cut on a character boundary: the title first, from its end, then the prefix, from its end; the cut never removes `-<NN>` or the extension.
- The part title rule has one owner, `forPart`: the writer, `ExportWork` (the title warning), and the app (the title banner) call it.

**Writer (DirigibleAudio, `Render/ExportParts.swift`).**

```swift
/// In `Export.swift`, beside `leftoverPrefix`: 255 minus the bytes of `.<name>.<UUID>.tag.tmp`
/// around the name, from the temporary-name code (209 today). Internal: `exportPartTargets` reads it.
let exportNameLimit: Int

public struct ExportPartTarget: Hashable, Sendable {
    public let part: ExportPart
    public let url: URL
}

/// The one owner of the targets of a set, for the writer and the callers.
public func exportPartTargets(
    _ session: Session, range: Range<Frames>, by kind: SplitKind, options: ExportOptions,
    folder: URL, prefix: String
) -> (targets: [ExportPartTarget], dropped: [Marker])

/// The old files of the prefix: the items of `folder` whose name `Session.isPartFileName` matches
/// and that are not in `targets`, by name. It reads the folder: call it off the main actor.
public func oldPartFiles(
    in folder: URL, prefix: String, pathExtension: String, targets: [ExportPartTarget]
) -> [URL]

public struct ExportedPart: Hashable, Sendable {
    public let url: URL
    public let part: ExportPart
    public let result: ExportResult
}

public struct ExportPartsResult: Hashable, Sendable {
    public let files: [ExportedPart]   // in part order; one file or more
    public let dropped: [Marker]       // from the parts of the rendered session, for the warning lines
}

/// A set that stopped or failed after the check of its targets.
public struct ExportPartsStop: Hashable, Sendable {
    public let error: ExportError        // .cancelled for a stop: Cancel, a take, a close, Control-C
    public let written: [ExportedPart]   // on disk, in part order
    public let remaining: [URL]          // the part in hand and each part after it: an old item stays
}

public enum ExportPartsError: Error, Hashable, Sendable {
    case exists([URL])                   // before the first write; nothing was written
    case noPoint(SplitKind, Range<Frames>) // the rendered session has no split point in the range; nothing was written
    case stopped(ExportPartsStop)
}

public struct ExportPartsProgress: Hashable, Sendable {
    public let fraction: Double          // of the set, by frames
    public let number: Int               // the place of the part in hand in the set, from 1
    public let count: Int
    public let name: String              // the file name of the part in hand
}

public func exportParts(
    _ session: Session, range: Range<Frames>, by kind: SplitKind, tracks: Set<TrackID>?, options: ExportOptions,
    folder: URL, prefix: String, replacing: [URL: ConfirmedFile],
    package: () throws(SessionFileError) -> URL,
    progress: (ExportPartsProgress) -> Void = { _ in }, isCancelled: () -> Bool = { Task.isCancelled }
) throws(ExportPartsError) -> ExportPartsResult
```

- It computes the parts and the targets with `exportPartTargets` on the session that it renders. The callers call `exportPartTargets` only to list the targets for their precheck and the replace sheet. When the two lists differ, the target check below refuses each name that the user did not confirm.
- It checks every target first. An item at a target that `replacing` does not hold, or that is not the confirmed item (device and inode of its `ConfirmedFile`), throws `.exists` with every such path, before any file exists. An item that appears after the first write stops the set: `.stopped` with the error `.exists`.
- For each part it calls `exportMix` with the part range, the tracks, and `session.forPart(part)`. So each MP3 or M4A file has the part title tag and the chapters of its own range (0045 rules, no new tag code).
- With no split point of the kind in the range of the rendered session (an edit after the caller check), it writes nothing and throws `.noPoint(kind, range)` (R5). It never returns an empty result.
- Loudness: each part is measured and normalized by itself, by the `exportMix` rule (0032: "Each Export Selection is measured and normalized by itself"; Reaper "each file separately"). A common gain for the set (Reaper "as if files play together") needs a fixed-gain mode of `exportMix` (R3): later item.
- It maps the progress of part k into its frame share of the set. It calls `progress` at each new whole percent and at the start of each part, with the number, the count, and the name of the part in hand, so a set of n parts has at most 101 + n calls.
- A stop (cancel, take, close) or a failure in part k throws `.stopped` with the error, the written files, and the remaining targets. Part k leaves no file (the `exportMix` rule); the files before it stay.

**Job (Studio).** `Studio.export(range:by:tracks:options:folder:prefix:replacing:progress:)` runs `exportParts` in the same `ExportJob` as `export`, on the same utility GCD queue with the same cancel flag, on the Studio session of the job start. `ExportJob.task` is a `Task<Void, Never>` handle that `cancelExport` and `endExport` cancel and await; each `export` awaits its own typed result. A cancel of the handle reaches the cancel flag of the GCD loop: the handle is the typed task with its result type erased, or it cancels that task. Studio computes the targets on the job session before it makes the job; with no target it throws `.exportParts(.noPoint(_, _))` and makes no job. The job `url` is the first target of the job session, a file in the folder: `endOtherExports` reads `job.url.deletingLastPathComponent()` for the volume, so the disk check of a take in another window ends the set by the volume of its folder. `Studio.exportFile` (the last `ExportPartsProgress`) is observable for the sheet. `StudioError` gets one case, `exportParts(ExportPartsError)`. Each stop of a set throws `.exportParts(.stopped(_))`, also a take in another studio, and `exportStop` gives the cause; a refusal before the first write throws `.exportParts(.exists(_))` or `.exportParts(.noPoint(_, _))`; a set never throws `.exportYielded` or `.export`. The four exhaustive switches on `StudioError` (the app messages, the MCP error text, the CLI exit code, the take log) get the case.

**CLI and tool.** `dirigible export <package> --out <folder>/<prefix>.<ext> --split chapters|markers [the export options]`. With `--split`, `--out` gives the folder, the prefix, and the format; the file `<prefix>.<ext>` is never written. `--replace` confirms each target that exists at the start. Stdout has one line per file: the path, then with `--loudness` a tab and the loudness line. After a stop or a failure, stdout has the lines of the written files, and stderr has a stop line that names the files not written (exit 130 for Control-C, 2 for a failure). After a set that ends with exit 0, stderr has one line that names the old files of the prefix (`oldPartFiles`), also when no target existed; Dirigible never deletes them. A range with no split point exits 1, and a `.noPoint` refusal of the writer gives the same text and exit. The `export` tool takes `split` with the same rules and text; on a package open in the app, the stop sentence names the cause and the count, not "No file was written.". `ExportWork` owns both; the tool kind stays `export`.

**App.** The Export save panel has a Files pop-up under Format: One File (the default at each panel), One for Each Chapter, One for Each Marker, each split item with the count of its files. A split item is off when the source has no point of its kind, with a help tag that says why. With a split item, the name field label is "Prefix:", the button is "Export", and a line names the count, the first file, and the file `<prefix>.<ext>`, which does not change. The panel name is the prefix. One sheet on the window lists the existing targets and the old files of the prefix that stay, with Cancel as the default button and a destructive Replace. The progress sheet reads "Exporting file 3 of 10: <name>". After a stop, Cancel included, a banner gives the count of the written files; after the set, a banner gives the count, the folder, and Show in Finder (UI council 2026-10-28b, section E). The done banner also names the old files of the prefix, also when no target existed and no sheet showed. A `.noPoint` refusal shows an alert that says that the session has no chapter (or marker) in the range now.

## Consequences

- A per-chapter M4A goes through the `AVAssetWriter` chapter copy of 0045 for its one chapter, so each M4A part pays that copy and its cancel wait (up to 10 s, backlog 0426).
- A stop leaves a partial set; the error, the CLI and tool lines, and the app banner name the written files and the files not written. A replace of an old set can leave old and new files mixed after a stop.
- Old files of the prefix that the new set does not write (a renamed or deleted chapter) stay. The app replace sheet lists them when a target exists, the done banner names them after each set, and the CLI and the tool print one line that names them. A stop does not name them.
- A crash during a set leaves a hidden temporary file that the leftover sweep misses when the part title changes (later item).
- A part under 400 ms has no loudness measurement: gain 0 dB, `none` (0032).
- The 16-bit parts do not join bit for bit to the whole export: the TPDF seed starts again at each file (0032).
- 0019, 0045, 0011, and 0041 get an Amended line.

## Alternatives considered

- **Candidate 2: callers loop `Studio.export` once per file.** No new DirigibleAudio API. Rejected: R1 fails (a take start between two files finds no job, and the loop starts the next file), and the target check, the progress, and the cancel go into four callers (CLI, the tool on files, the live tool, the window), so R2 fails.
- **A parts mode inside `exportMix`.** One call writes all files. Rejected: R3 fails; `exportMix` is 350 lines in the risk floor, and its loudness search, tag pass, and move are for one file.
- **A new tool `export_parts` and a new command.** Rejected: R4 fails; it needs the three kind lists (backlog 0245) and a manual line that does not fit.
- **A move of all files at the end of the set.** All or nothing for a stop. Rejected for now: it needs a write-only mode of `exportMix` (R3). Later item.
