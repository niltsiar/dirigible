import Testing

@testable import DirigibleMCP

/// C10 of the stem export: a long tool that writes a file or a folder can still write it after the
/// bridge gives up, so its limit text and its lost-call text tell the agent to check that output.
extension BridgeTests {
    static let fileAdvice = "can still write its file: check the output file"
    static let folderAdvice = "can still write its folder: check the output folder"

    @Test func eachLongFileToolGetsTheAdviceOfItsOutput() {
        let tools = Tool.all.filter { $0.output != nil }
        #expect(!tools.isEmpty)
        for tool in tools {
            let advice = tool.name == "export_stems" ? Self.folderAdvice : Self.fileAdvice
            #expect(limitMessage(tool: tool.name, seconds: 30).contains(advice), "\(tool.name)")
            #expect(lostMessage(tool: tool.name).contains(advice), "\(tool.name)")
        }
        #expect(!limitMessage(tool: "track_rename", seconds: 30).contains(Self.fileAdvice))
        #expect(lostMessage(tool: "track_rename") == lostCallMessage)
    }

    @Test func exportStemsGetsTheFolderAdvice() {
        #expect(Tool.output(of: "export_stems") == .folder)
        #expect(lostMessage(tool: "export_stems").contains("The export_stems \(Self.folderAdvice)"))
        #expect(!lostMessage(tool: "export_stems").contains("output file"))
    }
}
