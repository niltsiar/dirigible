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
/// decodes again (one or more, in time order), and the speech ticks (`ThinSegments.speechTicks`) of
/// the thin segments and of the span.
struct ThinSpan: Hashable, Sendable {
    var start: Int
    var end: Int
    var thin: [DecodedSegment]
    var thinSpeech: Int
    var spanSpeech: Int

    /// `speech` is the VAD speech of the piece, or nil for a call with no VAD.
    init(start: Int, end: Int, thin: [DecodedSegment], speech: [Range<Int>]?) {
        self.start = start
        self.end = end
        self.thin = thin
        thinSpeech = thin.reduce(0) { $0 + ThinSegments.speechTicks(from: $1.start, to: $1.end, speech: speech) }
        spanSpeech = ThinSegments.speechTicks(from: start, to: end, speech: speech)
    }

    var firstPassWordCount: Int { thin.reduce(0) { $0 + $1.words.count } }

    /// The words of the span speech at `ThinSegments.typicalWordsPerSecond`, less the first-pass words.
    var missingWords: Double {
        Double(spanSpeech) / 100 * ThinSegments.typicalWordsPerSecond - Double(firstPassWordCount)
    }
}

/// What one second call gives: its words in call time, a stop, or the return code of a failed call.
enum RedecodeOutcome: Hashable, Sendable {
    case words([TimedWord])
    case stopped
    case failed(code: Int32)

    /// The outcome of a `whisper_full` call that returned `code` (`whisperOutcome`). `words` runs
    /// only for a finished call.
    init(code: Int32, stopFlagSet: Bool, words: () -> [TimedWord]) {
        switch whisperOutcome(code: code, stopFlagSet: stopFlagSet) {
        case .stopped: self = .stopped
        case .failed: self = .failed(code: code)
        case .finished: self = .words(words())
        }
    }
}

struct Redecode: Hashable, Sendable {
    var span: ThinSpan
    var outcome: RedecodeOutcome
}

/// The journal note `transcript redecode` of one second call that ended (decision 0065 D7b).
struct RedecodeNote: Hashable, Sendable {
    enum Kept: String, Sendable {
        case firstPass = "first pass"
        case secondPass = "second pass"
    }

    enum Result: Hashable, Sendable {
        /// `after` is the count of second-pass words that the edge rule keeps; `kept` is the pass
        /// that the accept test chose.
        case compared(after: Int, kept: Kept)
        /// The first pass stays.
        case failed(code: Int32)
    }

    var start: Int
    var end: Int
    var before: Int
    var result: Result
}

/// The repair of a whisper.cpp decode that skips speech inside one 30 s window (decision 0065 D7b):
/// the skipped speech shows as a thin segment, and a fresh `whisper_full` call on its span decodes
/// it again. Times are ticks of 10 ms.
enum ThinSegments {
    /// A thin segment lasts 5.0 s or more, with more than 1.0 s per word.
    static let shortestThinTicks = 500
    static let thinTicksPerWord = 100
    static let callCap = 4
    /// The median rate of the 239 segments that are not thin in 10 trial tracks.
    static let typicalWordsPerSecond = 2.8
    static let densestWordsPerSecond = 6
    /// A run of at most 4 second-pass words at an edge of a call goes when it repeats the first-pass
    /// words on that side within 1.0 s.
    static let edgeRepeatWords = 4
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

    /// The ticks from `start` to `end` that the VAD `speech` ranges (in time order) cover, each tick
    /// once. With no VAD (nil), all ticks count. With VAD, a segment of short replies maps back over
    /// the silence that VAD removed, so its length is not its speech.
    static func speechTicks(from start: Int, to end: Int, speech: [Range<Int>]?) -> Int {
        guard let speech else { return max(0, end - start) }
        var covered = start
        var total = 0
        for part in speech {
            let upper = min(part.upperBound, end)
            let lower = max(part.lowerBound, covered)
            if upper > lower {
                total += upper - lower
                covered = upper
            }
        }
        return total
    }

    /// The second calls of a piece: at most `callCap` of `calls`, the calls with the most missing
    /// words first, ties in time order. The result is in time order.
    static func spans(of segments: [DecodedSegment], pieceEnd: Int, language: String, speech: [Range<Int>]?)
        -> [ThinSpan]
    {
        let all = calls(of: segments, pieceEnd: pieceEnd, language: language, speech: speech)
        let ranked = all.indices.sorted { a, b in
            let (missingA, missingB) = (all[a].missingWords, all[b].missingWords)
            return missingA != missingB ? missingA > missingB : a < b
        }
        return ranked.prefix(callCap).sorted().map { all[$0] }
    }

