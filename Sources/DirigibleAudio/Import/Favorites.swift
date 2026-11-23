import DirigibleCore
import Foundation

/// The Favorites store (F23, decision 0081): one session package for all sessions, at 48000 Hz.
/// Its bins are the favorite groups, and it holds its own copy of each file. Each write is one
/// `editPackageCore` of the store: the lock, a fresh read of `session.xml`, the edit by ID, the
/// write. So an edit from an old list cannot drop an item that another writer added.
package enum Favorites {
    package static let sampleRate = 48_000
    /// The name of the bin that the first add makes in an empty store.
    static let firstBinName = "Favorites"
    /// The source frames at each edge of a converted run, so that the converter reads the same input
    /// around each played frame as in a conversion of the whole file.
    static let conversionMargin = Frames(2048)

    /// `DIRIGIBLE_FAVORITES` when it is set (the CLI test children and the launch scripts), else
    /// `Favorites.dirigible` in the Application Support folder of the bundle ID.
    package static func package(environment: [String: String]) -> URL {
        if let path = environment["DIRIGIBLE_FAVORITES"], !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return URL.applicationSupportDirectory.appending(
            path: "com.delineas.dirigible/Favorites.dirigible", directoryHint: .isDirectory)
    }

    /// `.store` for a write of the store of this process, else `.standard`. Both URLs are standardized
    /// and symlink-resolved, so `dirigible bin` and the `bin_*` tools get the policy of the store
    /// whatever spelling of its path they get (decision 0081).
    package static func backups(for package: URL, environment: [String: String]) -> BackupPolicy {
        func resolved(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
        return resolved(package) == resolved(Favorites.package(environment: environment)) ? .store : .standard
    }

    /// Copies the frames that the clips of `clipboard` play (`Excerpt.cropped`) from `source` into the
    /// store with `copyExcerptFiles`, adds its excerpt as an item named `name` at the end of `bin`,
    /// and returns the new item ID. With no
    /// `bin`, the item goes to the first bin, which an empty store makes as "Favorites". It makes
    /// the store folder and each missing parent folder first, and never calls `Session.create`. It
    /// blocks: never call it on the main actor.
    package static func add(
        _ clipboard: Clipboard, from source: URL, named name: String, bin: BinID?, store: URL,
        log: () -> DiagnosticLog, progress: @escaping (Double) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) throws(EditFailure<PasteError>) -> BinItemID {
        do {
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        } catch {
            throw .file(.writeFailed(step: "createDirectory", errno: posixCode(of: error) ?? EIO))
        }
        // One ID for both runs of `place`, so the returned ID is the stored one.
        let (id, newBin) = (BinItemID(), BinID())
        let empty = { Session(sampleRate: sampleRate) }
        return try editPackageCore(store, ripple: false, backups: .store, log: log, whenMissing: empty) {
            session, lock throws(PasteError) in
            let target: URL
            do throws(SessionFileError) {
                target = try lock.package()
            } catch {
                throw .write(file: store.lastPathComponent, errno: ENOENT)
            }
            let rate = clipboard.excerpt.sampleRate
            let (excerpt, spans) =
                PackageID.same(clipboard.origin, lock.identity)
                ? (clipboard.excerpt, [:])
                : clipboard.excerpt.cropped(
                    grid: rate / greatestCommonDivisor(rate, sampleRate),
                    margin: rate == sampleRate ? .zero : conversionMargin)
            let added = try copyExcerptFiles(
                Clipboard(excerpt, package: clipboard.package, origin: clipboard.origin), from: source, into: session,
                in: target, identity: lock.identity, spans: spans, freeBytes: { lock.freeBytes() },
                canClone: { cloneWorks($0, into: $1) }, progress: progress, isCancelled: isCancelled,
                flush: NewClipFiles.flushToDisk
            ) { session, excerpt throws(SessionError) in
                let into: BinID
                if let given = bin ?? session.bins.first?.id {
                    into = given
                } else {
                    into = try session.addBin(newBin, named: firstBinName)
                }
                return try session.addItem(excerpt, named: name, to: into, id: id)
            }
            session = added.session
            return added.value
        }
    }

    static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int { b == 0 ? a : greatestCommonDivisor(b, a % b) }

    /// Runs `body` on the store session under its lock, and writes the store when `body` changed it:
    /// a rename, a remove, or a new group by `BinID` or `BinItemID`. A throw writes nothing.
    package static func edit<Result>(
        store: URL, log: () -> DiagnosticLog, _ body: (inout Session) throws(SessionError) -> Result
    ) throws(EditFailure<SessionError>) -> Result {
        try editPackageCore(store, ripple: false, writeUnchanged: false, backups: .store, log: log) {
            session, _ throws(SessionError) in
            try body(&session)
        }
    }
}
