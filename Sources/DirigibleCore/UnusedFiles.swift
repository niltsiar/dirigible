import Foundation

/// The clip files that no clip uses (decision 0047): the pool entries that no clip of the session
/// uses, and the stray WAVs at the top level of `Clips/` that no pool path names. A file that a
/// clip of a keeper uses stays, with each file of its origin chain (decision 0057): the
/// `session.xml` on the disk (the prune save can make it a backup), each readable backup, and the
/// keepers that the caller gives (the undo and redo entries, the clipboard files). Also each
/// transcript file in `Transcripts/` that the session and these holders do not name
/// (decision 0055), and with `listingCaptureFiles`, the capture files of each free capture. A
/// stem WAV whose CAF is gone is the only copy of its take audio (decision 0071): it is never a
/// stray WAV. An unused pool entry of it is a pool item, so its WAV and then its sidecar move, as
/// the files of a free capture do. The scan is the one place of this rule.
public struct UnusedFiles: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case pool(FileID)
            case stray
            /// A file in `Transcripts/` that no holder names (decision 0055).
            case transcript(TranscriptFileName)
            /// A capture file of a free capture (`captures`), from `listingCaptureFiles`.
            case capture(CaptureID)
        }
        public let kind: Kind
        /// Relative to `Clips/` for `.pool` and `.stray`, and to the package for `.transcript`
        /// ("Transcripts/<name>.xml") and `.capture`.
        public let path: String
        public let bytes: Int64
        /// The `lstat` identity at the scan, nil for a missing file. A file that another file
        /// replaced at the path is another item, so an intersection drops it.
        let identity: FileIdentity?
    }
    /// The files that a clip of a keeper uses, and the transcript files that only a keeper names,
    /// which the list does not have.
    public struct Kept: Hashable, Sendable {
        public let count: Int
        public let bytes: Int64
    }
    /// Sorted by path.
    public let items: [Item]
    public let kept: Kept
    /// The backups that the reader refused as damaged XML: they keep no file.
    public let damagedBackups: [Backup]
    /// The unused pool paths that are not a regular file (a symbolic link or a folder). They stay,
    /// so the prune never moves or follows a link to a file outside the package. Sorted.
    public let notFiles: [String]
    /// The free captures, each with its pool items.
    let owners: [CaptureID: Set<FileID>]

    /// Reads `Clips/`, `session.xml`, and `Backups/` of `package`. `keptFiles` are the pool paths
    /// of the files that the app clipboard of the same package uses. Throws for a `Clips/` that is
    /// not a folder (a link too) or does not read, for an unreadable `session.xml`, and for a backup
    /// of a newer version or with a read errno other than ENOENT: the scan cannot know its clips. A
    /// backup that is gone keeps nothing.
    /// `soleCopies` are the `Clips/` paths of the stem WAVs whose CAF is gone (decision 0071).
    public init(
        scanning session: Session, keptBy keepers: [Session], keptFiles: [String] = [], soleCopies: Set<String>,
        in package: URL
    ) throws(UnusedFilesError) {
        let clips = package.appending(path: clipsFolderName)
        if let code = folderErrno(clips) { throw .clipsUnreadable(errno: code) }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: clips.path)
        } catch {
            throw .clipsUnreadable(errno: posixCode(of: error))
        }
        var held: [Session]
        do throws(SessionFileError) {
            held = [try Self.read(package.appending(path: "session.xml"))]
        } catch {
            throw .sessionUnreadable(error)
        }
        var damaged: [Backup] = []
        for backup in Backup.all(in: package) {
            do throws(SessionFileError) {
                held.append(try Self.read(Backup.folder(of: package).appending(path: backup.fileName)))
            } catch {
                switch error {
                // A due save of an autosave can delete the oldest backup during the scan.
                case .readFailed(errno: ENOENT): continue
                case .unsupportedVersion, .readFailed: throw .backupUnreadable(backup, error)
                default: damaged.append(backup)
                }
            }
        }
        let own = Holders(session.usedPaths, in: clips)
        let others = Holders((held + keepers).flatMap(\.usedPaths) + keptFiles, in: clips)
        let poolNames = Set(session.files.values.map { normalized($0.path) })
        let used = session.filesInUse
        let realClips = package.resolvingSymlinksInPath().appending(path: clipsFolderName).path
        let sole = Set(soleCopies.map(normalized))

        var candidates: [(Item.Kind, String)] = session.files.values
            .filter { !used.contains($0.id) && Self.staysIn(realClips, clips.appending(path: $0.path)) }
            .map { (.pool($0.id), $0.path) }
        candidates += names.filter {
            Self.isStray($0, in: clips) && !poolNames.contains(normalized($0)) && !sole.contains(normalized($0))
        }
        .map { (.stray, $0) }

        var items: [Item] = []
        var notFiles: [String] = []
        var kept = Kept(count: 0, bytes: 0)
        for (kind, path) in candidates {
            let url = clips.appending(path: path)
            var info = stat()
            let found = lstat(url.path, &info) == 0
            if found && info.st_mode & S_IFMT != S_IFREG {
                notFiles.append(path)
                continue
            }
            let identity = found ? FileIdentity(info) : nil
            let identities = FileIdentity.both(url.path, lstat: identity)
            let bytes = found ? Int64(info.st_size) : 0
            if own.hold(path, identities) { continue }
            if others.hold(path, identities) {
                kept = Kept(count: kept.count + 1, bytes: kept.bytes + bytes)
                continue
            }
            items.append(Item(kind: kind, path: path, bytes: bytes, identity: identity))
        }
        let ownNames = session.transcriptFiles
        let heldNames = Set((held + keepers).flatMap(\.transcriptFiles))
        for item in try Self.transcriptItems(in: package) {
            guard case .transcript(let name) = item.kind, !ownNames.contains(name) else { continue }
            if heldNames.contains(name) {
                kept = Kept(count: kept.count + 1, bytes: kept.bytes + item.bytes)
            } else {
                items.append(item)
            }
        }
        self.init(
            items: items.sorted { $0.path < $1.path }, kept: kept, damagedBackups: damaged, notFiles: notFiles.sorted(),
            owners: Self.captureOwners(items, in: session, holders: held + keepers))
    }

    init(items: [Item], kept: Kept, damagedBackups: [Backup], notFiles: [String], owners: [CaptureID: Set<FileID>]) {
        self.notFiles = notFiles
        self.items = items
        self.kept = kept
        self.damagedBackups = damagedBackups
        self.owners = owners
    }

    /// Removes the pool entries of the items from `session`, calls `save` with the result, and
    /// only then moves each item to the Trash under the package URL that `save` returns. A crash
    /// between the two steps leaves WAVs with no pool entry. The next scan finds each as a stray
    /// WAV, except a stem WAV whose CAF is gone and whose sidecar has a finalize record: that WAV
    /// comes back as a WAV-backed unplaced segment (decision 0071). A failed save moves nothing
    /// and leaves `session` as it was. The CLI and MCP use this form.
    public func prune(_ session: inout Session, save: (Session) throws(SessionFileError) -> URL)
        throws(UnusedFilesError) -> PruneReport
    {
        try prune(&session, save: save, trash: Self.trash)
    }

    /// `prune` with the async save of `Studio`, in the same order. `save` also gets the items that
    /// move, after the `unused(in:)` filter, so the caller makes the same pool change in memory.
    public func prune(_ session: inout Session, save: (Session, UnusedFiles) async throws(SessionFileError) -> URL)
        async throws(UnusedFilesError) -> PruneReport
    {
        let live = unused(in: session)
        guard let pruned = try live.removingEntries(from: session) else {
            return PruneReport(moved: [], failed: [], dropped: [])
        }
        let package: URL
        do throws(SessionFileError) {
            package = try await save(pruned, live)
        } catch {
            throw .save(error)
        }
        session = pruned
        return live.moved(under: package, trash: Self.trash)
    }

    /// The seam of the failure tests. `trash` returns the Trash URL of the file.
    func prune(
        _ session: inout Session, save: (Session) throws(SessionFileError) -> URL, trash: (URL) throws -> URL
    ) throws(UnusedFilesError) -> PruneReport {
        let live = unused(in: session)
        guard let pruned = try live.removingEntries(from: session) else {
            return PruneReport(moved: [], failed: [], dropped: [])
        }
        let package: URL
        do throws(SessionFileError) {
            package = try save(pruned)
        } catch {
            throw .save(error)
        }
        session = pruned
        return live.moved(under: package, trash: trash)
    }

    /// The pool IDs of `session` that name an item: each pool item, and each entry whose path names
    /// a stray item. An undo or redo entry can name a stray WAV with no clip (decision 0047 D3).
    /// It builds its sets once, so a caller can use it for many sessions (the undo and redo entries).
    public var poolIDs: (Session) -> Set<FileID> {
        let strays = Set(items.filter { $0.kind == .stray }.map { normalized($0.path) })
        let ids = Set(items.compactMap { if case .pool(let id) = $0.kind { id } else { nil } })
        return { session in
            ids.union(session.files.values.filter { strays.contains(normalized($0.path)) }.map(\.id))
        }
    }

    /// The items that `session` still does not use, by the normalized path as the move uses it.
    /// An edit after the scan keeps a pool item that the pool no longer has, a file that a clip now
    /// uses through any pool entry, and a stray WAV that a pool entry now names.
    public func unused(in session: Session) -> UnusedFiles {
        let used = session.filesInUse
        let named = Set(session.files.values.map { normalized($0.path) })
        let usedNames = Set(session.files.values.filter { used.contains($0.id) }.map { normalized($0.path) })
        let transcriptFiles = session.transcriptFiles
        let live = items.filter { item in
            switch item.kind {
            case .pool(let id):
                session.files[id] != nil && !used.contains(id) && !usedNames.contains(normalized(item.path))
            case .stray: !named.contains(normalized(item.path))
            case .transcript(let name): !transcriptFiles.contains(name)
            case .capture: true
            }
        }
        return keeping(
            live,
            owners: owners.filter { capture, ids in
                !session.files.values.contains { $0.capture == capture && !ids.contains($0.id) }
            })
    }

    /// `session` with no pool entry of the items, or nil when there is no item.
    private func removingEntries(from session: Session) throws(UnusedFilesError) -> Session? {
        guard !items.isEmpty else { return nil }
        var pruned = session
        do throws(SessionError) {
            try pruned.removeFiles(poolIDs(session))
        } catch {
            // An in-memory conflict, not a write: only a failed write is a save error.
            throw .changedDuringPrune
        }
        return pruned
    }

    private static func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    /// Moves each item to the Trash under `package`, after the save. The capture files go last,
    /// and only for a capture whose pool items all moved: else the CAF can be the last copy. The
    /// files of a capture go in path order (the CAF, then its sidecar), each only after the earlier
    /// files of its capture left: a CAF with no sidecar can never place.
    private func moved(under package: URL, trash: (URL) throws -> URL) -> PruneReport {
        let clips = package.appending(path: clipsFolderName)
        var moved: [PruneReport.Moved] = []
        var failed: [PruneReport.Failed] = []
        var dropped: [FileID] = []
        var movedPool: Set<FileID> = []
        /// False when the item is still at its path.
        @discardableResult func move(_ item: Item) -> Bool {
            let url: URL =
                switch item.kind {
                case .transcript, .capture: package.appending(path: item.path)
                case .pool, .stray: clips.appending(path: item.path)
                }
            let now = FileIdentity(lstat: url.path)
            guard now != nil || errno != ENOENT else {
                if case .pool(let id) = item.kind { dropped.append(id) }
                return true
            }
            // With another lstat errno, the move runs, and its error gives the true cause.
            if let now, now != item.identity {
                failed.append(PruneReport.Failed(item: item, fault: .replaced))
                return false
            }
            do {
                moved.append(PruneReport.Moved(item: item, trashURL: try trash(url)))
                if case .pool(let id) = item.kind { movedPool.insert(id) }
                return true
            } catch {
                failed.append(PruneReport.Failed(item: item, fault: TrashFault(error)))
                return false
            }
        }
        for item in items {
            if case .capture = item.kind { continue }
            move(item)
        }
        var stuck: Set<CaptureID> = []
        for item in items {
            guard case .capture(let capture) = item.kind, owners[capture]?.isSubset(of: movedPool) == true,
                !stuck.contains(capture)
            else { continue }
            if !move(item) { stuck.insert(capture) }
        }
        return PruneReport(moved: moved, failed: failed, dropped: dropped)
    }

    /// The items that are in both scans, with the kept files, damaged backups, and not-files of `other`. The
    /// confirmation of the app moves only these.
    public func intersection(_ other: UnusedFiles) -> UnusedFiles {
        let others = Set(other.items)
        return other.keeping(items.filter(others.contains), owners: other.owners)
    }

    private static func read(_ url: URL) throws(SessionFileError) -> Session {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .readFailed(errno: posixCode(of: error))
        }
        return try Session(xml: data)
    }

    /// True when the folder of `url`, with its links resolved, is `real` or a folder in it.
    static func staysIn(_ real: String, _ url: URL) -> Bool {
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return folder == real || folder.hasPrefix(real + "/")
    }

    /// A regular file (not a link) with the extension `wav` in any case and no leading `.`.
    private static func isStray(_ name: String, in clips: URL) -> Bool {
        var info = stat()
        return !name.hasPrefix(".") && (name as NSString).pathExtension.lowercased() == "wav"
            && lstat(clips.appending(path: name).path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }
}

