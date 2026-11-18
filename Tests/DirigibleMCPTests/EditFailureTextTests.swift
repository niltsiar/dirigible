import DirigibleAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleMCP

/// The text of an `EditFailure` for each body (decision 0041): the pending take, the split take,
/// and the file error give the same text for each body, and the body gives its own. The literals
/// are written out, so a swapped case or a changed text fails.
struct EditFailureTextTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let pending, split, body, file: String
        let bodyText: String
        var testDescription: String { name }
    }

    static func row<Body: Error>(
        _ name: String, _ body: Body, text bodyText: String, _ message: (EditFailure<Body>) -> String
    ) -> Row {
        Row(
            name: name, pending: message(.pendingTake), split: message(.splitTake), body: message(.body(body)),
            file: message(.file(.malformedXML)), bodyText: bodyText)
    }

    static let pending = "p.dirigible has a take that is not finalized; open it in Dirigible first."
    static let split =
        "p.dirigible has a take with some segments on the timeline and some not. A ripple moves the timeline "
        + "under the other segments, so place them first (dirigible capture place)."
    static let file = "p.dirigible/session.xml is not a Dirigible session file."

    static let rows: [Row] = [
        row("SessionError", SessionError.unknownTrack("t9"), text: "no track \"t9\".") {
            $0.message(package: "p.dirigible")
        },
        row("LevelFailure", LevelFailure.cancelled, text: "the level was cancelled.") {
            $0.message(package: "p.dirigible")
        },
        row("PasteError", PasteError.cancelled, text: "the paste was cancelled.") {
            $0.message(package: "p.dirigible")
        },
        row("MarkerEditError", MarkerEditError.incomplete, text: "a new marker needs a name and a position.") {
            $0.message(package: "p.dirigible")
        },
        row(
            "ArtworkError", ArtworkError.unreadable(file: "a.png"),
            text: "the artwork file \"a.png\" does not open as an image."
        ) { $0.message(package: "p.dirigible") },
        row(
            "UnusedFilesError", UnusedFilesError.changedDuringPrune,
            text: "an edit during the prune uses a listed file. No file moved."
        ) { $0.message(package: "p.dirigible") },
        row("RevertError", RevertError.session(.unknownTrack("t9")), text: "no track \"t9\".") {
            $0.message(package: "p.dirigible")
        },
        row("StudioError", StudioError.busy, text: "p.dirigible is busy with a take.") {
            $0.message(package: "p.dirigible")
        },
        row("TranscribeFailure", TranscribeFailure.cancelled, text: "the transcription was cancelled.") {
            $0.message(package: "p.dirigible")
        },
        row("TakeImportError", TakeImportError.session(.unknownTrack("t9")), text: "no track \"t9\".") {
            $0.message(package: "p.dirigible")
        },
        row("DuckFailure", DuckFailure.cancelled, text: "the duck was cancelled.") {
            $0.message(package: "p.dirigible")
        },
        row(
            "BatchWork.Failure", BatchWork.Failure(index: 0, tool: "cut", cause: .rippleBlocked),
            text: "calls[0] cut failed, so the batch changed nothing: " + split
        ) { $0.message(package: "p.dirigible") },
    ]

    @Test(arguments: rows) func eachBodyGivesItsTextAndThePackageTexts(_ row: Row) {
        #expect(row.pending == Self.pending)
        #expect(row.split == Self.split)
        #expect(row.file == Self.file)
        #expect(row.body == row.bodyText)
    }
}
