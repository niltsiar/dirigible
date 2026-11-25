import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The transport tools on a package that the app has open (run agent-transport, criteria C4 to
/// C14 and C18). The package has clip `c1` of 3 s on `t1` (144 000 frames at 48 kHz). The Player
/// renders offline, so a play stays where it starts until a test renders it.
@MainActor
struct LiveTransportTests {
    let package: LivePackage
    let forward = Shuttle(direction: .forward, rate: .one)

    init() throws {
        package = try LivePackage()
        try package.addTone()
    }

    func open() async throws -> Studio {
        let studio = try await package.open()
        studio.environment.playerOutput = .offline
        return studio
    }

    func call(_ tool: String, _ arguments: [String: any Sendable] = [:], on socket: URL) async -> AgentBridge.Outcome {
        await send(socket, tool, ["package": package.path].merging(arguments) { $1 })
    }

    func reply(_ text: String, isError: Bool = false) -> AgentBridge.Outcome {
        .reply(.result(text: text, isError: isError))
    }

    var takeText: String {
        "\(package.path) records a take in Dirigible. transport_stop stops only a play; the user stops the take in "
            + "Dirigible."
    }

    // MARK: C10

    /// A take that records or finalizes: play and locate give the busy text, stop gives the take
    /// text, and the transport and the playhead do not change.
    @Test(arguments: [Studio.Transport.recording(take: 1), .finalizing(take: 1)])
    func aTakeRefusesTransport(state: Studio.Transport) async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let head = studio.playhead
        studio.transport = state
        defer { studio.transport = .idle }
        let busy = reply(AgentBusy.task.message(package: package.path), isError: true)

        let play = await call("transport_play", ["from": 100, "to": 200], on: folder.socket)
        let locate = await call("transport_locate", ["at": 500], on: folder.socket)
        let stop = await call("transport_stop", on: folder.socket)

        #expect(play == busy, "\(play)")
        #expect(locate == busy, "\(locate)")
        #expect(stop == reply(takeText, isError: true), "\(stop)")
        #expect(studio.transport == state)
        #expect(studio.playhead == head && studio.playback == .stopped)
    }

    // MARK: C2, C4, C4b, C5, C5b

    /// The server is on and no window has the package: the bridge runs the call on the files.
    @Test(arguments: [
        ("transport_play", [String: Int]()), ("transport_stop", [:]), ("transport_locate", ["at": 10]),
    ])
    func noWindowGivesTheFilesText(tool: String, arguments: [String: Int]) async throws {
        let folder = try SocketFolder()
        let server = AgentServer(socket: folder.socket) { [] }
        server.start()
        defer { server.stop() }
        let (path, socket) = (package.path, folder.socket)

        let answer = await onThread {
            var mcp = MCPServer(route: AgentBridge(socket: socket).route)
            return mcp.answer(callLine(tool, ["package": path].merging(arguments.mapValues { $0 as Any }) { $1 }))
        }

        let text =
            "To play, stop, or locate, open \(path) in Dirigible and turn on Let agents edit open sessions in Settings."
        #expect(toolText(answer) == (text, true))
    }

    @Test func playFromStoppedPlaysTheRange() async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await call("transport_play", ["from": 24_000, "to": 50_000], on: folder.socket)

        #expect(outcome == reply("Playing from 24000 to 50000."), "\(outcome)")
        #expect(studio.playback == .playing(forward))
        await studio.settle()
    }

    @Test func playWithNoRangePlaysFromThePlayhead() async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        await studio.perform(.seek(.frame(1000)))

        let plain = await call("transport_play", on: folder.socket)
        await studio.perform(.pause)
        let past = await call("transport_play", ["to": 200_000], on: folder.socket)

        #expect(plain == reply("Playing from 1000 to 144000."), "\(plain)")
        #expect(past == reply("Playing from 1000 to 144000."), "a to after the end gives the end: \(past)")
        await studio.settle()
    }

    /// The playhead of a new window is the session end, so a play with no range has nothing to play.
    @Test func aPlayAtTheEndPlaysNothing() async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await call("transport_play", on: folder.socket)

        let text =
            "Nothing changed: frame 144000 is at or after the end of the session (144000). Pass a from before that "
            + "end, or call transport_locate first."
        #expect(outcome == reply(text, isError: true), "\(outcome)")
        #expect(studio.playback == .stopped)
    }

    /// During a play, a `to` before the playhead changes nothing: the reply names `to`, and the
    /// play goes on with the same feed number.
    @Test func aToBeforeThePlayheadDuringAPlayChangesNothing() async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        _ = try await studio.play(from: 24_000, to: 50_000)
        let feed = studio.play.feed

        let outcome = await call("transport_play", ["to": 10_000], on: folder.socket)

        let text =
            "Nothing changed: frame 24000 is at or after to (10000). Pass a from before that end, or call "
            + "transport_locate first."
        #expect(outcome == reply(text, isError: true), "\(outcome)")
        #expect(studio.playback == .playing(forward) && studio.play.feed == feed)
        await studio.settle()
    }

    /// One case with `to`: a new play with the new end. One case with neither: the feed number
    /// and the bound of the running play stay.
    @Test func playWhilePlaying() async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        _ = try await studio.play(from: 24_000, to: 50_000)
        let feed = studio.play.feed

        let kept = await call("transport_play", on: folder.socket)
        let sameFeed = studio.play.feed
        let moved = await call("transport_play", ["to": 60_000], on: folder.socket)

        #expect(kept == reply("Playing from 24000 to 50000."), "\(kept)")
        #expect(sameFeed == feed, "no new feed")
        #expect(moved == reply("Playing from 24000 to 60000."), "\(moved)")
        #expect(studio.play.feed != feed)
        await studio.settle()
    }

    /// A user shuttle other than forward 1x: the call plays forward at 1x.
    @Test(arguments: [TransportCommand.reverse, .forward])
    func playDuringAShuttle(key: TransportCommand) async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        await studio.perform(.seek(.frame(100_000)))
        await studio.perform(key)
        if key == .forward { await studio.perform(key) }
        try #require(studio.playback != .playing(forward), "the shuttle runs")

        let outcome = await call("transport_play", ["to": 120_000], on: folder.socket)

        #expect(outcome == reply("Playing from 100000 to 120000."), "\(outcome)")
        #expect(studio.playback == .playing(forward))
        await studio.settle()
    }

    // MARK: C6, C7

    @Test func stopEndsThePlay() async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        _ = try await studio.play(from: 24_000, to: 50_000)

        let outcome = await call("transport_stop", on: folder.socket)

        #expect(studio.playback == .stopped)
        #expect(outcome == reply("Stopped at \(studio.playhead.count)."), "\(outcome)")
    }

    @Test func stopWhenStoppedReadsThePlayhead() async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        await studio.perform(.seek(.frame(1000)))
        let feed = studio.play.feed

        let outcome = await call("transport_stop", on: folder.socket)

        #expect(outcome == reply("Stopped at 1000."), "\(outcome)")
        #expect(studio.playhead == 1000 && studio.play.feed == feed)
    }

    @Test func locateWhenStopped() async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let inside = await call("transport_locate", ["at": 5000], on: folder.socket)
        let afterInside = (studio.playhead, studio.playback)
        let past = await call("transport_locate", ["at": 200_000], on: folder.socket)

        #expect(inside == reply("Stopped at 5000."), "\(inside)")
        #expect(afterInside == (5000, .stopped))
        #expect(past == reply("Stopped at 200000."), "an at after the end is allowed: \(past)")
        #expect(studio.playhead == 200_000)
    }

    @Test func locateWhilePlaying() async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        _ = try await studio.play(from: 24_000, to: 50_000)

        let before = await call("transport_locate", ["at": 30_000], on: folder.socket)
        let after = await call("transport_locate", ["at": 60_000], on: folder.socket)
        let end = await call("transport_locate", ["at": 144_000], on: folder.socket)

        #expect(before == reply("Playing from 30000 to 50000."), "a seek before the end keeps it: \(before)")
        #expect(after == reply("Playing from 60000 to 144000."), "a seek after the end drops it: \(after)")
        #expect(end == reply("Stopped at 144000."), "a seek at the session end stops the play: \(end)")
        #expect(studio.playback == .stopped && studio.playhead == 144_000)
    }

    /// C8: a trim of `c1` to 60 000 during a play with the end 100 000. The Player stops at
    /// 60 000, so a play with neither argument and a locate before 60 000 name 60 000.
    @Test func anEditThatShortensTheSessionMovesTheEnd() async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        _ = try await studio.play(from: 24_000, to: 100_000)
        try studio.edit(ripple: false) { session throws(SessionError) in try session.trim("c1", to: 0..<60_000) }
        try #require(studio.session.end == 60_000, "the edit shortens the session")

        let kept = await call("transport_play", on: folder.socket)
        let moved = await call("transport_locate", ["at": 30_000], on: folder.socket)

        #expect(kept == reply("Playing from 24000 to 60000."), "\(kept)")
        #expect(moved == reply("Playing from 30000 to 60000."), "\(moved)")
        await studio.settle()
    }

    @Test func locateDuringAReversePlay() async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        await studio.perform(.seek(.frame(100_000)))
        await studio.perform(.reverse)

        let outcome = await call("transport_locate", ["at": 50_000], on: folder.socket)

        #expect(outcome == reply("Playing from 50000 to 0, reverse at 1x."), "\(outcome)")
        await studio.settle()
    }

    // MARK: C11, C12, C13

    /// A held level is only in `DirigibleAudioTests`, so the state is set here; the real run is
    /// `StudioPlayRangeTests.aPlayDuringALevelThrowsBusy`.
    @Test func aBlockingRunRefusesPlay() async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let head = studio.playhead
        studio.transport = .leveling
        defer { studio.transport = .idle }
        let busy = reply(AgentBusy.task.message(package: package.path), isError: true)

        let play = await call("transport_play", ["from": 0], on: folder.socket)
        let locate = await call("transport_locate", ["at": 10], on: folder.socket)
        let stop = await call("transport_stop", on: folder.socket)

        #expect(play == busy && locate == busy, "\(play) \(locate)")
        #expect(stop == reply("Stopped at \(head.count)."), "\(stop)")
        #expect(studio.playhead == head && studio.playback == .stopped)
    }

    @Test(arguments: [AgentBusy.drag, .asking, .closing, .quit])
    func eachBusyCauseRefusesPlay(cause: AgentBusy) async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio, busy: cause)
        defer { server.stop() }
        try await expectRefused(studio, cause, folder)
    }

    @Test(arguments: [AgentBusy.dialog, .export])
    func eachSheetCauseRefusesPlay(cause: AgentBusy) async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio, sheetCause: { cause })
        defer { server.stop() }
        try await expectRefused(studio, cause, folder)
    }

    /// Play and locate give the text of the cause; stop acts in the same state.
    func expectRefused(_ studio: Studio, _ cause: AgentBusy, _ folder: SocketFolder) async throws {
        let busy = reply(cause.message(package: package.path), isError: true)
        let head = studio.playhead

        let play = await call("transport_play", ["from": 0, "to": 100], on: folder.socket)
        let locate = await call("transport_locate", ["at": 10], on: folder.socket)
        #expect(play == busy && locate == busy, "\(play) \(locate)")
        #expect(studio.playhead == head && studio.playback == .stopped)

        _ = try await studio.play(from: 24_000, to: 50_000)
        let stop = await call("transport_stop", on: folder.socket)
        #expect(studio.playback == .stopped, "stop acts in a busy window")
        #expect(stop == reply("Stopped at \(studio.playhead.count)."), "\(stop)")
    }

    @Test func transportIsNoEdit() async throws {
        let studio = try await open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let xml = package.url.appending(path: "session.xml")
        let files = { try FileManager.default.subpathsOfDirectory(atPath: package.path).sorted() }
        let (revision, bytes, listing) = (studio.sessionRevision, try Data(contentsOf: xml), try files())

        _ = await call("transport_play", ["from": 1000, "to": 5000], on: folder.socket)
        _ = await call("transport_locate", ["at": 3000], on: folder.socket)
        _ = await call("transport_stop", on: folder.socket)

        #expect(studio.sessionRevision == revision && !studio.canUndo)
        #expect(try Data(contentsOf: xml) == bytes)
        #expect(try files() == listing)
        await studio.settle()
    }

    // MARK: C14, C18

    @Test func eachOutcomeHasItsText() {
        let cases: [(TransportOutcome, String)] = [
            (.state(.stopped(at: 7)), "Stopped at 7."),
            (.state(.playing(from: 7, to: 9, shuttle: forward)), "Playing from 7 to 9."),
            (
                .state(.playing(from: 7, to: 0, shuttle: Shuttle(direction: .reverse, rate: .two))),
                "Playing from 7 to 0, reverse at 2x."
            ),
            (
                .state(.playing(from: 7, to: 9, shuttle: Shuttle(direction: .forward, rate: .half))),
                "Playing from 7 to 9, forward at 0.5x."
            ),
            (
                .pastEnd(start: 9, end: .session(9)),
                "Nothing changed: frame 9 is at or after the end of the session (9). Pass a from before that end, or "
                    + "call transport_locate first."
            ),
            (
                .pastEnd(start: 9, end: .to(5)),
                "Nothing changed: frame 9 is at or after to (5). Pass a from before that end, or call "
                    + "transport_locate first."
            ),
            (
                .superseded,
                "The user or another call changed the transport during this call. A new transport_play plays again."
            ),
            (.failed(.outputUnavailable(-10851)), "Nothing plays: the audio output did not start (error -10851)."),
            (.failed(.packageUnavailable), "Nothing plays: the session package is not available."),
            (
                .failed(.noFreeDescriptor(24)),
                "Nothing plays: Dirigible has no free file descriptor (errno 24)."
            ),
            (.failed(.outputChanged), "Nothing plays: the audio output changed."),
        ]
        for (outcome, text) in cases {
            let isError: Bool
            if case .state = outcome { isError = false } else { isError = true }
            #expect(outcome.reply == .result(text: text, isError: isError), "\(outcome)")
        }
    }
}
