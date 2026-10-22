import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The take sync note of an agent call on a package that the app has open (decision 0061, C7).
/// The note comes from the change of the studio, so it reads no file.
@MainActor
struct LiveTakeSyncNoteTests {
    static func insert(_ path: String, at: Int) -> [String: any Sendable] {
        ["package": path, "at": at, "length": 24_000, "track": ["t1"]]
    }

    static func reply(_ text: String) -> AgentBridge.Outcome { .reply(.result(text: text, isError: false)) }

    /// Take 1 on `t1` at 96 000 (offset 2 s): an insert inside it gives one line, a no-op edit
    /// after the break gives none, and a second insert keeps it broken with no line.
    @Test func aLiveInsertReportsTheBreakOnce() async throws {
        let package = try LiveTakeMapTests.takePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let first = await send(folder.socket, "clip_ripple_insert", Self.insert(package.path, at: 120_000))
        let noOp = await send(folder.socket, "track_rename", ["package": package.path, "track": "t1", "name": "Host"])
        let second = await send(folder.socket, "clip_ripple_insert", Self.insert(package.path, at: 100_000))

        #expect(
            first == Self.reply("OK\nTake sync: take 1 in sync, offset 2.000 s -> broken from 0:00:03.000 (2 shifts)"))
        #expect(noOp == Self.reply("OK"))
        #expect(second == Self.reply("OK"))
        await studio.settle()
    }

    @Test func noTakeAudioGivesNoLine() async throws {
        let package = try LivePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await send(folder.socket, "clip_ripple_insert", Self.insert(package.path, at: 0))

        #expect(outcome == Self.reply("OK"))
        await studio.settle()
    }

    /// Take 2 ends in the window (a retry of its finalize), so its anchor reaches the studio only
    /// with the take outcome. An agent insert inside take 2 gives one line that names take 2.
    @Test func aTakeRecordedInTheWindowGetsItsLine() async throws {
        let package = try LivePackage()
        try package.addPendingTake()
        try finalizeTake(of: Session(contentsOf: package.url), in: package.url).write(to: package.url)
        try package.addPendingTake(2, playhead: 96_000)
        let studio = try await package.open(pending: 2)
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        try await studio.retryFinalize()
        try #require(studio.pendingTake == nil && studio.takeError == nil)

        let outcome = await send(folder.socket, "clip_ripple_insert", Self.insert(package.path, at: 110_000))

        #expect(
            outcome == Self.reply("OK\nTake sync: take 2 in sync, offset 2.000 s -> broken from 0:00:02.792 (2 shifts)")
        )
        await studio.settle()
    }

    /// A live import over the one moved part of take 1 removes it: the job gives the line from
    /// broken back to in sync.
    @Test func aLiveImportOverTheMovedClipGivesTheLine() async throws {
        let package = try LiveTakeMapTests.takePackage()
        let source = package.folder.appending(path: "Voice.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for frame in 0..<48_000 { buffer.floatChannelData![0][frame] = Float(0.1 * sin(Double(frame) / 8)) }
        // The file closes at the end of the block, so the import reads a whole WAV.
        do { try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer) }
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let insert = await send(folder.socket, "clip_ripple_insert", Self.insert(package.path, at: 120_000))
        let imported = await send(
            folder.socket, "import",
            [
                "package": package.path, "file": source.path, "track": "t1", "at": 144_000, "length": 24_000,
                "no_level": true,
            ])

        #expect(
            insert == Self.reply("OK\nTake sync: take 1 in sync, offset 2.000 s -> broken from 0:00:03.000 (2 shifts)"))
        #expect(
            imported
                == Self.reply("Voice\nTake sync: take 1 broken from 0:00:03.000 (2 shifts) -> in sync, offset 2.000 s"))
        await studio.settle()
    }
}
