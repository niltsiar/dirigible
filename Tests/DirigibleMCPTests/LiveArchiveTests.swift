import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// A live MCP call on an archived window unarchives first, then runs once more (decision 0072,
/// run criterion C9 live part). The package has clip `c1` of 3 s on `t1`, on `tone.wav`, and the
/// pool file `copy.wav`, so the unarchive reports a fraction below 1. Both files are 24-bit
/// integer WAVs: the archive keeps a float WAV as it is (`KeptReason.notArchivable`).
@MainActor
struct LiveArchiveTests {
    let package: LivePackage

    init() throws {
        package = try LivePackage()
        var session = try Session(contentsOf: package.url)
        let clips = package.url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        for name in ["tone", "copy"] {
            try session.addFile(AudioFile(id: FileID(name), path: "\(name).wav", layout: .mono, length: 144_000))
            try writeWAV(clips.appending(path: "\(name).wav"), length: 144_000) { frames in
                frames.map { Float(0.1 * sin(Double($0) / 8)) }
            }
        }
        try session.place(Clip(id: "c1", file: "tone", start: 0, offset: 0, length: 144_000), on: "t1")
        try session.write(to: package.url)
    }

    var clipNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: "Clips").path)) ?? [])
            .sorted()
    }

    func archived() async throws -> Studio {
        let studio = try await package.open()
        studio.environment.playerOutput = .offline
        _ = try await studio.archive { _ in }
        try #require(clipNames == ["copy.flac", "tone.flac"])
        return studio
    }

    /// Asserts the state after an unarchive: each WAV is back, and the session on disk has no
    /// attribute.
    func expectUnarchived(_ studio: Studio, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(clipNames == ["copy.wav", "tone.wav"], "\(clipNames)", sourceLocation: sourceLocation)
        #expect(!studio.isArchived, sourceLocation: sourceLocation)
        #expect(try Session(contentsOf: package.url).archive == nil, sourceLocation: sourceLocation)
    }

    /// A short tool (`marker_set`, through `liveCall`): it has no progress of its own, so each
    /// progress line comes from the unarchive.
    @Test func aShortLiveEditOnAnArchivedWindowUnarchivesFirst() async throws {
        let studio = try await archived()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let (sent, socket, path) = (Sent(), folder.socket, package.path)

        let outcome = await onThread {
            let control = CallControl(token: 1, interval: .zero, send: sent.send, poll: { _ in false }, step: {})
            return AgentBridge(socket: socket, timeout: .seconds(120)).call(
                tool: "marker_set", arguments: ["package": path, "id": "m1", "name": "Intro", "at": 4_800],
                client: testClient, control: control)
        }

        #expect(outcome == .reply(.result(text: "m1", isError: false)), "\(outcome)")
        #expect(studio.session.markers["m1"]?.name == "Intro")
        #expect(sent.progress(token: 1) == [50], "\(sent.progress(token: 1))")
        try expectUnarchived(studio)
        await studio.settle()
    }

    /// A long tool (`level`, through `liveJob`).
    @Test func aLongLiveEditOnAnArchivedWindowUnarchivesFirst() async throws {
        let studio = try await archived()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await send(folder.socket, "level", ["package": package.path])

        guard case .reply(.result(let text, isError: false)) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(text.hasPrefix("c1\t") && text.hasSuffix("Clips changed: 1."), "\(text)")
        #expect((studio.session.clip("c1")?.clip.gain.dB ?? 0) > 1, "the level did not run")
        try expectUnarchived(studio)
        await studio.settle()
    }

    /// A live play runs after the unarchive (C18 `PLAY miss`).
    @Test func aLivePlayOnAnArchivedWindowUnarchivesFirst() async throws {
        let studio = try await archived()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await send(folder.socket, "transport_play", ["package": package.path, "from": 0, "to": 4_800])

        #expect(outcome == .reply(.result(text: "Playing from 0 to 4800.", isError: false)), "\(outcome)")
        try expectUnarchived(studio)
        await studio.settle()
    }

    /// A live call during a running archive job gets the busy text and starts no unarchive.
    @Test func aLiveEditDuringAnArchiveJobIsBusy() async throws {
        let studio = try await package.open()
        let hold = ChunkHold(at: 1)
        defer { hold.release() }
        studio.environment.archiveBlock = { hold.step() }
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let job = Task { try await studio.archive { _ in } }
        await until("the archive did not hold") { hold.isHeld }

        let outcome = await send(
            folder.socket, "marker_set", ["package": package.path, "id": "m1", "name": "Intro", "at": 4_800])

        #expect(outcome == .reply(.result(text: AgentBusy.task.message(package: package.path), isError: true)))
        #expect(studio.session.markers.isEmpty)
        hold.release()
        _ = try await job.value
        #expect(clipNames == ["copy.flac", "tone.flac"], "the busy call stopped the archive")
        #expect(studio.isArchived)
        await studio.settle()
    }
}
