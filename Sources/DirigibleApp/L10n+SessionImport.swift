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
        case .source: return errorImportSessionSource.format(source)
        case .unsafeFile(let path): return errorImportSessionFile.format(source, path)
        case .paste(let error): return message(forImport: error, source: source)
        }
    }

    /// The line under the title of a refusal that names the source session: the reason, then the next
    /// step. Nil for a refusal whose title says all.
    static func detail(for error: SessionImportError) -> String? {
        switch error {
        case .source(let error): message(for: error)
        case .paste(.notDownloaded(let file)): errorImportNotDownloaded.format(file)
        default: nil
        }
    }

    /// The text of a copy fault of a session import: the words of the import, not of a paste. The
    /// window shows no alert for a cancel.
    private static func message(forImport error: PasteError, source: String) -> String {
        switch error {
        case .sourceMissing, .sourceUnreadable: errorImportSessionMissing.format(source)
        case .sourceChanged: errorImportSessionChanged.format(source)
        case .notDownloaded: errorImportSessionSource.format(source)
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

    /// The banner of a window import: the muted call tracks and the markers that were left out, each in its
    /// own row when there is one. The tracks show in the window, so the banner does not count them.
    /// `table` gives the format of a key: the tests read the tables.
    static func sessionImportCheck(muted: Int, leftOut: Int, table: (L10n) -> String = { $0.text }) -> String {
        var parts: [String] = []
        if muted > 0 {
            parts.append(counted(muted, one: .importSessionMutedOne, many: .importSessionMutedOther, text: table))
        }
        if leftOut > 0 {
            parts.append(counted(leftOut, one: .importSessionLeftOutOne, many: .importSessionLeftOutOther, text: table))
        }
        return parts.joined(separator: "\n")
    }
}
