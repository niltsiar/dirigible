# 0079. Session templates: a template is a session package, and a new session is a copy of it with the episode data removed

- Status: accepted
- Date: 2026-10-28
- Amends: 0003 (a package can be the source of a new package), 0027 (the app also makes `Templates/` in its default folder; the start window has a Template pop-up; a name with a template has 193 UTF-8 bytes at most), 0042 (the template copy uses its file steps, with a regular-file check in front), 0056 (a copy of a whole package is not a new clip file), 0011 (`dirigible create --template`), 0041 (the `template` argument of the `session_create` tool).
- Amended: 2026-11-22, run `2026-10-28-import-session` (see 0075). `openChecked`, the `openat` and `fstat` check of the first pass, is in `DirigibleAudio/Import/CheckedOpen.swift`, shared with the session import.
- Amended: 2026-11-25, run `2026-11-04-flac-archive` (see 0072). `TemplateCopy` resolves each `Clips/` path of the source through `poolFileName` and converts a FLAC, so a copy of an archived session, for Save as Template or for a new session, holds WAVs. `newEpisode()` also sets `archive` to nil, so the copy is a working session. The source does not change, so Save as Template runs on an archived window with no unarchive.

## Context

F63 (R10, Release 7 item 2) asks for a new session from a template package. The reference apps (`docs/research/presets-templates.md`):

- Hindenburg has one default session: "Save default session > saves current settings as default", and a new session gets "the default properties" (finding 6). Its publish dialog keeps show metadata apart from episode metadata ([HM] table of contents).
- Logic Pro saves a whole project as a template with File > Save As Template, and lists it under My Templates in the Project Chooser. A template is a normal `.logicx` project in `~/Music/Audio Music Apps/Project Templates/` (findings 11, 12).
- GarageBand has built-in templates only (finding 13).

Facts of the code (main 46d71f6f):

- `Session.create(at:sampleRate:)` (`SessionWriter.swift`) makes a package: `mkdir`, the write, a flush of the parent; a failure removes the folder. `Studio.create` calls it off the main actor, and `AppDelegate.createSession(at:)` (`AppDelegate+Panels.swift:24-29` at 472841713) calls `Studio.create` with 48000 Hz.
- A package references files in `Clips/` (the pool paths), in `Artwork/` (the episode artwork and the marker images, 0045), and in `Transcripts/` (0055). `Backups/`, `Capture/`, `.lock`, and `recovery-attempt` hold the state of one package.
- 0056: "Each new writer of a `Clips/` file uses both" (`NewClipFiles` and `addDerivedFile`). Those two derive a new file ID and a new stem for a file that joins an existing pool.
- 0027: "The app makes only that folder, one level, and only at a Create in it."

Rubric: (R1) a template is a file that the user can see, copy to another Mac, and open to change, as in Logic; (R2) one rule says what a new session keeps, for the app, the CLI, and the tool; (R3) no new file format; (R4) the new package is complete or absent after a crash, a full disk, or a cancel (AGENTS.md, No data loss); (R5) a data kind that a later run adds to `session.xml` goes into the new session with no change to the rule (export presets, landing 2).

## Decision

**A template is a session package.** Any `.dirigible` package can be the template of a new session. The app keeps its templates in `<default folder>/Templates/` (`~/Music/Dirigible/Templates/`). No new file type, no new UTI, and no new format version.

**The rule (DirigibleCore, `SessionTemplate.swift`).**

```swift
/// A session that `newEpisode()` made. Only that call makes one, so each copy applies the rule.
public struct NewEpisode: Hashable, Sendable {
    public let session: Session
    /// The package-relative path of each file that the new package needs: each pool path in
    /// `Clips/`, the episode artwork, and each marker image in `Artwork/`.
    public var filePaths: [String] { get }
}

extension Session {
    /// The session of a new episode from this session: the same tracks, clips, markers, and
    /// export presets, with the episode data of one episode removed.
    public func newEpisode() throws(SessionError) -> NewEpisode
}
```

`newEpisode()` removes, and keeps everything else:

