import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `transcript_export` on a package that the app has open (decision 0061, C11): the file has the
/// cues of the session of the window, as `chapters_export`.
@MainActor
struct LiveTranscriptExportTests {
    /// The studio session has the import and a ripple insert that the files do not have yet, because
    /// the write turn is held. The first call meets a dialog, as `export`; then the file has the
    /// shifted cue, and a second call needs `replace`.
    @Test func aLiveExportReadsTheOpenSession() async throws {
        let package = try LiveTakeMapTests.takePackage()
        let studio = try await package.open()
        let shown = OSAllocatedUnfairLock(initialState: true)
        let (server, folder) = try liveServer(studio, sheetCause: { shown.withLock { $0 } ? .dialog : nil })
        defer { server.stop() }
        let gate = Gate()
        defer { gate.open() }
        let held = Task { await studio.serialized { await gate.wait() } }
        await until("the write turn is not held") { gate.waiting }
        let srt = "1\n00:00:02,100 --> 00:00:02,500\nHello\n"
        let imported = await send(
            folder.socket, "transcript_import", ["package": package.path, "text": srt, "track": "t1"])
        #expect(
            imported
                == .reply(
                    .result(
                        text: "1\nImported 1 cue: a cut removes a whole cue when it has no word times.", isError: false)
                ))
        try studio.edit(ripple: true) { session throws(SessionError) in
            try session.rippleInsert(1000, at: 0, on: ["t1", "t2"])
        }
        let out = package.folder.appending(path: "out.srt")
        let arguments: [String: String] = ["package": package.path, "out": out.path]

        let refused = await send(folder.socket, "transcript_export", arguments)
        shown.withLock { $0 = false }
        let written = await send(folder.socket, "transcript_export", arguments)
        let again = await send(folder.socket, "transcript_export", arguments)

        #expect(refused == .reply(.result(text: AgentBusy.dialog.message(package: package.path), isError: true)))
        #expect(written == .reply(.result(text: "OK", isError: false)))
        #expect(try String(contentsOf: out, encoding: .utf8) == "1\n00:00:02,121 --> 00:00:02,521\nHello\n")
        #expect(again == .reply(.result(text: "\(out.path) exists.", isError: true)))
        #expect(try Session(contentsOf: package.url).words().isEmpty, "the autosave waits")
        gate.open()
        await held.value
        await studio.settle()
    }
}
