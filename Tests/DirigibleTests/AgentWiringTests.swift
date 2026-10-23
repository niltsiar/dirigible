import AppKit
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleMCP

/// The app server in the app (decision 0046, criteria C1, C4, C12, and C17 of run
/// 2026-10-12-mcp-in-app): the Quit order, the busy windows, the agent mark, and no view change.
@Suite(.serialized) @MainActor struct AgentWiringTests {
    let folder: TemporaryFolder
    let socket = shortSocket()
    let app: AppDelegate

    init() throws {
        folder = try TemporaryFolder()
        app = AppDelegate(recordings: nil, agentSocket: socket)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// A call from an agent named "Test Agent", off the main actor, so the server can answer.
    func call(_ tool: String, _ arguments: [String: any Sendable]) async -> AgentBridge.Outcome {
        let socket = socket
        return await withCheckedContinuation { done in
            Thread.detachNewThread {
                let bridge = AgentBridge(socket: socket, timeout: .seconds(120))
                done.resume(
                    returning: bridge.call(
                        tool: tool, arguments: arguments, client: ClientInfo(title: "Test Agent", name: "test")))
            }
        }
    }

    /// C1: Quit stops the server after its cancel gates; a cancelled Quit starts it again when the
    /// stored switch is on.
    @Test func cancelledQuitKeepsTheSocket() async throws {
        let domain = "DirigibleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let app = AppDelegate(recordings: nil, defaults: defaults, agentSocket: socket)
        app.setAgents(true)
        let model = await app.open(try folder.package("quit"))
        let studio = try #require(await model.opened() ? model.studio : nil)
        studio.environment.saveSession = { _, _ throws(SessionFileError) in throw .writeFailed(step: "test", errno: EIO)
        }
        try studio.edit(ripple: false) { s throws(SessionError) in try s.addTrack("t1", name: "Host", layout: .mono) }
        var replied: Bool?
        var busyAtTheQuestion: [AgentBusy?] = []
        app.confirmQuit = { _, _, _ in
            busyAtTheQuestion = app.agentTargets().map(\.busy)
            return false
        }
        app.replyToTerminate = { replied = $0 }

        #expect(app.applicationShouldTerminate(NSApp) == .terminateLater)
        #expect(app.agents.state == .off, "C1: the server stops before the settle")
        await until("the Quit asks") { replied != nil }

        #expect(replied == false)
        #expect(busyAtTheQuestion == [.quit], "C4: a Quit refuses agent edits")
        await until("C1: a cancelled Quit keeps the server") { app.agents.state == .listening }
        #expect(FileManager.default.fileExists(atPath: socket.path))
        app.setAgents(false)
        await model.close()
        model.closeAnyway()
    }

    /// C4: a window that closes refuses agent edits. The test holds the settle of the close with
    /// a write turn.
    @Test func closingWindowRefusesEdits() async throws {
        let model = await app.open(try folder.package("closing"))
        let studio = try #require(await model.opened() ? model.studio : nil)
        #expect(app.agentTargets().map(\.busy) == [nil])
        let gate = AsyncGate()
        let held = Task { await studio.serialized { await gate.wait() } }
        await gate.entered()

        let closing = Task { await model.close() }
        await until("the close did not start") { studio.settling }
        #expect(app.agentTargets().map(\.busy) == [.closing], "C4: a closing window refuses agent edits")
        gate.open()
        await held.value
        await closing.value
    }

    /// Code gate 1 item 1: a window with a step of Export shows a dialog, so the app refuses an
    /// agent export, whose sheet could not show (decision 0049).
    @Test func anExportStepIsADialog() async throws {
        let model = await app.open(try folder.package("dialog"))
        let studio = try #require(await model.opened() ? model.studio : nil)
        #expect(app.agentTargets().first { $0.studio === studio }?.sheetCause() == nil)
        model.exportStep = .choosing
        #expect(
            app.agentTargets().first { $0.studio === studio }?.sheetCause() == .dialog, "the save panel is a dialog")
        model.exportStep = nil
        await model.close()
    }

