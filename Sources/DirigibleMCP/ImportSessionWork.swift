import DirigibleAudio
import DirigibleCore
import Foundation

/// The work of an `import-session` call after its arguments are checked (decisions 0075 and 0049).
/// It is the one owner of the texts and the exit codes of `dirigible import-session` and the
/// `import_session` tool. On the files it runs `importSession` under the target lock; in the app,
/// `liveJob` runs `Studio.importSession`.
package struct ImportSessionWork: Sendable {
    /// The source package, as the caller gave it.
    package let source: String
    package let at: Int
    package let markers: Bool

    package init(source: String, at: Int, markers: Bool) {
        (self.source, self.at, self.markers) = (source, at, markers)
    }

    var url: URL { URL(filePath: source) }

    /// The exit code of a refusal: 64 for an offset out of its range, 1 for an import that the
    /// session refuses, and 2 for a fault of the source or of the files.
    package static func exitCode(_ error: SessionImportError) -> Int32 {
        switch error {
        case .offsetOutOfRange: 64
        case .sameSession, .nothingToImport, .paste(.session): 1
        case .targetSampleRateOutOfRange, .sampleRateOutOfRange, .takeNotFinalized, .source, .unsafeFile, .paste: 2
        }
    }

    /// The import into `session` under `lock`. A cancel that comes after `importSession` returns
    /// removes the new WAVs, so the save writes nothing (decision 0049).
    package func run(
        _ session: inout Session, lock: PackageLock, package: URL, progress: @escaping (Double) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) throws(SessionImportError) -> [TrackID] {
        let target: URL
        do throws(SessionFileError) {
            target = try lock.package()
        } catch {
            // The target left its volume or was deleted after the lock: no file copies.
            throw .paste(.write(file: package.lastPathComponent, errno: ENOENT))
        }
        let imported = try importSession(
            from: url, into: session, in: target, identity: lock.identity, at: at, markers: markers,
            freeBytes: { lock.freeBytes() }, progress: progress, isCancelled: isCancelled)
        if isCancelled() {
            removeMadeFiles(imported.made)
            throw .paste(.cancelled)
        }
        session = imported.session
        return imported.tracks
    }

    /// The job of a tool call on the files, under the package lock. The text is the new track IDs,
    /// one per line, in source order.
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        do throws(EditFailure<SessionImportError>) {
            let (tracks, note) = try editPackageCore(package, ripple: false, log: control.log) {
                session, lock throws(SessionImportError) in
                try TakeWork.noted(&session, package: package) { session throws(SessionImportError) in
                    try run(
                        &session, lock: lock, package: package, progress: { control.report($0) },
                        isCancelled: { control.isCancelled() })
                }
            }
            return (tracks.map(\.rawValue) + note).joined(separator: "\n")
        } catch {
            let message =
                switch error {
                case .body(let error): error.message(source: source, package: path)
                case .file(let error): error.message(package: path)
                case .pendingTake: pendingTakeMessage(path)
                case .splitTake: splitTakeMessage(path)
                }
            throw ToolError(message)
        }
    }
}
