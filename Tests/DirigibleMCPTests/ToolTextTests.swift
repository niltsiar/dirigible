import DirigibleAudio
import DirigibleCore
import Foundation
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

    /// C1 (run 2026-11-08-role-explain): `track_role` says the role changes no sound, and names the
    /// tools and the track kinds that read it. The `track_follow` description does not gain the text.
    @Test func trackRoleSaysWhatTheRoleDoes() throws {
        let tool = try #require(Tool.all.first { $0.name == "track_role" })
        for word in ["no sound", "`duck`", "`clip_denoise`", "`session_info`", "music", "effects"] {
            #expect(tool.description.contains(word), "no \(word): \(tool.description)")
        }
        #expect(tool.description.contains(EditRules.roleNote), "the description does not hold roleNote")
        let follow = try #require(Tool.all.first { $0.name == "track_follow" })
        #expect(!follow.description.contains("`duck`") && !follow.description.contains("`clip_denoise`"))
    }

    /// A late cancel of `level`, `import`, `clip_split_stereo`, `clip_denoise`, or `clip_repair` keeps the change,
    /// so the text tells the agent to read the session before a retry (decision 0049, code gate 3 item 1).
    @Test(arguments: ["level", "import", "clip_split_stereo", "clip_denoise", "clip_repair"])
    func anEditCancelTextTellsTheAgentToReadTheSession(name: String) throws {
        let tool = try #require(Tool.all.first { $0.name == name })
        #expect(
            tool.description.contains("A cancel at the end can be late, so read session_info before a retry."),
            "\(tool.description)")
    }

    /// C20 and W10: `clip_denoise` lists `hum` (50 or 60) and `noise`, says that hum alone takes a
    /// clip on any track, and holds no word "voice".
    @Test func clipDenoiseListsTheHumArguments() throws {
        let tool = try #require(Tool.all.first { $0.name == "clip_denoise" })
        let properties = try #require(tool.inputSchema["properties"] as? [String: [String: Any]])

        #expect(properties["hum"]?["enum"] as? [Int] == [50, 60], "\(String(describing: properties["hum"]))")
        #expect(properties["noise"]?["default"] as? Bool == true, "\(String(describing: properties["noise"]))")
        #expect(properties["reduction"]?["minimum"] as? Int == 1, "reduction is not an optional argument")
        #expect(tool.description.contains("with noise false"), Comment(rawValue: tool.description))
        let texts = [tool.description] + properties.values.compactMap { $0["description"] as? String }
        #expect(!texts.contains { $0.lowercased().contains("voice") }, "\(texts)")
    }

    /// C14: the texts of a clip render error name the clip render, so a repair does not read as a noise
    /// reduction. The two cases of the noise reduction keep its name (fail: the L1 texts).
    @Test func clipRenderTextsAreNeutral() {
        let neutral: [(ClipRenderError, String)] = [
            (.space(needed: 9, free: 3), "the clip render needs 9 free bytes, and the disk has 3."),
            (.write(file: "f1 NR.wav", errno: ENOSPC), "the clip render cannot write \"f1 NR.wav\" (errno 28)."),
            (
                .sourceUnreadable(file: "f1.wav", errno: EIO),
                "the clip render cannot read the source \"f1.wav\" (errno 5)."
            ),
            (.sourceMissing(file: "f1.wav"), "the clip render cannot find the source \"f1.wav\" in Clips/."),
            (
                .notDownloaded(file: "f1.wav"),
                "the clip render cannot read the source \"f1.wav\": it is not on this Mac. Download it first."
            ),
            (.cancelled, "the clip render was cancelled."),
            (
                .mixedTreatments(clips: ["a", "b"]),
                "the clip render refuses clips \"a\", \"b\": they share one new file but have different settings."
            ),
            (.engine(status: -50), "the clip render stopped: the audio engine failed (status -50)."),
            (
                .stillOverFullScale(file: "Clips/f1 NR.wav"),
                "the clip render made \"Clips/f1 NR.wav\" louder than full scale, so it clips."
            ),
            (
                .cornerTooHigh(hertz: 9_923, limit: .hertz(9_922)),
                "the clip render refuses 9923 Hz: the session rate takes a filter corner of 9922 Hz at most."
            ),
            (
                .cornerTooHigh(hertz: 2_000, limit: .lowestRate(4_445)),
                "the clip render refuses 2000 Hz: the effect needs a session rate of 4445 Hz or more."
            ),
            (
                .nonFiniteSample(file: "f1 DC.wav"),
                "the clip render refuses \"f1 DC.wav\": a rendered sample is not a number, so it writes nothing."
            ),
        ]
        for (error, text) in neutral { #expect(error.message == text, "\(error)") }
        let noise: [ClipRenderError] = [.effectUnavailable(status: -3000), .trackRole(clip: "m1", role: .music)]
        for error in noise { #expect(error.message.hasPrefix("the noise reduction "), "\(error.message)") }
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

    /// The end rules of a play (C5, C7, C8): a play with neither argument keeps a running end, a
    /// seek at or after the end plays on, and the other transport commands drop the end.
    @Test func theTransportToolsStateTheEndRules() throws {
        let play = try #require(Tool.all.first { $0.name == "transport_play" }).description
        let locate = try #require(Tool.all.first { $0.name == "transport_locate" }).description
        for part in [
            "During a forward 1x play, a call with neither from nor to changes nothing and gives the end of the "
                + "running play.",
            "A call with from or to starts a new play with the new end.",
            "before its end keeps the end", "One at or after the end plays on to the end of the session",
            "Space, Stop and Return, J, K, L, and a speed change drop the end",
        ] {
            #expect(play.contains(part), "\(part)")
        }
        #expect(!play.contains("With neither, the play starts at the playhead and runs to the end of the session"))
        for part in [
            "a frame before to keeps to, and a frame at or after to plays on to the end of the session",
            "During a forward play, a frame at or after the end of the session stops the play there.",
        ] {
            #expect(locate.contains(part), "\(part)")
        }
    }

    /// U17: the playhead stays where an agent play stopped, so the next take of the user starts there.
    @Test func transportPlayNamesWhereTheNextTakeStarts() throws {
        let play = try #require(Tool.all.first { $0.name == "transport_play" }).description
        #expect(
            play.contains("After the play, the playhead stays where the play stopped, and the next take starts there."))
    }

    /// 0053: `clip_replace` and `clip_fill` name `at` and `until` as the edges of the target range,
    /// and `clip_fill` names the clip limit of `Session.fillClipLimit`. `clip_paste` keeps "The
    /// timeline frame.".
    @Test(arguments: ["clip_replace", "clip_fill"])
    func theRangePasteToolsNameTheTargetRange(name: String) throws {
        func properties(_ name: String) throws -> [String: [String: Any]] {
            let tool = try #require(Tool.all.first { $0.name == name })
            return try #require(tool.inputSchema["properties"] as? [String: [String: Any]])
        }
        let target = try properties(name)

        #expect(target["at"]?["description"] as? String == "The first frame of the target range.")
        #expect(target["until"]?["description"] as? String == "The frame after the last frame of the target range.")
        #expect(try properties("clip_paste")["at"]?["description"] as? String == "The timeline frame.")
        let description = try #require(Tool.all.first { $0.name == name }).description
        #expect(
            name == "clip_replace" || description.contains("More than \(Session.fillClipLimit) new clips are refused."),
            "\(description)")
    }
}