    /// The span of each thin segment runs from the end of the segment before it (the piece start for
    /// the first) to the start of the segment after it (the piece end for the last). Spans that
    /// overlap or touch make one call. A segment is thin over its speech ticks. A language with no
    /// spaces gives no call.
    static func calls(of segments: [DecodedSegment], pieceEnd: Int, language: String, speech: [Range<Int>]?)
        -> [ThinSpan]
    {
        guard !unspacedLanguages.contains(language) else { return [] }
        var found: [(start: Int, end: Int, thin: [DecodedSegment])] = []
        for (n, segment) in segments.enumerated() {
            let ticks = speechTicks(from: segment.start, to: segment.end, speech: speech)
            guard isThin(ticks: ticks, words: segment.words.count) else { continue }
            let start = min(n > 0 ? segments[n - 1].end : 0, segment.start)
            let end = max(n + 1 < segments.count ? segments[n + 1].start : pieceEnd, segment.end)
            if let last = found.indices.last, start <= found[last].end {
                found[last].end = max(found[last].end, end)
                found[last].thin.append(segment)
            } else {
                found.append((start, end, [segment]))
            }
        }
        return found.map { ThinSpan(start: $0.start, end: $0.end, thin: $0.thin, speech: speech) }
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

    /// The second-pass words of `span` that the merge keeps: all, except the longest run of at most
    /// `edgeRepeatWords` words at the start that repeats the last first-pass words before the thin
    /// segments, and the mirror at the end. The runs end (start) or start (end) 1.0 s apart or less:
    /// with VAD, a first-pass word can start long before its speech.
    static func kept(_ again: [TimedWord], first: [TimedWord], span: ThinSpan) -> [TimedWord] {
        let before = first[..<span.thin[0].words.lowerBound]
        let after = first[span.thin[span.thin.count - 1].words.upperBound...]
        func same(_ a: ArraySlice<TimedWord>, _ b: ArraySlice<TimedWord>) -> Bool {
            a.map { normalized($0.text) } == b.map { normalized($0.text) }
        }
        var lead = min(edgeRepeatWords, again.count, before.count)
        while lead > 0
            && !(same(again.prefix(lead), before.suffix(lead))
                && abs(again[lead - 1].end - before[before.endIndex - 1].end) <= edgeRepeatTicks)
        {
            lead -= 1
        }
        let rest = again[lead...]
        var trail = min(edgeRepeatWords, rest.count, after.count)
        while trail > 0
            && !(same(rest.suffix(trail), after.prefix(trail))
                && abs(rest[rest.endIndex - trail].start - after[after.startIndex].start) <= edgeRepeatTicks)
        {
            trail -= 1
        }
        return Array(rest.dropLast(trail))
    }

    /// True when the kept second-pass words replace the first-pass words of the thin segments of
    /// `span`: they are more, at most `densestWordsPerSecond` over the speech of the span (the time
    /// that the call decodes), not thin over the speech of the thin segments, and no loop.
    static func accepts(_ again: [TimedWord], over span: ThinSpan) -> Bool {
        again.count > span.firstPassWordCount && again.count * 100 <= densestWordsPerSecond * span.spanSpeech
            && !isThin(ticks: span.thinSpeech, words: again.count) && !hasLoop(again.map { normalized($0.text) })
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

    /// The second calls of one piece after its first call (decision 0065 D7b). `first` holds the
    /// first-pass words with the segment of each, `bounds` the segment bounds in ticks, and
    /// `language` the first-pass language code. `decode` runs one call on a sample range of the
    /// piece in that language and gives its words in call time. `speech` is the VAD speech of the
    /// first call in ticks, or nil with no VAD. A stopped call ends the loop. Each call that ends
    /// writes one `transcript redecode` note to `log`; a stopped call writes none. When the cap drops
    /// spans, one `transcript redecode cap` note names them.
    static func redecode(
        first: [(word: TimedWord, segment: Int)], bounds: [(start: Int, end: Int)], speech: [Range<Int>]?,
        sampleCount: Int, language: String, log: DiagnosticLog, decode: (Range<Int>, String) -> RedecodeOutcome
    ) -> PieceOutcome {
        let decoded = segments(bounds, wordSegments: first.map(\.segment))
        let pieceEnd = (sampleCount + WordEnds.samplesPerTick - 1) / WordEnds.samplesPerTick
        let chosen = spans(of: decoded, pieceEnd: pieceEnd, language: language, speech: speech)
        let dropped = calls(of: decoded, pieceEnd: pieceEnd, language: language, speech: speech)
            .filter { !chosen.contains($0) }
        if !dropped.isEmpty {
            log.note(
                .app, "transcript redecode cap",
                fields: [
                    ("dropped", .number(Int64(dropped.count))),
                    ("spans", .text(dropped.map { "\($0.start)-\($0.end)" }.joined(separator: ","))),
                ])
        }
        var redecodes: [Redecode] = []
        for span in chosen {
            var outcome = decode(sampleRange(ticks: span.start..<span.end, count: sampleCount), language)
            if case .words(let words) = outcome { outcome = .words(shifted(words, byTicks: span.start)) }
            redecodes.append(Redecode(span: span, outcome: outcome))
            if outcome == .stopped { break }
        }
        let composed = compose(first: first.map(\.word), language: language, redecodes: redecodes)
        for note in composed.notes { note.write(to: log) }
        return composed.outcome
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
            let result: RedecodeNote.Result
            switch redecode.outcome {
            case .stopped:
                return (.stopped, notes)
            case .failed(let code):
                result = .failed(code: code)
            case .words(let again):
                let words = kept(again, first: first, span: span)
                let accepted = accepts(words, over: span)
                if accepted { blocks.append((span, words)) }
                result = .compared(after: words.count, kept: accepted ? .secondPass : .firstPass)
            }
            notes.append(
                RedecodeNote(start: span.start, end: span.end, before: span.firstPassWordCount, result: result))
        }
        return (.words(merge(first, blocks: blocks), language: language), notes)
    }

    /// Case, punctuation, and accents do not count.
    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let kept = folded.unicodeScalars.filter {
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

extension RedecodeNote {
    /// Writes the journal line `transcript redecode`: the span in piece ticks, the word counts, the
    /// kept pass, and the return code of a failed call.
    func write(to log: DiagnosticLog) {
        var fields: [(key: String, value: DiagnosticValue)] = [
            ("start", .number(Int64(start))), ("end", .number(Int64(end))), ("before", .number(Int64(before))),
        ]
        switch result {
        case .compared(let after, let kept):
            fields += [("after", .number(Int64(after))), ("kept", .text(kept.rawValue))]
        case .failed(let code):
            fields += [("kept", .text(Kept.firstPass.rawValue)), ("fault", .number(Int64(code)))]
        }
        log.note(.app, "transcript redecode", fields: fields)
    }
}
