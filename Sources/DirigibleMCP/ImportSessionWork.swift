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

    /// Why `run` changed nothing: the target package that the lock holds is gone, or the import
    /// refused.
    package enum Failure: Error, Hashable {
        case target(SessionFileError)
        case refused(SessionImportError)

        /// The text, with the paths as the caller gave them.
        package func message(source: String, package: String) -> String {
            switch self {
            case .target(let error): error.message(package: package)
            case .refused(let error): error.message(source: source, package: package)
            }
        }

        /// The exit code: 2 for a target fault, else the code of the refusal.
        package var exitCode: Int32 {
            switch self {
            case .target: 2
            case .refused(let error): ImportSessionWork.exitCode(error)
            }
        }
    }

    /// The exit code of a refusal: 64 for an offset out of its range, 1 for an import that the
    /// session refuses, and 2 for a fault of the source or of the files.
    package static func exitCode(_ error: SessionImportError) -> Int32 {
        switch error {
        case .offsetOutOfRange: 64
        case .sameSession, .nothingToImport, .paste(.session): 1
        case .targetSampleRateOutOfRange, .sampleRateOutOfRange, .takeNotFinalized, .source, .unsafeFile, .paste: 2
        }
    }

    /// The lines of an import: the new track IDs in source order, then `marker <ID>` for each new
    /// marker, then the count of the markers left out when there is one.
    package static func lines(_ imported: SessionImported) -> [String] {
        let left = imported.leftOutMarkers
        return imported.tracks.map(\.rawValue) + imported.markers.map { "marker \($0.rawValue)" }
            + (left > 0 ? ["Left out: \(left) marker\(left == 1 ? "" : "s") before frame 0 or after frame 2^40."] : [])
    }

    /// The import into `session` under `lock`. A cancel that comes after `importSession` returns
    /// removes the new WAVs, so the save writes nothing (decision 0049).
    package func run(
        _ session: inout Session, lock: PackageLock, package: URL, progress: @escaping (Double) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) throws(Failure) -> SessionImported {
        let target: URL
        do throws(SessionFileError) { target = try lock.package() } catch { throw .target(error) }
        let imported: SessionImported
        do throws(SessionImportError) {
            imported = try importSession(
                from: url, into: session, in: target, identity: lock.identity, at: at, markers: markers,
                freeBytes: { lock.freeBytes() }, progress: progress, isCancelled: isCancelled)
        } catch {
            throw .refused(error)
        }
        if isCancelled() {
            removeMadeFiles(imported.made)
            throw .refused(.paste(.cancelled))
        }
        session = imported.session
        return imported
    }

    /// The job of a tool call on the files, under the package lock. The text is `lines`, then the
    /// take sync note.
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        do throws(EditFailure<Failure>) {
            let (imported, note) = try editPackageCore(package, ripple: false, touchesClips: true, log: control.log) {
                session, lock throws(Failure) in
                try TakeWork.noted(&session, package: package) { session throws(Failure) in
                    try run(
                        &session, lock: lock, package: package, progress: { control.report($0) },
                        isCancelled: { control.isCancelled() })
                }
            }
            return (Self.lines(imported) + note).joined(separator: "\n")
        } catch {
            let message =
                switch error {
                case .body(let error): error.message(source: source, package: path)
                case .file(let error): error.message(package: path)
                case .pendingTake: pendingTakeMessage(path)
                case .splitTake: splitTakeMessage(path)
                case .archive(let fault): fault.message(package: path)
                }
            throw ToolError(message)
        }
    }
}
