import Foundation

/// One segment of a `whisper_full` result, in piece ticks (`whisper_full_get_segment_t0/t1`), and the
/// indexes of its words in the word list of the piece. A word belongs to the segment of its first
/// token with a letter or a digit.
struct DecodedSegment: Hashable, Sendable {
    var start: Int
    var end: Int
    var words: Range<Int>
}

/// One second `whisper_full` call of a piece: its span in piece ticks, the thin segments that it
/// decodes again (one or more, in time order), and the language of the call.
struct ThinSpan: Hashable, Sendable {
    var start: Int
    var end: Int
    var thin: [DecodedSegment]
    var language: WhisperLanguage

    var firstPassWordCount: Int { thin.reduce(0) { $0 + $1.words.count } }
}

/// What one second call gives. A failed call keeps the return code of `whisper_full`.
enum RedecodeOutcome: Hashable, Sendable {
    case words([TimedWord], language: String)
    case stopped
    case failed(code: Int32)
}

struct Redecode: Hashable, Sendable {
    var span: ThinSpan
    var outcome: RedecodeOutcome
}

/// The journal note `transcript redecode` of one second call (decision 0065 D7b). `after` is the
/// count of second-pass words that the merge keeps, and nil for a failed call.
struct RedecodeNote: Hashable, Sendable {
    enum Kept: String, Sendable {
        case firstPass = "first pass"
        case secondPass = "second pass"
    }

    var start: Int
    var end: Int
    var before: Int
    var after: Int?
    var kept: Kept
    var fault: Int32?
}

/// The repair of a whisper.cpp decode that skips speech inside one 30 s window (decision 0065 D7b):
/// the skipped speech shows as a thin segment, and a fresh `whisper_full` call on its span decodes
/// it again. Times are ticks of 10 ms.
enum ThinSegments {
    /// A thin segment lasts 5.0 s or more, with more than 1.0 s per word.
    static let shortestThinTicks = 500
    static let thinTicksPerWord = 100
    static let callCap = 4
    static let densestWordsPerSecond = 6
    /// A second-pass word at an edge of a call goes when it repeats its first-pass neighbour within 1.0 s.
    static let edgeRepeatTicks = 100
    /// A loop is an n-gram of 1 to 8 words that comes 3 times or more back to back, over 6 words or more.
    static let loopLongestGram = 8
    static let loopRepeats = 3
    static let loopShortestRun = 6
    /// Languages with no space between words: a count of space-separated parts is not a word count.
    static let unspacedLanguages: Set<String> = ["zh", "ja", "th", "lo", "km", "my", "bo", "yue"]

    /// The segments of a result from the bounds of each segment and the segment of each word, in order.
    static func segments(_ bounds: [(start: Int, end: Int)], wordSegments: [Int]) -> [DecodedSegment] {
        var next = 0
        return bounds.enumerated().map { n, bound in
            let lower = next
            while next < wordSegments.count && wordSegments[next] <= n { next += 1 }
            return DecodedSegment(start: bound.start, end: bound.end, words: lower..<next)
        }
    }

    static func isThin(ticks: Int, words: Int) -> Bool {
        ticks >= shortestThinTicks && ticks > thinTicksPerWord * words
    }

    /// The second calls of a piece: at most `callCap` of `calls`, the calls with the most first-pass
    /// words first, ties in time order. The result is in time order.
    static func spans(of segments: [DecodedSegment], pieceEnd: Int, language: String) -> [ThinSpan] {
        let all = calls(of: segments, pieceEnd: pieceEnd, language: language)
        let ranked = all.indices.sorted { a, b in
            let (wordsA, wordsB) = (all[a].firstPassWordCount, all[b].firstPassWordCount)
            return wordsA != wordsB ? wordsA > wordsB : a < b
        }
        return ranked.prefix(callCap).sorted().map { all[$0] }
    }

    /// The span of each thin segment runs from the end of the segment before it (the piece start for
    /// the first) to the start of the segment after it (the piece end for the last). Spans that
    /// overlap or touch make one call. A language with no spaces gives no call.
    static func calls(of segments: [DecodedSegment], pieceEnd: Int, language: String) -> [ThinSpan] {
        guard !unspacedLanguages.contains(language) else { return [] }
        var found: [ThinSpan] = []
        for (n, segment) in segments.enumerated() {
            guard isThin(ticks: segment.end - segment.start, words: segment.words.count) else { continue }
            let start = min(n > 0 ? segments[n - 1].end : 0, segment.start)
            let end = max(n + 1 < segments.count ? segments[n + 1].start : pieceEnd, segment.end)
            if let last = found.indices.last, start <= found[last].end {
                found[last].end = max(found[last].end, end)
                found[last].thin.append(segment)
            } else {
                found.append(ThinSpan(start: start, end: end, thin: [segment], language: .code(language)))
            }
        }
        return found
    }

