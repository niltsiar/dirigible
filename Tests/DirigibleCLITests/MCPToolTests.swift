import DirigibleCore
import Foundation
import Testing

@testable import DirigibleMCP

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

        let unknown = try await info(["tracks": ["nope"]])
        #expect(unknown.isError && unknown.text == "no track \"nope\".", "\(unknown)")
    }

    /// 6 tracks of 201 clips, each split from the right part of the split before, so the IDs chain
    /// as the app makes them (c1@10000@20000...), and one marker.
    private func longPackage() throws -> TemporaryPackage {
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
        return try TemporaryPackage(session)
    }

    /// An answer over `sessionInfoBudget` is the overview. The JSON of 1950001...2010000 has
    /// 56,443 characters, which Claude Code refused (over 25,000 tokens).
    /// A short from/to range gives the full JSON.
    @Test func sessionInfoOfALongSessionGivesAnOverview() async throws {
        let long = try longPackage()
        let answers = try await mcp([
            toolCall(1, "session_info", ["package": long.path]),
            toolCall(2, "session_info", ["package": long.path, "tracks": ["track-1"]]),
            toolCall(3, "session_info", ["package": long.path, "from": 0, "to": 50_000]),
            toolCall(4, "session_info", ["package": long.path, "from": 1_950_001, "to": 2_010_000]),
        ])
        let (whole, one, range) = (
            toolResult(answer(answers, id: 1)).text, toolResult(answer(answers, id: 2)).text,
            toolResult(answer(answers, id: 3)).text
        )
        let refused = toolResult(answer(answers, id: 4)).text
        for text in [whole, one, range, refused] {
            #expect(text.count <= sessionInfoBudget, "\(text.count) characters")
        }
        #expect(json(refused)?["note"] is String, "56,443 characters of JSON pass 25,000 tokens: \(refused.count)")
        let overview = json(whole)
        let tracks = overview?["tracks"] as? [[String: Any]] ?? []
        #expect(tracks.map { $0["id"] as? String } == (1...6).map { "track-\($0)" })
        #expect(tracks.allSatisfy { $0["clips"] as? Int == 201 && $0["name"] is String }, "\(tracks.first ?? [:])")
        #expect(overview?["end"] as? Int == 2_010_000 && overview?["markers"] as? Int == 1)
        #expect((overview?["note"] as? String)?.contains("from and to (a frame range), or with tracks") == true)
        // A filtered overview gives the session values, and a note for a filter that is still too large.
        for (name, text) in [("tracks", one), ("from/to", refused)] {
            let filtered = json(text)
            #expect(filtered?["end"] as? Int == 2_010_000 && filtered?["markers"] as? Int == 1, "\(name): \(text)")
            let note = filtered?["note"] as? String ?? ""
            #expect(note.contains("smaller parts with from and to") && !note.contains("tracks"), "\(name): \(note)")
        }
        #expect((json(one)?["tracks"] as? [[String: Any]])?.first?["clips"] as? Int == 201, "one track: overview")
        let clips = (json(range)?["tracks"] as? [[String: Any]])?.map { ($0["clips"] as? [Any])?.count }
        #expect(clips == Array(repeating: 6, count: 6), "the range 0...50000 holds 6 clips of each track")
    }

    /// `compact` keeps `sampleRate`, `tracks` with their clips, and `markers`. The filters and
    /// the overview rule hold, and `compact` false gives the JSON of `info --json`.
    @Test func aCompactInfoHasOnlyTracksClipsAndMarkers() async throws {
        let full = try #require(json(try await info().text))
        let compact = try await info(["compact": true])
        let object = try #require(json(compact.text))
        #expect(!compact.isError && !compact.text.contains("\n"), "one compact line: \(compact.text)")
        #expect(Set(object.allKeys.compactMap { $0 as? String }) == ["markers", "sampleRate", "tracks"], "\(object)")
        for key in ["markers", "sampleRate", "tracks"] { #expect(object[key] as? NSObject == full[key] as? NSObject) }
        #expect(json(try await info(["compact": false]).text) == full, "compact false is the JSON of now")

        let byTrack = json(try await info(["compact": true, "tracks": ["b"]]).text)
        #expect(Set(byTrack?.allKeys.compactMap { $0 as? String } ?? []) == ["markers", "sampleRate", "tracks"])
        #expect((byTrack?["tracks"] as? [[String: Any]])?.map { $0["id"] as? String } == ["b"])
        let byRange = json(try await info(["compact": true, "from": 1000, "to": 3000]).text)
        let tracks = byRange?["tracks"] as? [[String: Any]] ?? []
        let clips = tracks.map { ($0["clips"] as? [[String: Any]] ?? []).map { $0["id"] as? String ?? "" } }
        #expect(clips == [["A1", "A2"], ["B1"]])
        #expect((byRange?["markers"] as? [[String: Any]])?.map { $0["id"] as? String } == ["m1"])

        let long = try longPackage()
        let overview = toolResult(
            answer(try await mcp([toolCall(1, "session_info", ["package": long.path, "compact": true])]), id: 1))
        let note = json(overview.text)?["note"] as? String ?? ""
        #expect(overview.text.count <= sessionInfoBudget && note.contains("This is an overview"), "\(overview.text)")
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
            toolCall(1, "clip_ripple_delete", ["package": pkg, "from": [0], "to": [48_000]]),
            toolCall(4, "clip_ripple_delete", ["package": pkg, "from": [0, 9_600], "to": [4_800, 48_000]]),
            toolCall(2, "clip_ripple_insert", ["package": pkg, "at": 0, "length": 48_000]),
            toolCall(3, "clip_ripple_trim", ["package": pkg, "clip": "take1-2-1", "edge": "end", "by": -4800]),
        ])
        let cli = try await fixture.package.run("clip", "ripple-delete", "PKG", "--from", "0", "--to", "48000")
        #expect(cli.status == 3)
        for id in 1...4 { #expect(toolResult(answer(answers, id: id)) == (errorText(cli), true), "ripple \(id)") }
        #expect(try fixture.package.xml() == before)

        let control = try await mcp([toolCall(1, "marker_set", ["package": pkg, "name": "M", "at": 0, "id": "m"])])
        #expect(toolResult(answer(control, id: 1)) == ("m", false))
        #expect(try fixture.package.xml() != before)
    }

    /// C17 of run 14: `backup_list` gives the names, newest first. `backup_revert` reverts and
    /// saves, and keeps a backup of the replaced session. A bad name changes nothing. The backup
    /// is from 2001, so the kept copy of the current file is newer on any test clock.
    @Test func backupToolsListAndRevert() async throws {
        let (pkg, name) = (package.path, "session-20011009T081530.250Z.xml")
        let none = try await mcp([toolCall(1, "backup_list", ["package": pkg])])
        #expect(toolResult(answer(none, id: 1)) == ("No backups.", false))
        let folder = package.url.appending(path: "Backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TemporaryPackage(Session(sampleRate: 48_000)).xml().write(to: folder.appending(path: name))
        let before = try package.xml()

        let refused = try await mcp([
            toolCall(1, "backup_list", ["package": pkg]),
            toolCall(2, "backup_revert", ["package": pkg, "name": "notes.xml"]),
        ])
        #expect(toolResult(answer(refused, id: 1)) == (name, false))
        let bad = toolResult(answer(refused, id: 2))
        #expect(bad.isError && bad.text.contains("backup file name"), "\(bad)")
        #expect(try package.xml() == before && FileManager.default.subpaths(atPath: folder.path) == [name])

        let answers = try await mcp([
            toolCall(1, "backup_revert", ["package": pkg, "name": name]),
            toolCall(2, "backup_list", ["package": pkg]),
        ])
        #expect(toolResult(answer(answers, id: 1)) == ("OK", false))
        #expect(try package.read() == Session(sampleRate: 48_000))
        let names = toolResult(answer(answers, id: 2)).text.split(separator: "\n").map(String.init)
        #expect(names.count == 2 && names.last == name, "\(names)")
        let kept = try names.first.map { try Data(contentsOf: folder.appending(path: $0)) }
        #expect(kept == before, "the new backup holds the replaced session")
    }

    /// 66 tools in a fixed order, each with a description and a closed schema with `package`,
    /// except `devices` and `apps`, which take no argument.
    @Test func toolsListHasEachTool() async throws {
        let answers = try await mcp([modernRequest(1, "tools/list"), modernRequest(2, "tools/list")])
        let tools = result(answer(answers, id: 1))["tools"] as? [[String: Any]] ?? []
        #expect(
            tools.compactMap { $0["name"] as? String } == [
                "session_create", "session_info", "track_add", "track_add_call", "track_remove", "track_rename",
                "track_gain", "track_route", "track_layout", "track_mute", "track_solo", "track_role", "marker_set",
                "marker_remove", "episode_set", "episode_get",
                "capture_remove", "file_remove", "file_prune", "clip_place", "clip_clear", "clip_split",
                "clip_split_at", "clip_split_stereo", "clip_paste", "clip_paste_clips", "clip_nudge", "clip_remove",
                "clip_move",
                "clip_trim", "clip_gain", "clip_fade", "clip_denoise", "clip_repair", "clip_restore",
                "clip_crossfade", "clip_heal", "clip_envelope", "clip_gain_range", "clip_ripple_delete",
                "clip_ripple_insert", "clip_ripple_trim",
                "transcript_import",
                "transcript_words", "transcript_cut", "transcript_export", "take_map", "backup_list",
                "backup_revert", "record", "transport_play", "transport_stop", "transport_locate", "loudness", "export",
                "render", "level", "duck", "import", "silences", "nearest_pause", "meter", "chapters_export",
                "chapters_import", "devices", "apps", "batch",
            ])
        for tool in tools {
            let name = tool["name"] as? String ?? ""
            let schema = tool["inputSchema"] as? [String: Any] ?? [:]
            #expect((tool["description"] as? String)?.isEmpty == false, "\(name)")
            #expect(schema["type"] as? String == "object" && schema["additionalProperties"] as? Bool == false)
            if ["devices", "apps"].contains(name) {
                // They read this Mac, not a package: no argument (W1).
                let properties = schema["properties"] as? [String: Any]
                #expect(properties?.isEmpty == true && schema["required"] == nil, "\(name): \(schema)")
                // The core rules ask for `package`, so the description says that these take none.
                #expect((tool["description"] as? String)?.hasSuffix(" It takes no argument.") == true, "\(name)")
            } else {
                #expect((schema["required"] as? [String])?.first == "package", "\(name)")
            }
        }
        #expect(NSArray(array: tools) == (result(answer(answers, id: 2))["tools"] as? NSArray), "two lists are equal")
        // The guide lists the tools by hand, so a new tool must also go there.
        let guide = try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/guide.md"),
            encoding: .utf8)
        #expect(guide.contains("The \(tools.count) tools"), "the guide gives another count of tools")
        for name in tools.compactMap({ $0["name"] as? String }) where !guide.contains("`\(name)`") {
            Issue.record("docs/guide.md does not name the tool \(name)")
        }
    }

    /// Run 2026-10-11-chapters-in-file, C8, G14: `marker_set` with only the ID and a URL keeps the
    /// kind, the name, the position, and the image of the marker.
    @Test func markerSetWithOnlyIDAndURLKeepsTheChapter() async throws {
        let image = try ArtworkName("0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.jpg")
        try package.edit { session in
            try session.setMarker(Marker(id: "c", name: "Part", position: 960, kind: .chapter, image: image))
        }
        let answers = try await mcp([
            toolCall(1, "marker_set", ["package": package.path, "id": "c", "url": "https://example.com/p"])
        ])
        #expect(toolResult(answer(answers, id: 1)) == ("c", false))
        #expect(
            try package.read().markers["c"]
                == Marker(
                    id: "c", name: "Part", position: 960, kind: .chapter, url: try WebURL("https://example.com/p"),
                    image: image))
    }

    /// C8: `marker_set` takes `url` and `image` (an absolute path), with the rules of the CLI.
    @Test func markerSetTakesURLAndImage() async throws {
        let source = package.folder.appending(path: "art.jpg")
        try EpisodeCommandTests.writeImage(source, width: 300, height: 300)
        let answers = try await mcp([
            toolCall(
                1, "marker_set",
                [
                    "package": package.path, "id": "n", "name": "New", "at": 480, "kind": "chapter",
                    "url": "https://example.com/n", "image": source.path,
                ]),
            toolCall(2, "marker_set", ["package": package.path, "id": "n", "image": "art.jpg"]),
        ])
        #expect(toolResult(answer(answers, id: 1)) == ("n", false))
        let marker = try #require(try package.read().markers["n"])
        #expect(marker.kind == .chapter && marker.url?.text == "https://example.com/n" && marker.image != nil)
        #expect(toolResult(answer(answers, id: 2)) == ("The argument \"image\" must be an absolute path.", true))
    }

    /// C1, C8, G14: a URL over 255 bytes and a new marker with no name or position give a tool
    /// error and no change.
    @Test func markerSetRefusesAURLOver255Bytes() async throws {
        let before = try package.xml()
        let head = "https://example.com/"
        let long = head + String(repeating: "a", count: Marker.maximumURLBytes + 1 - head.utf8.count)
        let answers = try await mcp([
            toolCall(1, "marker_set", ["package": package.path, "name": "X", "at": 0, "url": long]),
            toolCall(2, "marker_set", ["package": package.path, "id": "new", "name": "X"]),
        ])
        #expect(toolResult(answer(answers, id: 1)) == ("a marker URL has at most 255 bytes.", true))
        #expect(toolResult(answer(answers, id: 2)) == ("a new marker needs a name and a position.", true))
        #expect(try package.xml() == before)
    }

    /// C1 (decision 0048): on package files no tool records. With no app server, `record` gives
    /// a tool error that says how to record in the app, and the package does not change.
    @Test func recordOnFilesIsRefused() async throws {
        let before = try package.xml()
        let names = try FileManager.default.contentsOfDirectory(atPath: package.path).sorted()
        let answers = try await mcp([
            toolCall(1, "record", ["package": package.path, "seconds": 1, "arm": ["a"]])
        ])
        let expected =
            "To record, open \(package.path) in Dirigible and turn on Let Agents Edit Open Sessions in Settings. "
            + "A take needs the consent of the user in the app."
        #expect(toolResult(answer(answers, id: 1)) == (expected, true))
        #expect(try package.xml() == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.path).sorted() == names)
    }

    /// C17: the read tools say that they change nothing; record gives its three hints; an edit
    /// tool has no annotations (the control).
    @Test func annotations() async throws {
        let answers = try await mcp([modernRequest(1, "tools/list")])
        let tools = result(answer(answers, id: 1))["tools"] as? [[String: Any]] ?? []
        func annotations(_ name: String) -> [String: Bool]? {
            tools.first { $0["name"] as? String == name }?["annotations"] as? [String: Bool]
        }
        for name in ["session_info", "backup_list", "episode_get", "loudness", "devices", "apps"] {
            #expect(annotations(name) == ["readOnlyHint": true], "\(name)")
        }
        #expect(annotations("record") == ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": true])
        #expect(tools.contains { $0["name"] as? String == "track_add" })
        #expect(tools.first { $0["name"] as? String == "track_add" }?["annotations"] == nil)
    }
}
