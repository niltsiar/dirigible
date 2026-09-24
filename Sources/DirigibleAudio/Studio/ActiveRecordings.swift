import Foundation
import os

/// The hint of decision 0004: the packages whose `session.xml` has `<recording>`, so that the app
/// can open them again at launch. `session.xml` stays the truth. The file is a plist array of
/// paths in `packageIdentity` form. One lock for the process guards each read-modify-write, and
/// each write is atomic. A file error is logged, not thrown: a lost hint loses only the reopen at
/// launch. Every call runs off the main actor, so the main actor never waits on the lock.
public struct ActiveRecordings: Sendable {
    public let file: URL
    private static let lock = NSLock()
    private static let log = Logger(subsystem: "com.delineas.dirigible", category: "active-recordings")

    public init(file: URL) { self.file = file }

    /// The listed packages. A missing or bad file lists none.
    public func packages() -> [URL] {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return Self.lock.withLock { read() }.map { URL(filePath: $0) }
    }

    /// Lists `package` when `active`, else removes it. It also removes `previous`, the path before
    /// a move. With no change, it writes nothing. The write makes the parent folder first: a first
    /// launch has none.
    func set(_ package: URL, active: Bool, previous: URL? = nil) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        Self.lock.withLock {
            let paths = read()
            var next = paths.filter { $0 != package.path && $0 != previous?.path }
            if active { next.append(package.path) }
            guard next != paths else { return }
            do {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PropertyListEncoder().encode(next).write(to: file, options: .atomic)
            } catch {
                Self.log.error("No write of \(file.path, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    private func read() -> [String] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        do {
            return try PropertyListDecoder().decode([String].self, from: data)
        } catch {
            Self.log.error("No read of \(file.path, privacy: .public): \(error, privacy: .public)")
            return []
        }
    }
}

/// The one spelling of a package path: `F_GETPATH` gives `/private/var` where the open had
/// `/var`, and a symbolic link names the same package. It reads the file system.
public func packageIdentity(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