- `<recording>`: a session with a pending take throws `.pendingTake` (no copy of a take that is not finalized).
- The transcripts (0055): the words are of one episode.
- The episode fields of one episode: `title`, `number`, `date`, `summary`, `notes`, `episodeURL`, `guid`. It keeps the show fields: `show`, `author`, `season`, `language`, `copyright`, `explicit`, `feedURL`, `artwork` (Hindenburg show and episode metadata, inference from [HM]).
- The pool files `Set(files.keys).subtracting(filesInUse)`, through `removeFiles` (0057), and then each capture that no kept file names. `Session.filesInUse` is the one rule of the files that a session holds (Remove Unused Files, 0047 and 0057). A later data kind that references a file extends `filesInUse` (favorites-bins: a bin clip), so the template keeps its file with no change here.

The rule is a list of removals, so a later data kind stays in the copy (R5). A later kind that references a file must also be in `filesInUse`, or Remove Unused Files would remove its file too.

**The folder publish (DirigibleCore, `FolderPublish.swift`, made by 0078).** One function publishes a folder that appears whole or not at all. The stem export uses it with the kind `stems`; the template copy uses it with the kind `template` and changes nothing in it. The landed API (`FolderPublish.swift`, main 472841713):

```swift
public struct StagingFolder: ~Copyable {
    public let url: URL
    public func checkPublish() throws(SessionFileError)
    public consuming func publish() throws(SessionFileError)
    public consuming func discard()
}
public func folderNameLimit(kind: String) -> Int { 255 - 44 - kind.utf8.count }
public func stageFolder(for target: URL, kind: String) throws(SessionFileError) -> StagingFolder
```

- The publish: `renamex_np(RENAME_EXCL)`; on ENOTSUP or EPERM, `mkdir` of the target as the claim, then `rename(2)` over the empty claim. An item at the target gives `.exists`; a claim that became non-empty stays, with its content. A failed rename over the claim removes the claim while it is empty. A throw removes the staging folder and the lock file, because `publish` consumes the value. `checkPublish()` reads `VOL_CAP_INT_RENAME_EXCL`; with no exclusive rename, it renames an empty folder over an empty folder in the staging folder, and a failure throws before any content. The claim has a crash window: a crash between the `mkdir` of the claim and the `rename(2)` leaves an empty folder with the package name at the target, and no sweep removes it, because an empty folder with no lock file can be a folder of the user. The crash leftover stays by design: the next create to that name gives `.exists`, and R4 does not hold after a crash on a volume with no exclusive rename until the user removes the folder. The guide names this limit. Probe P1 of run `2026-10-28-stem-export` (macOS 15.8.1) proves the APFS rename, the exFAT ENOTSUP, the claim fallback, and ENOTEMPTY onto a full claim.
- The sweep (inside `stageFolder`): it removes each staging folder of the kind of any target whose lock file it can lock. For the same target only, it also removes a staging folder with no lock file and a lock file with no staging folder that it can lock. It never removes an empty target folder with no lock file.
- The name limit: the lock file `.<name>.<UUID>.template.lock` must fit 255 bytes, so `folderNameLimit(kind: "template")` is 203 bytes, and the package name `<name>.dirigible` has at most 193 bytes of name (`templateNameLimit`, below). The 245 bytes of 0027 do not hold for a template copy. The count is of the UTF-8 bytes of `URL.lastPathComponent`, which is decomposed (NFD): an "é" counts 3 bytes.

**The copy (DirigibleAudio, `Import/TemplateCopy.swift`, beside `copyFiles` of 0042).**

