import DirigibleCore
import Foundation
import Testing

/// `dirigible level` (run 8b criterion 14). Track t1 (stereo): `loud` of a -23 dBFS sine, `quiet`
/// of a -30 dBFS sine with +2 dB, and `hush` of silence. Track t2 (mono): `mono` of a -23 dBFS
/// sine, and `gone`, whose WAV is not on the disk.
struct LevelCommandTests {
    static func package() throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        for (id, layout) in [
            ("loud", ChannelLayout.stereo), ("quiet", .stereo), ("hush", .stereo), ("mono", .mono), ("gone", .mono),
        ] {
            try session.addFile(AudioFile(id: FileID(id), path: "\(id).wav", layout: layout, length: 480_000))
        }
        try session.addTrack("t1", name: "Host", layout: .stereo)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.place(Clip(id: "loud", file: "loud", start: 0, offset: 0, length: 480_000), on: "t1")
        try session.place(
            Clip(id: "quiet", file: "quiet", start: 480_000, offset: 0, length: 480_000, gain: Gain(dB: 2)!), on: "t1")
        try session.place(Clip(id: "hush", file: "hush", start: 960_000, offset: 0, length: 480_000), on: "t1")
        try session.place(Clip(id: "mono", file: "mono", start: 0, offset: 0, length: 480_000), on: "t2")
        try session.place(Clip(id: "gone", file: "gone", start: 480_000, offset: 0, length: 480_000), on: "t2")
        let package = try TemporaryPackage(session)
        let clips = package.url.appending(path: "Clips")
        try LoudnessCommandTests.writeWAV(clips.appending(path: "loud.wav"), seconds: 10)
        try LoudnessCommandTests.writeWAV(clips.appending(path: "quiet.wav"), seconds: 10, dBFS: -30)
        try LoudnessCommandTests.writeWAV(clips.appending(path: "hush.wav"), seconds: 10, dBFS: -.infinity)
        try LoudnessCommandTests.writeWAV(clips.appending(path: "mono.wav"), seconds: 10, channels: 1)
        return package
    }

    @Test func eachClipGetsItsTarget() async throws {
        let package = try Self.package()
        let level = try await package.run("level", "PKG")
        let expected = "loud\t+7.0 dB\nquiet\t+14.0 dB\nhush\tnone\nmono\t+7.0 dB\ngone\tunreadable\n"
        #expect(level == CLIResult(status: 0, stdout: expected, stderr: ""), "level: \(level)")
        let loudness = try await package.run("loudness", "PKG", "loud", "quiet", "mono")
        #expect(
            loudness.stdout == "loud\t-16.0 LUFS\nquiet\t-16.0 LUFS\nmono\t-19.0 LUFS\n",
            "loudness after the level: \(loudness)")
    }

    /// The union of `loud` (-23 LUFS) and `quiet` (-28 LUFS with its gain) reads about -24.82 LUFS.
    /// So both clips get +8.82 dB, and `quiet` keeps its 2 dB more gain.
    @Test func perTrackKeepsTheDifferences() async throws {
        let package = try Self.package()
        let level = try await package.run("level", "PKG", "loud", "quiet", "--per-track")
        #expect(level.status == 0, "per track: \(level)")
        let session = try package.read()
        let loud = try #require(session.clip("loud")?.clip.gain.dB)
        let quiet = try #require(session.clip("quiet")?.clip.gain.dB)
        #expect(abs(quiet - loud - 2) <= 0.001, "per track: loud \(loud), quiet \(quiet)")
        #expect(abs(loud - 8.82) <= 0.1, "per track: loud \(loud)")
        #expect(
            level.stdout == String(format: "loud\t%+.1f dB\nquiet\t%+.1f dB\n", loud, quiet),
            "per track output: \(level)")
    }

    @Test func aClipIDLimitsTheEdit() async throws {
        let package = try Self.package()
        let level = try await package.run("level", "PKG", "mono")
        #expect(level == CLIResult(status: 0, stdout: "mono\t+7.0 dB\n", stderr: ""), "one clip: \(level)")
        let session = try package.read()
        #expect(session.clip("loud")?.clip.gain == .zero, "one clip: loud changed")
        let mono = try #require(session.clip("mono")?.clip.gain.dB)
        #expect(abs(mono - 7) <= 0.1, "one clip: mono \(mono)")
    }

    @Test func anUnknownClipExitsOne() async throws {
        let package = try Self.package()
        let before = try package.xml()
        let result = try await package.run("level", "PKG", "loud", "nope")
        #expect(result == CLIResult(status: 1, stdout: "", stderr: "Error: no clip \"nope\".\n"), "unknown: \(result)")
        #expect(try package.xml() == before, "unknown: the package changed")
    }

    @Test func aPendingTakeExitsTwo() async throws {
        let package = try Self.package()
        try package.edit {
            try $0.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 0, armedTracks: ["t1"]))
        }
        let before = try package.xml()
        let result = try await package.run("level", "PKG")
        #expect(
            result
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: \(package.path) has a take that is not finalized; open it in Dirigible first.\n"),
            "pending take: \(result)")
        #expect(try package.xml() == before, "pending take: the package changed")
    }
}
