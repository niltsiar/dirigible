import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `track_match_voice` on a package that the app has open: with `reference` it runs through
/// `Studio.matchVoice`, and the other modes run as edits of the studio (decisions 0049 and 0074).
/// Track `t3` "Voice" holds clip `R` of 12 s of white noise (the reference), and track `t1` holds
/// clip `V` of 12 s of the same noise through a low-pass.
@MainActor
struct LiveMatchVoiceTests {
    let package: LivePackage
    var clips: URL { package.url.appending(path: "Clips") }

    init() throws {
        package = try LivePackage()
        var session = try Session(contentsOf: package.url)
        try session.addTrack("t3", name: "Voice", layout: .mono)
        for (file, track, clip) in [("r", "t3", "R"), ("v", "t1", "V")] {
            try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: 576_000))
            try session.place(
                Clip(id: ClipID(clip), file: FileID(file), start: 0, offset: 0, length: 576_000), on: TrackID(track))
        }
        try session.write(to: package.url)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        for (file, dark) in [("r", false), ("v", true)] {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 576_000))
            buffer.frameLength = 576_000
            var (state, low) = (UInt64(7), 0.0)
            for frame in 0..<576_000 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let noise = Double(state >> 11) / Double(1 << 53) * 2 - 1
                low += (noise - low) * 0.12
                buffer.floatChannelData![0][frame] = Float(dark ? low * 1.5 : noise * 0.3)
            }
            try AVAudioFile(forWriting: clips.appending(path: "\(file).wav"), settings: format.settings)
                .write(from: buffer)
        }
    }

    func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted() }

    /// The reply is the line of the track, the match is one undo step with the agent name, and no
    /// file is written.
    @Test func runsInTheStudio() async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await send(
            folder.socket, "track_match_voice", ["package": package.path, "reference": "R", "tracks": ["t1"]])

        let match = try #require(studio.session.track("t1")?.match)
        #expect(outcome == .reply(.result(text: "t1: " + match.text, isError: false)), "\(outcome)")
        #expect(match.reference == "r" && match.amount == VoiceMatch.defaultAmount)
        #expect(studio.undoAgent?.name == "Test Agent")
        #expect(try names() == ["r.wav", "v.wav"])
        try studio.undo()
        #expect(studio.session.track("t1")?.match == nil && !studio.canUndo)
        await studio.settle()
    }

    /// The amount and the bypass in one call are one undo step, and a remove is one more. A track
    /// with no match refuses with the session text.
    @Test func editsRunInTheStudio() async throws {
        let studio = try await package.open()
        try await studio.matchVoice(reference: "R", tracks: ["t1"], agent: nil)
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let change = await send(
            folder.socket, "track_match_voice",
            ["package": package.path, "tracks": ["t1"], "amount": 40, "bypass": true])

        let match = try #require(studio.session.track("t1")?.match)
        #expect(change == .reply(.result(text: "t1: " + match.text, isError: false)), "\(change)")
        #expect(match.amount.percent == 40 && match.isBypassed && match.text.hasSuffix(", bypassed"))
        #expect(studio.undoAgent?.name == "Test Agent")
        try studio.undo()
        #expect(studio.session.track("t1")?.match?.amount == VoiceMatch.defaultAmount)
        #expect(studio.session.track("t1")?.match?.isBypassed == false)

        let remove = await send(
            folder.socket, "track_match_voice", ["package": package.path, "tracks": ["t1"], "remove": true])
        #expect(remove == .reply(.result(text: "t1: match removed", isError: false)), "\(remove)")
        #expect(studio.session.track("t1")?.match == nil)
        try studio.undo()
        #expect(studio.session.track("t1")?.match != nil)

        let none = await send(
            folder.socket, "track_match_voice", ["package": package.path, "tracks": ["t3"], "amount": 40])
        #expect(none == .reply(.result(text: "track \"t3\" has no voice match.", isError: true)), "\(none)")
        await studio.settle()
    }

    /// A refusal of the library reaches the agent with its text, and the studio keeps its session.
    @Test func refusalsKeepTheSession() async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let revision = studio.sessionRevision

        let unknown = await send(
            folder.socket, "track_match_voice", ["package": package.path, "reference": "zz", "tracks": ["t1"]])
        let past = await send(
            folder.socket, "track_match_voice",
            ["package": package.path, "reference": "R", "from": 0, "to": 576_001, "tracks": ["t1"]])

        let text = "the range must lie inside the reference clip, frames 0 to 576000."
        #expect(past == .reply(.result(text: text, isError: true)), "\(past)")
        guard case .reply(.result(let message, true)) = unknown else {
            Issue.record("unknown clip: \(unknown)")
            return
        }
        #expect(message.contains("zz"), "\(message)")
        #expect(studio.sessionRevision == revision && studio.session.track("t1")?.match == nil)
        await studio.settle()
    }
}