```swift
/// A new session: an empty session at a rate, or a copy of a template. `Studio.create`, the
/// `create` command, and the `session_create` tool take it.
public enum NewSessionSource: Hashable, Sendable {
    case rate(Int)
    case template(URL)
}

public enum TemplateError: Error, Hashable, Sendable {
    case read(SessionFileError)           // the template does not read, or is newer (0024 P3)
    case pendingTake                      // the template has a take that is not finalized
    case notRegularFile(String)           // a link at any component, a FIFO, or a folder
    case sourceChanged(String)            // another device and inode than the first pass
    case missing(String)
    case notDownloaded(String)
    case space(needed: Int64, free: Int64)
    case write(file: String, errno: Int32)
    case cancelled
    case nameTooLong                      // the package name is over `templateNameLimit`
    case publish(SessionFileError)        // .exists, stageFolder, checkPublish, or the rename
}

/// The longest name of a template copy in UTF-8 bytes, with no ".dirigible": 193.
public let templateNameLimit = folderNameLimit(kind: "template") - ".dirigible".utf8.count

/// The one entry point of a new session from a template: reads `template` with no lock
/// (0024 P8), applies `newEpisode()`, copies, and publishes `package`.
public func createSession(
    at package: URL, template: URL, progress: (Double) -> Void, isCancelled: () -> Bool
) throws(TemplateError)

/// The copy of `createSession` and of `Studio.saveTemplate`. It takes a `NewEpisode`, so no
/// caller can skip the rule.
func copyNewEpisode(
    _ episode: NewEpisode, files source: URL, to package: URL, progress: (Double) -> Void,
    isCancelled: () -> Bool
) throws(TemplateError)
```

The steps of `copyNewEpisode`, in order:

1. A package name over `templateNameLimit` throws `.nameTooLong`, before any file. Then `stageFolder(for: package, kind: "template")`, an `lstat` of `package` (an item gives `.publish(.exists)`), and `checkPublish()`, in the order of `exportStems` (`ExportStems.swift:125-135`), so a refusal comes before the first copy.
2. Open the source package folder once with `O_RDONLY | O_DIRECTORY`. A link to the package itself is followed, because the user chose it.
3. First pass, for each path of `episode.filePaths`: `openat(packageFD, path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK)`, then `fstat`. A link at any component of the path (a linked `Artwork/` folder, a linked subfolder of `Clips/`, or a link at the file; ELOOP), a FIFO, a folder, or any item that is not `S_IFREG` throws `.notRegularFile(path)`. ENOENT throws `.missing(path)`. An evicted file throws `.notDownloaded(path)`. The pass records `st_dev`, `st_ino`, and `st_size`, and closes the descriptor, so the open files stay one at a time.
4. One space check before the first copy, through the 0042 symbols below: the bytes that a clone does not share plus `diskMargin`, against the free bytes of the volume, else `.space(needed:free:)`.
5. Copy pass, for each path: `openat` with the same flags, and `fstat`. A `st_dev` and `st_ino` pair that differs from the first pass throws `.sourceChanged(path)`; 0042 `copyFiles` has no such check, so the template copy owns it. A test seam sits between this `fstat` and the copy. Then the copy from that same descriptor: `fclonefileat(sourceFD, stagingFD, name, 0)` when the file clones, else `fcopyfile` into a target descriptor that `openat(stagingFD, name, O_WRONLY | O_CREAT | O_EXCL)` made. The `fcopyfile` state has the `COPYFILE_STATE_STATUS_CB` callback of 0042 (`copyCallback` and `CopyContext` in `PasteClipboard.swift`, through `COPYFILE_STATE_STATUS_CTX`). It runs at each `write(2)` and returns `COPYFILE_QUIT` when `isCancelled()`, and at stage `COPYFILE_ERR`, where a continue retries a full disk with no end (0042 probe P1). A failed `fcopyfile` with the flag set throws `.cancelled`, so a cancel ends the copy within one write, also inside one large file (a take waits on this end, in `Studio+Export.swift`). A clone makes no callback and needs none. After the copy, an `openat` of the path with the same flags and an `fstat` must give the recorded pair again, else `.sourceChanged(path)`: a template that changes while it copies makes nothing. The check and the copy use one descriptor, so no path is opened twice for the copy. A cancel check, a progress call, and a flush for each file, through a `flush` seam as `pasteClipboard` has.
6. A flush of each subfolder of the staging folder (deepest first: the subfolders of `Clips/`, then `Clips/` and `Artwork/`), then of the staging folder. A folder flush that the volume refuses does not stop the copy, as in `Export.swift:292`. Then the durable write of `session.xml` into the staging folder (0003), then `publish()`, which flushes the parent. This is the order of an export: the file, then its folder (`Export.swift:285-292`). So a power loss after the publish cannot show a package whose folder entries are not on disk.

Each throw before `publish()` calls `discard()`, and a throw of `publish()` removes the staging folder itself, so the target path has nothing and the parent has no staging folder.

