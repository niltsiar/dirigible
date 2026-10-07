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

    /// C9a: 6 tracks of 201 clips. One track is under 100,000 characters (about 25,000 tokens).
    @Test func sessionInfoOfALongSessionFitsWithAFilter() async throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 2_010_000))
        for track in 1...6 {
            let id = TrackID("track-\(track)")
            try session.addTrack(id, name: "Track \(track)", layout: .mono)
            try session.place(Clip(id: ClipID("c\(track)"), file: "f", start: 0, offset: 0, length: 2_010_000), on: id)
            _ = try session.splitClips(at: (1...200).map { Frames($0 * 10_000) }, on: [id])
        }
        let long = try TemporaryPackage(session)
        let answers = try await mcp([
            toolCall(1, "session_info", ["package": long.path]),
            toolCall(2, "session_info", ["package": long.path, "tracks": ["track-1"]]),
        ])
        let whole = toolResult(answer(answers, id: 1)).text
        let one = toolResult(answer(answers, id: 2)).text
        #expect(json(one).map { (($0["tracks"] as? [[String: Any]])?.first?["clips"] as? [Any])?.count } == 201)
        #expect(one.count < 100_000, "one track has \(one.count) characters")
        print("C9a: the whole session has \(whole.count) characters, one track \(one.count)")
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
        #expect(zero.isError && zero.text.contains("\"sample_rate\""), "\(zero)")
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
}
