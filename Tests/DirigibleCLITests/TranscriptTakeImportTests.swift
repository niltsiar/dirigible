import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// `dirigible transcript import --take` (decision 0061, criterion C10 of run 2026-10-22-take-sync).
/// The fixtures have no audio: the import reads only the clips and the take anchors.
struct TranscriptTakeImportTests {
    static let takeStart: UInt64 = 1_000_000_000_000

    /// One word row of `transcript words`: start, end, track, text.
    struct Row: Equatable, CustomStringConvertible {
        let start: Int
        let end: Int
        let track: String
        let text: String
        var description: String { "\(text)@\(start)..<\(end) \(track)" }
    }

    /// Track `t1` with one clip for each take, at the playhead of its record start, over a file of
    /// `length` frames, and the take anchor of each take from the real writer. 48 kHz.
    static func takes(_ takes: [(take: Int, host: UInt64, playhead: Frames, length: Int)]) throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        for (take, host, playhead, length) in takes {
            let id = "take\(take)-1-1"
            try session.addCapture(
                Capture(
                    id: CaptureID(id), deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: host, sampleTime: 0,
                    nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0, resampledFromRate: nil,
                    driftCorrected: true))
            try session.addFile(
                AudioFile(
                    id: FileID(id), path: "\(id).wav", layout: .mono, length: Frames(length), capture: CaptureID(id)))
            try session.place(
                Clip(id: ClipID(id), file: FileID(id), start: playhead, offset: 0, length: Frames(length)), on: "t1")
        }
        let package = try TemporaryPackage(session)
        try FileManager.default.createDirectory(
            at: package.url.appending(path: "Capture"), withIntermediateDirectories: true)
        for (take, host, playhead, _) in takes {
            try TakeAnchor.write(
                Recording(take: take, playheadFrame: playhead, takeStartHostTimeNanos: host, armedTracks: ["t1"]),
                in: package.url)
        }
        return package
    }

    /// Take 1 at playhead 0 over 10 s, the case of most tests.
    static func oneTake() throws -> TemporaryPackage { try takes([(1, takeStart, 0, 480_000)]) }

    /// Three words at 1 s, 3 s, and 6 s of the take, 1 s long each.
    static let words =
        #"{"words":[{"word":"one","start":1,"end":2},{"word":"two","start":3,"end":4},"#
        + #"{"word":"three","start":6,"end":7}]}"#

    static func write(_ text: String, in package: TemporaryPackage, name: String = "t.json") throws -> String {
        let file = package.folder.appending(path: name)
        try Data(text.utf8).write(to: file)
        return file.path
    }

    static func rows(_ package: TemporaryPackage) async throws -> [Row] {
        let result = try await package.run("transcript", "words", "PKG")
        try #require(result.status == 0, "transcript words: \(result)")
        return result.stdout.split(separator: "\n").compactMap { line in
            let cells = line.split(separator: "\t").map(String.init)
            guard cells.count == 5, let start = Int(cells[1]), let end = Int(cells[2]) else { return nil }
            return Row(start: start, end: end, track: cells[3], text: cells[4])
        }
    }

    func edit(_ package: TemporaryPackage, _ arguments: String...) async throws {
        let result = try await package.run(["clip"] + arguments)
        try #require(result.status == 0, "clip \(arguments): \(result)")
    }

    /// C10. A transcript in take time lands where the edit moved the audio: the words equal an
    /// import without `--take` on an unedited session; a ripple insert of 5 s at 0 moves each word
    /// 5 s; a ripple delete of 2 s through the second word skips it and counts it, and the third word
    /// follows its audio, 2 s earlier.
    @Test func aTranscriptOfTheTakeLandsOnTheEditedTimeline() async throws {
        let plain = try Self.oneTake()
        _ = try await plain.run("transcript", "import", "PKG", try Self.write(Self.words, in: plain), "--track", "t1")
        let unedited = try Self.oneTake()
        let first = try await unedited.run(
            "transcript", "import", "PKG", try Self.write(Self.words, in: unedited), "--track", "t1", "--take", "1")
        #expect(first == CLIResult(status: 0, stdout: "1\ntake 1: 3 words placed, 0 skipped\n", stderr: ""), "\(first)")
        let (withTake, without) = (try await Self.rows(unedited), try await Self.rows(plain))
        #expect(withTake == without && withTake.count == 3, "the words of an unedited session")

        let package = try Self.oneTake()
        try await edit(package, "ripple-insert", "PKG", "--at", "0", "--length", "240000")
        let shifted = try await package.run(
            "transcript", "import", "PKG", try Self.write(Self.words, in: package), "--track", "t1", "--take", "1")
        #expect(shifted.status == 0 && shifted.stdout == "1\ntake 1: 3 words placed, 0 skipped\n", "\(shifted)")
        #expect(
            try await Self.rows(package) == [
                Row(start: 288_000, end: 336_000, track: "t1", text: "one"),
                Row(start: 384_000, end: 432_000, track: "t1", text: "two"),
                Row(start: 528_000, end: 576_000, track: "t1", text: "three"),
            ], "a constant shift of 5 s")

        // Timeline 8 s to 10 s is take 3 s to 5 s: the word "two" is in it.
        try await edit(package, "ripple-delete", "PKG", "--from", "384000", "--to", "480000")
        let broken = try await package.run(
            "transcript", "import", "PKG", try Self.write(Self.words, in: package), "--track", "t1", "--take", "1")
        #expect(
            broken
                == CLIResult(
                    status: 0, stdout: "2\ntake 1: 2 words placed, 1 skipped (audio removed by an edit)\n", stderr: ""),
            "\(broken)")
        #expect(
            try await Self.rows(package) == [
                Row(start: 288_000, end: 336_000, track: "t1", text: "one"),
                Row(start: 432_000, end: 480_000, track: "t1", text: "three"),
            ], "the cut word is skipped and the third word follows its audio")
    }

    /// A pre-roll take file starts before the take playhead: file frame 0 is take frame -144,000
    /// (3 s), and the clip starts at the playhead 480,000 with offset 144,000. A transcript of the
    /// file imports with `--at=-144000`, so each word lands on its audio; the word before the
    /// playhead has no clip under it.
    @Test func preRollTakeFileImportsWithANegativeAt() async throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addCapture(
            Capture(
                id: "take1-1-1", deviceUID: "usb-1", deviceName: "USB Mic",
                hostTimeNanos: Self.takeStart - 3_000_000_000,
                sampleTime: 0, nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0,
                resampledFromRate: nil,
                driftCorrected: true))
        try session.addFile(
            AudioFile(id: "take1-1-1", path: "take1-1-1.wav", layout: .mono, length: 480_000, capture: "take1-1-1"))
        try session.place(
            Clip(id: "take1-1-1", file: "take1-1-1", start: 480_000, offset: 144_000, length: 336_000), on: "t1")
        let package = try TemporaryPackage(session)
        try FileManager.default.createDirectory(
            at: package.url.appending(path: "Capture"), withIntermediateDirectories: true)
        try TakeAnchor.write(
            Recording(take: 1, playheadFrame: 480_000, takeStartHostTimeNanos: Self.takeStart, armedTracks: ["t1"]),
            in: package.url)

        let result = try await package.run(
            "transcript", "import", "PKG", try Self.write(Self.words, in: package), "--track", "t1", "--take", "1",
            "--at=-144000")

        #expect(result.status == 0 && result.stdout.hasPrefix("1\ntake 1: 2 words placed, 1 skipped"), "\(result)")
        // File 3 s is the playhead; file 6 s is 3 s after it.
        #expect(
            try await Self.rows(package) == [
                Row(start: 480_000, end: 528_000, track: "t1", text: "two"),
                Row(start: 624_000, end: 672_000, track: "t1", text: "three"),
            ])
    }

    /// C10. A pasted cold open does not shorten a word. The cold open is a copy of take frames
    /// 156 000 to 180 000, the middle of the word "two" (144 000 to 192 000), at timeline 0. The
    /// stored word is the whole word of the file, so the main clip shows all of it and the copy
    /// shows its part. The copy comes first in timeline order, and it must not set the word range.
    @Test func aColdOpenCopyDoesNotShortenTheWordUnderTheMainClip() async throws {
        let package = try Self.oneTake()
        try await edit(package, "ripple-insert", "PKG", "--at", "0", "--length", "240000")
        let paste = try await package.run(
            "clip", "paste", "PKG", "--from", "396000", "--to", "420000", "--track", "t1", "--at", "0")
        try #require(paste.status == 0, "clip paste: \(paste)")

        let result = try await package.run(
            "transcript", "import", "PKG", try Self.write(Self.words, in: package), "--track", "t1", "--take", "1")

        #expect(result.status == 0 && result.stdout == "1\ntake 1: 3 words placed, 0 skipped\n", "\(result)")
        let rows = try await Self.rows(package)
        #expect(
            rows == [
                Row(start: 0, end: 24_000, track: "t1", text: "two"),
                Row(start: 288_000, end: 336_000, track: "t1", text: "one"),
                Row(start: 384_000, end: 432_000, track: "t1", text: "two"),
                Row(start: 528_000, end: 576_000, track: "t1", text: "three"),
            ], "the main clip shows the whole word, the copy shows the part that it holds: \(rows)")
    }

    /// C10. `--at` is the take frame of second 0 of the transcript. After a ripple delete of the
    /// first 2 s, a transcript of the export of the edited timeline has its second 0 at take frame
    /// 96 000, and `--at 96000` gives the rows of an import without `--take`.
    @Test func atGivesTheTakeFrameOfSecondZero() async throws {
        let words = #"{"words":[{"word":"one","start":1,"end":2},{"word":"two","start":3,"end":4}]}"#
        let plain = try Self.oneTake()
        try await edit(plain, "ripple-delete", "PKG", "--from", "0", "--to", "96000")
        _ = try await plain.run("transcript", "import", "PKG", try Self.write(words, in: plain), "--track", "t1")

        let take = try Self.oneTake()
        try await edit(take, "ripple-delete", "PKG", "--from", "0", "--to", "96000")
        let result = try await take.run(
            "transcript", "import", "PKG", try Self.write(words, in: take), "--track", "t1", "--take", "1", "--at",
            "96000")

        #expect(result.status == 0 && result.stdout == "1\ntake 1: 2 words placed, 0 skipped\n", "\(result)")
        let (rows, expected) = (try await Self.rows(take), try await Self.rows(plain))
        #expect(rows == expected && rows.map(\.start) == [48_000, 144_000], "\(rows)")
    }

    /// C10. With two takes, `--take 2` puts the words on the audio of take 2 only. The same
    /// transcript with `--take 1` finds only the first 5 s of take 1: the other word is skipped, and
    /// the count shows that the take was wrong.
    @Test func theTakeNumberPicksTheAudio() async throws {
        let words = #"{"words":[{"word":"early","start":1,"end":2},{"word":"late","start":7,"end":8}]}"#
        let two: [(take: Int, host: UInt64, playhead: Frames, length: Int)] = [
            (1, Self.takeStart, 0, 240_000), (2, Self.takeStart + 60_000_000_000, 480_000, 480_000),
        ]
        let second = try Self.takes(two)
        let result = try await second.run(
            "transcript", "import", "PKG", try Self.write(words, in: second), "--track", "t1", "--take", "2")
        #expect(result.status == 0 && result.stdout == "1\ntake 2: 2 words placed, 0 skipped\n", "\(result)")
        #expect(
            try await Self.rows(second) == [
                Row(start: 528_000, end: 576_000, track: "t1", text: "early"),
                Row(start: 816_000, end: 864_000, track: "t1", text: "late"),
            ])

        let first = try Self.takes(two)
        let wrong = try await first.run(
            "transcript", "import", "PKG", try Self.write(words, in: first), "--track", "t1", "--take", "1")
        #expect(
            wrong
                == CLIResult(
                    status: 0, stdout: "1\ntake 1: 1 word placed, 1 skipped (audio removed by an edit)\n", stderr: ""),
            "\(wrong)")
        #expect(try await Self.rows(first) == [Row(start: 48_000, end: 96_000, track: "t1", text: "early")])
    }

    /// C10. A track with no audio of the take, a take that does not exist, and an anchor that does
    /// not read give an error and change nothing.
    @Test func aTakeWithNoAudioOnTheTrackExitsOne() async throws {
        let package = try Self.oneTake()
        let file = try Self.write(Self.words, in: package)
        let before = try package.xml()

        for (arguments, message) in [
            (["--track", "t2", "--take", "1"], "The track t2 has no audio of take 1 with a take time."),
            (["--track", "t1", "--take", "3"], "The track t1 has no audio of take 3 with a take time."),
        ] {
            let result = try await package.run(["transcript", "import", "PKG", file] + arguments)
            #expect(result == CLIResult(status: 1, stdout: "", stderr: "Error: \(message)\n"), "\(result)")
        }
        let anchor = package.url.appending(path: "Capture/take1.anchor")
        chmod(anchor.path, 0o000)
        defer { chmod(anchor.path, 0o644) }
        let fault = try await package.run("transcript", "import", "PKG", file, "--track", "t1", "--take", "1")
        #expect(fault.status == 2 && fault.stderr.contains("Capture/take1.anchor (errno 13)"), "\(fault)")
        #expect(try package.xml() == before)
    }
}
