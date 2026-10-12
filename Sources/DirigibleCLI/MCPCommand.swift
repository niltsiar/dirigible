import ArgumentParser
import DirigibleMCP
import Foundation

/// `dirigible mcp`: the only owner of stdin and stdout for the MCP server (decision 0041).
struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the session tools to an agent over MCP on stdin and stdout.",
        discussion: """
            Each stdin line is one JSON-RPC message, and each answer is one stdout line. The command \
            exits 0 when stdin closes.
            """)

    func run() throws {
        // A client that closes stdout gives a write error, not a SIGPIPE that stops the process
        // with no message.
        signal(SIGPIPE, SIG_IGN)
        // The bridge connects at start, so the app counts the agent before its first call (0046).
        let bridge = AgentBridge()
        bridge.connect()
        var server = MCPServer(route: bridge.route)
        // readLine splits on \n and \r\n only, and gives nil at the end of stdin.
        while let line = readLine() {
            guard let answer = server.answer(line) else { continue }
            do {
                // One write(2) for each answer, with no stdio buffer, so the client gets it at once.
                try FileHandle.standardOutput.write(contentsOf: Data((answer + "\n").utf8))
            } catch {
                throw fail("cannot write to stdout: \(error.localizedDescription)", code: ExitCode.failure.rawValue)
            }
        }
    }
}
