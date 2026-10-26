import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `clip_split_stereo` on a package that the app has open: it runs through `Studio.splitStereo`
/// (decisions 0049 and 0053, criterion C8b). Track `t3` "Voice" (stereo) holds clip `s1` of 3 s of
/// `st.wav`, so each side has three blocks.
@MainActor
struct LiveSplitTests {
    let package: LivePackage
    var clips: URL { package.url.appending(path: "Clips") }
    var arguments: [String: any Sendable] { ["package": package.path, "clips": ["s1"]] }

    init() throws {
        package = try LivePackage()
        var session = try Session(contentsOf: package.url)
        try session.addFile(AudioFile(id: "st", path: "st.wav", layout: .stereo, length: 144_000))
        try session.addTrack("t3", name: "Voice", layout: .stereo)
        try session.place(Clip(id: "s1", file: "st", start: 0, offset: 0, length: 144_000), on: "t3")
        try session.write(to: package.url)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let file = try AVAudioFile(forWriting: clips.appending(path: "st.wav"), settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000))
        buffer.frameLength = 144_000
        for frame in 0..<144_000 {
            buffer.floatChannelData![0][frame] = Float(0.1 * sin(Double(frame) / 8))
            buffer.floatChannelData![1][frame] = Float(0.1 * sin(Double(frame) / 5))
        }
        try file.write(from: buffer)
    }

    func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted() }

    /// The reply is the line of the clip, the new tracks are "Voice L" and "Voice R" in every
    /// language, and the split is one undo step with the agent name that keeps the WAVs.
    @Test func splitRunsInTheStudio() async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await send(folder.socket, "clip_split_stereo", arguments)

        let session = studio.session
        #expect(
            session.tracks.map(\.name) == ["Host", "Music", "Voice", "Voice L", "Voice R"],
            "\(session.tracks.map(\.name))")
        let left = try #require(session.tracks.first { $0.name == "Voice L" }?.id)
        let right = try #require(session.tracks.first { $0.name == "Voice R" }?.id)
        let line = "s1 L\ts1 R\t\(left)\t\(right)"
        #expect(outcome == .reply(.result(text: line, isError: false)), "\(outcome)")
        #expect(session.clip("s1") == nil && session.clip("s1 L")?.clip.file == "st L")
        #expect(studio.undoAgent?.name == "Test Agent")
        let files = ["st L.wav", "st R.wav", "st.wav"]
        #expect(try names() == files)
        try studio.undo()
        #expect(studio.session.tracks.map(\.name) == ["Host", "Music", "Voice"] && !studio.canUndo)
        let afterUndo = try names()
        #expect(studio.session.clip("s1") != nil && afterUndo == files, "Undo keeps the WAVs")
        await studio.settle()
    }

    /// The Cancel of the split banner ends an agent split with no track and no new WAV, and the
    /// agent gets the text of the user cancel.
    @Test func cancelAddsNoTrack() async throws {
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        let studio = try await package.open()
        studio.environment.importStep = { hold.step() }
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let (socket, arguments) = (folder.socket, arguments)
        let call = Task { await send(socket, "clip_split_stereo", arguments) }
        await until("the split does not hold") { hold.isHeld }

        studio.cancelImport()
        hold.release()
        let outcome = await call.value

        let text = "The user cancelled the split in Dirigible. No track was added."
        #expect(outcome == .reply(.result(text: text, isError: true)), "\(outcome)")
        #expect(studio.session.tracks.count == 3 && studio.session.clip("s1") != nil && !studio.canUndo)
        #expect(try names() == ["st.wav"], "a cancelled split left a file")
        await studio.settle()
    }

    /// A take start in another studio ends the split with the take text.
    @Test func takeStartStopsTheSplit() async throws {
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        let studio = try await package.open()
        studio.environment.importStep = { hold.step() }
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let (socket, arguments) = (folder.socket, arguments)
        let call = Task { await send(socket, "clip_split_stereo", arguments) }
        await until("the split does not hold") { hold.isHeld }

        studio.endImport(.take)
        hold.release()
        let outcome = await call.value

        let text = "A take started in Dirigible, so the split stopped. No track was added."
        #expect(outcome == .reply(.result(text: text, isError: true)), "\(outcome)")
        #expect(studio.session.tracks.count == 3 && !studio.canUndo)
        #expect(try names() == ["st.wav"], "a stopped split left a file")
        await studio.settle()
    }
}
