import ArgumentParser
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

    func run() {
        var server = MCPServer()
        // readLine splits on \n and \r\n only, and gives nil at the end of stdin.
        while let line = readLine() {
            guard let answer = server.answer(line) else { continue }
            // One write(2) for each answer, with no stdio buffer, so the client gets it at once.
            FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        }
    }
}
