import DirigibleCore
import Foundation
import Testing

/// `clip fill` (decision 0053, C13, C15). The package of `PasteFromCommandTests.package`: track t1
/// with clips A (0..<24 000) and C (24 000..<48 000) of file take1-mic.
struct FillCommandTests {
    let package: TemporaryPackage

    init() throws {
        package = try PasteFromCommandTests.package(tone: true, track: "t1", rate: 48_000)
    }

    /// C13 and C15: a fill of 48 000..<108 000 with A gives copies at 48 000 and 72 000 and a last
    /// copy cut to 12 000 frames at 96 000, prints their IDs, and saves.
    @Test func fillsAndPrints() async throws {
        let result = try await package.run(
            "clip", "fill", "PKG", "--track", "t1", "--from", "0", "--to", "24000", "--at", "48000", "--until",
            "108000")

        #expect(result == CLIResult(status: 0, stdout: "A@48000\nA@72000\nA@96000\n", stderr: ""))
        let clips = try package.read().track("t1")?.clips
        #expect(clips?.map(\.start) == [0, 24_000, 48_000, 72_000, 96_000])
        #expect(clips?.map(\.length) == [24_000, 24_000, 24_000, 24_000, 12_000])
    }

    /// C13: 1001 copies of a one-clip clipboard exit 1 with the limit text and change nothing.
    @Test func tooManyCopiesExits1() async throws {
        let before = try package.xml()

        let result = try await package.run(
            "clip", "fill", "PKG", "--track", "t1", "--from", "0", "--to", "24000", "--at", "0", "--until",
            String(24_000 * 1_001))

        #expect(result.status == 1, "\(result)")
        #expect(result.stderr.contains("the fill makes 1001 clips, more than the limit of 1000"), "\(result.stderr)")
        #expect(try package.xml() == before)
    }

    /// C13: a clipboard of 0 frames exits 1 with the empty excerpt text and changes nothing.
    @Test func emptyRangeExits1() async throws {
        let before = try package.xml()

        let result = try await package.run(
            "clip", "fill", "PKG", "--track", "t1", "--from", "100", "--to", "100", "--at", "0", "--until", "48000")

        #expect(result.status == 1 && result.stderr.contains("the excerpt has no frames"), "\(result)")
        #expect(try package.xml() == before)
    }
}
