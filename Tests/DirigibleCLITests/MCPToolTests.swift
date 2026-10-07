import DirigibleCore
import Foundation
import Testing

/// The tools of `dirigible mcp` that are not a plain edit row: `session_info`, `session_create`,
/// the lock, the pending take, and the argument checks (decision 0041).
struct MCPToolTests {
    let package: TemporaryPackage

    /// Track "a": clips A1 0..<1000, A2 2000..<3000, A3 5000..<6000 (file f, capture k1). Track
    /// "b": clip B1 0..<1000 (file g). File h has capture k2 and no clip. Markers at 3000 and 7000.
    init() throws {
        var session = Session(sampleRate: 48_000)
        for id in ["k1", "k2"] {
            try session.addCapture(
                Capture(
                    id: CaptureID(id), deviceUID: "usb", deviceName: "USB", hostTimeNanos: 1, sampleTime: 0,
                    nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0, resampledFromRate: nil,
                    driftCorrected: true))
        }
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000, capture: "k1"))
        try session.addFile(AudioFile(id: "g", path: "g.wav", layout: .mono, length: 480_000))
        try session.addFile(AudioFile(id: "h", path: "h.wav", layout: .mono, length: 480_000, capture: "k2"))
        try session.addTrack("a", name: "A", layout: .mono)
        try session.addTrack("b", name: "B", layout: .mono)
        for (id, start) in [("A1", 0), ("A2", 2000), ("A3", 5000)] {
            try session.place(Clip(id: ClipID(id), file: "f", start: Frames(start), offset: 0, length: 1000), on: "a")
        }
        try session.place(Clip(id: "B1", file: "g", start: 0, offset: 0, length: 1000), on: "b")
        try session.setMarker(Marker(id: "m1", name: "One", position: 3000, kind: .marker))
        try session.setMarker(Marker(id: "m2", name: "Two", position: 7000, kind: .chapter))
        package = try TemporaryPackage(session)
    }

    private func info(_ arguments: [String: Any] = [:]) async throws -> (text: String, isError: Bool) {
        let answers = try await mcp([toolCall(1, "session_info", arguments.merging(["package": package.path]) { $1 })])
        return toolResult(answer(answers, id: 1))
    }

    private func json(_ text: String) -> NSDictionary? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? NSDictionary
    }

    @Test func sessionInfoMatchesInfoJSON() async throws {
        let (text, isError) = try await info()
        let cli = try await dirigible("info", package.path, "--json")
        #expect(!isError && !text.contains("\n"), "one compact line: \(text)")
        #expect(json(text) != nil && json(text) == json(cli.stdout), "\(text)")

        let missing = package.folder.appending(path: "Gone.dirigible").path
        let answers = try await mcp([toolCall(1, "session_info", ["package": missing])])
        let refused = toolResult(answer(answers, id: 1))
        let cliRefused = try await dirigible("info", missing)
        #expect(refused.isError && refused.text == errorText(cliRefused), "\(refused)")
    }

    /// A clip touches the range at its edges, and a marker at `to` is in it.
    @Test func sessionInfoFilters() async throws {
        let byTrack = json(try await info(["tracks": ["b"]]).text)
        #expect((byTrack?["tracks"] as? [[String: Any]])?.map { $0["id"] as? String } == ["b"])
        #expect((byTrack?["files"] as? [[String: Any]])?.map { $0["id"] as? String } == ["g"])
        #expect((byTrack?["captures"] as? [Any])?.isEmpty == true, "file g has no capture")
        #expect((byTrack?["markers"] as? [Any])?.count == 2, "all markers")

        let byRange = json(try await info(["from": 1000, "to": 3000]).text)
        let tracks = byRange?["tracks"] as? [[String: Any]] ?? []
        let clips = tracks.map { ($0["clips"] as? [[String: Any]] ?? []).map { $0["id"] as? String ?? "" } }
        #expect(clips == [["A1", "A2"], ["B1"]], "A1 and B1 end at 1000, A2 starts in the range, A3 is out")
        #expect((byRange?["markers"] as? [[String: Any]])?.map { $0["id"] as? String } == ["m1"], "m1 is at to")
        #expect((byRange?["files"] as? [[String: Any]])?.map { $0["id"] as? String } == ["f", "g"])
        #expect((byRange?["captures"] as? [[String: Any]])?.map { $0["id"] as? String } == ["k1"])
    }

    /// C9a: 6 tracks of 201 clips, each split from the right part of the split before, so the IDs
    /// chain as the app makes them (c1@10000@20000...). An answer over 60,000 characters (about
    /// 15,000 tokens) is the overview; a from/to range gives the full JSON of the clips in it.
    @Test func sessionInfoOfALongSessionGivesAnOverview() async throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 2_010_000))
        for track in 1...6 {
            let id = TrackID("track-\(track)")
            try session.addTrack(id, name: "Track \(track)", layout: .mono)
            var right = ClipID("c\(track)")
            try session.place(Clip(id: right, file: "f", start: 0, offset: 0, length: 2_010_000), on: id)
            for split in 1...200 { right = try session.split(right, at: Frames(split * 10_000)) }
        }
        try session.setMarker(Marker(id: "m", name: "M", position: 0, kind: .marker))
        let long = try TemporaryPackage(session)
        let answers = try await mcp([
            toolCall(1, "session_info", ["package": long.path]),
            toolCall(2, "session_info", ["package": long.path, "tracks": ["track-1"]]),
            toolCall(3, "session_info", ["package": long.path, "from": 0, "to": 50_000]),
        ])
        let (whole, one, range) = (
            toolResult(answer(answers, id: 1)).text, toolResult(answer(answers, id: 2)).text,
            toolResult(answer(answers, id: 3)).text
        )
        for text in [whole, one, range] { #expect(text.count <= 60_000, "\(text.count) characters") }
        let overview = json(whole)
        let tracks = overview?["tracks"] as? [[String: Any]] ?? []
        #expect(tracks.map { $0["id"] as? String } == (1...6).map { "track-\($0)" })
        #expect(tracks.allSatisfy { $0["clips"] as? Int == 201 && $0["name"] is String }, "\(tracks.first ?? [:])")
        #expect(overview?["end"] as? Int == 2_010_000 && overview?["markers"] as? Int == 1)
        #expect((overview?["note"] as? String)?.contains("from and to") == true, "\(whole.prefix(300))")
        #expect((json(one)?["tracks"] as? [[String: Any]])?.first?["clips"] as? Int == 201, "one track: overview")
        let clips = (json(range)?["tracks"] as? [[String: Any]])?.map { ($0["clips"] as? [Any])?.count }
        #expect(clips == Array(repeating: 6, count: 6), "the range 0...50000 holds 6 clips of each track")
    }

    @Test func sessionCreateMatchesCreate() async throws {
        let (tool, cli) = (try TemporaryPackage(), try TemporaryPackage())
        let other = tool.folder.appending(path: "Show.txt").path
        let answers = try await mcp([
            toolCall(1, "session_create", ["package": tool.path, "sample_rate": 1]),
            toolCall(2, "session_create", ["package": tool.path, "sample_rate": 48_000]),
            toolCall(3, "session_create", ["package": other, "sample_rate": 48_000]),
            toolCall(
                4, "session_create", ["package": cli.folder.appending(path: "Zero.dirigible").path, "sample_rate": 0]),
        ])
        #expect(try await dirigible("create", cli.path, "--sample-rate", "1").status == 0)
        #expect(toolResult(answer(answers, id: 1)) == ("OK", false))
        #expect(try tool.xml() == cli.xml())

        let exists = try await dirigible("create", cli.path, "--sample-rate", "48000")
        #expect(
            toolResult(answer(answers, id: 2)) == (errorText(exists).replacing(cli.path, with: tool.path), true),
            "a package that exists")
        #expect(toolResult(answer(answers, id: 3)) == ("The package path must end in .dirigible.", true))
        #expect(!FileManager.default.fileExists(atPath: other))
        let zero = toolResult(answer(answers, id: 4))
        #expect(zero == ("The sample rate must be more than 0.", true), "the text of dirigible create: \(zero)")
        #expect(!FileManager.default.fileExists(atPath: cli.folder.appending(path: "Zero.dirigible").path))
    }

    @Test func aLockedPackageIsRefused() async throws {
        let before = try package.xml()
        let rename = toolCall(1, "track_rename", ["package": package.path, "track": "a", "name": "X"])
        let locked: [Answer]
        do {
            let lock = try PackageLock(package.url)
            defer { withExtendedLifetime(lock) {} }
            locked = try await mcp([rename])
        }
        #expect(toolResult(answer(locked, id: 1)) == ("\(package.path) is open in Dirigible.", true))
        #expect(try package.xml() == before)

        #expect(toolResult(answer(try await mcp([rename]), id: 1)) == ("OK", false), "control: no lock")
        #expect(try package.read().track("a")?.name == "X")
    }

    @Test func aPendingTakeIsRefused() async throws {
        try package.edit { session in
            try session.setRecording(
                Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["a"]))
        }
        let before = try package.xml()
        let answers = try await mcp([toolCall(1, "track_rename", ["package": package.path, "track": "a", "name": "X"])])
        #expect(
            toolResult(answer(answers, id: 1))
                == ("\(package.path) has a take that is not finalized; open it in Dirigible first.", true))
        #expect(try package.xml() == before)
    }

    /// C12: each ripple tool refuses a split take with the exit-3 text of the CLI. Control: an
    /// edit that is not a ripple changes the package.
    @Test func aSplitTakeRefusesARipple() async throws {
        let fixture = try await PlaceCommandTests()
        let before = try fixture.package.xml()
        let pkg = fixture.package.path
        let answers = try await mcp([
            toolCall(1, "clip_ripple_delete", ["package": pkg, "from": 0, "to": 48_000]),
            toolCall(2, "clip_ripple_insert", ["package": pkg, "at": 0, "length": 48_000]),
            toolCall(3, "clip_ripple_trim", ["package": pkg, "clip": "take1-2-1", "edge": "end", "by": -4800]),
        ])
        let cli = try await fixture.package.run("clip", "ripple-delete", "PKG", "--from", "0", "--to", "48000")
        #expect(cli.status == 3)
        for id in 1...3 { #expect(toolResult(answer(answers, id: id)) == (errorText(cli), true), "ripple \(id)") }
        #expect(try fixture.package.xml() == before)

        let control = try await mcp([toolCall(1, "marker_set", ["package": pkg, "name": "M", "at": 0, "id": "m"])])
        #expect(toolResult(answer(control, id: 1)) == ("m", false))
        #expect(try fixture.package.xml() != before)
    }

    /// C5: 31 tools in a fixed order, each with a description and a closed schema with `package`.
    @Test func toolsListHasEachTool() async throws {
        let answers = try await mcp([modernRequest(1, "tools/list"), modernRequest(2, "tools/list")])
        let tools = result(answer(answers, id: 1))["tools"] as? [[String: Any]] ?? []
        #expect(
            tools.compactMap { $0["name"] as? String } == [
                "session_create", "session_info", "track_add", "track_add_call", "track_remove", "track_rename",
                "track_gain", "track_route", "track_layout", "track_mute", "track_solo", "marker_set", "marker_remove",
                "capture_remove", "file_remove", "clip_place", "clip_clear", "clip_split", "clip_split_at",
                "clip_paste",
                "clip_paste_clips", "clip_nudge", "clip_remove", "clip_move", "clip_trim", "clip_gain", "clip_fade",
                "clip_crossfade", "clip_ripple_delete", "clip_ripple_insert", "clip_ripple_trim",
            ])
        for tool in tools {
            let schema = tool["inputSchema"] as? [String: Any] ?? [:]
            #expect((tool["description"] as? String)?.isEmpty == false, "\(tool["name"] ?? "")")
            #expect(schema["type"] as? String == "object" && schema["additionalProperties"] as? Bool == false)
            #expect((schema["required"] as? [String])?.first == "package", "\(tool["name"] ?? "")")
        }
        #expect(NSArray(array: tools) == (result(answer(answers, id: 2))["tools"] as? NSArray), "two lists are equal")
        // The guide lists the tools by hand, so a new tool must also go there.
        let guide = try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/guide.md"),
            encoding: .utf8)
        for name in tools.compactMap({ $0["name"] as? String }) where !guide.contains("`\(name)`") {
            Issue.record("docs/guide.md does not name the tool \(name)")
        }
    }
}
