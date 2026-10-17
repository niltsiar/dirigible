import DirigibleCore
import Foundation
import Testing

/// `dirigible clip heal` and the tool `clip_heal` on the files. Track `t1` has a clip of
/// 4 pieces of 1 s, and track `t2` has two clips of two files (a butt join).
struct ClipHealCommandTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        for id in ["f1", "f2"] as [FileID] {
            try session.addFile(AudioFile(id: id, path: "\(id).wav", layout: .mono, length: 480_000))
        }
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Music", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 192_000), on: "t1")
        try session.splitClips(at: [48_000, 96_000, 144_000], on: ["t1"])
        try session.place(Clip(id: "m1", file: "f1", start: 0, offset: 0, length: 48_000), on: "t2")
        try session.place(Clip(id: "m2", file: "f2", start: 48_000, offset: 0, length: 48_000), on: "t2")
        package = try TemporaryPackage(session)
    }

    private func lengths(_ track: TrackID) throws -> [Int] {
        try package.read().track(track).map { $0.clips.map(\.length.count) } ?? []
    }

    /// The output is the ID of each healed clip. `--track` keeps the other tracks, and a
    /// join at `--to` heals.
    @Test func aHealJoinsThePiecesAndWritesTheIDs() async throws {
        let ranged = try await package.run("clip", "heal", "PKG", "--track", "t1", "--from", "48000", "--to", "96000")
        #expect(ranged == CLIResult(status: 0, stdout: "c1\n", stderr: ""))
        #expect(try lengths("t1") == [144_000, 48_000], "the joins at 48 000 and 96 000 healed")

        let all = try await package.run("clip", "heal", "PKG")
        #expect(all == CLIResult(status: 0, stdout: "c1\n", stderr: ""))
        #expect(try lengths("t1") == [192_000] && lengths("t2") == [48_000, 48_000], "the butt join stays")
    }

    /// No join to heal exits 1 and the bytes of `session.xml` stay. The tool gives the same
    /// line as an error, with no edit.
    @Test func noJoinToHealExitsOneAndChangesNothing() async throws {
        let before = try package.xml()
        let refused = try await package.run("clip", "heal", "PKG", "--track", "t2")
        #expect(refused == CLIResult(status: 1, stdout: "", stderr: "Error: no join to heal.\n"))
        #expect(try package.xml() == before)

        let answers = try await mcp([toolCall(1, "clip_heal", ["package": package.path, "track": ["t2"]])])
        #expect(toolResult(answer(answers, id: 1)) == (errorText(refused), true))
        #expect(try package.xml() == before)
    }

    /// `--from` alone, `--to` alone, and `--from` over `--to` are usage errors (exit 64).
    @Test(arguments: [
        (["--from", "5"], "Give --from and --to, or neither."),
        (["--to", "5"], "Give --from and --to, or neither."),
        (["--from", "9", "--to", "3"], "--from must not be more than --to."),
    ])
    func aBadRangeIsAUsageError(options: [String], line: String) async throws {
        let before = try package.xml()
        let result = try await package.run(["clip", "heal", "PKG"] + options)
        #expect(result.status == 64 && result.stdout.isEmpty && result.stderr.contains(line), "\(result)")
        #expect(try package.xml() == before)
    }

    /// The tool heals the same pieces as the command, and gives the IDs, one per line.
    @Test func theHealToolGivesTheCommandResult() async throws {
        let twin = try TemporaryPackage(package.read())
        let cli = try await twin.run("clip", "heal", "PKG", "--from", "0", "--to", "96000")
        let answers = try await mcp([
            toolCall(1, "clip_heal", ["package": package.path, "from": 0, "to": 96_000]),
            toolCall(2, "clip_heal", ["package": package.path, "from": 9, "to": 3]),
            toolCall(3, "clip_heal", ["package": package.path, "to": 3]),
        ])
        #expect(toolResult(answer(answers, id: 1)) == (cli.stdout.trimmingCharacters(in: .newlines), false))
        #expect(try package.xml() == twin.xml())
        #expect(toolResult(answer(answers, id: 2)) == ("from must not be more than to.", true))
        #expect(toolResult(answer(answers, id: 3)) == ("Give from and to, or neither.", true))
    }
}
