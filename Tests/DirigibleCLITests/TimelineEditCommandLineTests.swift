import DirigibleCore
import Foundation
import Testing

/// `dirigible clip close-gaps`, `clip roll`, and `clip slip` (decision 0036, criterion C14). File f1
/// has 480 000 frames. Track t1: a 0..<48 000, b 48 000..<96 000 (a butt join with a), and c
/// 120 000..<168 000. Track t2: d 10 000..<20 000 and e 50 000..<60 000. Each clip starts at its offset.
struct TimelineEditCommandLineTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 480_000))
        for track in ["t1", "t2"] as [TrackID] { try session.addTrack(track, name: track.rawValue, layout: .mono) }
        for (id, start, length, track) in [
            ("a", 0, 48_000, "t1"), ("b", 48_000, 48_000, "t1"), ("c", 120_000, 48_000, "t1"),
            ("d", 10_000, 10_000, "t2"), ("e", 50_000, 10_000, "t2"),
        ] as [(ClipID, Int, Int, TrackID)] {
            try session.place(
                Clip(id: id, file: "f1", start: Frames(start), offset: Frames(start), length: Frames(length)), on: track
            )
        }
        package = try TemporaryPackage(session)
    }

    private func clip(_ id: ClipID) throws -> Clip { try #require(try package.read().clip(id)?.clip) }

    /// The output is the ID of each moved clip, track by track, one per line. A clip that stays is
    /// not in the list.
    @Test func closeGapsPrintsTheMovedClips() async throws {
        let result = try await package.run("clip", "close-gaps", "PKG", "a", "c", "d", "e")
        #expect(result == CLIResult(status: 0, stdout: "c\ne\n", stderr: ""))
        #expect(try clip("c").start == 96_000 && clip("e").start == 20_000)
        #expect(try clip("a").start == 0 && clip("b").start == 48_000 && clip("d").start == 10_000)
    }

    @Test func closeGapsWithNoGapPrintsNothingAndChangesNothing() async throws {
        let before = try package.xml()
        let result = try await package.run("clip", "close-gaps", "PKG", "a", "b")
        #expect(result == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try package.xml() == before)
    }

    /// The right clip loses what the left clip gains, and its offset follows.
    @Test func rollMovesTheJoin() async throws {
        let result = try await package.run("clip", "roll", "PKG", "a", "--by", "-1000")
        #expect(result == CLIResult(status: 0, stdout: "", stderr: ""))
        let (left, right) = try (clip("a"), clip("b"))
        #expect(left.length == 47_000 && right.start == 47_000 && right.offset == 47_000 && right.length == 49_000)
    }

    @Test func slipMovesTheAudioUnderTheClips() async throws {
        let result = try await package.run("clip", "slip", "PKG", "b", "d", "--by", "500")
        #expect(result == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try clip("b").offset == 48_500 && clip("b").start == 48_000 && clip("d").offset == 10_500)
    }

    /// No clip or a bad `--by` is a usage error (64). An unknown clip, a clip with no join, and a
    /// delta past a limit are refusals (1) that name the clip. No refusal changes the package.
    @Test(
        arguments: [
            (["close-gaps"], 64, "Missing expected argument"),
            (["roll", "--by", "5"], 64, "Missing expected argument"),
            (["slip", "--by", "5"], 64, "Missing expected argument"),
            (["roll", "a"], 64, "Missing expected argument '--by"),
            (["slip", "a"], 64, "Missing expected argument '--by"),
            (["roll", "a", "--by", "x"], 64, "The value 'x' is invalid for '--by"),
            (["slip", "a", "--by", "1.5"], 64, "The value '1.5' is invalid for '--by"),
            (["close-gaps", "zz"], 1, "Error: no clip \"zz\".\n"),
            (["roll", "zz", "--by", "5"], 1, "Error: no clip \"zz\".\n"),
            (["slip", "zz", "--by", "5"], 1, "Error: no clip \"zz\".\n"),
            (
                ["roll", "c", "--by", "5"], 1,
                "Error: no clip touches the end of clip \"c\", so it has no join to roll.\n"
            ),
            (["roll", "a", "--by", "48000"], 1, "Error: clip \"b\" is not inside its file.\n"),
            (["slip", "a", "--by", "432001"], 1, "Error: clip \"a\" is not inside its file.\n"),
            (["slip", "a", "--by", "-1"], 1, "Error: clip \"a\" is not inside its file.\n"),
            (["roll", "a", "--by", "9223372036854775807"], 1, "Error: a frame is negative or more than 2^40.\n"),
            (["slip", "a", "--by", "-9223372036854775807"], 1, "Error: a frame is negative or more than 2^40.\n"),
        ] as [([String], Int32, String)])
    func aRefusalExitsWithItsCodeAndChangesNothing(arguments: [String], status: Int32, line: String) async throws {
        let before = try package.xml()
        let result = try await package.run(["clip"] + [arguments[0], "PKG"] + arguments.dropFirst())
        #expect(result.status == status && result.stdout.isEmpty && result.stderr.contains(line), "\(result)")
        #expect(try package.xml() == before)
    }
}
