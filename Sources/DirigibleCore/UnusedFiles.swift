import Foundation

/// The clip files that no clip uses (decision 0047): the pool entries that no clip of the session
/// uses, and the stray WAVs at the top level of `Clips/` that no pool path names. A file that a
/// clip of a keeper uses stays: the `session.xml` on the disk (the prune save can make it a
/// backup), each readable backup, and the keepers that the caller gives (the undo and redo
/// entries, the clipboard files). The scan is the one place of this rule.
public struct UnusedFiles: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case pool(FileID)
            case stray
        }
        public let kind: Kind
        /// Relative to `Clips/`.
        public let path: String
        public let bytes: Int64
        /// The `lstat` identity at the scan, nil for a missing file. A file that another file
        /// replaced at the path is another item, so an intersection drops it.
        let identity: FileIdentity?
    }
    /// The files that a clip of a keeper uses, which the list does not have.
    public struct Kept: Hashable, Sendable {
        public let count: Int
        public let bytes: Int64
    }
    /// Sorted by path.
    public let items: [Item]
    public let kept: Kept
    /// The backups that the reader refused as damaged XML: they keep no file.
    public let damagedBackups: [Backup]

    /// Reads `Clips/`, `session.xml`, and `Backups/` of `package`. `keptFiles` are the pool paths
    /// of the files that the app clipboard of the same package uses. Throws for an unreadable
    /// `Clips/` or `session.xml`, and for a backup of a newer version or with a read errno: the
    /// scan cannot know its clips.
    public init(scanning session: Session, keptBy keepers: [Session], keptFiles: [String] = [], in package: URL)
        throws(UnusedFilesError)
    {
        let clips = package.appending(path: clipsFolderName)
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
                case .unsupportedVersion, .readFailed: throw .backupUnreadable(backup, error)
                default: damaged.append(backup)
                }
            }
        }
        let own = Holders(session.usedPaths, in: clips)
        let others = Holders((held + keepers).flatMap(\.usedPaths) + keptFiles, in: clips)
        let poolNames = Set(session.files.values.map { normalized($0.path) })
        let used = Set(session.tracks.flatMap { $0.clips.map(\.file) })
        let realClips = clips.resolvingSymlinksInPath().path

        var candidates: [(Item.Kind, String)] = session.files.values
            .filter { !used.contains($0.id) && Self.staysIn(realClips, clips.appending(path: $0.path)) }
            .map { (.pool($0.id), $0.path) }
        candidates += names.filter { Self.isStray($0, in: clips) && !poolNames.contains(normalized($0)) }
            .map { (.stray, $0) }

        var items: [Item] = []
        var kept = Kept(count: 0, bytes: 0)
        for (kind, path) in candidates {
            let url = clips.appending(path: path)
            let identities = FileIdentity.both(url.path)
            var info = stat()
            let bytes = lstat(url.path, &info) == 0 ? Int64(info.st_size) : 0
            if own.hold(path, identities) { continue }
            if others.hold(path, identities) {
                kept = Kept(count: kept.count + 1, bytes: kept.bytes + bytes)
                continue
            }
            items.append(Item(kind: kind, path: path, bytes: bytes, identity: FileIdentity(lstat: url.path)))
        }
        self.init(items: items.sorted { $0.path < $1.path }, kept: kept, damagedBackups: damaged)
    }

    private init(items: [Item], kept: Kept, damagedBackups: [Backup]) {
        self.items = items
        self.kept = kept
        self.damagedBackups = damagedBackups
    }

    /// Removes the pool entries of the items from `session`, calls `save` with the result, and
    /// only then moves each item to the Trash under the package URL that `save` returns. The one
    /// place of this order: a crash between the two steps leaves stray WAVs that the next scan
    /// finds. A failed save moves nothing and leaves `session` as it was.
    public func prune(_ session: inout Session, save: (Session) async throws(SessionFileError) -> URL)
        async throws(UnusedFilesError) -> PruneReport
    {
        try await prune(&session, save: save) { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return (result as URL?) ?? url
        }
    }

    /// The seam of the failure tests. `trash` returns the Trash URL of the file.
    func prune(
        _ session: inout Session, save: (Session) async throws(SessionFileError) -> URL, trash: (URL) throws -> URL
    ) async throws(UnusedFilesError) -> PruneReport {
        guard !items.isEmpty else { return PruneReport(moved: [], failed: [], dropped: []) }
        var pruned = session
        do throws(SessionError) {
            for case .pool(let id) in items.map(\.kind) { try pruned.removeFile(id) }
        } catch {
            throw .save(.invalidSession(error))
        }
        let package: URL
        do throws(SessionFileError) {
            package = try await save(pruned)
        } catch {
            throw .save(error)
        }
        session = pruned
        let clips = package.appending(path: clipsFolderName)
        var moved: [PruneReport.Moved] = []
        var failed: [PruneReport.Failed] = []
        var dropped: [FileID] = []
        for item in items {
            let url = clips.appending(path: item.path)
            guard FileIdentity(lstat: url.path) != nil || errno != ENOENT else {
                if case .pool(let id) = item.kind { dropped.append(id) }
                continue
            }
            do {
                moved.append(PruneReport.Moved(item: item, trashURL: try trash(url)))
            } catch {
                failed.append(PruneReport.Failed(item: item, fault: TrashFault(error)))
            }
        }
        return PruneReport(moved: moved, failed: failed, dropped: dropped)
    }

    /// The items that are in both scans, with the kept files and damaged backups of `other`. The
    /// confirmation of the app moves only these.
    public func intersection(_ other: UnusedFiles) -> UnusedFiles {
        let others = Set(other.items)
        return UnusedFiles(items: items.filter(others.contains), kept: other.kept, damagedBackups: other.damagedBackups)
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

    /// True when the folder of `url`, with its links resolved, is `Clips/` or a folder in it.
    private static func staysIn(_ realClips: String, _ url: URL) -> Bool {
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return folder == realClips || folder.hasPrefix(realClips + "/")
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

    init(_ paths: [String], in clips: URL) {
        for path in paths {
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

    private init(device: dev_t, inode: ino_t) {
        (self.device, self.inode) = (device, inode)
    }

    /// The `lstat` and the `stat` identity, so a link and its target match.
    static func both(_ path: String) -> Set<FileIdentity> {
        var result = Set([FileIdentity(lstat: path)].compactMap(\.self))
        var info = stat()
        if stat(path, &info) == 0 { result.insert(FileIdentity(device: info.st_dev, inode: info.st_ino)) }
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
    /// The pool paths of the files that a clip uses.
    fileprivate var usedPaths: [String] { tracks.flatMap { $0.clips.compactMap { files[$0.file]?.path } } }
}

/// Why a file did not move to the Trash: the domain and the code of the `trashItem` error. The
/// error of a refused move has no POSIX code under it (probe U2: NSCocoaErrorDomain 513 over
/// NSOSStatusErrorDomain -5000).
public struct TrashFault: Hashable, Sendable {
    public let domain: String
    public let code: Int

    public init(domain: String, code: Int) {
        (self.domain, self.code) = (domain, code)
    }

    init(_ error: any Error) {
        let error = error as NSError
        self.init(domain: error.domain, code: error.code)
    }
}

/// The result of `UnusedFiles.prune`.
public struct PruneReport: Hashable, Sendable {
    public struct Moved: Hashable, Sendable {
        public let item: UnusedFiles.Item
        public let trashURL: URL
    }
    public struct Failed: Hashable, Sendable {
        public let item: UnusedFiles.Item
        public let fault: TrashFault
    }
    public let moved: [Moved]
    /// The files that stayed in `Clips/`. Their pool entries are gone, so the next scan lists them
    /// as stray WAVs.
    public let failed: [Failed]
    /// The pool entries whose file was not on the disk: not a failure.
    public let dropped: [FileID]
}

public enum UnusedFilesError: Error, Hashable, Sendable {
    case clipsUnreadable(errno: Int32)
    /// The `session.xml` on the disk does not read: the scan cannot know its clips.
    case sessionUnreadable(SessionFileError)
    /// A backup of a newer version, or with a read errno. The block stays until that backup goes.
    case backupUnreadable(Backup, SessionFileError)
    /// The save before the Trash failed, so no file moved.
    case save(SessionFileError)
}
