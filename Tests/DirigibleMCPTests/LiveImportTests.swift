import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `import` on a package that the app has open: it runs through `Studio.importAudio` (decision
/// 0049, C11). The source is the tone of 3 s of `addTone`, beside the package, so the conversion
/// has three blocks.
@MainActor
struct LiveImportTests {
    let package: LivePackage
    let source: URL
    var clips: URL { package.url.appending(path: "Clips") }

    init() throws {
        package = try LivePackage()
        try package.addTone()
        source = package.folder.appending(path: "Voice.wav")
        try FileManager.default.copyItem(at: package.url.appending(path: "Clips/tone.wav"), to: source)
    }

    func arguments(_ extra: [String: any Sendable] = [:]) -> [String: any Sendable] {
        extra.merging(["package": package.path, "file": source.path, "track": "t2"]) { $1 }
    }

    func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted() }

    /// The reply is the clip ID, the import is one undo step with the agent name, and `no_level`
    /// keeps the gain of the conversion.
    @Test(arguments: [false, true])
    func liveImportIsOneUndoStepOfTheAgent(noLevel: Bool) async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await send(folder.socket, "import", arguments(["no_level": noLevel]))

        #expect(outcome == .reply(.result(text: "Voice", isError: false)), "\(outcome)")
        let gain = try #require(studio.session.clip("Voice")?.clip.gain.dB)
        #expect(noLevel ? gain == 0 : gain > 1, "no_level \(noLevel): gain \(gain)")
        #expect(studio.undoAgent?.name == "Test Agent")
        try studio.undo()
        #expect(studio.session.clip("Voice") == nil && !studio.canUndo, "one undo step removes the clip")
        await studio.settle()
    }

    /// A cancel line on stdin closes the bridge, the listener cancels the call task, and the
    /// import ends with no clip, no new WAV, no undo entry, and no answer.
    @Test func aCancelOfTheCallImportsNothing() async throws {
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        let studio = try await package.open()
        studio.environment.importStep = { hold.step() }
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let stdin = try StdinPipe()
        let (socket, fd) = (folder.socket, stdin.readFD)
        stdin.put(progressCall("import", arguments(), id: 7))
        let answers = Task {
            await onThread { () -> [String?] in
                let input = LineInput(fd: fd)
                var server = MCPServer(
                    route: AgentBridge(socket: socket, input: input).route, pollCancel: input.pollCancel)
                var answers: [String?] = []
                while let line = input.next() { answers.append(server.answer(line)) }
                return answers
            }
        }
        await until("the import does not hold") { hold.isHeld && server.connected == 1 }
        stdin.put(
            MCPServer.encode(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 7]]))
        await until("the bridge did not close") { server.connected == 0 }
        hold.release()
        await until("the import did not end") { studio.transport == .idle }
        stdin.closeWrite()
        let all = await answers.value
        withExtendedLifetime(stdin) {}

        #expect(all.count == 2 && all.allSatisfy { $0 == nil }, "the cancelled import got an answer: \(all)")
        #expect(studio.session.clip("Voice") == nil && !studio.canUndo, "a cancelled import added a clip")
        #expect(try names() == ["tone.wav"], "a cancelled import left a file")
        await studio.settle()
    }

    /// The Cancel of the import banner ends an agent import, and the agent gets the text of the
    /// user cancel.
    @Test func aWindowCancelGivesTheAgentTheCancelText() async throws {
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        let studio = try await package.open()
        studio.environment.importStep = { hold.step() }
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let (socket, arguments) = (folder.socket, arguments())
        let call = Task { await send(socket, "import", arguments) }
        await until("the import does not hold") { hold.isHeld }

        studio.cancelImport()
        hold.release()
        let outcome = await call.value

        let text = "The user cancelled the import in Dirigible. No clip was added."
        #expect(outcome == .reply(.result(text: text, isError: true)), "\(outcome)")
        #expect(studio.session.clip("Voice") == nil && !studio.canUndo, "a cancelled import added a clip")
        #expect(try names() == ["tone.wav"], "a cancelled import left a file")
        await studio.settle()
    }

    /// A window close during an agent import gives the agent the close text, as for an export
    /// (code gate 3 item 2).
    @Test func aWindowCloseGivesTheAgentTheCloseText() async throws {
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        let studio = try await package.open()
        studio.environment.importStep = { hold.step() }
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let (socket, arguments) = (folder.socket, arguments())
        let call = Task { await send(socket, "import", arguments) }
        await until("the import does not hold") { hold.isHeld }

        let settled = Task { await studio.settle() }
        await until("the close did not cancel the import") { studio.importRun?.flags.isCancelled == true }
        hold.release()
        let outcome = await call.value
        await settled.value

        let text = "The session window closed, so the import stopped. No clip was added."
        #expect(outcome == .reply(.result(text: text, isError: true)), "\(outcome)")
        #expect(try names() == ["tone.wav"], "a cancelled import left a file")
    }
}
