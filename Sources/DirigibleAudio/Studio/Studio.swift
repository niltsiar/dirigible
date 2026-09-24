import DirigibleCore
import Foundation

/// The facade that the app calls for one open package (decisions 0002 and 0004). It holds the
/// package lock, runs recovery at open, and keeps the pending take.
@MainActor public final class Studio {
    public enum Transport: Hashable, Sendable {
        case idle
        case recording(take: Int)
        case finalizing(take: Int)
    }

    public let url: URL
    public private(set) var transport: Transport = .idle
    public var session: Session { history.session }
    /// Derived, not stored: `session.recording` while the transport is idle (decision 0004).
    public var pendingTake: Recording? { transport == .idle ? session.recording : nil }
    /// The last error of a finalize or of the save after it. Nil after a success.
    public private(set) var takeError: StudioError?
    /// The stems of CAFs with audio that no pool file points to. Open, stop, and retry refresh
    /// it; the disk holds the fact (decision 0012).
    public private(set) var unplacedSegments: [String]
    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    private var history: History
    /// Held for the life of the studio. Dropping the studio releases it.
    private let lock: PackageLock

    private init(url: URL, opened: OpenedPackage) {
        self.url = url
        self.lock = opened.lock
        self.history = History(opened.session)
        self.takeError = opened.takeError
        self.unplacedSegments = opened.unplaced
    }

    /// Opens the package and runs recovery (decision 0004). No file I/O runs on the main actor.
    /// Throws `.locked` when another studio or the CLI has the package.
    public static func open(_ package: URL) async throws(StudioError) -> Studio {
        Studio(url: package, opened: try await openPackage(package))
    }

    /// Runs `body` on a copy of the session and records one undo entry if it changed.
    public func edit<Result>(_ body: (inout Session) throws(SessionError) -> Result) throws(StudioError) -> Result {
        do {
            return try history.edit(body)
        } catch {
            throw .session(error)
        }
    }

    public func undo() throws(StudioError) {
        do { try history.undo() } catch { throw .session(error) }
    }

    public func redo() throws(StudioError) {
        do { try history.redo() } catch { throw .session(error) }
    }

    /// Saves `session.xml` atomically. With a pending take, it writes `<recording>` back.
    public func save() throws(StudioError) {
        do { try session.write(to: url) } catch { throw .file(error) }
    }

    /// Runs finalize again for the pending take (decision 0004). With no pending take, it does
    /// nothing. A success records one undo entry. A failure keeps the take pending and throws.
    public func retryFinalize() async throws(StudioError) {
        guard let take = pendingTake?.take else { return }
        transport = .finalizing(take: take)
        let outcome = await completeTake(of: session, in: url)
        transport = .idle
        takeError = outcome.error
        unplacedSegments = outcome.unplaced
        if let error = outcome.error { throw error }
        history.edit { $0 = outcome.session }
    }
}

public enum StudioError: Error, Hashable, Sendable {
    /// Another studio or the CLI has the package.
    case locked
    case session(SessionError)
    case file(SessionFileError)
    case finalize(FinalizeError)
}