    /// C4: an agent edit during a lane drag is refused, so it never joins the drag's undo step.
    @Test func dragRefusesEdits() async throws {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 20)
        let (model, studio, _, view) = try await openLanes(app, package)
        app.agents.start()
        defer { app.agents.stop() }
        view.viewWillMove(toWindow: nil)
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 100, y: 20), in: view))
        try #require(view.gesture.isActive, "a lane gesture")
        let track = try #require(studio.session.tracks.first?.id.rawValue)

        let outcome = await call("track_rename", ["package": package.path, "track": track, "name": "Agent"])

        #expect(outcome == .reply(.result(text: AgentBusy.drag.message(package: package.path), isError: true)))
        #expect(studio.session.tracks.first?.name != "Agent")
        _ = view.cancelGesture()
        await model.close()
    }

    /// C12: the mark shows while a bridge is connected and hides after the last one closes.
    @Test func agentMarkFollowsConnections() async throws {
        let model = await app.open(try folder.package("mark"))
        _ = try #require(await model.opened() ? model.studio : nil)
        let mark = try #require(model.chrome?.agentMark)
        #expect(!shown(mark))
        app.agents.start()
        defer { app.agents.stop() }

        let bridge = AgentBridge(socket: socket)
        #expect(bridge.connect())
        await until("the mark shows") { shown(mark) }
        #expect(mark.view.toolTip == L10n.agentMarkHelp.text)
        // The title bar sizes a trailing accessory from the frame of its view: a zero frame draws
        // the mark 2 pt wide, so the user sees no mark.
        model.window?.layoutIfNeeded()
        #expect(
            mark.view.frame.width >= mark.view.fittingSize.width && mark.view.fittingSize.width > 20,
            "C12: the mark is \(mark.view.frame.width) pt of \(mark.view.fittingSize.width) pt")
        bridge.disconnect()
        await until("C12: the mark leaves the title bar after the agent left") { !shown(mark) }
        await model.close()
    }

    /// C12: the mark stays while one of two bridges is connected, shows in a window that opens
    /// while an agent is connected, and leaves each window when the switch turns off.
    @Test func agentMarkFollowsTheCountAndTheSwitch() async throws {
        let first = await app.open(try folder.package("mark-1"))
        _ = try #require(await first.opened() ? first.studio : nil)
        let mark = try #require(first.chrome?.agentMark)
        app.agents.start()
        defer { app.agents.stop() }
        let one = AgentBridge(socket: socket)
        let two = AgentBridge(socket: socket)
        #expect(one.connect())
        #expect(two.connect())
        await until("two bridges show the mark") { app.agents.connected == 2 && shown(mark) }

        one.disconnect()
        await until("one bridge stays") { app.agents.connected == 1 }
        #expect(shown(mark), "C12: the mark left with one bridge still connected")

        let second = await app.open(try folder.package("mark-2"))
        _ = try #require(await second.opened() ? second.studio : nil)
        let other = try #require(second.chrome?.agentMark)
        await until("C12: a window that opens while an agent is connected shows the mark") { shown(other) }

        app.agents.stop()
        await until("C12: the switch off takes the mark from each window") { !shown(mark) && !shown(other) }
        two.disconnect()
        await second.close()
        await first.close()
    }

    /// A hidden trailing accessory still draws (probe), so the mark is in the title bar only while
    /// an agent is connected.
    private func shown(_ mark: NSTitlebarAccessoryViewController) -> Bool {
        mark.view.window != nil && !mark.view.isHiddenOrHasHiddenAncestor
    }

    /// C17: an agent edit moves no playhead, selection, scroll, or zoom.
    @Test func agentEditKeepsTheView() async throws {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 20)
        let (model, studio, _, view) = try await openLanes(app, package)
        app.agents.start()
        defer { app.agents.stop() }
        let before = (studio.playhead, model.timeline.selection, view.origin, view.framesPerPoint)
        let track = try #require(studio.session.tracks.first?.id.rawValue)

        let outcome = await call("track_rename", ["package": package.path, "track": track, "name": "Agent"])

        #expect(outcome == .reply(.result(text: "OK", isError: false)))
        #expect(studio.session.tracks.first?.name == "Agent")
        #expect(studio.undoAgent?.name == "Test Agent")
        #expect(studio.playhead == before.0)
        #expect(model.timeline.selection == before.1)
        #expect(view.origin == before.2 && view.framesPerPoint == before.3)
        await model.close()
    }

    /// C17: four calls at once, each on its own bridge connection, each answer within the bridge
    /// timeout. The session then has both names, both new tracks, and four more undo steps.
    @Test func fourCallsAtOnceEachAnswer() async throws {
        let package = try await timelinePackage(in: folder.url, tracks: 2, seconds: 1)
        let (model, studio, _, _) = try await openLanes(app, package)
        app.agents.start()
        defer { app.agents.stop() }
        let ids = studio.session.tracks.map(\.id.rawValue)
        let steps = studio.history.entries.count

        async let renameOne = call("track_rename", ["package": package.path, "track": ids[0], "name": "One"])
        async let renameTwo = call("track_rename", ["package": package.path, "track": ids[1], "name": "Two"])
        async let addA = call("track_add", ["package": package.path, "name": "Added A", "layout": "mono"])
        async let addB = call("track_add", ["package": package.path, "name": "Added B", "layout": "mono"])
        let outcomes = await [renameOne, renameTwo, addA, addB]

        for outcome in outcomes {
            guard case .reply(.result(let text, let isError)) = outcome else {
                Issue.record("no reply: \(outcome)")
                continue
            }
            #expect(!isError, "\(text)")
        }
        #expect(Set(studio.session.tracks.map(\.name)) == ["One", "Two", "Added A", "Added B"])
        #expect(studio.session.tracks.count == 4)
        #expect(studio.history.entries.count == steps + 4)
        await model.close()
    }

    // MARK: What an agent gets while the window cannot show the sheet of its call

    enum Dialog: CaseIterable {
        case exportPanel, alert, sheet
    }

    /// The window shows a dialog that only the user clears: `export` gets the text that asks the
    /// user, and writes no file. After the dialog goes, the same call writes it.
    @Test(arguments: Dialog.allCases) func aDialogAsksTheUserToCloseIt(dialog: Dialog) async throws {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 1, audio: true)
        try Data(count: 64).write(to: package.appending(path: "Clips/stray-\(UUID().uuidString).wav"))
        let (model, _, window, _) = try await openLanes(app, package)
        app.agents.start()
        defer { app.agents.stop() }
        let out = folder.url.appending(path: "mix.wav")
        let arguments: [String: any Sendable] = ["package": package.path, "out": out.path]
        switch dialog {
        case .exportPanel: model.exportStep = .choosing
        case .alert: model.alert = .error(.busy)
        case .sheet: model.removeUnusedFiles()
        }
        if dialog != .exportPanel { await until("the dialog shows") { window.attachedSheet != nil } }

        let refused = await call("export", arguments)

        let text =
            "\(package.path) is busy in Dirigible: its window shows an alert, a sheet, or a panel. "
            + "Ask the user to finish or close it in Dirigible, then try again."
        #expect(refused == .reply(.result(text: text, isError: true)))
        #expect(!FileManager.default.fileExists(atPath: out.path), "the export ran")
        model.exportStep = nil
        model.alert = nil
        model.unusedFiles = nil
        await until("the dialog goes") { window.attachedSheet == nil }

        let written = await call("export", arguments)

        #expect(written == .reply(.result(text: "OK", isError: false)))
        #expect(FileManager.default.fileExists(atPath: out.path), "the export wrote no file")
        await model.close()
    }

    /// The window runs an export that holds its first chunk until `release`.
    private func startWindowExport(_ model: SessionWindow, _ studio: Studio, _ window: NSWindow) async throws -> (
        FirstChunkHold, Task<Void, Never>
    ) {
        let release = FirstChunkHold()
        studio.environment.exportChunk = { release.step() }
        let source = try #require(model.source(of: .session, in: studio))
        let target = ExportTarget(url: folder.url.appending(path: "window.caf"), options: .render, confirmed: nil)
        let export = Task { await model.run(source, target, studio) }
        await until("the progress sheet shows") { window.attachedSheet != nil && studio.exportProgress != nil }
        return (release, export)
    }

    /// The progress sheet of a running export is not a dialog that the user closes: Cancel is
    /// the user's choice, and the end of the export clears it. So `record` gets the export cause.
    @Test func aRunningExportGivesRecordItsBusyCause() async throws {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 1, audio: true)
        let (model, studio, window, _) = try await openLanes(app, package)
        let (release, export) = try await startWindowExport(model, studio, window)

        let request = RecordRequest(armed: ["t1"], seconds: 30, playhead: nil)
        let answer = await model.askRecord(request, agent: AgentName(title: "Test Agent", clientName: "test"))

        #expect(answer == .busy(.export))
        release.release()
        await export.value
        await model.close()
    }

    /// The same, when the export of the window starts during the media check of an agent export.
    @Test func anExportThatStartsDuringTheMediaCheckGivesItsBusyCause() async throws {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 1, audio: true)
        let (model, studio, window, _) = try await openLanes(app, package)
        app.agents.start()
        defer { app.agents.stop() }
        let check = AsyncGate()
        studio.environment.beforeMediaCheck = { await check.wait() }
        let out = folder.url.appending(path: "mix.wav")
        let agent = Task { await call("export", ["package": package.path, "out": out.path]) }
        await check.entered()
        let (release, export) = try await startWindowExport(model, studio, window)
        check.open()

        let refused = await agent.value

        let text = "\(package.path) is busy in Dirigible: an export runs in its window. Try again later."
        #expect(refused == .reply(.result(text: text, isError: true)))
        #expect(!FileManager.default.fileExists(atPath: out.path), "the agent export ran")
        release.release()
        await export.value
        await model.close()
    }

    /// The media check of a user export shows no view: nothing for the user to close. `export`
    /// and `record` get the export cause, which ends with the try-again step.
    @Test func theMediaCheckOfTheWindowIsNotADialog() async throws {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 1, audio: true)
        let (model, _, _, _) = try await openLanes(app, package)
        app.agents.start()
        defer { app.agents.stop() }
        model.exportStep = .checking
        let out = folder.url.appending(path: "mix.wav")

        let refused = await call("export", ["package": package.path, "out": out.path])
        let request = RecordRequest(armed: ["t1"], seconds: 30, playhead: nil)
        let answer = await model.askRecord(request, agent: AgentName(title: "Test Agent", clientName: "test"))

        let text = "\(package.path) is busy in Dirigible: an export runs in its window. Try again later."
        #expect(refused == .reply(.result(text: text, isError: true)))
        #expect(answer == .busy(.export))
        #expect(!FileManager.default.fileExists(atPath: out.path), "the export ran")
        model.exportStep = nil
        await model.close()
    }
}

/// Holds the first chunk of an export until `release`, with a limit that a release ends before.
final class FirstChunkHold: Sendable {
    static let limit = Duration.seconds(30)
    private let state = OSAllocatedUnfairLock(initialState: (chunks: 0, released: false))

    func release() { state.withLock { $0.released = true } }

    func step() {
        guard
            state.withLock({ state in
                state.chunks += 1
                return state.chunks == 1
            })
        else { return }
        let end = ContinuousClock.now + Self.limit
        while !state.withLock({ $0.released }) {
            guard ContinuousClock.now < end else {
                Issue.record("No release in \(Self.limit)")
                return
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}
