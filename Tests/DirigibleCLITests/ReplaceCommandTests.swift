import DirigibleCore
import Foundation
import Testing

/// `clip replace` (decision 0053, C12, C15). The package of `PasteFromCommandTests.package`: track
/// t1 with clips A (0..<24 000) and C (24 000..<48 000) of file take1-mic.
struct ReplaceCommandTests {
    let package: TemporaryPackage

    init() throws {
        package = try PasteFromCommandTests.package(tone: true, track: "t1", rate: 48_000)
    }

    func starts(_ session: Session) -> [Frames] { session.track("t1")?.clips.map(\.start) ?? [] }

    /// C15: a Replace of 24 000..<36 000 with A (24 000 frames) prints the pasted ID, saves, and
    /// moves the tail of C by 24 000 - 12 000.
    @Test func replacesAndPrints() async throws {
        let result = try await package.run(
            "clip", "replace", "PKG", "--track", "t1", "--from", "0", "--to", "24000", "--at", "24000", "--until",
            "36000")

        #expect(result == CLIResult(status: 0, stdout: "A@24000\n", stderr: ""))
        let session = try package.read()
        #expect(starts(session) == [0, 24_000, 48_000])
        #expect(session.track("t1")?.clips.map(\.length) == [24_000, 24_000, 12_000])
    }

    /// C12: under a split take (the fixture of `PlaceCommandTests`: take1-2-1 on t2 at 96 000), a
    /// Replace exits 3 and changes nothing. Control: a fill of the same ranges does not ripple and runs.
    @Test func splitTakeExits3() async throws {
        let fixture = try await PlaceCommandTests()
        let before = try fixture.package.xml()
        let ranges = ["--track", "t2", "--from", "96000", "--to", "120000", "--at", "0", "--until", "48000"]

        let result = try await fixture.package.run(["clip", "replace", "PKG"] + ranges)

        #expect(result.status == 3 && result.stderr.contains("has a take with some segments on the timeline"))
        #expect(try fixture.package.xml() == before)
        #expect(try await fixture.package.run(["clip", "fill", "PKG"] + ranges).status == 0)
        #expect(try fixture.package.xml() != before, "the fill changes the package")
    }

    /// C12: with `--source`, a Replace under a split take also exits 3 and copies no file.
    @Test func sourceSplitTakeExits3() async throws {
        let fixture = try await PlaceCommandTests()
        let before = try fixture.package.xml()
        let clips = fixture.package.url.appending(path: clipsFolderName)
        let files = try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted()

        let result = try await fixture.package.run(
            "clip", "replace", "PKG", "--source", package.path, "--track", "t1", "--from", "0", "--to", "24000", "--at",
            "0", "--until", "48000", "--onto", "t2")

        #expect(result.status == 3 && result.stderr.contains("has a take with some segments on the timeline"))
        #expect(try fixture.package.xml() == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted() == files, "no file copied")
    }

    /// U41: a clipboard of 0 frames exits 1 with the empty excerpt text and removes no audio.
    @Test func emptyRangeExits1() async throws {
        let before = try package.xml()

        let result = try await package.run(
            "clip", "replace", "PKG", "--track", "t1", "--from", "100", "--to", "100", "--at", "0", "--until",
            "24000")

        #expect(result.status == 1 && result.stderr.contains("the excerpt has no frames"), "\(result)")
        #expect(try package.xml() == before)
    }

    /// C15: no track, a target range that ends before it starts, and an onto count that differs exit 64.
    @Test func badArgumentsExit64() async throws {
        let before = try package.xml()
        for (arguments, text) in [
            (["--from", "0", "--to", "24000", "--at", "0", "--until", "10"], "Give one or more --track."),
            (
                ["--track", "t1", "--from", "0", "--to", "24000", "--at", "10", "--until", "0"],
                "--at must not be more than --until."
            ),
            (
                [
                    "--track", "t1", "--from", "0", "--to", "24000", "--at", "0", "--until", "10", "--onto", "a",
                    "--onto",
                    "b",
                ],
                "Give one --onto for each --track, or none."
            ),
        ] {
            let result = try await package.run(["clip", "replace", "PKG"] + arguments)
            #expect(result.status == 64 && result.stderr.contains(text), "\(arguments): \(result)")
        }
        #expect(try package.xml() == before)
    }

    /// C15: a Replace from another package copies the file once and prints the pasted IDs. Q has
    /// track u1 with clips A and C of its own take1-mic.
    @Test func sourcePackage() async throws {
        let q = try PasteFromCommandTests.package(tone: false, track: "u1", rate: 48_000)

        let result = try await q.run(
            "clip", "replace", "PKG", "--source", package.path, "--track", "t1", "--from", "0", "--to", "48000",
            "--at", "24000", "--until", "36000", "--onto", "u1")

        #expect(result == CLIResult(status: 0, stdout: "A@24000\nC@48000\n", stderr: ""))
        let session = try q.read()
        #expect(session.track("u1")?.clips.map(\.start) == [0, 24_000, 48_000, 72_000])
        #expect(session.clip("A@24000")?.clip.file == "take1-mic 2", "the copy of the source file")
    }
}
