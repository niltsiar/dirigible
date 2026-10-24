import DirigibleAudio
import DirigibleCore
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
        #expect(
            AgentBusy.dialog.message(package: "p")
                == "p is busy in Dirigible: its window shows an alert, a sheet, or a panel. "
                + "Ask the user to finish or close it in Dirigible, then try again.")
    }

    /// Decision 0050 (C19): the record text names the window grant, its ends, and the rate limit,
    /// with the values of the constants.
    @Test func recordNamesTheWindowGrant() throws {
        let text = try #require(Tool.all.first { $0.name == "record" }).description
        let values = (
            RecordRequest.grantLifetime, RecordRequest.grantTakeSeconds, RecordRequest.askLimit, RecordRequest.askWindow
        )
        #expect(values == (.seconds(3600), 7200, 3, .seconds(60)), "the values of decision 0050")
        let hour = RecordRequest.units(RecordRequest.grantLifetime.components.seconds / 3600, "hour")
        let hours = RecordRequest.units(Int64(RecordRequest.grantTakeSeconds / 3600), "hour")
        let minute = RecordRequest.units(RecordRequest.askWindow.components.seconds / 60, "minute")
        let rate = "\(RecordRequest.askLimit) requests in \(minute)"
        #expect((hour, hours, rate) == ("1 hour", "2 hours", "3 requests in 1 minute"))
        #expect(RecordRequest.takeLimit == 86_400, "24 hours (0041)")
        for part in [
            "window grant",
            "A grant ends \(hour) after the click, after \(hours) of takes with no sheet (the take of "
                + "the click does not count)", "new connection", "app track", "A window takes \(rate) at most.",
            "A take after a click can be up to \(RecordRequest.units(Int64(RecordRequest.takeLimit / 3600), "hour")) long.",
        ] {
            #expect(text.contains(part), "\(part)")
        }
        guard case .result(let tooMany, true) = RecordAnswer.tooMany.reply(package: "p") else {
            Issue.record("tooMany is not an error")
            return
        }
        #expect(tooMany == "Too many record requests: a window takes \(rate) at most. Wait, then ask again.")
    }

    /// The backup tools give the rule of decision 0043 with the values of `BackupPolicy` (C16).
    @Test func theBackupToolsStateTheRule() throws {
        #expect((BackupPolicy.interval, BackupPolicy.count) == (600_000, 20), "the values of decision 0043")
        let minutes = RecordRequest.units(BackupPolicy.interval / 60_000, "minute")
        let rule =
            "Dirigible keeps a backup of session.xml before a save when the newest backup is \(minutes) old or older, "
            + "and when the window of the session closes. It keeps the \(BackupPolicy.count) newest backups."
        for name in ["backup_list", "backup_revert"] {
            let text = try #require(Tool.all.first { $0.name == name }).description
            #expect(text.contains(rule), "\(text)")
        }
        let revert = try #require(Tool.all.first { $0.name == "backup_revert" }).description
        #expect(revert.contains("It keeps a backup of the replaced session first."), "\(revert)")
    }
}
