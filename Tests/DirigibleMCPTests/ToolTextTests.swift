import DirigibleAudio
import Testing

@testable import DirigibleMCP

/// The edit tool descriptions after decision 0046: a call on an open package is one undo step in
/// the app, and a call on the files has no undo.
struct ToolTextTests {
    @Test func editToolsNameTheUndoOfTheApp() {
        #expect(
            Tool.undoNote.contains("When Dirigible lets agents edit open sessions"), "the setting is off by default")
        let edits = Tool.all.filter { $0.description.hasSuffix(Tool.undoNote) }
        #expect(edits.count >= 30, "the edit tools: \(edits.map(\.name))")
        #expect(edits.contains { $0.name == "track_rename" })
        #expect(!edits.contains { $0.name == "session_info" })
        #expect(!Tool.all.contains { $0.description.contains("No undo: each call saves the package.") })
    }

    /// A late cancel of `level` or `import` keeps the change, so the text tells the agent to read the
    /// session before a retry (decision 0049, code gate 3 item 1).
    @Test(arguments: ["level", "import"])
    func anEditCancelTextTellsTheAgentToReadTheSession(name: String) throws {
        let tool = try #require(Tool.all.first { $0.name == name })
        #expect(
            tool.description.contains("A cancel at the end can be late, so read session_info before a retry."),
            "\(tool.description)")
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

    /// Decision 0050 (C19): the record text names the window grant, its ends, and the rate limit.
    @Test func recordNamesTheWindowGrant() throws {
        let text = try #require(Tool.all.first { $0.name == "record" }).description
        for part in ["window grant", "1 h", "2 h", "new connection", "app track", "3 requests"] {
            #expect(text.contains(part), "\(part)")
        }
    }
}
