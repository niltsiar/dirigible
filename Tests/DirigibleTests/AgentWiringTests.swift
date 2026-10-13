import AppKit
import DirigibleCore
import Foundation
import Testing

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
        try studio.edit { s throws(SessionError) in try s.addTrack("t1", name: "Host", layout: .mono) }
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
        // A hidden trailing accessory still draws (probe), so the mark is in the title bar only
        // while an agent is connected.
        let shown = { mark.view.window != nil && !mark.view.isHiddenOrHasHiddenAncestor }
        #expect(!shown())
        app.agents.start()
        defer { app.agents.stop() }

        let bridge = AgentBridge(socket: socket)
        #expect(bridge.connect())
        await until("the mark shows") { shown() }
        #expect(mark.view.toolTip == L10n.agentMarkHelp.text)
        // The title bar sizes a trailing accessory from the frame of its view: a zero frame draws
        // the mark 2 pt wide, so the user sees no mark.
        model.window?.layoutIfNeeded()
        #expect(
            mark.view.frame.width >= mark.view.fittingSize.width && mark.view.fittingSize.width > 20,
            "C12: the mark is \(mark.view.frame.width) pt of \(mark.view.fittingSize.width) pt")
        bridge.disconnect()
        await until("the mark hides") { !shown() }
        #expect(!shown(), "C12: the mark stays in the title bar after the agent left")
        await model.close()
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
}
