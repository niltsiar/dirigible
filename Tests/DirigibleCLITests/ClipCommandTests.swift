import DirigibleCore
import Foundation
import Testing

struct ClipCommandTests {
    let package: TemporaryPackage
    let silent = CLIResult(status: 0, stdout: "", stderr: "")

    /// Tracks host and guest (mono) and st (stereo); files f1 (mono) and f2 (stereo).
    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "host-1.wav", layout: .mono, length: 480_000))
        try session.addFile(AudioFile(id: "f2", path: "st.wav", layout: .stereo, length: 1000))
        try session.addTrack("host", name: "Host", layout: .mono)
        try session.addTrack("guest", name: "Guest", layout: .mono)
        try session.addTrack("st", name: "Stereo", layout: .stereo)
        package = try TemporaryPackage(session)
    }

    private func clips(_ track: TrackID) throws -> [Clip] { Array(try #require(try package.read().track(track)).clips) }

    @Test func eachVerbAppliesItsEdit() async throws {
        #expect(
            try await package.run(
                "clip", "place", "PKG", "--id", "c1", "--track", "host", "--file", "f1", "--start", "0", "--length",
                "480000") == CLIResult(status: 0, stdout: "c1\n", stderr: ""))
        #expect(try clips("host") == [Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 480_000)])

        let placed = try await package.run(
            "clip", "place", "PKG", "--track", "st", "--file", "f2", "--start", "100", "--length", "500", "--offset",
            "10",
            "--db", "-1.5")
        let id = ClipID(String(placed.stdout.dropLast()))
        #expect(placed.status == 0 && UUID(uuidString: id.rawValue) != nil)
        #expect(
            try clips("st") == [Clip(id: id, file: "f2", start: 100, offset: 10, length: 500, gain: Gain(dB: -1.5)!)])

        #expect(
            try await package.run("clip", "split", "PKG", "c1", "--at", "96000")
                == CLIResult(status: 0, stdout: "c1@96000\n", stderr: ""))
        #expect(
            try await package.run("clip", "split", "PKG", "c1@96000", "--at", "200000", "--right-id", "r")
                == CLIResult(status: 0, stdout: "r\n", stderr: ""))
        #expect(
            try clips("host") == [
                Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 96_000),
                Clip(id: "c1@96000", file: "f1", start: 96_000, offset: 96_000, length: 104_000),
                Clip(id: "r", file: "f1", start: 200_000, offset: 200_000, length: 280_000),
            ])

        #expect(try await package.run("clip", "move", "PKG", "r", "--track", "guest", "--start", "0") == silent)
        #expect(try clips("guest") == [Clip(id: "r", file: "f1", start: 0, offset: 200_000, length: 280_000)])
        #expect(try clips("host").map(\.id) == ["c1", "c1@96000"])

        #expect(try await package.run("clip", "trim", "PKG", "c1", "--from", "0", "--to", "50000") == silent)
        #expect(
            try await package.run("clip", "clear", "PKG", "--track", "host", "--from", "10", "--to", "20") == silent)
        #expect(try await package.run("clip", "gain", "PKG", "c1", "--db", "-6") == silent)
        #expect(
            try clips("host") == [
                Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 10, gain: Gain(dB: -6)!),
                Clip(id: "c1@20", file: "f1", start: 20, offset: 20, length: 49_980),
                Clip(id: "c1@96000", file: "f1", start: 96_000, offset: 96_000, length: 104_000),
            ])
    }

    @Test func refusedEditsExitOne() async throws {
        try package.edit {
            try $0.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 1000), on: "host")
            try $0.place(Clip(id: "c2", file: "f1", start: 2000, offset: 2000, length: 1000), on: "host")
        }
        let before = try package.xml()
        let cases: [([String], String)] = [
            (["clip", "trim", "PKG", "c1", "--from", "0", "--to", "2500"], "clip \"c1\" overlaps clip \"c2\"."),
            (
                ["clip", "place", "PKG", "--track", "host", "--file", "f2", "--start", "5000", "--length", "10"],
                "file \"f2\" does not have the layout of track \"host\"."
            ),
            (
                ["clip", "place", "PKG", "--track", "host", "--file", "f1", "--start", "-1", "--length", "10"],
                "a frame is negative or more than 2^40."
            ),
        ]
        for (arguments, message) in cases {
            #expect(try await package.run(arguments) == CLIResult(status: 1, stdout: "", stderr: "Error: \(message)\n"))
        }
        #expect(try package.xml() == before)
    }

    /// `Range` traps when the lower bound is above the upper bound, so the CLI refuses it first.
    @Test(arguments: [
        ["clip", "clear", "PKG", "--track", "host", "--from", "200", "--to", "100"],
        ["clip", "trim", "PKG", "c1", "--from", "200", "--to", "100"],
    ])
    func reversedRangeIsAUsageError(arguments: [String]) async throws {
        let before = try package.xml()
        #expect(try await package.run(arguments).status == 64)
        #expect(try package.xml() == before)
    }
}