/// The names and the file identities of the used files of some sessions.
private struct Holders {
    var names: Set<String> = []
    var identities: Set<FileIdentity> = []

    /// Many entries name the same paths, so each path gets one `lstat` and one `stat`.
    init(_ paths: [String], in clips: URL) {
        for path in Set(paths) {
            names.insert(normalized(path))
            identities.formUnion(FileIdentity.both(clips.appending(path: path).path))
        }
    }

    /// True when the name or an identity matches: when the two tests disagree, the file stays.
    func hold(_ path: String, _ ids: Set<FileIdentity>) -> Bool {
        names.contains(normalized(path)) || !identities.isDisjoint(with: ids)
    }
}

/// The device and the inode of a file.
struct FileIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t

    /// Nil when `lstat` fails; `errno` then has the reason.
    init?(lstat path: String) {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else { return nil }
        (device, inode) = (info.st_dev, info.st_ino)
    }

    /// The identity of the `info` of a `stat` or an `lstat`.
    init(_ info: stat) {
        (device, inode) = (info.st_dev, info.st_ino)
    }

    /// The `lstat` and the `stat` identity, so a link and its target match. A caller that has the
    /// `lstat` identity gives it, so the path gets only the `stat`.
    static func both(_ path: String, lstat known: FileIdentity? = nil) -> Set<FileIdentity> {
        var result = Set([known ?? FileIdentity(lstat: path)].compactMap(\.self))
        var info = stat()
        if stat(path, &info) == 0 { result.insert(FileIdentity(info)) }
        return result
    }
}

/// A pool path or a disk name for a compare: no `.` or empty parts, case folded, and in Unicode
/// canonical composed form (an HFS+ volume or a copied package can give NFD names).
private func normalized(_ path: String) -> String {
    path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
        .folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
}

extension Session {
    /// The pool paths of the files that a clip uses, and of the files of their origin chains.
    fileprivate var usedPaths: [String] { filesInUse.compactMap { files[$0]?.path } }
}
