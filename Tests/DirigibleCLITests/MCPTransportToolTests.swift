import DirigibleCore
import Foundation
import Testing

/// The transport tools of `dirigible mcp` with no app socket (run agent-transport, C2 and C3).
struct MCPTransportToolTests {
    let package: TemporaryPackage

    init() throws { package = try TemporaryPackage(Session(sampleRate: 48_000)) }

    private func text(_ path: String) -> String {
        "To play, stop, or locate, open \(path) in Dirigible and turn on Let Agents Edit Open Sessions in Settings."
    }

    private func call(_ tool: String, _ arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
        toolResult(answer(try await mcp([toolCall(1, tool, arguments)]), id: 1))
    }

    /// Each tool gives the files text, also for a path with no package, and reads and writes no
    /// package.
    @Test(arguments: [
        ("transport_play", [String: Int]()), ("transport_stop", [:]), ("transport_locate", ["at": 10]),
    ])
    func transportToolsOnFilesAreRefused(tool: String, arguments: [String: Int]) async throws {
        let before = try package.xml()
        let names = try FileManager.default.contentsOfDirectory(atPath: package.path).sorted()
        let missing = package.folder.appending(path: "Gone.dirigible").path

        for path in [package.path, missing] {
            let reply = try await call(tool, ["package": path].merging(arguments.mapValues { $0 as Any }) { $1 })
            #expect(reply == (text(path), true), "\(tool) on \(path): \(reply)")
        }
        #expect(try package.xml() == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.path).sorted() == names)
    }

    /// A bad argument gives its own text before the files text. `to = from + 1` passes.
    @Test func transportArgumentsAreChecked() async throws {
        let path = package.path
        let cases: [(String, [String: Any], String)] = [
            ("transport_play", ["from": -1], "The argument \"from\" must be an integer, 0 or more."),
            ("transport_play", ["to": 1.5], "The argument \"to\" must be an integer, 0 or more."),
            ("transport_play", ["from": 5, "to": 5], "to must be more than from."),
            ("transport_play", ["from": 5, "to": 4], "to must be more than from."),
            ("transport_play", ["from": 5, "to": 6], text(path)),
            ("transport_play", ["from": 1 << 41], "The argument \"from\" must be 1099511627776 or less."),
            ("transport_locate", [:], "The argument \"at\" is missing."),
            ("transport_locate", ["at": -3], "The argument \"at\" must be an integer, 0 or more."),
            ("transport_locate", ["at": 0], text(path)),
            ("transport_stop", ["at": 0], "There is no argument \"at\"."),
        ]
        for (tool, arguments, expected) in cases {
            let reply = try await call(tool, ["package": path].merging(arguments) { $1 })
            #expect(reply == (expected, true), "\(tool) \(arguments): \(reply)")
        }
    }
}
