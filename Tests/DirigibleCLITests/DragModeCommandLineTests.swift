import DirigibleCore
import Foundation
import Testing

/// `--mode` of `clip move` and `clip nudge`, and `clip shuffle` (decision 0020, criteria C40, C43, C46).
/// Fixture S: track `t1` with a 0 ..< 48 000, b 96 000 ..< 144 000, c 192 000 ..< 240 000, and d
/// 288 000 ..< 336 000; track `t2` with e 0 ..< 480 000; marker m1 at 200 000. Each clip is of file f
/// (e of file g) at the offset of its start.
struct DragModeCommandLineTests {
    static func package() throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        for file in ["f", "g"] as [FileID] {
            try session.addFile(AudioFile(id: file, path: "\(file).wav", layout: .mono, length: 480_000))
        }
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack("t2", name: "T2", layout: .mono)
        for (id, start) in [("a", 0), ("b", 96_000), ("c", 192_000), ("d", 288_000)] as [(ClipID, Int)] {
            try session.place(
                Clip(id: id, file: "f", start: Frames(start), offset: Frames(start), length: 48_000), on: "t1")
        }
        try session.place(Clip(id: "e", file: "g", start: 0, offset: 0, length: 480_000), on: "t2")
        try session.setMarker(Marker(id: "m1", name: "m1", position: 200_000, kind: .marker))
        return try TemporaryPackage(session)
    }

    static let covered = CLIResult(status: 1, stdout: "", stderr: "Error: clip \"b\" overlaps clip \"c\".\n")

    private func starts(_ package: TemporaryPackage, _ track: TrackID) throws -> [Int] {
        try package.read().track(track)?.clips.map(\.start.count) ?? []
    }

    /// C46: a covered start is refused and the package stays; the touch passes; a word that is not a
    /// mode of a move is a usage error.
    @Test func moveTakesAMode() async throws {
        let package = try Self.package()
        let before = try package.xml()
        let refused = try await package.run(
            "clip", "move", "PKG", "b", "--track", "t1", "--start", "144001", "--mode", "no-overlap")
        #expect(refused == Self.covered)
        #expect(try package.xml() == before)

        for word in ["shuffle", "bogus"] {
            let usage = try await package.run(
                "clip", "move", "PKG", "b", "--track", "t1", "--start", "144000", "--mode", word)
            #expect(
                usage.status == 64 && usage.stderr.contains("A mode is overwrite, no-overlap, or crossfade."),
                "\(word): \(usage)")
            #expect(try package.xml() == before)
        }

        let touch = try await package.run(
            "clip", "move", "PKG", "b", "--track", "t1", "--start", "144000", "--mode", "no-overlap")
        #expect(touch == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try starts(package, "t1") == [0, 144_000, 192_000, 288_000])

        let crossfade = try Self.package()
        _ = try await crossfade.run(
            "clip", "move", "PKG", "b", "--track", "t1", "--start", "170000", "--mode", "crossfade")
        let session = try crossfade.read()
        #expect(session.clip("b")?.clip.crossfades == Crossfades(start: 0, end: 26_000), "the covered length of c")
        #expect(session.clip("c")?.clip.crossfades == Crossfades(start: 26_000, end: 0))

        let overwrite = try Self.package()
        _ = try await overwrite.run("clip", "move", "PKG", "b", "--track", "t1", "--start", "170000")
        #expect(try overwrite.read().clip("c")?.clip.crossfades == Crossfades.zero, "no mode overwrites")
    }

    @Test func nudgeTakesAMode() async throws {
        let package = try Self.package()
        let before = try package.xml()
        let refused = try await package.run("clip", "nudge", "PKG", "b", "--by", "48001", "--mode", "no-overlap")
        #expect(refused == Self.covered)
        #expect(try package.xml() == before)
        let usage = try await package.run("clip", "nudge", "PKG", "b", "--by", "48000", "--mode", "shuffle")
        #expect(usage.status == 64, "\(usage)")
        #expect(try package.xml() == before)

        let touch = try await package.run("clip", "nudge", "PKG", "b", "--by", "48000", "--mode", "no-overlap")
        #expect(touch == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try starts(package, "t1") == [0, 144_000, 192_000, 288_000])
    }

    /// C43: the values of fixture S through the command.
    @Test func shuffleGivesTheFixtureValues() async throws {
        let package = try Self.package()
        let same = try await package.run("clip", "shuffle", "PKG", "b", "--track", "t1", "--start", "240000")
        #expect(same == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try starts(package, "t1") == [0, 144_000, 240_000, 288_000])
        #expect(try package.read().clip("b")?.track == "t1")
        #expect(try package.read().markers["m1"]?.position == 152_000, "the marker stays 8000 into c")

        let across = try Self.package()
        _ = try await across.run("clip", "shuffle", "PKG", "b", "--track", "t2", "--start", "100000")
        #expect(try starts(across, "t1") == [0, 144_000, 240_000])
        #expect(try starts(across, "t2") == [0, 100_000, 148_000])
        #expect(try across.read().markers["m1"]?.position == 200_000)

        let before = try across.xml()
        let unknown = try await across.run("clip", "shuffle", "PKG", "zz", "--track", "t1", "--start", "0")
        #expect(unknown.status == 1 && unknown.stderr == "Error: no clip \"zz\".\n", "\(unknown)")
        #expect(try across.xml() == before)
    }

    /// C40: under a split take `clip shuffle` exits 3 and `clip move --mode no-overlap` exits 0. The
    /// fixture of `PlaceCommandTests` has `take1-2-1` on `t2` and `t1` empty.
    @Test func onlyShuffleIsARipple() async throws {
        let fixture = try await PlaceCommandTests()
        let before = try fixture.package.xml()
        let shuffle = try await fixture.package.run(
            "clip", "shuffle", "PKG", "take1-2-1", "--track", "t1", "--start", "0")
        #expect(shuffle.status == 3 && shuffle.stderr.contains("has a take with some segments on the timeline"))
        #expect(try fixture.package.xml() == before)

        let move = try await fixture.package.run(
            "clip", "move", "PKG", "take1-2-1", "--track", "t1", "--start", "0", "--mode", "no-overlap")
        #expect(move == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try fixture.package.read().clip("take1-2-1")?.track == "t1")
    }
}
