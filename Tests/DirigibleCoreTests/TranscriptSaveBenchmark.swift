import Foundation
import Testing

@testable import DirigibleCore

/// T13b (decision 0055): a 3 h session with a transcript of 27 000 words, optimized
/// (`make bench FILTER=TranscriptSaveBenchmark`): (a) one edit (a gain change) through
/// `History.edit` compares two sessions in 5 ms or less; (b) its autosave writes no transcript
/// file, and `checkedData` plus the write take 300 ms or less; (c) the first save after a change of
/// the words (encode, check, write) takes 300 ms or less; (d) an open (read, decode) takes 300 ms
/// or less.
struct TranscriptSaveBenchmark {
    #if DEBUG
        static let budgets = (compare: Duration.milliseconds(100), file: Duration.seconds(3))
    #else
        static let budgets = (compare: Duration.milliseconds(5), file: Duration.milliseconds(300))
    #endif

    /// 3 h at 48 kHz on one track, a word each 0.4 s.
    static func session() throws -> Session {
        let length = Frames(3 * 3_600 * 48_000)
        var session = Session(sampleRate: 48_000)
        try session.addTrack("host", name: "Host", layout: .mono)
        try session.addFile(AudioFile(id: "h", path: "h.wav", layout: .mono, length: length))
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: length), on: "host")
        let words = (0..<27_000).map { n in
            #"{"word":"word\#(n % 97)","start":\#(Double(n) * 0.4),"end":\#(Double(n) * 0.4 + 0.3)}"#
        }
        let file = try TranscriptFile(data: Data(#"{"words":[\#(words.joined(separator: ","))]}"#.utf8))
        try session.importTranscript(file, name: "episode.json", track: "host", at: 0)
        return session
    }

    /// The p90 of 10 runs.
    static func p90(_ times: [Duration]) -> Duration { times.sorted()[8] }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theTranscriptFilePathsOfThreeHours() throws {
        var session = try Self.session()
        #expect(session.words().count == 27_000)
        let package = FileManager.default.temporaryDirectory.appending(path: "TranscriptSave-\(UUID())/E.dirigible")
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        let transcripts = package.appending(path: "Transcripts")
        try session.write(to: package)
        var compares: [Duration] = []
        var autosaves: [Duration] = []
        var changes: [Duration] = []
        var opens: [Duration] = []
        for n in 0..<10 {
            var history = History(session)
            let start = ContinuousClock.now
            try history.edit { (session: inout Session) throws(SessionError) in
                try session.setGain(Gain(dB: Double(n % 3) - 1)!, track: "host")
            }
            compares.append(ContinuousClock.now - start)
            let files = try FileManager.default.contentsOfDirectory(atPath: transcripts.path)
            let autosave = ContinuousClock.now
            try history.session.write(to: package)
            autosaves.append(ContinuousClock.now - autosave)
            #expect(try FileManager.default.contentsOfDirectory(atPath: transcripts.path) == files)

            session = history.session
            let id = TranscriptID(1)
            let words = try #require(session.transcripts[id]?.words?["h"]?.all)
            session.setWords(Array(words.dropLast()), file: "h", transcript: id)
            let change = ContinuousClock.now
            try session.write(to: package)
            changes.append(ContinuousClock.now - change)

            let open = ContinuousClock.now
            let opened = try Session(contentsOf: package)
            opens.append(ContinuousClock.now - open)
            #expect(opened.transcriptsNotLoaded.isEmpty)
        }
        let (compare, autosave, change, open) = (
            Self.p90(compares), Self.p90(autosaves), Self.p90(changes), Self.p90(opens)
        )
        print(
            "bench report: TranscriptSaveBenchmark edit p90 \(compare), autosave p90 \(autosave), "
                + "words change save p90 \(change), open p90 \(open)")
        expectWithinBudget(compare, Self.budgets.compare, "the edit of 27 000 words takes \(compare)")
        expectWithinBudget(autosave, Self.budgets.file, "the autosave takes \(autosave)")
        expectWithinBudget(change, Self.budgets.file, "the first save after a change of the words takes \(change)")
        expectWithinBudget(open, Self.budgets.file, "the open takes \(open)")
    }
}
