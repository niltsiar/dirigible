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
                    for anchor in transcript.words?[clip.file]?.anchors(midpointIn: file) ?? [] {
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
    /// that it cut: the ranges of the runs, with overlapping and touching ones merged. A run is a sequence of named
    /// words with no other shown word between them on any track, of one transcript, each number the
    /// same as or one more than the one before. The occurrences of one word at one start (one file
    /// on two tracks) are one step, named when any of them is named. A run goes from its first start
    /// to its largest end. An occurrence that is not shown now throws `.unknownWord`, and words with
    /// no audio throw `.nothingToCut`; both change nothing.
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
        let cut = Self.merged(ranges)
        guard !cut.isEmpty else { throw .nothingToCut }
        try rippleDelete(cut, on: tracks.map(\.id))
        return cut
    }

    /// Imports `file`, a transcript of an export from timeline frame `at`, through the clips of
    /// `track` (decision 0055). A unit goes to the clip of `track` under its midpoint, as file frames
    /// clamped to the clip. Each unit with a usable time gets the number of its index, from 1; a unit
    /// with no clip under it is skipped, and its number is used up, so a cut never joins words
    /// around audio of another place. A unit over file audio that an earlier clip of the import
    /// already gave (a duplicated region) adds no anchor and counts as repeated: the words of the
    /// first use show under both clips. A unit past `Frames.limit` counts as untimed with the
    /// untimed units of the file. For each file that it anchors, the import first drops the old
    /// words (of any transcript) whose midpoint is in the span of the new words. A transcript with
    /// no word left goes. No kept word throws `.noWordOnTrack` and changes nothing.
    @discardableResult
    public mutating func importTranscript(_ file: TranscriptFile, name: String, track: TrackID, at: Frames)
        throws(SessionError) -> (id: TranscriptID, kept: Int, skipped: Int, untimed: Int, repeated: Int)
    {
        try Self.checkText(name)
        guard at.isInRange else { throw .frameOutOfRange }
        let clips = tracks[try trackIndex(track)].clips
        func frame(_ seconds: Double) -> Frames? {
            let frames = (seconds * Double(sampleRate)).rounded()
            guard frames <= Double(Frames.limit.count) else { return nil }
            let frame = Frames(Int(frames)) + at
            return frame.isInRange ? frame : nil
        }
        var untimed = file.untimed
        var number = 0
        var skipped = 0
        var repeats = 0
        var added: [FileID: [Anchor]] = [:]
        var heard: Set<Int> = []
        for unit in file.units {
            guard let start = frame(unit.start), let end = frame(unit.end) else {
                untimed += 1
                continue
            }
            number += 1
            let midpoint = Frames((start.count + end.count) / 2)
            guard let index = clips.index(holding: midpoint) else {
                skipped += 1
                continue
            }
            let clip = clips[index]
            let shift = clip.offset - clip.start
            // A repeat of audio that another clip of the file gave already shows there: no second anchor.
            let repeated = heard.contains { other in
                other != index && clips[other].file == clip.file
                    && (clips[other].offset..<(clips[other].offset + clips[other].length)).contains(midpoint + shift)
            }
            guard !repeated else {
                repeats += 1
                continue
            }
            heard.insert(index)
            let range = (max(start, clip.start) + shift)..<(min(end, clip.end) + shift)
            added[clip.file, default: []].append(Anchor(number: number, range: range, text: unit.text))
        }
        guard !added.isEmpty else { throw .noWordOnTrack(track) }
        // The ID comes before the replace, so a re-import never gives the ID of a transcript that it empties.
        let id = nextTranscriptID
        for (fileID, anchors) in added {
            let span = anchors.map(\.range.lowerBound).min()!...anchors.map(\.range.upperBound).max()!
            for old in transcripts.keys {
                guard let words = transcripts[old]?.words?[fileID] else { continue }
                setWords(words.all.filter { !span.contains($0.midpoint) }, file: fileID, transcript: old)
            }
        }
        try insertTranscript(Transcript(id: id, name: name, words: added.mapValues(Anchors.init)))
        return (id, added.values.map(\.count).reduce(0, +), skipped, untimed, repeats)
    }

    /// Sets the words of `file` in transcript `id`. No word removes the file from the transcript,
    /// and a transcript with no file left goes (decision 0055).
    mutating func setWords(_ anchors: [Anchor], file: FileID, transcript id: TranscriptID) {
        transcripts[id]?.words?[file] = anchors.isEmpty ? nil : Anchors(anchors)
        if transcripts[id]?.words?.isEmpty == true { transcripts[id] = nil }
    }

    /// The ID of a new transcript: one more than the largest ID.
    // shortcut: an undo, or a removeFile that empties the top transcript, lets a later import take
    // its ID again, because session.xml keeps no counter; add one when the format next changes.
    var nextTranscriptID: TranscriptID { TranscriptID((transcripts.keys.map(\.number).max() ?? 0) + 1) }

    /// Puts a new transcript in the store: a new ID and a storable name. The reader, the import,
    /// and the paste call it once per transcript.
    mutating func insertTranscript(_ transcript: Transcript) throws(SessionError) {
        guard transcripts[transcript.id] == nil else { throw .duplicateID(transcript.id.description) }
        try Self.checkText(transcript.name)
        transcripts[transcript.id] = transcript
    }

    /// Gives each transcript with no words the words that `words` returns for it, when they pass
    /// `checkWords`. The value keeps the file name of its reference, so an open and a save with no
    /// edit keep the file (decision 0055).
    mutating func resolveTranscripts(_ words: (Transcript) -> [FileID: Anchors]?) {
        for transcript in transcripts.values where transcript.words == nil {
            guard let found = words(transcript), !found.isEmpty, (try? checkWords(found)) != nil else { continue }
            transcripts[transcript.id] = Transcript(
                id: transcript.id, name: transcript.name, file: transcript.file, words: found)
        }
    }

    /// The rules of the import for the words of a transcript: files of the pool, each number once
    /// in a file, a storable text that is not empty, and each word inside its file.
    func checkWords(_ words: [FileID: Anchors]) throws(SessionError) {
        for (id, anchors) in words {
            guard let file = files[id] else { throw .unknownFile(id) }
            var numbers = Set<Int>()
            for anchor in anchors.all {
                guard !anchor.text.isEmpty else { throw .invalidText(anchor.text) }
                try Self.checkText(anchor.text)
                guard numbers.insert(anchor.number).inserted else { throw .duplicateID("\(id).\(anchor.number)") }
                guard anchor.range.lowerBound >= .zero, anchor.range.upperBound <= file.length else {
                    throw .wordOutsideFile(id)
                }
            }
        }
    }
}
