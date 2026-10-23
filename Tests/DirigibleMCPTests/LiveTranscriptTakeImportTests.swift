import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `transcript_import` with `take` on a package that the app has open (decision 0061, C10). The
/// studio gives its stored take map, so the call reads no anchor file.
@MainActor
struct LiveTranscriptTakeImportTests {
    static let text = #"{"words":[{"word":"hi","start":0.5,"end":0.75}]}"#

    @Test func theImportFollowsTheEditOfTheWindow() async throws {
        let package = try LiveTakeMapTests.takePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        try studio.edit(ripple: true) { session throws(SessionError) in
            try session.rippleInsert(1000, at: 0, on: ["t1", "t2"])
        }

        let imported = await send(
            folder.socket, "transcript_import",
            ["package": package.path, "text": Self.text, "track": "t1", "take": 1])

        #expect(
            imported == .reply(.result(text: "1\ntake 1: 1 word placed, 0 skipped", isError: false)), "\(imported)")
        // Take frame 24 000 is 96 000 + 1 000 + 24 000 on the timeline.
        #expect(studio.session.words().map(\.range) == [Frames(121_000)..<Frames(133_000)])
        await studio.settle()
    }

    @Test func anAnchorFaultRefusesTheImport() async throws {
        let package = try LiveTakeMapTests.takePackage()
        let anchor = package.url.appending(path: "Capture/take1.anchor")
        chmod(anchor.path, 0o000)
        defer { chmod(anchor.path, 0o644) }
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let imported = await send(
            folder.socket, "transcript_import",
            ["package": package.path, "text": Self.text, "track": "t1", "take": 1])

        let message = "Cannot read the take anchor file Capture/take1.anchor (errno 13), so the take time is not known."
        #expect(imported == .reply(.result(text: message, isError: true)), "\(imported)")
        #expect(studio.session.words().isEmpty)
        await studio.settle()
    }
}
