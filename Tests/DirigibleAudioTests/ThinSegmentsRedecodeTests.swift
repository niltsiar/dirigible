import Foundation
import Testing

@testable import DirigibleAudio

/// Decision 0065 D7b: the second calls of one piece through `ThinSegments.redecode`, with a scripted
/// `decode` in place of `whisper_full`. The piece is the drop of episode 360 (`ThinSegmentsTests`)
/// and a fourth segment of 7.0 s with 2 words, so it has two thin spans.
struct ThinSegmentsRedecodeTests {
    static let hola = ThinSegmentsTests.words("Hola 12300 12310  sí 12800 12810")
    static let firstPass = ThinSegmentsTests.firstPass + hola
    static let first = zip(
        firstPass,
        Array(repeating: 0, count: 9) + Array(repeating: 1, count: 10)
            + Array(repeating: 2, count: 17) + [3, 3]
    ).map { (word: $0, segment: $1) }
    static let bounds: [(start: Int, end: Int)] = [(10141, 10345), (10391, 11645), (11720, 12112), (12200, 12900)]
    static let sampleCount = 13_000 * 160
    static let spanRanges = [1_655_200..<1_875_200, 1_937_920..<2_080_000]
    /// The first pass with the 29 words of the fresh call on the drop span.
    static let repaired = Array(firstPass[0..<9]) + ThinSegmentsTests.redecoded + Array(firstPass[19...])

    /// The words of the fresh call on the drop span, in call time.
    static let dropCall = ThinSegments.shifted(ThinSegmentsTests.redecoded, byTicks: -10345)

    /// Runs the second calls with `log`; `answer` gives the outcome of call n. The calls go to `calls`.
    static func redecode(
        language: String = "es", log: DiagnosticLog = .disabled, calls: inout [(range: Range<Int>, language: String)],
        answer: (Int) -> RedecodeOutcome
    ) -> PieceOutcome {
        ThinSegments.redecode(first: first, bounds: bounds, sampleCount: sampleCount, language: language, log: log) {
            calls.append(($0, $1))
            return answer(calls.count - 1)
        }
    }

    /// The fields of each `event` line of the journal in `folder`.
    static func notes(_ event: String = "transcript redecode", in folder: URL) throws -> [[String: String]] {
        try journalLines(of: try #require(journalFiles(in: folder).first))
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count > 5 && $0[5] == event }
            .map(fieldValues)
    }

    /// The five thin spans of `ThinSegmentsTests.fiveThinSpans`: the cap drops the span of 0 s to 12 s,
    /// and the journal names it. The two-span piece writes no cap note.
    @Test func theJournalNamesEachSpanThatTheCapDrops() throws {
        let segments = ThinSegmentsTests.segments(ThinSegmentsTests.fiveThinSpans)
        let first = segments.enumerated().flatMap { n, segment in
            segment.words.map {
                (word: TimedWord(text: "w\($0)", start: segment.start + $0, end: segment.start + $0 + 1), segment: n)
            }
        }
        let folder = try TemporaryFolder()
        let log = startLog(in: folder.url)
        var calls = 0
        _ = ThinSegments.redecode(
            first: first, bounds: segments.map { (start: $0.start, end: $0.end) }, sampleCount: 10_000 * 160,
            language: "es",
            log: log
        ) { _, _ in
            calls += 1
            return .words([])
        }
        var twoSpans: [(range: Range<Int>, language: String)] = []
        _ = Self.redecode(log: log, calls: &twoSpans) { _ in .words([]) }
        log.drain()
        #expect(calls == 4)
        #expect(try Self.notes("transcript redecode cap", in: folder.url) == [["dropped": "1", "spans": "0-1200"]])
        #expect(try Self.notes(in: folder.url).count == 6)
    }

    /// The job language does not reach the calls: a job with `.automatic` and a job with
    /// `.code("es")` both give each second call the code of the first pass.
    @Test func eachCallGetsTheSampleRangeOfItsSpanInTheFirstPassLanguage() {
        for code in ["es", "en"] {
            var calls: [(range: Range<Int>, language: String)] = []
            _ = Self.redecode(language: code, calls: &calls) { _ in .words([]) }
            #expect(calls.map { $0.range } == Self.spanRanges, "\(code)")
            #expect(calls.map { $0.language } == [code, code])
        }
    }

    @Test func secondPassWordsComeBackInPieceTime() {
        var calls: [(range: Range<Int>, language: String)] = []
        let outcome = Self.redecode(calls: &calls) { $0 == 0 ? .words(Self.dropCall) : .words([]) }
        #expect(outcome == .words(Self.repaired, language: "es"))
    }

    @Test func aStoppedCallEndsThePieceAndMakesNoLaterCall() throws {
        let folder = try TemporaryFolder()
        let log = startLog(in: folder.url)
        var calls: [(range: Range<Int>, language: String)] = []
        let outcome = Self.redecode(log: log, calls: &calls) { _ in .stopped }
        log.drain()
        #expect(outcome == .stopped)
        #expect(calls.count == 1)
        #expect(try Self.notes(in: folder.url).isEmpty)
    }

    /// A stopped call writes no note; the note of the call before it stays.
    @Test func aStoppedCallAfterAnAcceptedCallWritesOnlyTheFirstNote() throws {
        let folder = try TemporaryFolder()
        let log = startLog(in: folder.url)
        var calls: [(range: Range<Int>, language: String)] = []
        let outcome = Self.redecode(log: log, calls: &calls) { $0 == 0 ? .words(Self.dropCall) : .stopped }
        log.drain()
        #expect(outcome == .stopped)
        #expect(calls.count == 2)
        #expect(
            try Self.notes(in: folder.url) == [
                ["start": "10345", "end": "11720", "before": "10", "after": "29", "kept": "second pass"]
            ])
    }

    /// C5: a failed call keeps the first pass, the next call still runs, and each call that ends
    /// writes one `transcript redecode` line.
    @Test func eachSecondCallWritesOneJournalLine() throws {
        let folder = try TemporaryFolder()
        let log = startLog(in: folder.url)
        let again = (0..<8).map { TimedWord(text: "w\($0)", start: 200 + 50 * $0, end: 240 + 50 * $0) }
        var calls: [(range: Range<Int>, language: String)] = []
        let outcome = Self.redecode(log: log, calls: &calls) { $0 == 0 ? .failed(code: -7) : .words(again) }
        log.drain()
        #expect(calls.count == 2)
        #expect(
            outcome
                == .words(Array(Self.firstPass[0..<36]) + ThinSegments.shifted(again, byTicks: 12112), language: "es"))
        #expect(
            try Self.notes(in: folder.url) == [
                ["start": "10345", "end": "11720", "before": "10", "kept": "first pass", "fault": "-7"],
                ["start": "12112", "end": "13000", "before": "2", "after": "8", "kept": "second pass"],
            ])
    }

    @Test func aWhisperReturnCodeMapsToTheRedecodeOutcome() {
        var joined = 0
        func words() -> [TimedWord] {
            joined += 1
            return ThinSegmentsTests.redecoded
        }
        #expect(RedecodeOutcome(code: 0, stopFlagSet: false, words: words) == .words(ThinSegmentsTests.redecoded))
        #expect(RedecodeOutcome(code: -7, stopFlagSet: false, words: words) == .failed(code: -7))
        #expect(RedecodeOutcome(code: -6, stopFlagSet: true, words: words) == .stopped)
        #expect(RedecodeOutcome(code: 0, stopFlagSet: true, words: words) == .stopped)
        #expect(joined == 1)
    }
}
