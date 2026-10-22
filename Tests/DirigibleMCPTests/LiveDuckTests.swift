import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `duck` on a package that the app has open: it runs through `Studio.duck` (decisions 0049 and
/// 0060, C16). Track `t1` (dialogue) plays the 3 s tone of `addTone` as clip `c1`, and track `t2`
/// (music) plays it as clip `c2`, so the read has three seconds of audio.
@MainActor
struct LiveDuckTests {
    let package: LivePackage

    init() throws {
        package = try LivePackage()
        try package.addTone()
        var session = try Session(contentsOf: package.url)
        try session.place(Clip(id: "c2", file: "tone", start: 0, offset: 0, length: 144_000), on: "t2")
        try session.setRole(.dialogue, tracks: ["t1"])
        try session.setRole(.music, tracks: ["t2"])
        try session.write(to: package.url)
    }

    /// Opens the studio with its read held before second 3, and starts a server for it.
    func open(_ hold: ChunkHold) async throws -> (Studio, AgentServer, SocketFolder) {
        let studio = try await package.open()
        studio.environment.loudnessBlock = { hold.step() }
        let (server, folder) = try liveServer(studio)
        return (studio, server, folder)
    }

    func envelope(_ studio: Studio) -> GainEnvelope? { studio.session.clip("c2")?.clip.envelope }

    /// The bridge gets progress values that grow, the reply is the text of the command, and the
    /// duck is one undo step with the agent name.
    @Test func liveDuckReportsProgressAndIsOneUndoStepOfTheAgent() async throws {
        let hold = ChunkHold(at: 3)
        defer { hold.release() }
        let (studio, server, folder) = try await open(hold)
        defer { server.stop() }
        let (sent, socket, path) = (Sent(), folder.socket, package.path)
        let call = Task {
            await onThread {
                let control = CallControl(token: 1, interval: .zero, send: sent.send, poll: { _ in false }, step: {})
                return AgentBridge(socket: socket, timeout: .seconds(120)).call(
                    tool: "duck", arguments: ["package": path], client: testClient, control: control)
            }
        }
        await until("no progress line before the last second") { !sent.progress(token: 1).isEmpty }
        hold.release()
        let outcome = await call.value

        let text = "speech\t0\t144000\nducked\tc2\nSpeech runs: 1. Clips ducked: 1, with 2 points."
        #expect(outcome == .reply(.result(text: text, isError: false)), "\(outcome)")
        let values = sent.progress(token: 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 } && values.allSatisfy { $0 < 100 }, "\(values)")
        #expect(envelope(studio)?.gain(at: 72_000) == -16, "the music ducks")
        #expect(studio.undoAgent?.name == "Test Agent")
        try studio.undo()
        #expect(envelope(studio) == .empty, "one undo step removes the duck")
        #expect(!studio.canUndo, "the duck is one undo step")
        await studio.settle()
    }

    /// A cancel line on stdin closes the bridge, the listener cancels the call task, and the duck
    /// ends with no envelope change, no undo entry, and no answer.
    @Test func aCancelOfTheCallDucksNothing() async throws {
        let hold = ChunkHold(at: 3)
        defer { hold.release() }
        let (studio, server, folder) = try await open(hold)
        defer { server.stop() }
        let stdin = try StdinPipe()
        let (socket, fd, path) = (folder.socket, stdin.readFD, package.path)
        stdin.put(progressCall("duck", ["package": path], id: 7))
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
        await until("the duck does not hold") { hold.isHeld && server.connected == 1 }
        stdin.put(
            MCPServer.encode(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 7]]))
        await until("the bridge did not close") { server.connected == 0 }
        hold.release()
        await until("the duck did not end") { studio.transport == .idle }
        stdin.closeWrite()
        let all = await answers.value
        withExtendedLifetime(stdin) {}

        #expect(all.count == 2 && all.allSatisfy { $0 == nil }, "the cancelled duck got an answer: \(all)")
        #expect(envelope(studio) == .empty && !studio.canUndo, "a cancelled duck changed the envelope")
        #expect(try Session(contentsOf: package.url).clip("c2")?.clip.envelope == .empty, "a cancelled duck saved")
        await studio.settle()
    }

    /// The Cancel of the banner ends an agent duck, and the agent gets the text of the user cancel.
    @Test func aWindowCancelGivesTheAgentTheCancelText() async throws {
        let hold = ChunkHold(at: 3)
        defer { hold.release() }
        let (studio, server, folder) = try await open(hold)
        defer { server.stop() }
        let (socket, path) = (folder.socket, package.path)
        let call = Task { await send(socket, "duck", ["package": path]) }
        await until("the duck does not hold") { hold.isHeld }

        studio.cancelLevel()
        hold.release()
        let outcome = await call.value

        let text = "The user cancelled the duck in Dirigible. No envelope changed."
        #expect(outcome == .reply(.result(text: text, isError: true)), "\(outcome)")
        #expect(envelope(studio) == .empty && !studio.canUndo, "a cancelled duck changed the envelope")
        await studio.settle()
    }
}
