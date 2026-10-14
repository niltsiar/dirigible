import DirigibleCore
import Foundation
import Testing

/// `dirigible transcript import`, `words`, and `cut` (run transcript-1, criteria T3, T10 to T12,
/// T20, and T21).
struct TranscriptCommandTests {
    let package: TemporaryPackage

    /// The E38 transcript of the eval: 95 words in 11 segments, from 6.0 s to 81.22 s.
    static let fixture = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../scripts/eval/agent-transcript.json").standardized

    init() throws { package = try TemporaryPackage(Self.session()) }

    /// Tracks "host" and "guest" with a clip each over 100 s of their own file.
    static func session() throws -> Session {
        var session = Session(sampleRate: 48_000)
        for (track, file) in [("host", "h"), ("guest", "g")] {
            try session.addTrack(TrackID(track), name: track, layout: .mono)
            try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: 4_800_000))
            try session.place(
                Clip(id: ClipID(file.uppercased()), file: FileID(file), start: 0, offset: 0, length: 4_800_000),
                on: TrackID(track))
        }
        return session
    }

    /// The first column of each row of `words`.
    static func occurrences(_ result: CLIResult) -> [String] {
        result.stdout.split(separator: "\n").map { String($0.split(separator: "\t")[0]) }
    }

    /// T10 end to end: import on the host track, find two sentences with --match, cut them in one
    /// call. Both tracks lose the same frames.
    @Test func importThenCutTwoSentences() async throws {
        #expect(
            try await package.run("transcript", "import", "PKG", Self.fixture.path, "--track", "host")
                == CLIResult(status: 0, stdout: "1\nImported 95 words.\n", stderr: ""))
        let first = try await package.run("transcript", "words", "PKG", "--match", "Sorry, let me say that again.")
        let second = try await package.run(
            "transcript", "words", "PKG", "--match", "Oops, I lost my notes for a second.")
        #expect(first.stdout.hasPrefix("1.33.1497600@H\t1497600\t1514400\thost\tSorry,\n"), "\(first.stdout)")
        let named = Self.occurrences(first) + Self.occurrences(second)
        #expect(named.count == 14)

        let cut = try await package.run(["transcript", "cut", "PKG"] + named)

        #expect(cut == CLIResult(status: 0, stdout: "1497600 1605600\n2803200 2942880\n", stderr: ""))
        let session = try package.read()
        for track in ["host", "guest"] as [TrackID] {
            #expect(session.track(track)?.clips.last?.end == 4_552_320, "track \(track) loses 247 680 frames")
        }
        #expect(try await package.run("transcript", "words", "PKG", "--match", "let me say").stdout == "No words.\n")
    }

    /// T21: `-` reads stdin, with the name `transcript` or `--name`.
    @Test func importReadsStdin() async throws {
        let result = try await dirigible(
            ["transcript", "import", package.path, "-", "--track", "host", "--name", "episode.json"],
            input: Self.fixture)
        #expect(result == CLIResult(status: 0, stdout: "1\nImported 95 words.\n", stderr: ""))
        #expect(try package.read().words().count == 95)
        let xml = String(decoding: try package.xml(), as: UTF8.self)
        #expect(xml.contains(#"<transcript id="1" name="episode.json" file=""#))
    }

    /// T5: the skipped words go to stderr; the ID and the count go to stdout.
    @Test func importReportsTheSkippedWords() async throws {
        try package.edit { session in try session.clear(1_440_000..<4_800_000, on: ["host"]) }
        let words = #"{"words":[{"word":"a","start":1,"end":2},{"word":"b","start":40,"end":41},{"word":"c"}]}"#
        let file = package.folder.appending(path: "t.json")
        try Data(words.utf8).write(to: file)
        #expect(
            try await package.run("transcript", "import", "PKG", file.path, "--track", "host")
                == CLIResult(
                    status: 0, stdout: "1\nImported 1 word.\n",
                    stderr: "Skipped 1 word with no clip under it.\nSkipped 1 word with no time.\n"))
    }

    /// Code gate 2 item 2: a word with no length stays matchable text, and a cut of only that word
    /// exits 1 with the nothing-to-cut text and changes nothing.
    @Test func cutOfAWordWithNoLengthExits1() async throws {
        let file = package.folder.appending(path: "t.json")
        try Data(#"{"words":[{"word":"a","start":1,"end":1.5},{"word":"zero","start":2,"end":2}]}"#.utf8).write(
            to: file)
        _ = try await package.run("transcript", "import", "PKG", file.path, "--track", "host")
        let word = Self.occurrences(try await package.run("transcript", "words", "PKG", "--match", "zero"))
        let before = try package.xml()

        #expect(
            try await package.run(["transcript", "cut", "PKG"] + word)
                == CLIResult(status: 1, stdout: "", stderr: "Error: the words have no audio to cut.\n"))
        #expect(try package.xml() == before)
    }

    /// Code gate 2 item 1: room tone from one host file under two gaps, with other guest speech over
    /// each. The second region repeats audio that the first gave, so its word is dropped and counted.
    @Test func importCountsTheRepeatedWords() async throws {
        try package.edit { session in
            try session.clear(0..<4_800_000, on: ["host"])
            try session.place(Clip(id: "R1", file: "h", start: 0, offset: 0, length: 480_000), on: "host")
            try session.place(Clip(id: "R2", file: "h", start: 2_400_000, offset: 0, length: 480_000), on: "host")
        }
        let file = package.folder.appending(path: "t.json")
        try Data(#"{"words":[{"word":"um","start":1,"end":1.5},{"word":"yes","start":51,"end":51.5}]}"#.utf8)
            .write(to: file)
        #expect(
            try await package.run("transcript", "import", "PKG", file.path, "--track", "host")
                == CLIResult(
                    status: 0, stdout: "1\nImported 1 word.\n",
                    stderr: "Skipped 1 word over audio that an earlier clip already gave.\n"))
    }

    /// Code gate 1 item 9 and gate 2 item 5: a WebVTT import reports cues in each line, because a
    /// cut removes a whole cue.
    @Test func importReportsCues() async throws {
        let file = package.folder.appending(path: "t.vtt")
        let vtt =
            "WEBVTT\n\n00:01.000 --> 00:02.000\nHello there.\n\n00:02.000 --> 00:03.000\nBye.\n\n"
            + "00:0x.000 --> 00:04.000\nBad time.\n"
        try Data(vtt.utf8).write(to: file)
        #expect(
            try await package.run("transcript", "import", "PKG", file.path, "--track", "host")
                == CLIResult(
                    status: 0, stdout: "1\nImported 2 cues: a cut removes a whole cue when it has no word times.\n",
                    stderr: "Skipped 1 cue with no time.\n"))
    }

    /// T3: a file that is not a transcript, and one with no timed word, exit 1 with the file and the
    /// reason, and change nothing.
    @Test func badFileChangesNothing() async throws {
        let before = try package.xml()
        let text = package.folder.appending(path: "notes.txt")
        try Data("not a transcript".utf8).write(to: text)
        let untimed = package.folder.appending(path: "untimed.json")
        try Data(#"{"words":[{"word":"a"}]}"#.utf8).write(to: untimed)
        #expect(
            try await package.run("transcript", "import", "PKG", text.path, "--track", "host")
                == CLIResult(
                    status: 1, stdout: "",
                    stderr: "Error: \(text.path): the file is neither WebVTT nor Whisper JSON.\n"))
        #expect(
            try await package.run("transcript", "import", "PKG", untimed.path, "--track", "host")
                == CLIResult(status: 1, stdout: "", stderr: "Error: \(untimed.path): no word has a usable time.\n"))
        #expect(try await package.run("transcript", "import", "PKG", Self.fixture.path, "--track", "zz").status == 1)
        #expect(try package.xml() == before)
    }

    /// T11: a token that does not parse, and no token, are usage errors (exit 64), with no change.
    @Test func cutRefusesAMalformedToken() async throws {
        _ = try await package.run("transcript", "import", "PKG", Self.fixture.path, "--track", "host")
        let before = try package.xml()
        let bad = try await package.run("transcript", "cut", "PKG", "1.33@H")
        #expect(bad.status == 64 && bad.stderr.contains("1.33@H is not a word"), "\(bad)")
        #expect(try await package.run("transcript", "cut", "PKG").status == 64)
        #expect(try package.xml() == before)
    }

    /// T11: a word that the last cut removed exits 1 with the stale-token text, and changes nothing.
    @Test func cutRefusesAStaleWord() async throws {
        _ = try await package.run("transcript", "import", "PKG", Self.fixture.path, "--track", "host")
        let word = Self.occurrences(try await package.run("transcript", "words", "PKG", "--match", "Welcome"))
        #expect(try await package.run(["transcript", "cut", "PKG"] + word).status == 0)
        let before = try package.xml()

        #expect(
            try await package.run(["transcript", "cut", "PKG"] + word)
                == CLIResult(status: 1, stdout: "", stderr: "Error: \(Self.stale(word[0]))\n"))
        #expect(try package.xml() == before)
    }

    /// The error text of a token that an edit made stale.
    static func stale(_ token: String) -> String {
        "no word \(token) on the timeline: it is not there now, or an edit changed it. Read the words again, then cut."
    }

    /// Code gate 1 item 5: a cut splits the clip, so the tokens of the second phrase from the same
    /// read are stale; the error says to read the words again, and a second read cuts.
    @Test func twoCutsFromOneReadNeedASecondRead() async throws {
        _ = try await package.run("transcript", "import", "PKG", Self.fixture.path, "--track", "host")
        let phrase = "Oops, I lost my notes for a second."
        let first = Self.occurrences(try await package.run("transcript", "words", "PKG", "--match", "Welcome"))
        let second = Self.occurrences(try await package.run("transcript", "words", "PKG", "--match", phrase))
        #expect(try await package.run(["transcript", "cut", "PKG"] + first).status == 0)

        let stale = try await package.run(["transcript", "cut", "PKG"] + second)
        #expect(stale == CLIResult(status: 1, stdout: "", stderr: "Error: \(Self.stale(second[0]))\n"))
        let again = Self.occurrences(try await package.run("transcript", "words", "PKG", "--match", phrase))
        #expect(try await package.run(["transcript", "cut", "PKG"] + again).status == 0)
    }

    /// T12: --match keeps whole words of one track, with case and punctuation ignored.
    @Test func wordsMatchAPhrase() async throws {
        _ = try await package.run("transcript", "import", "PKG", Self.fixture.path, "--track", "host")
        let result = try await package.run("transcript", "words", "PKG", "--match", "welcome to THE show")
        #expect(
            result.stdout == "1.1.288000@H\t288000\t308160\thost\tWelcome\n1.2.312000@H\t312000\t324000\thost\tto\n"
                + "1.3.327840@H\t327840\t341760\thost\tthe\n1.4.345600@H\t345600\t360960\thost\tshow.\n")
        let json = try await package.run("transcript", "words", "PKG", "--match", "welcome", "--json")
        let object = try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any]
        let rows = object?["words"] as? [[String: Any]]
        #expect(object?["more"] as? Int == 0 && rows?.count == 1)
        #expect(rows?.first?["occurrence"] as? String == "1.1.288000@H" && rows?.first?["text"] as? String == "Welcome")
        #expect(rows?.first?["start"] as? Int == 288_000 && rows?.first?["track"] as? String == "host")
    }

    /// T12: --from and --to keep the words that touch the range; one without the other is a usage
    /// error; an unknown --track exits 1.
    @Test func wordsInARange() async throws {
        _ = try await package.run("transcript", "import", "PKG", Self.fixture.path, "--track", "host")
        let result = try await package.run("transcript", "words", "PKG", "--from", "310000", "--to", "330000")
        #expect(Self.occurrences(result) == ["1.2.312000@H", "1.3.327840@H"])
        #expect(try await package.run("transcript", "words", "PKG", "--from", "310000").status == 64)
        #expect(try await package.run("transcript", "words", "PKG", "--track", "guest").stdout == "No words.\n")
        #expect(try await package.run("transcript", "words", "PKG", "--track", "zz").status == 1)
    }

    /// T12: on 9 000 words, no filter prints 200 rows and the count line; a 4-word phrase that occurs
    /// once prints 4 rows, under 1 KB.
    @Test func wordsStopAtTheLimit() async throws {
        try package.edit { session in
            try session.addFile(AudioFile(id: "long", path: "long.wav", layout: .mono, length: 180_000_000))
            try session.clear(0..<4_800_000, on: ["host"])
            try session.place(Clip(id: "L", file: "long", start: 0, offset: 0, length: 180_000_000), on: "host")
        }
        let phrase = ["alpha", "beta", "gamma", "delta"]
        let words = (0..<9_000).map { n in
            let text = (5_000..<5_004).contains(n) ? phrase[n - 5_000] : "w\(n % 50)"
            return #"{"word":"\#(text)","start":\#(Double(n) * 0.4),"end":\#(Double(n) * 0.4 + 0.3)}"#
        }
        let file = package.folder.appending(path: "long.json")
        try Data(#"{"words":[\#(words.joined(separator: ","))]}"#.utf8).write(to: file)
        _ = try await package.run("transcript", "import", "PKG", file.path, "--track", "host")

        let all = try await package.run("transcript", "words", "PKG")
        let lines = all.stdout.split(separator: "\n")
        #expect(lines.count == 201 && lines.last == "8800 more words: narrow with from, to, or match.")
        let match = try await package.run("transcript", "words", "PKG", "--match", "alpha beta gamma delta")
        #expect(match.stdout.split(separator: "\n").count == 4 && match.stdout.utf8.count < 1_024)
        #expect(try await package.run("transcript", "words", "PKG", "--limit", "0").status == 64)
    }

    /// T20: the help of `transcript` lists its three commands.
    @Test func helpListsTheSubcommands() async throws {
        let help = try await dirigible("transcript", "--help")
        for command in ["import", "words", "cut"] {
            #expect(help.stdout.contains("  \(command) "), "dirigible transcript --help does not list \(command)")
        }
    }

    /// T23: when the file of a transcript is missing, `words` names the transcript, and `cut`
    /// exits 1 with the text that says to import it again.
    @Test func wordsReportsATranscriptNotLoaded() async throws {
        _ = try await package.run("transcript", "import", "PKG", Self.fixture.path, "--track", "host")
        let token = Self.occurrences(try await package.run("transcript", "words", "PKG", "--limit", "1"))[0]
        let folder = package.url.appending(path: "Transcripts")
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder.appending(path: name))
        }
        let line = "Transcript 1 (agent-transcript.json): its file is missing or damaged, so its words do not show. "
        #expect(
            try await package.run("transcript", "words", "PKG")
                == CLIResult(status: 0, stdout: line + "Import the transcript again.\nNo words.\n", stderr: ""))
        let before = try package.xml()
        #expect(
            try await package.run("transcript", "cut", "PKG", token)
                == CLIResult(
                    status: 1, stdout: "",
                    stderr:
                        "Error: transcript 1 did not load: its file is missing or damaged. Import the transcript again.\n"
                ))
        #expect(try package.xml() == before)
    }
}
