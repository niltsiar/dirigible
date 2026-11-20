import Testing

@testable import DirigibleMCP

/// C10 of the stem export: a long tool that writes a file can still write it after the bridge
/// gives up, so its limit text and its lost-call text tell the agent to check the output.
extension BridgeTests {
    static let fileAdvice = "can still write its file: check the output file"

    @Test func eachLongFileToolGetsTheFileAdvice() {
        let tools = Tool.all.filter(\.writesFile)
        #expect(!tools.isEmpty)
        for tool in tools {
            #expect(limitMessage(tool: tool.name, seconds: 30).contains(Self.fileAdvice), "\(tool.name)")
            #expect(lostMessage(tool: tool.name).contains(Self.fileAdvice), "\(tool.name)")
        }
        #expect(!limitMessage(tool: "track_rename", seconds: 30).contains(Self.fileAdvice))
        #expect(lostMessage(tool: "track_rename") == lostCallMessage)
    }

    @Test func exportStemsGetsTheFileAdvice() {
        #expect(Tool.all.first { $0.name == "export_stems" }?.writesFile == true)
        #expect(lostMessage(tool: "export_stems").contains("The export_stems \(Self.fileAdvice)"))
    }
}
