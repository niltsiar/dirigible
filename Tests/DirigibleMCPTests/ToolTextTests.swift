import DirigibleAudio
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

    /// The CLI keeps its busy text; a live edit names why the app refuses it (C4).
    @Test func busyTextsNameTheCause() {
        #expect(StudioError.busy.message(package: "p") == "p is busy with a take.")
        #expect(AgentBusy.quit.message(package: "p") == "p is busy in Dirigible: Dirigible quits. Try again later.")
        #expect(
            AgentBusy.closing.message(package: "p") == "p is busy in Dirigible: its window closes. Try again later.")
        #expect(
            AgentBusy.drag.message(package: "p")
                == "p is busy in Dirigible: a drag runs in its window. Try again later.")
        #expect(
            AgentBusy.task.message(package: "p")
                == "p is busy in Dirigible: a take, an import, a level, or a close runs. Try again later.")
    }
}