    /// The samples of a span of ticks, at `WordEnds.samplesPerTick` samples per tick, clamped to a
    /// piece of `count` samples.
    static func sampleRange(ticks: Range<Int>, count: Int) -> Range<Int> {
        min(ticks.lowerBound * WordEnds.samplesPerTick, count)..<min(ticks.upperBound * WordEnds.samplesPerTick, count)
    }

    /// The words of a call on the samples from `ticks` on, in piece time.
    static func shifted(_ words: [TimedWord], byTicks ticks: Int) -> [TimedWord] {
        words.map { TimedWord(text: $0.text, start: $0.start + ticks, end: $0.end + ticks) }
    }

    /// The second-pass words of `span` that the merge keeps: all, except a first or a last word that
    /// repeats the nearest first-pass word on its side that is not a word of the thin segments, with
    /// starts 1.0 s apart or less.
    static func kept(_ again: [TimedWord], first: [TimedWord], span: ThinSpan) -> [TimedWord] {
        func repeats(_ word: TimedWord, _ index: Int) -> Bool {
            first.indices.contains(index) && normalized(word.text) == normalized(first[index].text)
                && abs(word.start - first[index].start) <= edgeRepeatTicks
        }
        var kept = again[...]
        if let word = kept.first, repeats(word, span.thin[0].words.lowerBound - 1) { kept = kept.dropFirst() }
        if let word = kept.last, repeats(word, span.thin[span.thin.count - 1].words.upperBound) {
            kept = kept.dropLast()
        }
        return Array(kept)
    }

    /// True when the kept second-pass words replace the first-pass words of `thin`: they are more, at
    /// most `densestWordsPerSecond` over the thin segments, not thin over the same time, and no loop.
    static func accepts(_ again: [TimedWord], over thin: [DecodedSegment]) -> Bool {
        let before = thin.reduce(0) { $0 + $1.words.count }
        let ticks = thin.reduce(0) { $0 + $1.end - $1.start }
        return again.count > before && again.count * 100 <= densestWordsPerSecond * ticks
            && !isThin(ticks: ticks, words: again.count) && !hasLoop(again.map { normalized($0.text) })
    }

    /// `first` with the words of the thin segments of each block replaced by the words of the block,
    /// in call order, at the place of the first thin-segment word. Every other first-pass word stays.
    static func merge(_ first: [TimedWord], blocks: [(span: ThinSpan, words: [TimedWord])]) -> [TimedWord] {
        var removed = Set<Int>()
        var inserts: [Int: [TimedWord]] = [:]
        for block in blocks {
            for segment in block.span.thin { removed.formUnion(segment.words) }
            inserts[block.span.thin[0].words.lowerBound, default: []] += block.words
        }
        var merged: [TimedWord] = []
        for index in 0...first.count {
            merged += inserts[index] ?? []
            if index < first.count && !removed.contains(index) { merged.append(first[index]) }
        }
        return merged
    }

    /// The piece outcome from the first pass and the second calls in order: a stopped call stops the
    /// piece; a failed call keeps the first-pass words and notes its code; an accepted call replaces
    /// the words of its thin segments. The language of the piece is the first-pass language.
    static func compose(first: [TimedWord], language: String, redecodes: [Redecode])
        -> (outcome: PieceOutcome, notes: [RedecodeNote])
    {
        var notes: [RedecodeNote] = []
        var blocks: [(span: ThinSpan, words: [TimedWord])] = []
        for redecode in redecodes {
            let span = redecode.span
            var note = RedecodeNote(
                start: span.start, end: span.end, before: span.firstPassWordCount, after: nil, kept: .firstPass,
                fault: nil)
            switch redecode.outcome {
            case .stopped:
                return (.stopped, notes)
            case .failed(let code):
                note.fault = code
            case .words(let again, _):
                let words = kept(again, first: first, span: span)
                note.after = words.count
                if accepts(words, over: span.thin) {
                    blocks.append((span, words))
                    note.kept = .secondPass
                }
            }
            notes.append(note)
        }
        return (.words(merge(first, blocks: blocks), language: language), notes)
    }

    /// Case and punctuation do not count.
    private static func normalized(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.filter {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }
        return String(kept)
    }

    private static func hasLoop(_ words: [String]) -> Bool {
        for gram in 1...loopLongestGram where words.count >= gram {
            for start in 0...(words.count - gram) {
                let block = words[start..<(start + gram)]
                var end = start + gram
                while end + gram <= words.count && words[end..<(end + gram)] == block { end += gram }
                if (end - start) / gram >= loopRepeats && end - start >= loopShortestRun { return true }
            }
        }
        return false
    }
}