**The 0042 symbols (internal; L1-S1 extracts them, the 0042 code then calls them, and the 0042 paste tests pin the extraction).**

```swift
// PasteClipboard.swift, from the size step of the private `copyFiles` (no conversion).
/// The bytes of a list of source and target pairs that a clone does not share, and which
/// pairs clone (`canClone(source, target folder)`).
func copyNeed(_ pairs: [(source: URL, size: Int64, target: URL)], canClone: (URL, URL) -> Bool)
    -> (clones: [Bool], bytes: Int64)

// NewClipFiles.swift, from the check of `NewClipFiles.init` (line 46), which then calls it.
/// Nil when `bytes` is 0 or the volume has `bytes` plus `diskMargin` free; else the need and
/// the free bytes.
func spaceShortfall(bytes: Int64, freeBytes: () -> Int64) -> (needed: Int64, free: Int64)?

// PasteClipboard.swift, private today: the `copyfile` status callback with `CopyContext`
// (cancel at each write, quit at `COPYFILE_ERR`); the `fcopyfile` of step 5 uses it.
let copyCallback: copyfile_callback_t
```

The source check of 0042 is `sourceIsDownloaded` (`AudioImport.swift`, already public) and a `stat` that follows links. The template copy calls `sourceIsDownloaded` after the `openat` of the first pass, and uses its `fstat` in place of the `stat`. The copy never reads `Backups/`, `Capture/`, `Transcripts/`, `.lock`, `recovery-attempt`, or a file that no reference names. A template of a newer version gives `.read` with the newer-version error of 0024 (P3); the template does not change (P4).

The copy refuses a link at any component under the package, in `Clips/` too, although a session with one opens (0042 copies such a link as its target; the package-boundary run keeps it allowed at open). A template moves between Macs (R1), so a link in it names a file of another Mac or a private file of this one.

**Not a new clip file (amends 0056 and 0042).** The copy makes a new package. It keeps each file ID, path, and capture, so no ID or stem is derived, and no pool exists at the target. `NewClipFiles` and `addDerivedFile` stay the one path of a new file in an existing package. The copy uses the file steps of 0042 (`sourceIsDownloaded`, `copyNeed`, `spaceShortfall`, cancel, progress) and adds the regular-file check, the device and inode check, and a copy from the checked descriptor.

**Studio and app.**

- `Studio.create(_:source:...)` takes a `NewSessionSource`. With `.template` it calls `createSession(at:template:)` off the main actor; with `.rate` it calls `Session.create` as today. The CLI and the MCP tool call the same `createSession`.
- The copy of `Studio.create(.template)` runs before a studio exists, so `otherStudios()` does not see it. It registers in a main-actor list of studio-less copy jobs (the target URL and a cancel flag) for its run. `exportEnd` ends each such job at a take start, and `endOtherExports` ends each one whose target folder is on the volume of the take. An end throws `.template(.cancelled)` and leaves nothing at the target.
- The start window shows a fraction bar and a Cancel button while a template create copies. `Studio.create` with `.template` takes a `progress` callback and a cancel handle that the start window holds; Cancel sets the flag of the studio-less copy job, and the form shows again with nothing at the target.
- `Studio.saveTemplate(to:)` calls `copyNewEpisode(session.newEpisode(), files: lock.package(), ...)` in the `ExportJob` slot, with the job URL at the template, so a take start, `settle()`, and the take disk check of another window on its volume end it (`endExport`, `exportEnd`, and `endOtherExports`, `Studio+Export.swift:86-138` at 472841713, 0019). `ExportJob.task` is already a `Task<Void, Never>` handle (`:18`); `jobTask` and `handle` (`:159`, `:184`) become internal, so `Studio+Template.swift` runs the copy on the job thread of an export. An end throws `.template(.cancelled)` (the new case `StudioError.template(TemplateError)`, with the four exhaustive `StudioError` switches) and leaves no package and no staging folder. A take start or the take disk check of another studio, and each take end of a template create, throw `.templateYielded` instead, and the window shows its alert, as for `.exportYielded`; only Cancel, a take start in the same window, and `settle()` are silent. It throws `.busy` during a take start, a take, a finalize, a pending take, an export, or `settle()`. While the job slot holds a template job, `removeUnusedFiles` throws `.busy`, so no file of the job snapshot goes to the Trash during the copy. The progress sheet of the job says that it saves a template. The window gives the sheet its title: the template text while its template job runs, else the title of `exportSheetTitle` (`SessionWindow+ExportSet.swift:51`). The preset set of the export presets record reuses this title shape.
- The start window New Session form gets a Template pop-up (UI panel ruling of 2026-10-28, `ui-panel.md`): None, then each package in `Templates/` by name, and a last item "Show Templates in Finder". The pop-up shows only when `Templates/` has at least one template. The row fits the 700 by 420 start window. It keeps the last choice in the key `session.template` (a `String`, an absolute path; 0024 P11). A missing template shows None.
- File > Save as Template... asks for a name and writes `Templates/<name>.dirigible`. The name sheet has one line with the size, "Keeps 12 clips, 1.4 GB of audio.", and no check box. The app makes `Templates/` at that step, only in its default folder (amends 0027). A name that exists shows an alert that names the template, with Replace and Cancel (no button takes Return, and Esc cancels); Replace refuses an old template that a window or another process has open (its window key, its `PackageID`, or its `PackageLock`), and holds its lock until the end. It saves the new template into a folder on the same volume, swaps the two with `renamex_np(RENAME_SWAP)`, and then moves the old one to the Trash; a failed move swaps them back; if the swap back fails too, the new one stays at the name, and an alert gives the path of the old one. A volume with no swap (exFAT) moves the old one to the Trash first, then puts the new one at the name with `renameFolder`, the claim rename of 0078; if that rename fails, the new one stays in its folder, and an alert names the Trash and the path of the new one. A stopped or failed save keeps the old template. File > Show Templates in Finder opens the folder; the Finder renames and deletes templates. Both items are a menu group of their own, after the Export items.
- The name rule of 0027 applies to a template name, with `templateNameLimit` (193 bytes) in place of 245 bytes. The start window uses the same limit when the pop-up has a template.

