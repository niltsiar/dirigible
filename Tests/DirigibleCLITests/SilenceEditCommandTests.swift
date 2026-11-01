import DirigibleCore
import Foundation
import Testing

/// `dirigible silence-edit` and the tool `silence_edit` (decision 0066, criteria C24 to C26). The
/// worked fixture of the run analysis: 48 kHz, the mono tracks "host" and "guest", each with one
/// clip from frame 0 of 480 000 frames. Silence A is 96 000 ..< 240 000 and silence B is 264 000
/// ..< 312 000. The default keep is 24 000 frames (500 ms).
struct SilenceEditCommandTests {
    let package: TemporaryPackage

    static func session() throws -> Session {
        var session = Session(sampleRate: 48_000)
        for (track, file) in [("host", "h"), ("guest", "g")] {
            try session.addTrack(TrackID(track), name: track, layout: .mono)
            try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: 480_000))
            try session.place(
                Clip(id: ClipID(file.uppercased()), file: FileID(file), start: 0, offset: 0, length: 480_000),
                on: TrackID(track))
        }
        return session
    }

    init() throws { package = try TemporaryPackage(Self.session()) }

    static let shortenA = ["--from", "96000", "--to", "240000", "--action", "shorten"]
    static let markB = ["--from", "264000", "--to", "312000", "--action", "mark"]
    static let keepSized = ["--from", "400000", "--to", "424000", "--action", "shorten"]

    func ranges(_ track: TrackID) throws -> [Range<Frames>] {
        try #require(try package.read().track(track)).clips.map(\.range)
    }

    /// C24. A is shortened and B is marked: one line for each pair, then the frames removed. The
    /// cut is 108 000 ..< 228 000, so B is at 168 000 and the speech between them at 120 000.
    /// Fail values: a cut at the start of A, a marker at B before the cut.
    @Test func theCommandEditsAndPrintsEachPair() async throws {
        let result = try await package.run(["silence-edit", "PKG"] + Self.shortenA + Self.markB)
        #expect(result.status == 0 && result.stderr.isEmpty, "\(result)")
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 3, "\(lines)")
        #expect(lines.first == "shorten\t96000\t240000\t108000\t228000")
        #expect(lines.last == "removed 120000 frames")
        let mark = lines[1].split(separator: "\t").map(String.init)
        #expect(mark.count == 4 && Array(mark.prefix(3)) == ["mark", "264000", "312000"], "\(lines[1])")
        let saved = try package.read()
        for track in ["host", "guest"] as [TrackID] {
            #expect(try ranges(track) == [0..<108_000, 108_000..<360_000], "\(track)")
        }
        let marker = try #require(saved.markers[MarkerID(mark[3])])
        #expect(marker.name == "Silence 1" && marker.position == 168_000 && marker.kind == .marker)
    }

    /// C24. A shorten of exactly the keep has nothing to cut: the line says `skipped`, the other
    /// pairs apply, and the exit is 0. Fail value: a refusal of the whole call.
    @Test func aPairOfTheKeepFramesIsSkippedAndTheCallGoesOn() async throws {
        let result = try await package.run(["silence-edit", "PKG"] + Self.shortenA + Self.keepSized)
        #expect(result.status == 0, "\(result)")
        #expect(
            result.stdout
                == "shorten\t96000\t240000\t108000\t228000\nskipped\t400000\t424000\tshorten\nremoved 120000 frames\n")
        #expect(try ranges("host") == [0..<108_000, 108_000..<360_000])
        let fresh = try TemporaryPackage(Self.session())
        let loose = try await fresh.run(["silence-edit", "PKG", "--keep", "23999"] + Self.keepSized)
        #expect(loose.stdout == "shorten\t400000\t424000\t411999\t412000\nremoved 1 frames\n", "\(loose)")
    }

    /// C10 through the command: a mute lowers the `--track` tracks only.
    @Test func aMuteLowersTheNamedTracksOnly() async throws {
        let result = try await package.run(
            ["silence-edit", "PKG", "--track", "host", "--from", "96000", "--to", "240000", "--action", "mute"])
        #expect(result == CLIResult(status: 0, stdout: "mute\t96000\t240000\nremoved 0 frames\n", stderr: ""))
        let saved = try package.read()
        let host = try #require(saved.clip("H")?.clip.envelope)
        let guest = try #require(saved.clip("G")?.clip.envelope)
        #expect(host.gain(at: 168_000) == -96)
        #expect(guest.gain(at: 168_000) == 0)
    }

    /// C25. Each refusal exits 64 with its reason and does not save. Several pairs name the pair.
    @Test(
        arguments: [
            ([], "Give one or more --from, --to, and --action."),
            (["--from", "0", "--to", "10"], "Give one --to and one --action for each --from."),
            (["--from", "0", "--action", "mark", "--action", "mark"], "Give one --to and one --action"),
            (
                ["--from", "0", "--to", "10", "--action", "cut"],
                "--action must be shorten, mute, or mark, not \"cut\"."
            ),
            (
                ["--from", "0", "--to", "10", "--action", "mark", "--from", "20", "--to", "30", "--action", "Mute"],
                "not \"Mute\" (pair 2)."
            ),
            (["--from", "20", "--to", "10", "--action", "mark"], "--from must not be more than --to."),
            (
                ["--from", "0", "--to", "10", "--action", "mark", "--from", "30", "--to", "20", "--action", "mark"],
                "--from must not be more than --to (pair 2)."
            ),
            (
                ["--from", "0", "--to", "100", "--action", "mark", "--from", "50", "--to", "200", "--action", "mark"],
                "The ranges must not overlap (pair 2)."
            ),
            (["--from", "-5", "--to", "10", "--action", "mark"], "A frame must be 0 to 2^40."),
            (["--from", "0", "--to", "1099511627777", "--action", "mark"], "A frame must be 0 to 2^40."),
            (["--from", "0", "--to", "10", "--action", "mark", "--keep", "-1"], "--keep must be 0 to 2^40."),
            (
                ["--from", "0", "--to", "10", "--action", "mark", "--keep", "1099511627777"],
                "--keep must be 0 to 2^40."
            ),
        ] as [([String], String)])
    func badArgumentsChangeNothing(arguments: [String], reason: String) async throws {
        let before = try package.xml()
        let result = try await package.run(["silence-edit", "PKG"] + arguments)
        #expect(result.status == 64 && result.stderr.contains(reason), "\(result)")
        #expect(try package.xml() == before)
    }

    /// C25. Keep 0 and keep 2^40 are plans. An unknown track exits 1 and changes nothing.
    @Test func theKeepBoundsPassAndAnUnknownTrackExits1() async throws {
        for keep in ["0", "1099511627776"] {
            let result = try await package.run(["silence-edit", "PKG", "--keep", keep] + Self.markB)
            #expect(result.status == 0, "keep \(keep): \(result)")
        }
        let before = try package.xml()
        let result = try await package.run(
            ["silence-edit", "PKG", "--track", "zz", "--from", "96000", "--to", "240000", "--action", "mute"])
        #expect(result.status == 1 && result.stderr.contains("zz"), "\(result)")
        #expect(try package.xml() == before)
    }

    /// C25. A shorten under a take with some segments on the timeline exits 3, and a mute under it
    /// exits 0 (decision 0037). Fail value: a mute that exits 3.
    @Test func aSplitTakeRefusesAShortenAndAllowsAMute() async throws {
        let fixture = try await PlaceCommandTests()
        let before = try fixture.package.xml()
        let shorten = try await fixture.package.run(
            "silence-edit", "PKG", "--from", "96000", "--to", "144000", "--action", "shorten")
        #expect(shorten.status == 3 && shorten.stderr.contains("has a take with some segments"), "\(shorten)")
        #expect(try fixture.package.xml() == before)
        let mute = try await fixture.package.run(
            "silence-edit", "PKG", "--from", "96000", "--to", "144000", "--action", "mute")
        #expect(mute == CLIResult(status: 0, stdout: "mute\t96000\t144000\nremoved 0 frames\n", stderr: ""))
    }

    /// C26. The tool on files prints the text of the command, the skipped line too, and edits the
    /// package as the command does. The marker ID is new in each run, so the test masks it.
    @Test func theToolOnFilesGivesTheTextOfTheCommand() async throws {
        let other = try TemporaryPackage(Self.session())
        let cli = try await package.run(["silence-edit", "PKG"] + Self.shortenA + Self.markB + Self.keepSized)
        let answers = try await mcp([
            toolCall(
                1, "silence_edit",
                [
                    "package": other.path, "from": [96_000, 264_000, 400_000], "to": [240_000, 312_000, 424_000],
                    "action": ["shorten", "mark", "shorten"],
                ]),
            toolCall(2, "silence_edit", ["package": other.path, "from": [0], "to": [10], "action": ["cut"]]),
        ])
        let tool = toolResult(answer(answers, id: 1))
        func masked(_ text: String) -> [String] {
            text.split(separator: "\n").map {
                $0.hasPrefix("mark\t") ? $0.split(separator: "\t").dropLast().joined() : String($0)
            }
        }
        #expect(cli.status == 0 && !tool.isError, "\(cli) \(tool)")
        #expect(masked(tool.text) == masked(cli.stdout), "\(tool.text) | \(cli.stdout)")
        #expect(tool.text.contains("\nskipped\t400000\t424000\tshorten\n"), "\(tool.text)")
        #expect(try other.read().track("host")?.clips.map(\.range) == [0..<108_000, 108_000..<360_000])
        let refused = toolResult(answer(answers, id: 2))
        #expect(refused == ("action must be shorten, mute, or mark, not \"cut\".", true), "\(refused)")
    }
}
