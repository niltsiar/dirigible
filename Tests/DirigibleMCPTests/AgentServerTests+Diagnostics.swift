import DirigibleAudio
import Foundation
import Testing

@testable import DirigibleMCP

extension AgentServerTests {
    /// C32 (decision 0059): each call that reaches the app server writes one `agent call` line
    /// with the tool, the ms, and the error flag, and no argument value.
    @Test func aCallWritesOneLineWithNoArguments() async throws {
        let folder = try SocketFolder()
        let logs = folder.url.appending(path: "logs")
        let log = DiagnosticLog.start(.app, folder: logs, version: "0.4.9", commit: "abc1234")
        let server = AgentServer(socket: folder.socket, log: log) { [] }
        server.start()
        defer { server.stop() }

        let outcome = await send(folder.socket, "session_info", ["package": "/tmp/fixture-argument.dirigible"])
        log.quit()

        #expect(outcome == .reply(.notOpen))
        let names = try FileManager.default.contentsOfDirectory(atPath: logs.path).filter { $0.hasSuffix(".tsv") }
        let text = try names.map { try String(contentsOf: logs.appending(path: $0), encoding: .utf8) }.joined()
        let calls = text.split(separator: "\n").filter { $0.contains("\tagent\tcall\t") }
        #expect(calls.count == 1, "\(calls)")
        let fields = calls.first?.split(separator: "\t").dropFirst(6).map { $0.split(separator: "=").first ?? "" }
        #expect(fields == ["tool", "ms", "error"], "\(calls)")
        #expect(
            calls.first?.contains("\ttool=session_info\t") == true && calls.first?.hasSuffix("\terror=false") == true)
        #expect(!text.contains("fixture-argument"), "an argument is in the journal")
    }
}