**CLI and tool (0011, 0041).** `dirigible create <package> --template <package>` makes the new package from the template through `createSession`; `--sample-rate` and `--template` together exit 64, and one of them is required. The same command saves a template: `dirigible create Templates/Show.dirigible --template Episode.dirigible`. The `session_create` tool takes `template`; `ToolWork` `.create` (in `MCPToolKit.swift`) takes a `NewSessionSource`. Exit 2 for each `TemplateError`: a template that does not read, a newer template, a pending take, an item that is not a regular file, a missing or evicted file, no space, a failed write, a name over `templateNameLimit`, or an existing target.

## Consequences

- A template with long recordings copies them. On one APFS volume a clone shares its blocks (0042); across volumes it is a full copy. The space check refuses before the first byte with `.space(needed:free:)`, and the app shows a full-disk text with both numbers.
- A template opened with File > Open is a normal session: its edits change the template.
- A crash during the copy leaves a staging folder and its lock file in the parent folder. The next template copy into that folder removes them (the sweep of `stageFolder` is limited to one kind). On a volume with no exclusive rename (exFAT), a crash between the claim and the rename leaves an empty folder with the package name. The folder publish of 0078 cleans only a failed rename, so this crash leftover stays by design: R4 does not hold after such a crash, the next create to that name gives `.exists`, the user removes the folder, and the guide names this.
- 0003, 0011, 0027, 0041, 0042, and 0056 get an Amended line.

## Alternatives considered

- **A new package type `.dirigibletemplate`** (Pages and Numbers templates): a double-click makes a new session. Rejected for now: a new UTI and a new document type, and the Finder open of a template must then never change it. The rule above does not change if a later run adds it.
- **Templates as app preferences** (Hindenburg default session). Rejected: R1 fails (no file to copy to another Mac), and the CLI cannot read the app preferences, so CLI parity fails.
- **A new session that the edits build from the template** (`Session(sampleRate:)`, then each track, clip, and marker, and the files through `NewClipFiles`). Rejected: it derives new IDs and stems, so markers and clips of the template change their IDs, and each new data kind needs its own copy step (R5 fails).
- **A plain folder copy of the whole package.** Rejected: it copies `Backups/`, the transcripts, and the unused files, and it needs a second pass to remove the episode data.
