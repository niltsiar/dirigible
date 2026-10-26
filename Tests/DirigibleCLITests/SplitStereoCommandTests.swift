import DirigibleCore
import Foundation
import Testing

/// `dirigible clip split-stereo` (decision 0053, criterion C8). Track `t1` "Host" (stereo) holds
/// `c1` and `c2` of the 4 s file `f1`; track `t2` "Guest" (mono) holds `m1`.
struct SplitStereoCommandTests {
    static func package() throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .stereo, length: 192_000))
        try session.addFile(AudioFile(id: "m1", path: "m1.wav", layout: .mono, length: 48_000))
        try session.addTrack("t1", name: "Host", layout: .stereo)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 48_000), on: "t1")
        try session.place(Clip(id: "c2", file: "f1", start: 96_000, offset: 96_000, length: 48_000), on: "t1")
        try session.place(Clip(id: "m1", file: "m1", start: 0, offset: 0, length: 48_000), on: "t2")
        let package = try TemporaryPackage(session)
        let clips = package.url.appending(path: "Clips")
        try LoudnessCommandTests.writeWAV(clips.appending(path: "f1.wav"), seconds: 4)
        try LoudnessCommandTests.writeWAV(clips.appending(path: "m1.wav"), seconds: 1, channels: 1)
        return package
    }

    /// The names in `Clips/`.
    static func clips(_ package: TemporaryPackage) -> [String] {
        let names = try? FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: "Clips").path)
        return (names ?? []).sorted()
    }

    /// The line of a split of `clip` in the session after it: the two clip IDs, then the IDs of
    /// the tracks `<track> L` and `<track> R`.
    static func line(of clip: String, track: String, in session: Session) throws -> String {
        let left = try #require(session.tracks.first { $0.name == "\(track) L" }?.id)
        let right = try #require(session.tracks.first { $0.name == "\(track) R" }?.id)
        return "\(clip) L\t\(clip) R\t\(left)\t\(right)"
    }

    /// C8: one line for each source clip, the session is saved, and the new tracks are
    /// "<name> L" and "<name> R" under the source track.
    @Test func splitsAndPrints() async throws {
        let package = try Self.package()

        let result = try await package.run("clip", "split-stereo", "PKG", "c1", "c2")

        let session = try package.read()
        let lines = try ["c1", "c2"].map { try Self.line(of: $0, track: "Host", in: session) }
        #expect(
            result == CLIResult(status: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: ""), "split: \(result)"
        )
        #expect(session.tracks.map(\.name) == ["Host", "Host L", "Host R", "Guest"], "\(session.tracks.map(\.name))")
        #expect(session.tracks.map(\.layout) == [.stereo, .mono, .mono, .mono])
        let left = try #require(session.tracks.first { $0.name == "Host L" })
        let right = try #require(session.tracks.first { $0.name == "Host R" })
        #expect(left.clips.map(\.id) == ["c1 L", "c2 L"] && right.clips.map(\.id) == ["c1 R", "c2 R"])
        #expect(session.clip("c1") == nil && session.clip("c2") == nil && session.clip("m1") != nil)
        // The two clips are near, so they share one pair of mono files.
        #expect(Self.clips(package) == ["f1 L.wav", "f1 R.wav", "f1.wav", "m1.wav"], "\(Self.clips(package))")
        #expect(session.files["f1 L"]?.layout == .mono && session.files["f1 L"]?.length == 192_000)
    }

    /// C8: a mono clip exits 1 with the text of the session, and nothing changes. The mono check
    /// comes before the source check, so a mono clip with no WAV exits 1 too.
    @Test func monoClipExits1() async throws {
        let package = try Self.package()
        let before = (try package.xml(), Self.clips(package))

        let result = try await package.run("clip", "split-stereo", "PKG", "c1", "m1")

        let text = "clip \"m1\" is on a mono track, so it has no two sides to split."
        #expect(result == CLIResult(status: 1, stdout: "", stderr: "Error: \(text)\n"), "mono clip: \(result)")
        #expect(try package.xml() == before.0 && Self.clips(package) == before.1, "a refused split changed the package")

        try FileManager.default.removeItem(at: package.url.appending(path: "Clips/m1.wav"))
        let missing = try await package.run("clip", "split-stereo", "PKG", "c1", "m1")
        #expect(missing == CLIResult(status: 1, stdout: "", stderr: "Error: \(text)\n"), "no WAV: \(missing)")
    }

    @Test func noClipIsAnArgumentError() async throws {
        let package = try Self.package()

        let result = try await package.run("clip", "split-stereo", "PKG")

        #expect(result.status == 64 && result.stderr.contains("Give one or more clips"), "no clip: \(result)")
    }
}
