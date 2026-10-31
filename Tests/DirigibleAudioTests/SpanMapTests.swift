import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The file spans of a transcription job and the map of its words to file frames (decision 0065
/// D3, D4; run whisper-in-app, criteria C6, C7, and C25). Word times are in ticks of 10 ms; one
/// tick is 480 frames at 48 kHz.
struct SpanMapTests {
    static let rate = 48_000

    func clip(_ id: String, _ file: FileID, start: Int, offset: Int, length: Int) -> Clip {
        Clip(id: ClipID(id), file: file, start: Frames(start), offset: Frames(offset), length: Frames(length))
    }

    func span(_ file: FileID, _ frames: Range<Frames>, time: Frames) -> SpanMap.Span {
        SpanMap.Span(file: file, frames: frames, time: time)
    }

    /// C6. A duplicated region gives one span, a touching clip joins it, and a gap gives nothing:
    /// the length is the sum of the merged spans, not the timeline length.
    @Test func aDuplicatedRegionAndAGapGiveTheMergedSpans() {
        let map = SpanMap(
            clips: [
                clip("A", "h", start: 0, offset: 0, length: 1_000),
                clip("B", "h", start: 5_000, offset: 0, length: 1_000),
                clip("C", "h", start: 7_000, offset: 1_000, length: 500),
            ], sampleRate: Self.rate)

        #expect(map.spans == [span("h", 0..<1_500, time: 0)])
        #expect(map.length == 1_500)
    }

    /// D3. The spans come in the timeline order of their first clip, not in file order.
    @Test func spansFollowTheirFirstClip() {
        let map = SpanMap(
            clips: [
                clip("C", "b", start: 4_000, offset: 5_000, length: 1_000),
                clip("A", "b", start: 0, offset: 0, length: 1_000),
                clip("B", "a", start: 2_000, offset: 0, length: 500),
            ], sampleRate: Self.rate)

        #expect(
            map.spans == [
                span("b", 0..<1_000, time: 0), span("a", 0..<500, time: 1_000), span("b", 5_000..<6_000, time: 1_500),
            ])
    }

    /// C7. Span b holds concatenated 0 ..< 48 000 and span a holds 48 000 ..< 96 000. A word from
    /// tick 90 to tick 120 has its midpoint at frame 50 400, in span a: it lands in a, clamped to
    /// the span start.
    @Test func aWordAcrossASpanEdgeLandsInTheSpanOfItsMidpoint() {
        let map = SpanMap(
            clips: [
                clip("B", "b", start: 0, offset: 10_000, length: 48_000),
                clip("A", "a", start: 100_000, offset: 200_000, length: 48_000),
            ], sampleRate: Self.rate)
        let result = map.fileWords([[TimedWord(text: "edge", start: 90, end: 120)]], in: [0..<96_000])

        #expect(result.untimed == 0)
        #expect(result.words.words.map(\.file) == ["a"])
        #expect(result.words.words.map(\.range) == [200_000..<209_600])
    }

    /// Plan gate 3 Y1 and round 2 Z3. A word with end < start, a word with end == start, and a
    /// last word that starts at the piece end give no file word, and each counts as untimed.
    @Test func aWordWithNoLengthIsDroppedAndCounted() {
        let map = SpanMap(clips: [clip("A", "h", start: 0, offset: 0, length: 48_000)], sampleRate: Self.rate)
        for word in [
            TimedWord(text: "back", start: 20, end: 10), TimedWord(text: "flat", start: 20, end: 20),
            TimedWord(text: "late", start: 100, end: 101),
        ] {
            let result = map.fileWords([[word]], in: [0..<48_000])
            #expect(result.words.words.isEmpty, "\(word.text) gives no file word")
            #expect(result.untimed == 1, "\(word.text) counts as untimed")
        }
    }

    /// C7, seeded property. Random spans, pieces, and words: each word whose midpoint is more than
    /// 1 frame from a span edge lands in the span of its midpoint, and its start and end are within
    /// 1 frame of `span start + round((t - span time) x rate)` with t in seconds, clamped to the span.
    @Test func everyWordLandsInTheSpanOfItsMidpoint() throws {
        var generator = SeededGenerator(seed: 41)
        for _ in 0..<50 {
            var clips: [Clip] = []
            var start = 0
            for index in 0..<Int.random(in: 1...6, using: &generator) {
                let length = Int.random(in: 10_000...500_000, using: &generator)
                let file = FileID(["a", "b", "c"][Int.random(in: 0...2, using: &generator)])
                clips.append(clip("C\(index)", file, start: start, offset: index * 600_000, length: length))
                start += length + Int.random(in: 0...50_000, using: &generator)
            }
            let map = SpanMap(clips: clips, sampleRate: Self.rate)
            let total = map.length.count
            let cut = Int.random(in: 1..<total, using: &generator)
            let ranges: [Range<Frames>] = [0..<Frames(cut), Frames(cut)..<map.length]
            var pieces: [[TimedWord]] = [[], []]
            var expected: [String: (file: FileID, start: Double, end: Double)] = [:]
            for index in 0..<40 {
                let piece = Int.random(in: 0...1, using: &generator)
                let ticks = (ranges[piece].upperBound.count - ranges[piece].lowerBound.count) / 480
                guard ticks >= 2 else { continue }
                let first = Int.random(in: 0..<(ticks - 1), using: &generator)
                let last = Int.random(in: (first + 1)...min(ticks, first + 300), using: &generator)
                let seconds = (Double(ranges[piece].lowerBound.count) / Double(Self.rate))
                let startTime = seconds + Double(first) / 100
                let endTime = seconds + Double(last) / 100
                let midpoint = (startTime + endTime) / 2 * Double(Self.rate)
                guard
                    let span = map.spans.first(where: {
                        let end = Double($0.time.count + $0.frames.upperBound.count - $0.frames.lowerBound.count)
                        return midpoint >= Double($0.time.count) + 1 && midpoint < end - 1
                    })
                else { continue }
                let time = Double(span.time.count) / Double(Self.rate)
                func frame(_ t: Double) -> Double {
                    let mapped = Double(span.frames.lowerBound.count) + ((t - time) * Double(Self.rate)).rounded()
                    return min(max(mapped, Double(span.frames.lowerBound.count)), Double(span.frames.upperBound.count))
                }
                pieces[piece].append(TimedWord(text: "w\(index)", start: first, end: last))
                expected["w\(index)"] = (span.file, frame(startTime), frame(endTime))
            }
            let result = map.fileWords(pieces, in: ranges)
            #expect(result.untimed == 0)
            #expect(Set(result.words.words.map(\.text)) == Set(expected.keys))
            for word in result.words.words {
                let want = try #require(expected[word.text])
                let close =
                    word.file == want.file && abs(Double(word.range.lowerBound.count) - want.start) <= 1
                    && abs(Double(word.range.upperBound.count) - want.end) <= 1
                #expect(close, "\(word.text): \(word.file) \(word.range) against \(want)")
            }
        }
    }

    /// Seeded property: after the map and the clamp, every file word has lowerBound < upperBound,
    /// for random token times that include end < start, end == start, and a last word at the
    /// piece end. Each word either gives one file word or counts as untimed.
    @Test func everyOutputAnchorHasLowerBoundBelowUpperBound() {
        var generator = SeededGenerator(seed: 43)
        let map = SpanMap(
            clips: [
                clip("A", "a", start: 0, offset: 0, length: 96_000),
                clip("B", "b", start: 200_000, offset: 48_000, length: 48_000),
            ], sampleRate: Self.rate)
        let ticks = map.length.count / 480
        var words = [TimedWord(text: "last", start: ticks, end: ticks + 1)]
        for index in 0..<500 {
            let start = Int.random(in: 0...ticks, using: &generator)
            words.append(
                TimedWord(text: "w\(index)", start: start, end: start + Int.random(in: -3...30, using: &generator)))
        }
        let result = map.fileWords([words], in: [0..<map.length])

        #expect(result.words.words.allSatisfy { $0.range.lowerBound < $0.range.upperBound })
        #expect(result.words.words.count + result.untimed == words.count)
        #expect(!result.words.words.contains { $0.text == "last" })
    }

    /// U24. 25 min of audio gives pieces of at most 10 min, each cut at the pause that the search
    /// gives for a point 2 s before the limit, with a window of 2 s.
    @Test func piecesAreAtMostTenMinutesCutAtTheNearestPause() {
        let minute = 60 * Self.rate
        let map = SpanMap(clips: [clip("A", "h", start: 0, offset: 0, length: 25 * minute)], sampleRate: Self.rate)
        var asked: [(at: Frames, window: Frames)] = []
        let pieces = map.pieces { at, window in
            asked.append((at, window))
            return at - 1_000
        }

        let first = Frames(10 * minute - 2 * Self.rate - 1_000)
        let second = first + Frames(10 * minute - 2 * Self.rate - 1_000)
        #expect(pieces == [0..<first, first..<second, second..<Frames(25 * minute)])
        #expect(asked.map(\.at) == [Frames(10 * minute - 2 * Self.rate), first + Frames(10 * minute - 2 * Self.rate)])
        #expect(asked.allSatisfy { $0.window == Frames(2 * Self.rate) })
        #expect(pieces.allSatisfy { $0.upperBound - $0.lowerBound <= Frames(10 * minute) })
    }

    /// C25. The first clip uses file h and the second file g: the words of h get the numbers 1 and
    /// 2, and the word of g gets 3, although g comes first in file order.
    @Test func numbersFollowTheSpanOrderAcrossFiles() throws {
        var session = Session(sampleRate: Self.rate)
        try session.addTrack("host", name: "host", layout: .mono)
        for file in ["h", "g"] {
            try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: 1_000_000))
        }
        try session.place(clip("H", "h", start: 0, offset: 0, length: 48_000), on: "host")
        try session.place(clip("G", "g", start: 100_000, offset: 0, length: 48_000), on: "host")
        let map = SpanMap(clips: try #require(session.track("host")).clips, sampleRate: Self.rate)
        let words = [
            TimedWord(text: "uno", start: 10, end: 20), TimedWord(text: "dos", start: 30, end: 40),
            TimedWord(text: "tres", start: 110, end: 120),
        ]
        let result = map.fileWords([words], in: [0..<map.length])
        try session.addTranscript(result.words, name: "t", derived: [])

        let shown = session.words().map { "\($0.text) \($0.occurrence.word.number)@\($0.occurrence.clip)" }
        #expect(shown == ["uno 1@H", "dos 2@H", "tres 3@G"])
    }
}
