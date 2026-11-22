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
        case .paste(let error): return message(for: error, source: source)
        }
    }

    /// The result line of a window import (C16): the count of new tracks, then the count of muted
    /// call tracks when there is one. `table` gives the format of a key: the tests read the tables.
    static func sessionImportLine(tracks: Int, muted: Int, table: (L10n) -> String = { $0.text }) -> String {
        func count(_ one: L10n, _ other: L10n, _ value: Int) -> String {
            value == 1 ? table(one) : String(format: table(other), locale: .current, value)
        }
        let added = count(.importSessionAddedOne, .importSessionAddedOther, tracks)
        guard muted > 0 else { return added }
        return added + " " + count(.importSessionMutedOne, .importSessionMutedOther, muted)
    }
}
