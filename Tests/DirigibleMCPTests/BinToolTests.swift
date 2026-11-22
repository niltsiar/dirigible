import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The bin tools on a package that the app has open (F22, C10): each edit is one undo step of the
/// window, and `bin_list` reads the session of the window.
@MainActor
struct BinToolTests {
    @Test func eachBinCallIsOneUndoEntryAndTheListReadsTheWindow() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
            try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 48_000), on: "t1")
        }
        func call(_ tool: String, _ arguments: [String: any Sendable]) async -> AgentBridge.Outcome {
            await send(folder.socket, tool, arguments.merging(["package": package.path]) { $1 })
        }
        func text(_ outcome: AgentBridge.Outcome) -> String {
            guard case .reply(.result(let text, false)) = outcome else { return "refused: \(outcome)" }
            return text
        }

        let bin = text(await call("bin_add", ["name": "Show"]))
        #expect(studio.session.bins.map(\.id.rawValue) == [bin], "the window session has the bin")
        let item = text(await call("bin_item_add", ["bin": bin, "name": "Sting", "clips": ["A"]]))
        #expect(studio.session.bins.first?.items.map(\.id.rawValue) == [item])

        let list = await call("bin_list", [:])
        let lines = "bin \(bin) \"Show\"\nitem \(item) \"Sting\" clips length 48000 tracks t1"
        #expect(list == .reply(.result(text: lines, isError: false)), "\(list)")

        for (tool, arguments) in [
            ("bin_paste", ["item": item, "at": 96_000] as [String: any Sendable]),
            ("bin_item_rename", ["item": item, "name": "Intro"]),
            ("bin_rename", ["bin": bin, "name": "Talk"]),
        ] {
            let (before, revision) = (studio.session, studio.sessionRevision)
            let outcome = await call(tool, arguments)
            #expect(!text(outcome).hasPrefix("refused"), "\(tool): \(outcome)")
            #expect(studio.sessionRevision == revision + 1, "one \(tool) call is one edit")
            try studio.undo()
            #expect(studio.session == before, "one undo gives back the session before \(tool)")
            try studio.redo()
        }
        #expect(studio.session.clip("A@96000")?.track == "t1")
        await studio.settle()
    }
}
