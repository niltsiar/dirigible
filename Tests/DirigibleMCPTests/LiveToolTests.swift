import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The tools on a package that the app has open (decision 0046, criteria C2 to C7 of run
/// 2026-10-12-mcp-in-app). Each call goes over a real socket.
@MainActor
struct LiveToolTests {
    let ok = AgentBridge.Outcome.reply(.result(text: "OK", isError: false))

    /// C2: a live edit changes the studio at once, as one undo entry with the agent name.
    @Test func renameRunsInTheStudio() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let revision = studio.sessionRevision

        let outcome = await send(
            folder.socket, "track_rename", ["package": package.path, "track": "t1", "name": "Guest"])

        #expect(outcome == ok, "C2: the live edit did not run")
        #expect(studio.session.track("t1")?.name == "Guest")
        #expect(studio.sessionRevision == revision + 1)
        #expect(studio.canUndo)
        #expect(studio.undoAgent == AgentName(title: "Test Agent", clientName: nil))
        await studio.settle()
    }

    /// C2 negative control: with the server stopped, the bridge runs the call on the files, and
    /// the lock of the open studio refuses it.
    @Test func stoppedServerGivesTheFileRefusal() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        server.stop()
        let (path, socket) = (package.path, folder.socket)

        let answer = await onThread {
            var mcp = MCPServer(route: AgentBridge(socket: socket).route)
            return mcp.answer(callLine("track_rename", ["package": path, "track": "t1", "name": "Guest"]))
        }

        #expect(toolText(answer) == ("\(path) is open in Dirigible.", true))
        #expect(studio.session.track("t1")?.name == "Host")
        await studio.settle()
    }

    /// C3: under a pending take, a live ripple gives the text of `.rippleBlocked` and changes nothing.
    @Test func rippleUnderPendingTakeIsRefused() async throws {
        let package = try LivePackage()
        try package.addPendingTake()
        let studio = try await package.open(pending: true)
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let before = studio.session

        let outcome = await send(
            folder.socket, "clip_ripple_delete", ["package": package.path, "from": 0, "to": 48_000])

        let text = StudioError.rippleBlocked.message(package: package.path)
        #expect(outcome == .reply(.result(text: text, isError: true)), "C3: a live ripple under a pending take ran")
        #expect(studio.session == before)
        await studio.settle()
    }

    /// C3: under the same pending take, a live edit that is not a ripple runs, as in the app.
    @Test func plainEditUnderPendingTakeRuns() async throws {
        let package = try LivePackage()
        try package.addPendingTake()
        let studio = try await package.open(pending: true)
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await send(
            folder.socket, "track_rename", ["package": package.path, "track": "t2", "name": "Jingle"])

        #expect(outcome == ok, "C3: a plain live edit under a pending take was refused")
        #expect(studio.session.track("t2")?.name == "Jingle")
        await studio.settle()
    }

    /// C4: a studio that is not idle, and a window that the app marks busy, refuse a live edit.
    @Test func editWhileBusyIsRefused() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        func busy(_ cause: AgentBusy) -> AgentBridge.Outcome {
            .reply(.result(text: cause.message(package: package.path), isError: true))
        }
        let rename: [String: any Sendable] = ["package": package.path, "track": "t1", "name": "Guest"]

        let (server, folder) = try liveServer(studio)
        studio.transport = .leveling
        #expect(await send(folder.socket, "track_rename", rename) == busy(.task), "a studio that levels")
        studio.transport = .idle
        server.stop()

        let (marked, other) = try liveServer(studio, busy: .drag)
        defer { marked.stop() }
        #expect(await send(other.socket, "track_rename", rename) == busy(.drag), "a window that the app marks busy")
        #expect(studio.session.track("t1")?.name == "Host")
        #expect(!studio.canUndo)
        await studio.settle()
    }

    /// C4: a live edit during `settle()` (a close or a Quit) is refused, so an edit that gets OK is
    /// on disk before the window closes. A held write turn keeps `settle()` open, and the call
    /// goes only after `settling` is true (plan gate 2 item 3).
    @Test func editDuringSettleIsRefused() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let gate = Gate()
        let held = Task { await studio.serialized { await gate.wait() } }
        await until("the write turn is not held") { gate.waiting }
        let settled = Task { await studio.settle() }
        await until("settle did not start") { studio.settling }

        let outcome = await send(
            folder.socket, "track_rename", ["package": package.path, "track": "t1", "name": "Guest"])

        #expect(studio.settling, "the call came during the settle")
        #expect(
            outcome == .reply(.result(text: AgentBusy.task.message(package: package.path), isError: true)),
            "C4: a live edit during settle ran")
        gate.open()
        await held.value
        await settled.value
        #expect(studio.session.track("t1")?.name == "Host")
    }

    /// C5: the reads of a live call read the studio: a change that the autosave has not written
    /// yet shows at once.
    @Test func infoReadsTheStudio() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let gate = Gate()
        let held = Task { await studio.serialized { await gate.wait() } }
        await until("the write turn is not held") { gate.waiting }
        try studio.edit { session throws(SessionError) in
            try session.renameTrack("t1", to: "Unsaved")
            var episode = session.episode
            try? episode.set(.title, text: "Pilot")
            session.setEpisode(episode)
        }

        let info = await send(folder.socket, "session_info", ["package": package.path])
        let episode = await send(folder.socket, "episode_get", ["package": package.path])
        let backups = await send(folder.socket, "backup_list", ["package": package.path])

        #expect(replyText(info).contains("\"Unsaved\""), "session_info: \(info)")
        #expect(replyText(episode) == #"{"title":"Pilot"}"#)
        #expect(replyText(backups) == "No backups.")
        #expect(try Session(contentsOf: package.url).track("t1")?.name == "Host", "the autosave waits")
        gate.open()
        await held.value
        await studio.settle()
    }

    /// C6: a path through a symlink, or with a trailing slash, runs live. A package that no
    /// window has gets "not open", and a studio of another package never runs the call.
    @Test func symlinkPathRunsLive() async throws {
        let package = try LivePackage()
        let other = try LivePackage(name: "Other")
        let studio = try await package.open()
        let otherStudio = try await other.open()
        let folder = try SocketFolder()
        let server = AgentServer(socket: folder.socket) {
            [AgentTarget(studio: otherStudio), AgentTarget(studio: studio)]
        }
        server.start()
        defer { server.stop() }
        let link = package.folder.appending(path: "Link.dirigible")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package.url)
        let closed = try LivePackage(name: "Closed")

        let viaLink = await send(folder.socket, "track_rename", ["package": link.path, "track": "t1", "name": "A"])
        let withSlash = await send(
            folder.socket, "track_rename", ["package": package.path + "/", "track": "t2", "name": "B"])
        let notOpen = await send(folder.socket, "track_rename", ["package": closed.path, "track": "t1", "name": "C"])

        #expect(viaLink == ok, "C6: the symlink path did not run live")
        #expect(withSlash == ok, "C6: the path with a trailing slash did not run live")
        #expect(notOpen == .reply(.notOpen), "C6: a closed package did not get not open")
        #expect(studio.session.track("t1")?.name == "A")
        #expect(studio.session.track("t2")?.name == "B")
        #expect(otherStudio.session.track("t1")?.name == "Host", "the other studio did not change")
        #expect(try Session(contentsOf: closed.url).track("t1")?.name == "Host")
        await studio.settle()
        await otherStudio.settle()
    }

    /// C6: on a volume that ignores case (the default APFS), a path in another case names the same
    /// package, so it runs live.
    @Test func pathInAnotherCaseRunsLive() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let upper = package.folder.appending(path: "SHOW.dirigible")
        try #require(FileManager.default.fileExists(atPath: upper.path), "the volume does not ignore case")

        let outcome = await send(folder.socket, "track_rename", ["package": upper.path, "track": "t1", "name": "A"])

        #expect(outcome == .reply(.result(text: "OK", isError: false)), "C6: a path in another case did not run live")
        #expect(studio.session.track("t1")?.name == "A")
        await studio.settle()
    }

    /// C7: a call that copies a file into an open package is refused with the app text.
    @Test func fileToolsAreRefusedLive() async throws {
        let package = try LivePackage()
        let source = try LivePackage(name: "Source")
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let before = studio.session
        let image = package.folder.appending(path: "art.png").path
        let refused = AgentBridge.Outcome.reply(
            .result(
                text: "\(package.path) is open in Dirigible. Do this in the app, or close the window.", isError: true))

        let calls: [(String, [String: any Sendable])] = [
            ("marker_set", ["package": package.path, "name": "A", "at": 0, "image": image]),
            ("episode_set", ["package": package.path, "artwork": image]),
            ("backup_revert", ["package": package.path, "name": "session-20261009T081530.250Z.xml"]),
            (
                "clip_paste",
                [
                    "package": package.path, "from": 0, "to": 100, "track": ["t1"], "at": 0, "onto": ["t1"],
                    "source": source.path,
                ]
            ),
        ]
        for (tool, arguments) in calls {
            #expect(await send(folder.socket, tool, arguments) == refused, "\(tool)")
        }
        #expect(studio.session == before)
        await studio.settle()
    }

    /// C7: `marker_set` with no image file runs live in one `Studio.edit`; an empty image runs too.
    @Test func markerSetRunsLive() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let added = await send(
            folder.socket, "marker_set", ["package": package.path, "id": "m1", "name": "Intro", "at": 4_800])
        let cleared = await send(folder.socket, "marker_set", ["package": package.path, "id": "m1", "image": ""])
        let incomplete = await send(folder.socket, "marker_set", ["package": package.path, "name": "No position"])

        #expect(added == .reply(.result(text: "m1", isError: false)))
        #expect(cleared == .reply(.result(text: "m1", isError: false)))
        #expect(incomplete == .reply(.result(text: "a new marker needs a name and a position.", isError: true)))
        #expect(studio.session.markers["m1"]?.name == "Intro")
        #expect(studio.session.markers["m1"]?.position == 4_800)
        #expect(studio.undoAgent?.name == "Test Agent")
        await studio.settle()
    }

    /// C7: `episode_set` with no artwork file runs live in one `Studio.edit`.
    @Test func episodeSetRunsLive() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let revision = studio.sessionRevision

        let outcome = await send(
            folder.socket, "episode_set", ["package": package.path, "title": "Pilot", "artwork": ""])

        #expect(outcome == ok)
        #expect(studio.session.episode.title?.text == "Pilot")
        #expect(studio.sessionRevision == revision + 1, "one undo entry")
        await studio.settle()
    }
}

/// The text of a reply, or an empty text and an issue.
func replyText(_ outcome: AgentBridge.Outcome) -> String {
    guard case .reply(.result(let text, false)) = outcome else {
        Issue.record("not a result: \(outcome)")
        return ""
    }
    return text
}
