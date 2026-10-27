import Foundation

/// Why a file did not move to the Trash: the domain and the code of the `trashItem` error. The
/// error of a refused move has no POSIX code under it (probe U2: NSCocoaErrorDomain 513 over
/// NSOSStatusErrorDomain -5000).
public struct TrashFault: Hashable, Sendable {
    public let domain: String
    public let code: Int

    init(domain: String, code: Int) {
        (self.domain, self.code) = (domain, code)
    }

    init(_ error: any Error) {
        let error = error as NSError
        self.init(domain: error.domain, code: error.code)
    }

    /// Another file took the place of the file of the scan, so the prune did not move it.
    public static let replaced = TrashFault(domain: "Dirigible.UnusedFiles", code: 1)
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
    /// `Transcripts/` gave a read error other than ENOENT (decision 0055).
    case transcriptsUnreadable(errno: Int32)
    /// The `session.xml` on the disk does not read: the scan cannot know its clips.
    case sessionUnreadable(SessionFileError)
    /// A backup of a newer version, or with a read errno. The block stays until that backup goes.
    case backupUnreadable(Backup, SessionFileError)
    /// The save before the Trash failed, so no file moved.
    case save(SessionFileError)
    /// An edit after the scan conflicts with a listed file. During the prune save (`Studio`), the
    /// save wrote the session before that edit, no file moved, and the autosave of the edit
    /// writes it.
    case changedDuringPrune
}
