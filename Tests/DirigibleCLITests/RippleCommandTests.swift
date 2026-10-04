import DirigibleCore
import Foundation
import Testing

/// `dirigible clip ripple-delete` and `clip ripple-insert` (decision 0037, criteria C3, C17, and
/// C20). Tracks host, guest, and music (mono) on file f1 of 480 000 frames.
struct RippleCommandTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 480_000))
        for (id, name) in [("host", "Host"), ("guest", "Guest"), ("music", "Music")] {
            try session.addTrack(TrackID(id), name: name, layout: .mono)
            try session.place(Clip(id: ClipID(id), file: "f1", start: 0, offset: 0, length: 200_000), on: TrackID(id))
        }
        for (id, position) in [("before", 24_000), ("inside", 60_000), ("after", 144_000)] {
            try session.setMarker(Marker(id: MarkerID(id), name: id, position: Frames(position), kind: .marker))
        }
        package = try TemporaryPackage(session)
    }

    /// The position of each marker, by ID, as `info --json` shows them.
    static func markers(_ package: TemporaryPackage) async throws -> [String: Int] {
        struct View: Decodable {
            struct Marker: Decodable {
                let id: String
                let position: Int
            }
            let markers: [Marker]
        }
        let result = try await package.run("info", "PKG", "--json")
        try #require(result.status == 0)
        let view = try JSONDecoder().decode(View.self, from: Data(result.stdout.utf8))
        return Dictionary(uniqueKeysWithValues: view.markers.map { ($0.id, $0.position) })
    }

    func clips(_ track: TrackID) throws -> [Clip] { Array(try #require(try package.read().track(track)).clips) }

    /// C3 (CLI). Controls: markers that do not move with the music out of scope; a marker inside R
    /// that goes.
    @Test func rippleDeleteWithTheMusicOutOfScopeWritesLiteralMarkerFrames() async throws {
        let music = try clips("music")
        let result = try await package.run(
            "clip", "ripple-delete", "PKG", "--from", "48000", "--to", "96000", "--track", "host", "--track", "guest")
        #expect(result == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try await Self.markers(package) == ["before": 24_000, "inside": 48_000, "after": 96_000])
        #expect(try clips("music") == music, "the music clips do not change")
        #expect(try clips("host").map(\.range) == [0..<48_000, 48_000..<152_000], "the host closes the gap")
        #expect(try clips("guest").map(\.range) == [0..<48_000, 48_000..<152_000], "the guest closes the gap")
    }

    /// No `--track` ripples every track.
    @Test func rippleInsertWithNoTrackPushesEveryTrack() async throws {
        let result = try await package.run("clip", "ripple-insert", "PKG", "--at", "60000", "--length", "24000")
        #expect(result == CLIResult(status: 0, stdout: "", stderr: ""))
        for track in ["host", "guest", "music"] as [TrackID] {
            #expect(
                try clips(track).map(\.range) == [0..<60_000, 84_000..<224_000], "\(track) splits at 60 000 and moves")
        }
        #expect(try await Self.markers(package) == ["before": 24_000, "inside": 84_000, "after": 168_000])
    }

    /// C17. Each bad value exits 64 with its reason, and the package does not change.
    @Test(
        arguments: [
            // `FrameRange` or the command refuses it first; both texts start so.
            (["clip", "ripple-delete", "PKG", "--from", "96000", "--to", "48000"], "--from must "),
            (["clip", "ripple-delete", "PKG", "--from", "48000", "--to", "48000"], "--from must be less than --to."),
            (["clip", "ripple-insert", "PKG", "--at", "0", "--length", "-1"], "--length must not be negative."),
        ] as [([String], String)])
    func aBadValueExits64(arguments: [String], reason: String) async throws {
        let before = try package.xml()
        let result = try await package.run(arguments)
        #expect(result.status == 64 && result.stderr.contains(reason), "\(result)")
        #expect(try package.xml() == before)
    }

    /// C17 marker limit (plan gate 1 item 4). Control: a marker past the limit that is written.
    @Test func anInsertThatPushesAMarkerPastTheLimitIsRefused() async throws {
        try package.edit {
            try $0.setMarker(Marker(id: "late", name: "late", position: Frames.limit - 10, kind: .marker))
        }
        let before = try package.xml()
        let result = try await package.run("clip", "ripple-insert", "PKG", "--at", "0", "--length", "11")
        #expect(result == CLIResult(status: 1, stdout: "", stderr: "Error: a frame is negative or more than 2^40.\n"))
        #expect(try package.xml() == before)
    }

    /// C20. The fixture of `PlaceCommandTests` has a split take: `take1-1-1` is unplaced and
    /// `take1-2-1` is on t2. Controls: a ripple that runs (exit 0, the package changes).
    @Test func aSplitTakeRefusesEachRippleCommand() async throws {
        let fixture = try await PlaceCommandTests()
        let before = try fixture.package.xml()
        for arguments in [
            ["clip", "ripple-delete", "PKG", "--from", "0", "--to", "48000"],
            ["clip", "ripple-insert", "PKG", "--at", "0", "--length", "48000"],
        ] {
            let result = try await fixture.package.run(arguments)
            #expect(result.status == 3, "RIPPLE-C1 \(arguments[1]) with a split take: \(result)")
            #expect(result.stderr.contains("has a take with some segments on the timeline"), "\(result.stderr)")
            #expect(try fixture.package.xml() == before, "\(arguments[1]) changes nothing")
        }
    }

    /// C20. With no segment of take 1 on the timeline, the take moves as one unit, so each ripple
    /// runs. Control: the old guard that refuses any unplaced segment.
    @Test func aWhollyUnplacedTakeAllowsEachRippleCommand() async throws {
        let fixture = try await PlaceCommandTests()
        let package = fixture.package
        for arguments in [
            ["clip", "clear", "PKG", "--track", "t2", "--from", "0", "--to", "1000000"],
            ["file", "remove", "PKG", "take1-2-1"],
            ["marker", "set", "PKG", "--name", "M", "--at", "200000", "--id", "m"],
        ] {
            try #require(try await package.run(arguments).status == 0, "\(arguments)")
        }
        let delete = try await package.run("clip", "ripple-delete", "PKG", "--from", "0", "--to", "48000")
        #expect(delete.status == 0, "RIPPLE-C2 ripple-delete with a wholly unplaced take: \(delete)")
        #expect(try await Self.markers(package) == ["m": 152_000])
        let insert = try await package.run("clip", "ripple-insert", "PKG", "--at", "0", "--length", "48000")
        #expect(insert.status == 0, "RIPPLE-C2 ripple-insert with a wholly unplaced take: \(insert)")
        #expect(try await Self.markers(package) == ["m": 200_000])
    }
}
