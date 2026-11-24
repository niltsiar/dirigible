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
        let pending, split, body, file, archive: String
        let bodyText: String
        var testDescription: String { name }
    }

    static func row<Body: Error>(
        _ name: String, _ body: Body, text bodyText: String, _ message: (EditFailure<Body>) -> String
    ) -> Row {
        Row(
            name: name, pending: message(.pendingTake), split: message(.splitTake), body: message(.body(body)),
            file: message(.file(.malformedXML)), archive: message(.archive(.space(need: 2_000, free: 1_000))),
            bodyText: bodyText)
    }

    static let pending = "p.dirigible has a take that is not finalized; open it in Dirigible first."
    static let split =
        "p.dirigible has a take with some segments on the timeline and some not. A ripple moves the timeline "
        + "under the other segments, so place them first (dirigible capture place)."
    static let file = "p.dirigible/session.xml is not a Dirigible session file."
    static let archive = "the audio files of p.dirigible need 2000 bytes free to convert; 1000 bytes are free."

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
        row("ClipRenderError", ClipRenderError.cancelled, text: "the clip render was cancelled.") {
            $0.message(package: "p.dirigible")
        },
        row("SplitError", SplitError.cancelled, text: "the split was cancelled.") {
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
        #expect(row.archive == Self.archive)
    }

    /// The unarchive step of a write into an archived Favorites store (decision 0072): its fault
    /// keeps its case through `StudioError.init(favorites:)` for both bodies.
    @Test func aStoreStepFaultIsAnArchiveFault() {
        let fault = ArchiveFault.space(need: 2_000, free: 1_000)
        #expect(StudioError(favorites: EditFailure<PasteError>.archive(fault)) == .archive(fault))
        #expect(StudioError(favorites: EditFailure<SessionError>.archive(fault)) == .archive(fault))
        #expect(ArchiveFault.favoritesStore.message(package: "p.dirigible") == "The Favorites store is never archived.")
    }

    /// The tool call of the clip render and of the split on the files.
    enum Tool: CaseIterable, Sendable, CustomTestStringConvertible {
        case clipRender, split
        var testDescription: String { self == .clipRender ? "ClipRenderWork" : "SplitWork" }

        /// The error text of a call on a clip that the session does not hold.
        func message(in package: LivePackage) -> String {
            let control = CallControl(token: nil, interval: .zero, send: { _ in }, poll: { _ in false }, step: {})
            do throws(ToolError) {
                switch self {
                case .clipRender:
                    let request = ClipRenderRequest(Treatment(.rumble(.standard)))
                    _ = try ClipRenderWork(clips: ["c9"], request: request).run(
                        package.url, path: package.path, control: control)
                case .split:
                    _ = try SplitWork(clips: ["c9"]).run(package.url, path: package.path, control: control)
                }
                return "the call did not fail"
            } catch {
                return error.message
            }
        }
    }

    /// The tool call of each of these two edits gives the text of its pending take, its file error, and
    /// its body. The two tools do not ripple, so the rows above hold their split take text.
    @Test(arguments: Tool.allCases) func theToolCallGivesTheTextOfEachFailure(_ tool: Tool) throws {
        let pending = try LivePackage()
        var session = try Session(contentsOf: pending.url)
        try session.setRecording(
            Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["t1"]))
        try session.write(to: pending.url)
        let damaged = try LivePackage()
        try Data("not xml".utf8).write(to: damaged.url.appending(path: "session.xml"))
        let body = try LivePackage()

        let notFinalized = "\(pending.path) has a take that is not finalized; open it in Dirigible first."
        #expect(tool.message(in: pending) == notFinalized)
        #expect(tool.message(in: damaged) == "\(damaged.path)/session.xml is not a Dirigible session file.")
        #expect(tool.message(in: body) == "no clip \"c9\".")
    }
}
