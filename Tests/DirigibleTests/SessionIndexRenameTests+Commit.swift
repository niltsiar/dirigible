import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleMCP

/// The row field and the commits of the window: a take, a close, an agent job, and a busy studio.
extension SessionIndexRenameTests {
    @Test func noRenameDuringATake() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await open(routed: true)
        studio.environment = windows.hal.environment
        await model.record()
        try #require(!studio.isIdle, "the take runs")
        try windows.click(row: 2, table, in: window)
        pressReturn(in: window)
        pressF2(in: window)
        #expect(rowField(in: table) == nil && beeps() == 0, "Return and F2 open no field and do not beep")
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }

    /// The take starts in the Studio, so no commit of the window ends the field first.
    @Test func returnWithABusyStudioBeepsAndKeepsTheTypedName() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await open(routed: true)
        studio.environment = windows.hal.environment
        _ = try start(row: 2, table, in: window)
        type("Breath 2", in: window)
        try await studio.startRecording(armed: ["t1"])
        try #require(!studio.isIdle, "the take runs")

        pressReturn(in: window)
        #expect(beeps() == 1, "Return beeps")
        #expect(rowField(in: table)?.stringValue == "Breath 2", "the field stays with the typed name")
        #expect(name("m1", in: studio) == "Breath")

        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        model.commitDrafts()
        #expect(name("m1", in: studio) == "Breath 2" && rowField(in: table) == nil, "the next commit saves it")
        await model.close()
    }

    /// A click on another row while the studio is busy ends the field: the list keys reach the list, the list
    /// follows the playhead, and the typed name is saved when the studio is idle again.
    @Test func aFocusLossWithABusyStudioEndsTheFieldAndSavesTheNameWhenIdle() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await open(routed: true)
        studio.environment = windows.hal.environment
        _ = try start(row: 2, table, in: window)
        type("Breath 2", in: window)
        try await studio.startRecording(armed: ["t1"])
        try #require(!studio.isIdle, "the take runs")

        try windows.click(row: 4, table, in: window)
        #expect(rowField(in: table) == nil && model.leadingPane.rowEdit == nil, "the field ends")
        #expect(!table.mark.hold.contains(.rowField), "the list follows the playhead")
        #expect(name("m1", in: studio) == "Breath", "nothing is saved during the take")
        await model.stop()
        await until("the name is saved when the studio is idle") { name("m1", in: studio) == "Breath 2" }

        try #require(model.indexListHasFocus(in: window) && model.timeline.selectedRows == [.clip("c")])
        let marks = Marks(inPoint: 48_000, outPoint: 144_000)
        model.timeline.selection = .range(marks)
        let before = studio.session
        windows.app.timeline(.deleteCloseGap, event: event("\u{7f}", code: 51, .shift, in: window), in: window)
        #expect(beeps() == 1 && studio.session == before, "Shift-Delete beeps and changes nothing")
        pressReturn(in: window)
        #expect(model.inspectorTab == .clip && model.renamingTrack == nil, "Return shows the Clip tab")
        try #require(model.indexListHasFocus(in: window))
        windows.app.timeline(.deselectAll, event: event("a", code: 0, [.command, .shift], in: window), in: window)
        #expect(model.timeline.selectedRows.isEmpty && model.timeline.selection == .range(marks), "rows only")
        await model.close()
    }

    /// An agent job commits the open field first, as a take start does.
    @Test func anAgentJobCommitsTheField() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await open()
        _ = try start(row: 2, table, in: window)
        type("Breath 2", in: window)
        let target = try #require(windows.app.agentTargets().first { $0.studio === studio })
        let call = AgentCall(
            path: studio.url.path, tool: "level", identity: studio.url,
            work: .level(LevelWork(clips: [], perTrack: false)), agent: AgentName(title: "Agent", clientName: nil),
            connection: AgentConnection(serial: 0))
        _ = await liveJob(call, target: target) { _ in }
        #expect(name("m1", in: studio) == "Breath 2", "the typed name is saved")
        #expect(rowField(in: table) == nil && model.leadingPane.rowEdit == nil, "the field ends")
        await model.close()
    }

    @Test func aTakeStartCommitsTheField() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await open(routed: true)
        studio.environment = windows.hal.environment
        _ = try start(row: 2, table, in: window)
        type("Breath 2", in: window)
        await model.record()
        try #require(!studio.isIdle, "the take runs")
        #expect(name("m1", in: studio) == "Breath 2" && rowField(in: table) == nil, "Command-R saves the typed name")
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }

    @Test func aCloseCommitsTheField() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await open()
        _ = try start(row: 2, table, in: window)
        type("Breath 2", in: window)
        await model.close()
        #expect(name("m1", in: studio) == "Breath 2", "a close saves the typed name")
    }
}
