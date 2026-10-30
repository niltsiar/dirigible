import Foundation
import os

/// The hint of decision 0004: the packages whose `session.xml` has `<recording>`, so that the app
/// can open them again at launch. `session.xml` stays the truth. The file is a plist array of
/// paths in `packageIdentity` form. A lock in the process and the file lock `active-recordings.lock`
/// beside the list guard each read-modify-write, and each write is atomic. One `set` waits at
/// most 1 s for both locks; after that, the write goes on with no lock. A file error
/// is logged, not thrown: a lost hint loses only the reopen at launch. Every call runs off the main
/// actor, so the main actor never waits on the lock.
public struct ActiveRecordings: Sendable {
    public let file: URL
    private static let lock = NSLock()
    private static let log = Logger(subsystem: "com.delineas.dirigible", category: "active-recordings")

    public init(file: URL) { self.file = file }

    /// The list of the app with `bundleID` in the Application Support folder `support`.
    public static func file(bundleID: String, support: URL) -> URL {
        support.appending(path: "\(bundleID)/active-recordings.plist")
    }

    /// The listed packages. A missing or bad file lists none.
    public func packages() -> [URL] {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return Self.lock.withLock { read() }.map { URL(filePath: $0) }
    }

    /// Lists `package` when `active`, else removes it. It also removes `previous`, the path before
    /// a move. The first read takes no lock, so a call with no change writes nothing, takes no
    /// lock, and does not wait. Else it makes the parent folder (a first launch has none, and the
    /// lock file goes there), takes the locks, reads again, and writes.
    func set(_ package: URL, active: Bool, previous: URL? = nil) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        func changed(_ paths: [String]) -> [String] {
            var next = paths.filter { $0 != package.path && $0 != previous?.path }
            if active { next.append(package.path) }
            return next
        }
        let first = read()
        guard changed(first) != first else { return }
        let end = ContinuousClock.now + .seconds(1)
        let locked = Self.lock.lock(before: Date(timeIntervalSinceNow: 1))
        defer { if locked { Self.lock.unlock() } }
        if !locked { Self.log.error("No process lock of \(file.path, privacy: .public) after 1 s") }
        let folder = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Self.log.error("No folder \(folder.path, privacy: .public): \(error, privacy: .public)")
        }
        let descriptor = lockFile(in: folder, until: end)
        defer { if let descriptor { close(descriptor) } }
        let paths = read()
        let next = changed(paths)
        guard next != paths else { return }
        do {
            try PropertyListEncoder().encode(next).write(to: file, options: .atomic)
        } catch {
            Self.log.error("No write of \(file.path, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// Opens `active-recordings.lock` in `folder` with an exclusive lock, which another process
    /// takes for its own read-modify-write. While another process holds it, the call tries again
    /// each 10 ms until `end`. On a timeout or a failed open, it logs one error and returns nil.
    private func lockFile(in folder: URL, until end: ContinuousClock.Instant) -> Int32? {
        let path = folder.appending(path: "active-recordings.lock").path
        while true {
            let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o644)
            if descriptor >= 0 { return descriptor }
            let code = errno
            guard code == EWOULDBLOCK, ContinuousClock.now < end else {
                Self.log.error("No lock of \(path, privacy: .public): errno \(code, privacy: .public)")
                return nil
            }
            usleep(10_000)
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
