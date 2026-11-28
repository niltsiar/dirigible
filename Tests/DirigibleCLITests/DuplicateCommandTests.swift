import DirigibleCore
import Foundation
import Testing

/// `clip duplicate` and `clip duplicate-clips` (decision 0053, C14, C15). The package of
/// `PasteFromCommandTests.package`: track t1 with clips A (0..<24 000) and C (24 000..<48 000) of
/// file take1-mic.
struct DuplicateCommandTests {
    let package: TemporaryPackage

    init() throws {
        package = try PasteFromCommandTests.package(tone: true, track: "t1", rate: 48_000)
    }

    /// C15: a duplicate of 0..<24 000 prints the pasted ID and saves. The copy lies at 24 000, over C.
    @Test func duplicatesAndPrints() async throws {
        let result = try await package.run("clip", "duplicate", "PKG", "--track", "t1", "--from", "0", "--to", "24000")

        #expect(result == CLIResult(status: 0, stdout: "A@24000\n", stderr: ""))
        let clips = try package.read().track("t1")?.clips
        #expect(clips?.map(\.id) == ["A", "A@24000"])
        #expect(clips?.map(\.start) == [0, 24_000])
    }

    /// C15: a duplicate of the set A and C prints the two pasted IDs and saves. The copies lie after the end
    /// of C, with the distance of A and C.
    @Test func clipsAndPrints() async throws {
        let result = try await package.run("clip", "duplicate-clips", "PKG", "A", "C")

        #expect(result == CLIResult(status: 0, stdout: "A@48000\nC@72000\n", stderr: ""))
        let clips = try package.read().track("t1")?.clips
        #expect(clips?.map(\.start) == [0, 24_000, 48_000, 72_000])
        #expect(clips?.map(\.length) == [24_000, 24_000, 24_000, 24_000])
    }

    /// C14 and C15: a range with no frame exits 1 with the empty excerpt text and changes nothing.
    /// The control duplicate of a range with frames changes the package.
    @Test func emptyInputExits1() async throws {
        let before = try package.xml()

        let range = try await package.run("clip", "duplicate", "PKG", "--track", "t1", "--from", "100", "--to", "100")
        #expect(range.status == 1 && range.stderr.contains("the excerpt has no frames"), "\(range)")
        #expect(try package.xml() == before)
        let control = try await package.run("clip", "duplicate", "PKG", "--track", "t1", "--from", "0", "--to", "10")
        #expect(control.status == 0)
        #expect(try package.xml() != before, "a range with frames duplicates")
    }

    /// C15: no track, a range that ends before it starts, and no clip exit 64 and change nothing.
    /// The clip set command takes at least one clip, as `paste-clips` and `close-gaps` do.
    @Test func badArgumentsExit64() async throws {
        let before = try package.xml()
        let noTrack = try await package.run("clip", "duplicate", "PKG", "--from", "0", "--to", "24000")
        let backwards = try await package.run("clip", "duplicate", "PKG", "--track", "t1", "--from", "10", "--to", "0")
        let noClip = try await package.run("clip", "duplicate-clips", "PKG")
        #expect(noClip.status == 64, "\(noClip)")
        #expect(noClip.stderr.contains("Missing expected argument"), "\(noClip)")
        #expect(noTrack.status == 64, "\(noTrack)")
        #expect(noTrack.stderr.contains("Give one or more --track."), "\(noTrack)")
        #expect(backwards.status == 64, "\(backwards)")
        #expect(backwards.stderr.contains("--from must not be more than --to."), "\(backwards)")
        #expect(try package.xml() == before)
    }
}
