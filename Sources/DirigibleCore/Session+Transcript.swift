import Foundation

/// The transcript queries and edits (decision 0055). A word shows under each clip, on any track,
/// whose file range `offset ..< offset + length` holds the midpoint of its anchor, so each clip edit
/// moves the words with no transcript code.
extension Session {
    /// The shown words in timeline order (start, then word, then track). `range` keeps the words
    /// that touch it. `phrase` keeps each run of adjacent words of one track whose words equal the
    /// words of the phrase, with case, diacritics, and the punctuation at word edges ignored. `tracks`
    /// nil is all tracks.
    public func words(in range: Range<Frames>? = nil, matching phrase: String? = nil, on tracks: [TrackID]? = nil)
        -> [SpokenWord]
    {
        var shown: [(word: SpokenWord, lane: Int)] = []
        for (lane, track) in self.tracks.enumerated() where tracks?.contains(track.id) ?? true {
            var words: [SpokenWord] = []
            for clip in track.clips {
                let file = clip.offset..<(clip.offset + clip.length)
                for transcript in transcripts.values {
                    for anchor in transcript.words[clip.file]?.anchors(midpointIn: file) ?? [] {
                        let start = clip.start + max(anchor.range.lowerBound, file.lowerBound) - clip.offset
                        let end = clip.start + min(anchor.range.upperBound, file.upperBound) - clip.offset
                        words.append(
                            SpokenWord(
                                occurrence: WordOccurrence(
                                    word: WordID(transcript: transcript.id, number: anchor.number),
                                    fileStart: anchor.range.lowerBound, clip: clip.id),
                                track: track.id, text: anchor.text, range: start..<end))
                    }
                }
            }
            words.sort { ($0.range.lowerBound, $0.occurrence.word) < ($1.range.lowerBound, $1.occurrence.word) }
            if let phrase { words = Self.matches(of: phrase, in: words) }
            shown += words.map { ($0, lane) }
        }
        if let range {
            shown.removeAll {
                !($0.word.range.lowerBound < range.upperBound && $0.word.range.upperBound > range.lowerBound)
            }
        }
        return shown.sorted {
            ($0.word.range.lowerBound, $0.word.occurrence.word, $0.lane)
                < ($1.word.range.lowerBound, $1.word.occurrence.word, $1.lane)
        }.map(\.word)
    }

    /// Each run of `words` whose folded tokens equal the tokens of `phrase`. A word can hold more
    /// than one token (a WebVTT cue), so the match runs over the tokens.
    private static func matches(of phrase: String, in words: [SpokenWord]) -> [SpokenWord] {
        func tokens(_ text: String) -> [String] {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split(whereSeparator: \.isWhitespace)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }
        }
        let wanted = tokens(phrase)
        let flat = words.indices.flatMap { index in tokens(words[index].text).map { (token: $0, word: index) } }
        guard !wanted.isEmpty, flat.count >= wanted.count else { return [] }
        var kept = Set<Int>()
        for start in 0...(flat.count - wanted.count)
        where zip(flat[start..<(start + wanted.count)], wanted).allSatisfy({ $0.token == $1 }) {
            for item in flat[start..<(start + wanted.count)] { kept.insert(item.word) }
        }
        return words.indices.filter(kept.contains).map { words[$0] }
    }

    /// Cuts the audio of `occurrences` from all tracks in one ripple delete, and returns the ranges
    /// of the runs, before the ripple delete merges the touching ones. A run is a sequence of named
    /// words with no other shown word between them on any track, of one transcript, each number the
    /// same as or one more than the one before. The occurrences of one word at one start (one file
    /// on two tracks) are one step, named when any of them is named. A run goes from its first start
    /// to its largest end. An occurrence that is not shown now throws `.unknownWord` and changes
    /// nothing.
    @discardableResult
    public mutating func cutWords(_ occurrences: [WordOccurrence]) throws(SessionError) -> [Range<Frames>] {
        let shown = words()
        let present = Set(shown.map(\.occurrence))
        if let missing = occurrences.first(where: { !present.contains($0) }) { throw .unknownWord(missing) }
        let named = Set(occurrences)
        var steps: [(word: WordID, range: Range<Frames>, named: Bool)] = []
        for word in shown {
            let isNamed = named.contains(word.occurrence)
            if let last = steps.last, last.word == word.occurrence.word, last.range.lowerBound == word.range.lowerBound
            {
                steps[steps.count - 1] = (
                    last.word, last.range.lowerBound..<max(last.range.upperBound, word.range.upperBound),
                    last.named || isNamed
                )
            } else {
                steps.append((word.occurrence.word, word.range, isNamed))
            }
        }
        var ranges: [Range<Frames>] = []
        var previous: WordID?
        for step in steps {
            guard step.named else {
                previous = nil
                continue
            }
            if let last = previous, last.transcript == step.word.transcript,
                (0...1).contains(step.word.number - last.number)
            {
                let run = ranges[ranges.count - 1]
                ranges[ranges.count - 1] = run.lowerBound..<max(run.upperBound, step.range.upperBound)
            } else {
                ranges.append(step.range)
            }
            previous = step.word
        }
        try rippleDelete(ranges, on: tracks.map(\.id))
        return ranges
    }
}
