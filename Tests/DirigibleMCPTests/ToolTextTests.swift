import Testing

@testable import DirigibleMCP

/// The edit tool descriptions after decision 0046: a call on an open package is one undo step in
/// the app, and a call on the files has no undo.
struct ToolTextTests {
    @Test func editToolsNameTheUndoOfTheApp() {
        let edits = Tool.all.filter { $0.description.hasSuffix(Tool.undoNote) }
        #expect(edits.count >= 30, "the edit tools: \(edits.map(\.name))")
        #expect(edits.contains { $0.name == "track_rename" })
        #expect(!edits.contains { $0.name == "session_info" })
        #expect(!Tool.all.contains { $0.description.contains("No undo: each call saves the package.") })
    }
}
