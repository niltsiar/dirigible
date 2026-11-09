import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `clip_level_over_time` on a package that the app has open: it runs through `Studio.levelOverTime`
/// and `Studio.removeLevelOverTime` (decisions 0049 and 0060). Track `t3` "Voice" (mono)
/// holds clip `n1` of 3 s of `nv.wav`: 1.5 s of a loud tone, then 1.5 s of a quiet one.
@MainActor
struct LiveLevelOverTimeTests {
    let package: LivePackage
    var clips: URL { package.url.appending(path: "Clips") }

    init() throws {
        package = try LivePackage()
        var session = try Session(contentsOf: package.url)
        try session.addFile(AudioFile(id: "nv", path: "nv.wav", layout: .mono, length: 144_000))
        try session.addTrack("t3", name: "Voice", layout: .mono)
        try session.place(Clip(id: "n1", file: "nv", start: 0, offset: 0, length: 144_000), on: "t3")
        try session.write(to: package.url)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: clips.appending(path: "nv.wav"), settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000))
        buffer.frameLength = 144_000
        for frame in 0..<144_000 {
            let amplitude: Float = frame < 72_000 ? 0.2 : 0.05
            buffer.floatChannelData![0][frame] = amplitude * Float(sin(2 * .pi * 1_000 * Double(frame) / 48_000))
        }
        try file.write(from: buffer)
    }

    func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted() }

    /// The reply is the line of the clip, the ride is one undo step with the agent name, and no
    /// file is written.
    @Test func rideRunsInTheStudio() async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await send(folder.socket, "clip_level_over_time", ["package": package.path, "clips": ["n1"]])

        let clip = try #require(studio.session.clip("n1")?.clip)
        let summary = try #require(clip.rideSummary)
        let line = RideWork(clips: ["n1"], clear: false, range: nil).lines(changed: [], in: studio.session)
        #expect(outcome == .reply(.result(text: line.joined(separator: "\n"), isError: false)), "\(outcome)")
        #expect(summary.lowest < 0 && summary.highest > 0, "\(summary): the loud half is cut, the quiet half lifted")
        #expect(studio.undoAgent?.name == "Test Agent")
        #expect(try names() == ["nv.wav"])
        try studio.undo()
        #expect(studio.session.clip("n1")?.clip.ride.isEmpty == true && !studio.canUndo)
        await studio.settle()
    }

    /// `clear` runs in the studio too: the reply names the removed ride, and the remove is one
    /// undo step that brings the ride back.
    @Test func clearRunsInTheStudio() async throws {
        let studio = try await package.open()
        _ = try await studio.levelOverTime(["n1"], agent: nil)
        let ridden = try #require(studio.session.clip("n1")?.clip.ride)
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await send(
            folder.socket, "clip_level_over_time", ["package": package.path, "clips": ["n1"], "clear": true])

        #expect(outcome == .reply(.result(text: "n1: ride removed", isError: false)), "\(outcome)")
        #expect(studio.session.clip("n1")?.clip.ride.isEmpty == true)
        #expect(studio.undoAgent?.name == "Test Agent")
        try studio.undo()
        #expect(studio.session.clip("n1")?.clip.ride == ridden)
        await studio.settle()
    }
}
