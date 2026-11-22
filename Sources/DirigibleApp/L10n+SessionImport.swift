import DirigibleAudio
import DirigibleCore
import Foundation

extension L10n {
    /// The text of a session import error, with `source` the name of the source session (decision 0075).
    static func message(for error: SessionImportError, source: String) -> String {
        switch error {
        // The window imports at offset 0, and the CLI and the tool have their own texts.
        case .offsetOutOfRange: return errorSessionOther.text
        case .targetSampleRateOutOfRange(let rate): return errorImportSessionTargetRate.format(rate)
        case .sampleRateOutOfRange(let rate): return errorImportSessionRate.format(source, rate)
        case .sameSession: return errorImportSessionSame.text
        case .takeNotFinalized: return errorImportSessionPending.format(source)
        case .nothingToImport: return errorImportSessionEmpty.format(source)
        case .source(let error): return errorImportSessionSource.format(source, message(for: error))
        case .unsafeFile(let path): return errorImportSessionFile.format(source, path)
        case .paste(let error): return message(forImport: error, source: source)
        }
    }

    /// The text of a copy fault of a session import: the words of the import, not of a paste. The
    /// window shows no alert for a cancel.
    private static func message(forImport error: PasteError, source: String) -> String {
        switch error {
        case .sourceMissing: errorImportSessionMissing.format(source)
        case .sourceChanged: errorImportSessionChanged.format(source)
        case .notDownloaded(let file): errorImportNotDownloaded.format(file)
        case .space, .write(_, ENOSPC): errorImportSessionSpace.format(source)
        case .write(_, let code): errorImportSessionCopy.format(source, Int(code))
        case .convert(_, let code): errorImportSessionConvert.format(source, Int(code))
        case .session(let error): message(for: error, name: { $0.rawValue })
        case .cancelled: errorSessionOther.text
        }
    }

    /// The result line of a window import (C16): the count of new tracks, then the count of muted
    /// call tracks and the count of markers left out, each when there is one. `table` gives the
    /// format of a key: the tests read the tables.
    static func sessionImportLine(
        tracks: Int, muted: Int, leftOut: Int, table: (L10n) -> String = { $0.text }
    ) -> String {
        func count(_ one: L10n, _ other: L10n, _ value: Int) -> String {
            value == 1 ? table(one) : String(format: table(other), locale: .current, value)
        }
        var line = count(.importSessionAddedOne, .importSessionAddedOther, tracks)
        if muted > 0 { line += " " + count(.importSessionMutedOne, .importSessionMutedOther, muted) }
        if leftOut > 0 { line += " " + count(.importSessionLeftOutOne, .importSessionLeftOutOther, leftOut) }
        return line
    }
}
