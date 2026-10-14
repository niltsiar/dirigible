import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `level` on a package that the app has open: it runs through `Studio.level` (decision 0049,
/// C10). The package has clip `c1` of 3 s on the mono track `t1`, so the measure has three blocks.
@MainActor
struct LiveLevelTests {
    let package: LivePackage

    init() throws {
        package = try LivePackage()
        try package.addTone()
    }

    /// Opens the studio with its measure held before block 2, and starts a server for it.
    func open(_ hold: ChunkHold) async throws -> (Studio, AgentServer, SocketFolder) {
        let studio = try await package.open()
        studio.environment.loudnessBlock = { hold.step() }
        let (server, folder) = try liveServer(studio)
        return (studio, server, folder)
    }

    func gain(_ studio: Studio) -> Double? { studio.session.clip("c1")?.clip.gain.dB }

    /// The reply is the line of the clip and the report line, and the level is one undo step with
    /// the agent name.
    @Test func liveLevelIsOneUndoStepOfTheAgent() async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await send(folder.socket, "level", ["package": package.path])

        let level = try #require(gain(studio))
        let line = "c1\t" + String(format: "%+.1f dB", level)
        #expect(level > 1, "the tone of 0.1 peak gets more gain: \(level)")
        #expect(outcome == .reply(.result(text: line + "\nClips changed: 1.", isError: false)), "\(outcome)")
        #expect(studio.undoAgent?.name == "Test Agent")
        try studio.undo()
        #expect(gain(studio) == 0, "one undo step removes the level")
        #expect(!studio.canUndo, "the level is one undo step")
        await studio.settle()
    }

    /// A cancel line on stdin closes the bridge, the listener cancels the call task, and the level
    /// ends with no gain change, no undo entry, and no answer.
    @Test func aCancelOfTheCallLevelsNothing() async throws {
        let hold = ChunkHold(at: 3)
        defer { hold.release() }
        let (studio, server, folder) = try await open(hold)
        defer { server.stop() }
        let stdin = try StdinPipe()
        let (socket, fd, path) = (folder.socket, stdin.readFD, package.path)
        stdin.put(progressCall("level", ["package": path], id: 7))
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
        await until("the level does not hold") { hold.isHeld && server.connected == 1 }
        stdin.put(
            MCPServer.encode(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 7]]))
        await until("the bridge did not close") { server.connected == 0 }
        hold.release()
        await until("the level did not end") { studio.transport == .idle }
        stdin.closeWrite()
        let all = await answers.value
        withExtendedLifetime(stdin) {}

        #expect(all.count == 2 && all.allSatisfy { $0 == nil }, "the cancelled level got an answer: \(all)")
        #expect(gain(studio) == 0 && !studio.canUndo, "a cancelled level changed the gain")
        #expect(try Session(contentsOf: package.url).clip("c1")?.clip.gain.dB == 0, "a cancelled level saved")
        await studio.settle()
    }

    /// The Cancel of the level banner ends an agent level, and the agent gets the text of the user
    /// cancel.
    @Test func aWindowCancelGivesTheAgentTheCancelText() async throws {
        let hold = ChunkHold(at: 3)
        defer { hold.release() }
        let (studio, server, folder) = try await open(hold)
        defer { server.stop() }
        let (socket, path) = (folder.socket, package.path)
        let call = Task { await send(socket, "level", ["package": path]) }
        await until("the level does not hold") { hold.isHeld }

        studio.cancelLevel()
        hold.release()
        let outcome = await call.value

        let text = "The user cancelled the level in Dirigible. No gain changed."
        #expect(outcome == .reply(.result(text: text, isError: true)), "\(outcome)")
        #expect(gain(studio) == 0 && !studio.canUndo, "a cancelled level changed the gain")
        await studio.settle()
    }
}
