import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `record` on a package that the app has open (decision 0048): the server gives the request and
/// the agent name to the window, and the window answer is the reply. Each call goes over a real
/// socket.
@MainActor
struct LiveRecordTests {
    /// The request reaches the `record` closure of the target with the agent name, and the answer
    /// is the reply.
    @Test func recordCallsTheWindow() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        var asked: [(RecordRequest, AgentName)] = []
        let folder = try SocketFolder()
        let server = AgentServer(socket: folder.socket) {
            [
                AgentTarget(
                    studio: studio,
                    record: { request, agent, _ in
                        asked.append((request, agent))
                        return .started(take: 3, tracks: ["Host"], seconds: 1.5)
                    })
            ]
        }
        server.start()
        defer { server.stop() }

        let outcome = await send(
            folder.socket, "record", ["package": package.path, "seconds": 1.5, "arm": ["t1"], "playhead": 480])

        let text = "Take 3 records on Host for 1.5 s. The user can stop it earlier. Read session_info: the take ended "
        #expect(outcome == .reply(.result(text: text + "when recording is gone.", isError: false)), "\(outcome)")
        #expect(asked.count == 1)
        #expect(asked.first?.0 == RecordRequest(armed: ["t1"], seconds: 1.5, playhead: 480))
        #expect(asked.first?.1 == AgentName(title: "Test Agent", clientName: nil))
        await studio.settle()
    }

    /// Decision 0050: the window gets the connection of the call. Two connections give two
    /// serials, each more than 0.
    @Test func recordGetsTheConnection() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        var connections: [AgentConnection] = []
        let folder = try SocketFolder()
        let server = AgentServer(socket: folder.socket) {
            [
                AgentTarget(
                    studio: studio,
                    record: { _, _, connection in
                        connections.append(connection)
                        return .declined
                    })
            ]
        }
        server.start()
        defer { server.stop() }

        _ = await send(folder.socket, "record", ["package": package.path, "seconds": 1, "arm": ["t1"]])
        _ = await send(folder.socket, "record", ["package": package.path, "seconds": 1, "arm": ["t1"]])

        #expect(connections.count == 2 && connections.allSatisfy { $0.serial > 0 }, "\(connections)")
        #expect(connections.first != connections.last, "each send is a new connection")
        await studio.settle()
    }

    /// A busy window refuses the request with its busy text, and the window is not asked.
    @Test func busyWindowIsNotAsked() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        var asked = 0
        let folder = try SocketFolder()
        let server = AgentServer(socket: folder.socket) {
            [
                AgentTarget(
                    studio: studio, busy: .asking,
                    record: { _, _, _ in
                        asked += 1
                        return .declined
                    })
            ]
        }
        server.start()
        defer { server.stop() }

        let outcome = await send(folder.socket, "record", ["package": package.path, "seconds": 1, "arm": ["t1"]])

        let text = AgentBusy.asking.message(package: package.path)
        #expect(outcome == .reply(.result(text: text, isError: true)), "\(outcome)")
        #expect(asked == 0)
        await studio.settle()
    }

    /// A refused microphone access in the app names Dirigible, not the terminal of the CLI, so
    /// the agent asks the user to allow the right app.
    @Test func aMicrophoneRefusalNamesDirigible() {
        for access in [MicrophoneAccess.denied, .restricted] {
            let reply = RecordAnswer.refused(.microphoneAccess(access)).reply(package: "/p.dirigible")
            let text =
                "Dirigible has no microphone access. Ask the user to allow Dirigible in System Settings > "
                + "Privacy & Security > Microphone, then ask again."
            #expect(reply == .result(text: text, isError: true), "\(access)")
        }
    }

    /// Decision 0048: the answer limit and a start of 10 s fit in the reply limit of the bridge.
    @Test func lifetimeFitsTheBridgeLimit() {
        #expect(RecordRequest.answerLimit + .seconds(10) <= AgentBridge.replyLimit)
    }
}
