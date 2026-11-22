import DirigibleAudio
import DirigibleCore
import Foundation

extension SessionImportError {
    /// The text of an import of `source` into `package` that changed nothing, with the paths as
    /// the caller gave them. No `default` case: a new error case does not compile until it has a message.
    package func message(source: String, package: String) -> String {
        switch self {
        case .offsetOutOfRange(let at):
            "the offset \(at) is outside -2^40...2^40 frames. Give an offset in -\(1 << 40)...\(1 << 40)."
        case .targetSampleRateOutOfRange(let rate):
            "the sample rate \(rate) Hz of \(package) is outside 8000...384000 Hz, so Dirigible does not import a "
                + "session into it."
        case .sampleRateOutOfRange(let rate):
            "the sample rate \(rate) Hz is outside 8000...384000 Hz, so Dirigible does not import \(source)."
        case .sameSession:
            "\(source) is the same session as \(package), so Dirigible does not import it. Give a different source."
        case .takeNotFinalized: pendingTakeMessage(source)
        case .nothingToImport:
            "\(source) has no clip to import. Give a session with a clip, or an --at value that keeps one."
        case .source(let error): error.message(package: source)
        case .unsafeFile(let path):
            "\(source)/Clips/\(path) is a link, a folder, or a path through a link, so Dirigible does not import "
                + "\(source). Replace that item with a plain file."
        case .paste(.sourceMissing(let file)):
            "the source file \"\(file)\" is not there: \(source) moved, or the file was deleted."
        case .paste(.space(let needed, let free)): "the import needs \(needed) free bytes, and the disk has \(free)."
        case .paste(.cancelled): "the import was cancelled."
        case .paste(let error): error.message
        }
    }
}
