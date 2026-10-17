import DirigibleAudio
import DirigibleCore
import Foundation

/// The work of an `import` call after its arguments are checked (decisions 0040 and 0049). It is
/// the one owner of the texts of `dirigible import` and the `import` tool. On the files it runs
/// `importAudio` under the package lock; in the app, `liveJob` runs `Studio.importAudio`.
package struct ImportWork: Sendable {
    /// The audio file, as the caller gave it: the tool takes an absolute path.
    let file: String
    let target: ImportTarget
    let level: Bool

    var url: URL { URL(filePath: file) }

    /// The text of an import of `file` into `package` that changed nothing.
    package static func message(_ error: ImportError, file: String, package: String) -> String {
        switch error {
        case .notAudio: "\(file) is not an audio file that Dirigible can read."
        case .notDownloaded: "\(file) is not on this Mac. Download the file first."
        case .tooManyChannels(_, let channels):
            "\(file) has \(channels) channels; Dirigible imports only mono and stereo files."
        case .unreadable(_, let code): "cannot read \(file): \(String(cString: strerror(code)))."
        case .space(_, let needed, let free):
            "the import needs \(needed) bytes free on the disk of \(package); \(free) bytes are free."
        case .write(_, let error): StudioError.finalize(error).message(package: package)
        case .session(let error): error.message
        case .cancelled: "the import was cancelled."
        }
    }

    /// The job of a tool call on the files, under the package lock. The cancel read before the
    /// save removes the WAV and writes nothing (decision 0049).
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        do throws(EditFailure<ImportError>) {
            return try editPackageCore(package, ripple: false) { session, lock throws(ImportError) -> ClipID in
                let imported = try importAudio(
                    url, to: target, of: session, in: package, level: level, freeBytes: { lock.freeBytes() },
                    progress: { control.report($0) }, isCancelled: { control.isCancelled() })
                if control.isCancelled() {
                    removeMadeFiles([imported.made].compactMap { $0 })
                    throw .cancelled
                }
                session = imported.session
                return imported.clip
            }.rawValue
        } catch {
            let message =
                switch error {
                case .body(let error): Self.message(error, file: file, package: path)
                case .file(let error): error.message(package: path)
                case .pendingTake: pendingTakeMessage(path)
                case .splitTake: splitTakeMessage(path)
                }
            throw ToolError(message)
        }
    }
}
