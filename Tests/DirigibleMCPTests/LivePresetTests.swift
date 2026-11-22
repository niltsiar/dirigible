import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `preset_set` and `preset_remove` on a package that the app has open (decision 0080, criterion E10):
/// the edit is one undo step of the window, as `track_role`, and the files do not change.
@MainActor
struct LivePresetTests {
    @Test func aLivePresetEditChangesTheWindowSessionAsOneUndoStep() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let arguments: [String: any Sendable] = [
            "package": package.path, "name": "Show", "format": "mp3", "bitrate": 96, "mono": true,
        ]

        let add = await send(folder.socket, "preset_set", arguments)

        #expect(add == .reply(.result(text: "OK", isError: false)), "\(add)")
        #expect(studio.session.exportPresets.map(\.name.text) == ["Show"], "the window session has the preset")
        #expect(studio.undoAgent == AgentName(title: "Test Agent", clientName: nil))
        try studio.undo()
        #expect(studio.session.exportPresets.isEmpty, "one undo step takes the preset out")
        try studio.redo()
        let remove = await send(folder.socket, "preset_remove", ["package": package.path, "name": "Show"])
        #expect(remove == .reply(.result(text: "OK", isError: false)), "\(remove)")
        #expect(studio.session.exportPresets.isEmpty)
        await studio.settle()
    }

    @Test func aLiveRefusalLeavesTheWindowSession() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let taken = await send(
            folder.socket, "preset_set", ["package": package.path, "name": "Master", "format": "wav"])

        let text = "the preset name \"Master\" is taken by another preset or a built-in preset."
        #expect(taken == .reply(.result(text: text, isError: true)), "\(taken)")
        #expect(studio.session.exportPresets.isEmpty)
        await studio.settle()
    }
}
