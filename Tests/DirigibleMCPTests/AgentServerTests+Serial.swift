import DirigibleAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleMCP

extension AgentServerTests {
    /// Decision 0050 (C4): the connection serial is one counter for the process, so the first
    /// connection after a stop and a start has a higher serial than each earlier one.
    @Test func serialsDoNotRepeatAfterARestart() async throws {
        let folder = try SocketFolder()
        let package = try LivePackage()
        let studio = try await package.open()
        var serials: [UInt64] = []
        let server = AgentServer(socket: folder.socket) {
            [
                AgentTarget(
                    studio: studio,
                    record: { _, _, connection in
                        serials.append(connection.serial)
                        return .declined
                    })
            ]
        }
        server.start()
        _ = await send(folder.socket, "record", ["package": package.path, "seconds": 1, "arm": ["t1"]])
        server.stop()
        await until("the stop did not free the lock") { !server.draining }

        server.start()
        defer { server.stop() }
        _ = await send(folder.socket, "record", ["package": package.path, "seconds": 1, "arm": ["t1"]])

        #expect(serials.count == 2, "\(serials)")
        #expect((serials.last ?? 0) > (serials.first ?? .max), "the serial repeats after a restart: \(serials)")
        await studio.settle()
    }
}
