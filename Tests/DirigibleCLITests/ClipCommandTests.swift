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

    /// K3: `clip gain` takes one or more clips and sets them in one edit. A duplicate, an unknown
    /// clip, or no clip exits nonzero and leaves the file unchanged.
    @Test func gainSetsManyClips() async throws {
        try package.edit {
            for (id, start) in [("A", 0), ("B", 2000), ("C", 4000)] as [(ClipID, Frames)] {
                try $0.place(Clip(id: id, file: "f1", start: start, offset: start, length: 1000), on: "host")
            }
        }
        #expect(try await package.run("clip", "gain", "PKG", "A", "C", "--db", "-6") == silent)
        #expect(try clips("host").map(\.gain) == [Gain(dB: -6)!, .zero, Gain(dB: -6)!])
        #expect(try await package.run("clip", "gain", "PKG", "B", "--db", "2.5") == silent, "one clip still works")
        #expect(try clips("host").map(\.gain) == [Gain(dB: -6)!, Gain(dB: 2.5)!, Gain(dB: -6)!])

        let before = try package.xml()
        let duplicate = try await package.run("clip", "gain", "PKG", "A", "A", "--db", "0")
        #expect(duplicate.status == 64 && duplicate.stderr.contains("Clip \"A\" is given twice."), "\(duplicate)")
        #expect(
            try await package.run("clip", "gain", "PKG", "A", "X", "--db", "0")
                == CLIResult(status: 1, stdout: "", stderr: "Error: no clip \"X\".\n"))
        let none = try await package.run("clip", "gain", "PKG", "--db", "0")
        #expect(none.status == 64 && none.stderr.contains("Missing expected argument '<clips> ...'"), "\(none)")
        #expect(try package.xml() == before, "a refused gain changes nothing")
    }

    /// Fades C8 (decision 0035): `clip fade` sets both fades and saves version 3; `info` shows them,
    /// and `info --json` leaves out a fade of 0.
    @Test func fadeSetsBothFades() async throws {
        try package.edit {
            try $0.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 2000), on: "host")
            try $0.place(Clip(id: "c2", file: "f1", start: 3000, offset: 3000, length: 1000), on: "host")
        }
        #expect(try await package.run("clip", "fade", "PKG", "--clip", "c1", "--in", "480", "--out", "960") == silent)
        #expect(try clips("host").first?.fades == Fades(fadeIn: 480, fadeOut: 960))
        #expect(String(decoding: try package.xml(), as: UTF8.self).contains(#"version="3""#), "saved as version 3")

        let text = try await package.run("info", "PKG").stdout
        #expect(text.contains("  clip c1 file f1 start 0 offset 0 length 2000 0.0 dB fade in 480, out 960\n"))
        #expect(text.contains("  clip c2 file f1 start 3000 offset 3000 length 1000 0.0 dB\n"), "no fade, no text")

        let json = try await package.run("info", "PKG", "--json").stdout
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let tracks = try #require(object?["tracks"] as? [[String: Any]])
        let host = try #require(tracks.first?["clips"] as? [[String: Any]])
        #expect(host[0]["fadeIn"] as? Int == 480 && host[0]["fadeOut"] as? Int == 960, "c1 fades in the JSON")
        #expect(host[1]["fadeIn"] == nil && host[1]["fadeOut"] == nil, "a fade of 0 is left out")

        #expect(try await package.run("clip", "fade", "PKG", "--clip", "c2", "--in", "0", "--out", "5") == silent)
        let json2 = try await package.run("info", "PKG", "--json").stdout
        let clips2 = (try JSONSerialization.jsonObject(with: Data(json2.utf8)) as? [String: Any])
            .flatMap { ($0["tracks"] as? [[String: Any]])?.first?["clips"] as? [[String: Any]] }
        #expect(clips2?[1]["fadeIn"] == nil && clips2?[1]["fadeOut"] as? Int == 5, "only fadeOut")

        // An absent --in or --out keeps the current value; one of them is required.
        #expect(try await package.run("clip", "fade", "PKG", "--clip", "c1", "--out", "100") == silent)
        #expect(try clips("host").first?.fades == Fades(fadeIn: 480, fadeOut: 100), "--out only keeps fadeIn")
        #expect(try await package.run("clip", "fade", "PKG", "--clip", "c1", "--in", "200") == silent)
        #expect(try clips("host").first?.fades == Fades(fadeIn: 200, fadeOut: 100), "--in only keeps fadeOut")
        #expect(try await package.run("clip", "fade", "PKG", "--clip", "c1").status == 64, "no --in and no --out")

        let before = try package.xml()
        let cases: [([String], String)] = [
            (
                ["--clip", "c2", "--in", "600", "--out", "500"],
                "the fades and crossfades of clip \"c2\" are longer than the clip (1000 frames)."
            ),
            (["--clip", "c9", "--in", "0", "--out", "0"], "no clip \"c9\"."),
            (["--clip", "c1", "--in", "-1", "--out", "0"], "a frame is negative or more than 2^40."),
        ]
        for (arguments, message) in cases {
            #expect(
                try await package.run(["clip", "fade", "PKG"] + arguments)
                    == CLIResult(status: 1, stdout: "", stderr: "Error: \(message)\n"))
        }
        #expect(try package.xml() == before, "a refused fade changes nothing")
    }

    /// Clips A (f1) and B (f3) on host with a join at 5 000; B has `bOffset` frames of handle.
    private func joined(bOffset: Int = 1_000, bFile: FileID = "f3") throws {
        try package.edit { session in
            try session.addFile(AudioFile(id: "f3", path: "guest-1.wav", layout: .mono, length: 10_000))
            try session.place(Clip(id: "A", file: "f1", start: 1_000, offset: 1_000, length: 4_000), on: "host")
            try session.place(
                Clip(id: "B", file: bFile, start: 5_000, offset: Frames(bOffset), length: 4_000), on: "host")
        }
    }

    /// Crossfades F5: `clip crossfade` sets the crossfade on both clips, `info` shows it, and 0
    /// removes it.
    @Test func crossfadeSetsBothClips() async throws {
        try joined()
        #expect(try await package.run("clip", "crossfade", "PKG", "--clip", "A", "--length", "960") == silent)
        #expect(
            try clips("host").map(\.crossfades) == [Crossfades(start: 0, end: 960), Crossfades(start: 960, end: 0)])
        #expect(String(decoding: try package.xml(), as: UTF8.self).contains(#"version="4""#), "saved as version 4")

        let text = try await package.run("info", "PKG").stdout
        #expect(text.contains("  clip A file f1 start 1000 offset 1000 length 4000 0.0 dB crossfade out 960\n"))
        #expect(text.contains("  clip B file f3 start 5000 offset 1000 length 4000 0.0 dB crossfade in 960\n"))
        let json = try await package.run("info", "PKG", "--json").stdout
        let host = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            .flatMap { ($0["tracks"] as? [[String: Any]])?.first?["clips"] as? [[String: Any]] }
        #expect(host?[0]["crossfadeOut"] as? Int == 960 && host?[0]["crossfadeIn"] == nil, "A in the JSON")
        #expect(host?[1]["crossfadeIn"] as? Int == 960 && host?[1]["crossfadeOut"] == nil, "B in the JSON")

        #expect(try await package.run("clip", "crossfade", "PKG", "--clip", "A", "--length", "0") == silent)
        #expect(try clips("host").allSatisfy { $0.crossfades == .zero }, "--length 0 removes it")
    }

    /// Seamless crossfade C32 and C34: `clip crossfade` at a seamless join with two gains saves
    /// version 9, and `info` reads it.
    @Test func crossfadeAtASeamlessJoinWithTwoGains() async throws {
        try joined(bOffset: 5_000, bFile: "f1")
        #expect(try await package.run("clip", "gain", "PKG", "B", "--db", "-6") == silent)
        #expect(try await package.run("clip", "crossfade", "PKG", "--clip", "A", "--length", "960") == silent)
        #expect(
            try clips("host").map(\.crossfades) == [Crossfades(start: 0, end: 960), Crossfades(start: 960, end: 0)])
        #expect(String(decoding: try package.xml(), as: UTF8.self).contains(#"version="9""#), "saved as version 9")
        let info = try await package.run("info", "PKG")
        #expect(info.status == 0 && info.stdout.contains("crossfade in 960\n"), "\(info)")
    }

    /// Seamless crossfade C32: at a seamless join with equal gains, a fade at the join makes a dip,
    /// so `clip crossfade` sets the crossfade and saves version 9.
    @Test func crossfadeAtASeamlessJoinWithAFade() async throws {
        try joined(bOffset: 5_000, bFile: "f1")
        #expect(try await package.run("clip", "fade", "PKG", "--clip", "A", "--in", "0", "--out", "400") == silent)
        #expect(try await package.run("clip", "fade", "PKG", "--clip", "B", "--in", "400", "--out", "0") == silent)
        #expect(try await package.run("clip", "crossfade", "PKG", "--clip", "A", "--length", "960") == silent)
        #expect(
            try clips("host").map(\.crossfades) == [Crossfades(start: 0, end: 960), Crossfades(start: 960, end: 0)])
        #expect(try clips("host").allSatisfy { $0.fades == .zero }, "the crossfade replaces the fades at the join")
        #expect(String(decoding: try package.xml(), as: UTF8.self).contains(#"version="9""#), "saved as version 9")
    }

    /// Crossfades F5 and F2b: each refusal exits with its message and changes nothing.
    @Test func crossfadeRefusesWithNoHandle() async throws {
        try joined(bOffset: 479)
        try package.edit { session in
            try session.place(Clip(id: "C", file: "f1", start: 9_000, offset: 5_000, length: 1_000), on: "host")
            try session.place(Clip(id: "D", file: "f1", start: 10_000, offset: 6_000, length: 1_000), on: "host")
            try session.place(Clip(id: "E", file: "f1", start: 11_000, offset: 20_000, length: 1_000), on: "host")
            try session.setCrossfades(["D": 400])
        }
        let before = try package.xml()
        let cases: [([String], String)] = [
            (
                ["--clip", "A", "--length", "960"],
                "clip \"B\" needs 480 frames of audio past its edge in its file for this crossfade."
            ),
            (["--clip", "E", "--length", "960"], "no clip touches the crossfade edge of clip \"E\"."),
            (
                ["--clip", "C", "--length", "960"],
                "clip \"C\" and the next clip play one piece of audio at one gain with no fade at the join, so a "
                    + "crossfade there changes nothing."
            ),
            (
                ["--clip", "D", "--length", "2002"],
                "the fades and crossfades of clip \"D\" are longer than the clip (1000 frames)."
            ),
        ]
        for (arguments, message) in cases {
            #expect(
                try await package.run(["clip", "crossfade", "PKG"] + arguments)
                    == CLIResult(status: 1, stdout: "", stderr: "Error: \(message)\n"))
        }
        #expect(
            try await package.run("clip", "fade", "PKG", "--clip", "D", "--out", "10")
                == CLIResult(
                    status: 1, stdout: "",
                    stderr: "Error: clip \"D\" has a crossfade at that edge, so it cannot also have a fade there.\n"))
        for length in ["961", "-2"] {
            let result = try await package.run("clip", "crossfade", "PKG", "--clip", "A", "--length", length)
            #expect(
                result.status == 64
                    && result.stderr.contains("A crossfade length is an even number of frames, 0 or more."))
        }
        #expect(try package.xml() == before, "a refused crossfade changes nothing")
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
