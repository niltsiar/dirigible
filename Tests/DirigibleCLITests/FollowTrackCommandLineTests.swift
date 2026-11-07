import DirigibleCore
import Foundation
import Testing

/// `dirigible track follow`, `info`, and the ripple commands with a follow track (decision 0073,
/// criteria C36, C37, C51, C55). Fixture F: track `host` with h 0 ..< 960 000, track `bed` with
/// bed 0 ..< 960 000, and track `sfx` with w at 192 000, x at 264 000 (12 000), and y at 360 000.
/// The cut is 240 000 ..< 336 000. `follow` names the tracks that follow.
struct FollowTrackCommandLineTests {
    static func package(w: Int = 24_000, follow: [TrackID] = ["bed", "sfx"]) throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        for (track, file) in [("host", "h"), ("bed", "b"), ("sfx", "s")] {
            try session.addTrack(TrackID(track), name: track, layout: .mono)
            try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: 1_000_000))
        }
        try session.place(Clip(id: "h", file: "h", start: 0, offset: 0, length: 960_000), on: "host")
        try session.place(Clip(id: "bed", file: "b", start: 0, offset: 0, length: 960_000), on: "bed")
        for clip in [
            Clip(id: "w", file: "s", start: 192_000, offset: 0, length: Frames(w)),
            Clip(id: "x", file: "s", start: 264_000, offset: 100_000, length: 12_000),
            Clip(id: "y", file: "s", start: 360_000, offset: 200_000, length: 48_000),
        ] { try session.place(clip, on: "sfx") }
        if !follow.isEmpty { try session.setFollowTrack(true, tracks: follow) }
        return try TemporaryPackage(session)
    }

    static let cut = ["clip", "ripple-delete", "PKG", "--from", "240000", "--to", "336000"]

    private func follows(_ package: TemporaryPackage) throws -> [String] {
        try package.read().tracks.filter(\.isFollowTrack).map(\.id.rawValue)
    }

    /// C37: the command sets the flag, and `--off` clears it.
    @Test func trackFollowSetsAndClears() async throws {
        let package = try Self.package(follow: [])
        let on = try await package.run("track", "follow", "PKG", "bed", "sfx")
        #expect(on == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try follows(package) == ["bed", "sfx"])
        #expect(String(decoding: try package.xml(), as: UTF8.self).contains("follow=\"true\""))

        let off = try await package.run("track", "follow", "PKG", "bed", "--off")
        #expect(off == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try follows(package) == ["sfx"])
    }

    /// C37: no track is a usage error (64); an unknown track is a refusal (1). The package stays.
    @Test(arguments: [
        (["track", "follow", "PKG"], Int32(64), "Give one track or more."),
        (["track", "follow", "PKG", "zz"], Int32(1), "Error: no track \"zz\".\n"),
        (["track", "follow", "PKG", "bed", "zz", "--off"], Int32(1), "Error: no track \"zz\".\n"),
    ])
    func trackFollowExitCodes(arguments: [String], status: Int32, text: String) async throws {
        let package = try Self.package(follow: [])
        let before = try package.xml()
        let result = try await package.run(arguments)
        #expect(result.status == status && result.stderr.contains(text), "\(result)")
        #expect(try package.xml() == before)
    }

    /// C37: the text line of a follow track ends with ` follow`, and the JSON has the key only when on.
    @Test func infoShowsTheFlag() async throws {
        let package = try Self.package(follow: ["bed"])
        let text = try await package.run("info", "PKG")
        let lines = text.stdout.split(separator: "\n").filter { $0.hasPrefix("track ") }.map(String.init)
        #expect(lines.count == 3)
        #expect(lines.first { $0.hasPrefix("track bed ") }?.hasSuffix(" follow") == true, "\(lines)")
        #expect(lines.filter { $0.hasSuffix(" follow") }.count == 1, "\(lines)")

        let json = try await package.run("info", "PKG", "--json")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        let tracks = try #require(root["tracks"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0["id"] as? String ?? "", $0) })
        #expect(byID["bed"]?["follow"] as? Bool == true)
        #expect(byID["host"]?["follow"] == nil && byID["sfx"]?["follow"] == nil)
    }

    /// C36: a follow clip that would cover another clip refuses with the clip names, and the file
    /// stays. With w of length 48000 the cut passes.
    @Test func aRippleDeleteOverlapExits1WithTheText() async throws {
        let package = try Self.package(w: 48_001)
        let before = try package.xml()
        let refused = try await package.run(Self.cut)
        #expect(
            refused
                == CLIResult(
                    status: 1, stdout: "", stderr: "Error: clip \"x\" follows ripples and would cover clip \"w\".\n"))
        #expect(try package.xml() == before)

        let fits = try Self.package(w: 48_000)
        #expect(try await fits.run(Self.cut).status == 0)
    }

    /// C51: `--track bed` names the bed, so it cuts as with no flag.
    @Test func aRippleDeleteWithTrackCutsTheFollowTrack() async throws {
        let package = try Self.package()
        let result = try await package.run(Self.cut + ["--track", "bed"])
        #expect(result.status == 0, "\(result)")
        let bed = try #require(try package.read().track("bed")?.clips)
        #expect(bed.map(\.range) == [0..<240_000, 240_000..<864_000])
    }

    /// C55: when each track follows and none is named, the edit cuts nothing and refuses. `--track host` passes.
    @Test func aRippleDeleteOfOnlyFollowTracksExits1() async throws {
        let package = try Self.package(follow: ["host", "bed", "sfx"])
        let before = try package.xml()
        let refused = try await package.run(Self.cut)
        #expect(
            refused
                == CLIResult(
                    status: 1, stdout: "",
                    stderr:
                        "Error: no track to edit: each track of the ripple follows ripples, and the edit names none.\n")
        )
        #expect(try package.xml() == before)
        #expect(try await package.run(Self.cut + ["--track", "host"]).status == 0)
    }
}
