import DirigibleCore
import Foundation
import Testing

/// Edit-commands criteria 9 and 10: `clip paste`, `clip split-at`, `clip nudge`, and a
/// repeatable `--track` on `clip clear`. The fixture of criterion 2: clip "A" on track "a" at
/// 0..<48 000, clip "C" on "b" at 90 000..<150 000, and the stereo clip "G" on "s".
struct EditCommandTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
        try session.addFile(AudioFile(id: "g", path: "g.wav", layout: .stereo, length: 480_000))
        try session.addTrack("a", name: "A", layout: .mono)
        try session.addTrack("b", name: "B", layout: .mono)
        try session.addTrack("s", name: "S", layout: .stereo)
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 48_000), on: "a")
        try session.place(Clip(id: "C", file: "f", start: 90_000, offset: 0, length: 60_000), on: "b")
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 48_000), on: "s")
        package = try TemporaryPackage(session)
    }

    private func clips(_ track: TrackID) throws -> [Clip] { Array(try #require(try package.read().track(track)).clips) }

    /// Control: a paste that prints nothing fails the output.
    @Test func pasteWritesThePastedIDsAndTheSessionOfCriterion2() throws {
        let result = try package.run(
            "clip", "paste", "PKG", "--from", "12000", "--to", "36000", "--track", "a", "--at", "96000", "--onto", "b")

        #expect(result == CLIResult(status: 0, stdout: "A@96000\n", stderr: ""))
        #expect(
            try clips("b") == [
                Clip(id: "C", file: "f", start: 90_000, offset: 0, length: 6_000),
                Clip(id: "A@96000", file: "f", start: 96_000, offset: 12_000, length: 24_000),
                Clip(id: "C@120000", file: "f", start: 120_000, offset: 30_000, length: 30_000),
            ])
        #expect(try clips("a") == [Clip(id: "A", file: "f", start: 0, offset: 0, length: 48_000)])
    }

    @Test func pasteWithNoOntoUsesTheSourceTracks() throws {
        let result = try package.run(
            "clip", "paste", "PKG", "--from", "0", "--to", "10000", "--track", "a", "--track", "b", "--at", "200000")

        #expect(result == CLIResult(status: 0, stdout: "A@200000\n", stderr: ""))
        #expect(try clips("a").map(\.id) == ["A", "A@200000"])
        #expect(try clips("b").map(\.id) == ["C"])
    }

    /// Control: a paste that requires `--onto` fails the no-onto case.
    @Test func pasteWithAnOntoCountMismatchIsAUsageError() throws {
        let before = try package.xml()
        let result = try package.run(
            "clip", "paste", "PKG", "--from", "0", "--to", "10", "--track", "a", "--at", "0", "--onto", "a", "--onto",
            "b")
        #expect(result.status == 64)
        #expect(try package.run("clip", "paste", "PKG", "--from", "0", "--to", "10", "--at", "0").status == 64)
        #expect(try package.xml() == before)
    }

    @Test func pasteOfAStereoLaneOnAMonoTrackExits1() throws {
        let before = try package.xml()
        let result = try package.run(
            "clip", "paste", "PKG", "--from", "0", "--to", "10", "--track", "s", "--at", "0", "--onto", "b")
        #expect(
            result
                == CLIResult(
                    status: 1, stdout: "", stderr: "Error: file \"g\" does not have the layout of track \"b\".\n"))
        #expect(try package.xml() == before)
    }

    /// Control: a Core paste that sums before its range check crashes the command.
    @Test func pasteWithAHugeAtGivesExitOneNotACrash() throws {
        let before = try package.xml()
        let result = try package.run(
            "clip", "paste", "PKG", "--from", "0", "--to", "10", "--track", "a", "--at", "\(Int.max)")
        #expect(
            result == CLIResult(status: 1, stdout: "", stderr: "Error: a frame is negative or more than 2^40.\n"))
        #expect(try package.xml() == before)
    }

    /// Controls: a split-at that allows no `--at` exits 0; one that requires two fails here.
    @Test func splitAtWritesTheRightIDs() throws {
        try package.edit {
            try $0.trim("A", to: 0..<100_000)
            try $0.place(Clip(id: "B", file: "f", start: 50_000, offset: 0, length: 20_000), on: "b")
        }
        #expect(
            try package.run("clip", "split-at", "PKG", "--track", "a", "--track", "b", "--at", "60000", "--at", "20000")
                == CLIResult(status: 0, stdout: "A@60000\nA@20000\nB@60000\n", stderr: ""))
        #expect(try clips("a").map(\.range) == [0..<20_000, 20_000..<60_000, 60_000..<100_000])
        #expect(
            try package.run("clip", "split-at", "PKG", "--track", "b", "--at", "65000")
                == CLIResult(status: 0, stdout: "B@60000@65000\n", stderr: ""))
        #expect(try package.run("clip", "split-at", "PKG", "--track", "a").status == 64)
    }

    @Test func nudgeByMinus480() throws {
        #expect(try package.run("clip", "nudge", "PKG", "A", "C", "--by", "-480").status == 1)
        #expect(
            try package.run("clip", "nudge", "PKG", "C", "--by", "-480")
                == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try clips("b") == [Clip(id: "C", file: "f", start: 89_520, offset: 0, length: 60_000)])
        #expect(try package.run("clip", "nudge", "PKG", "C", "--by", "480").status == 0)
        #expect(try clips("b") == [Clip(id: "C", file: "f", start: 90_000, offset: 0, length: 60_000)])
    }

    /// Control: a Core nudge that sums before its range check crashes the command.
    @Test func nudgeWithAHugeByGivesExitOneNotACrash() throws {
        let before = try package.xml()
        let result = try package.run("clip", "nudge", "PKG", "C", "--by", "\(Int.max)")
        #expect(
            result == CLIResult(status: 1, stdout: "", stderr: "Error: a frame is negative or more than 2^40.\n"))
        #expect(try package.xml() == before)
    }

    /// Control: a clear of the first `--track` only keeps "C" on b.
    @Test func clearOnTwoTracksInOneCommand() throws {
        #expect(
            try package.run("clip", "clear", "PKG", "--track", "a", "--track", "b", "--from", "0", "--to", "100000")
                == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try clips("a") == [])
        #expect(try clips("b") == [Clip(id: "C", file: "f", start: 100_000, offset: 10_000, length: 50_000)])
        #expect(try package.run("clip", "clear", "PKG", "--from", "0", "--to", "10").status == 64)
    }
}
