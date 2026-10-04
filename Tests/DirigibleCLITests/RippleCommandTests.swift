import DirigibleCore
import Foundation
import Testing

/// `dirigible clip ripple-delete`, `clip ripple-insert`, and `clip ripple-trim` (decision 0037,
/// criteria C3, C11, C17, and C20). Tracks host, guest, and music (mono) on file f1 of 480 000 frames.
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

    /// C11 (CLI). No `--track` ripples every track. Control: the plain `trim` (no other track changes).
    @Test func rippleTrimRipplesEveryTrack() async throws {
        let result = try await package.run("clip", "ripple-trim", "PKG", "host", "--edge", "end", "--by", "-100000")
        #expect(result == CLIResult(status: 0, stdout: "", stderr: ""))
        for track in ["host", "guest", "music"] as [TrackID] {
            #expect(try clips(track).map(\.range) == [0..<100_000], "\(track) loses the span before the old end")
        }
        #expect(try await Self.markers(package) == ["before": 24_000, "inside": 60_000, "after": 100_000])
    }

    /// C11 (CLI). A bad edge exits 64 with its reason, and the package does not change.
    @Test func rippleTrimRefusesABadEdge() async throws {
        let before = try package.xml()
        let result = try await package.run("clip", "ripple-trim", "PKG", "host", "--edge", "middle", "--by", "10")
        #expect(result.status == 64 && result.stderr.contains("An edge is start or end."), "\(result)")
        #expect(try package.xml() == before)
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
            ["clip", "ripple-trim", "PKG", "take1-2-1", "--edge", "end", "--by", "-4800"],
        ] {
            let result = try await fixture.package.run(arguments)
            #expect(result.status == 3, "RIPPLE-C1 \(arguments[1]) with a split take: \(result)")
            #expect(result.stderr.contains("has a take with some segments on the timeline"), "\(result.stderr)")
            #expect(try fixture.package.xml() == before, "\(arguments[1]) changes nothing")
        }
    }

    /// Code gate 1 item 2: a split take whose unplaced segment has a CAF that is not audio can
    /// never place, so it does not block a ripple. Control: the block of every unplaced segment.
    @Test func aSplitTakeWithACAFThatIsNotAudioAllowsARipple() async throws {
        let fixture = try await PlaceCommandTests()
        try Data("not a CAF".utf8).write(to: fixture.capture.appending(path: "take1-1-1.caf"))
        let result = try await fixture.package.run("clip", "ripple-delete", "PKG", "--from", "0", "--to", "48000")
        #expect(result.status == 0, "RIPPLE-C3 a CAF that is not audio blocks: \(result)")
    }

    /// Code gate 2 item 1: a CAF that the user cannot read now (mode 000) can place later, so it
    /// still blocks. Control: a rule that a CAF that is not audio or does not open never blocks.
    @Test func aSplitTakeWithAnUnreadableCAFStaysBlocked() async throws {
        let fixture = try await PlaceCommandTests()
        let caf = fixture.capture.appending(path: "take1-1-1.caf")
        chmod(caf.path, 0)
        defer { chmod(caf.path, 0o644) }
        let before = try fixture.package.xml()
        let result = try await fixture.package.run("clip", "ripple-delete", "PKG", "--from", "0", "--to", "48000")
        #expect(result.status == 3, "RIPPLE-C4 an unreadable CAF does not block: \(result)")
        #expect(try fixture.package.xml() == before)
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
        try package.edit {
            try $0.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 96_000))
            try $0.place(Clip(id: "c", file: "f", start: 0, offset: 0, length: 48_000), on: "t1")
        }
        let trim = try await package.run("clip", "ripple-trim", "PKG", "c", "--edge", "end", "--by", "4800")
        #expect(trim.status == 0, "RIPPLE-C2 ripple-trim with a wholly unplaced take: \(trim)")
        #expect(try await Self.markers(package) == ["m": 204_800])
    }
}
