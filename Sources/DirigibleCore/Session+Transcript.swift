import Foundation

/// The transcript queries and edits (decision 0055). A word shows under each clip, on any track,
/// whose file range `offset ..< offset + length` holds the midpoint of its anchor, so each clip edit
/// moves the words with no transcript code. The anchors of a rendered file are on the root of its
/// chain, in root frames (decision 0057 D11).
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
                let root = self.root(of: clip.file)
                let file = (clip.offset + root.offset)..<(clip.offset + root.offset + clip.length)
                for transcript in transcripts.values {
                    for anchor in transcript.words?[root.file]?.anchors(midpointIn: file) ?? [] {
                        let start = clip.start + max(anchor.range.lowerBound, file.lowerBound) - file.lowerBound
                        let end = clip.start + min(anchor.range.upperBound, file.upperBound) - file.lowerBound
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
    /// no audio throw `.nothingToCut`; both change nothing. While a transcript did not load, a
    /// hidden word could join a run across other speech, so the cut throws `.transcriptNotLoaded`.
    @discardableResult
    public mutating func cutWords(_ occurrences: [WordOccurrence]) throws(SessionError) -> [Range<Frames>] {
        let unloaded = transcriptsNotLoaded.map(\.id)
        guard unloaded.isEmpty else { throw .transcriptNotLoaded(unloaded) }
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

    /// The time base of the units of a transcript file.
    public enum TranscriptTime: Sendable {
        /// Seconds of an export of the timeline, from timeline frame `at`.
        case timeline
        /// Seconds of the take with this number, from take frame `at` (decision 0061): take time 0
        /// is the record start of the take, and `map` says where each edit moved its audio.
        case take(Int, TakeMap)
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
    /// no word left goes. Then it drops each transcript that did not load, and returns their
    /// names. No kept word throws `.noWordOnTrack` and changes nothing.
    ///
    /// With `time` `.take(n, map)`, the times are take time of take `n`, and `at` is a take frame.
    /// The clip under a unit is the first clip of `track`, in timeline order, whose file is a file
    /// of take `n` and whose take range holds the midpoint, so a unit in audio that an edit removed
    /// is skipped. A word is stored at its range in the file, not clamped to that clip, so it does
    /// not depend on which other clips of the file the timeline plays. A track with no clip of
    /// take `n` throws `.noTakeAudio`. In both time bases, a word over a clip on a rendered file goes
    /// to the root of its chain, in root frames (decision 0057 D11).
    @discardableResult
    public mutating func importTranscript(
        _ file: TranscriptFile, name: String, track: TrackID, at: Frames, time: TranscriptTime = .timeline
    ) throws(SessionError) -> (
        id: TranscriptID, kept: Int, skipped: Int, untimed: Int, repeated: Int, dropped: [String]
    ) {
        try Self.checkText(name)
        let valid: ClosedRange<Int>
        switch time {
        case .timeline:
            guard at.isInRange else { throw .frameOutOfRange }
            valid = 0...Frames.limit.count
        case .take:
            guard TakeMap.takeFrames.contains(at.count) else { throw .frameOutOfRange }
            valid = TakeMap.takeFrames
        }
        let clips = tracks[try trackIndex(track)].clips
        if case .take(let take, let map) = time, !clips.contains(where: { map.origins[$0.file]?.take == take }) {
            throw .noTakeAudio(track, take)
        }
        func frame(_ seconds: Double) -> Int? {
            let frames = (seconds * Double(sampleRate)).rounded()
            guard frames <= Double(Frames.limit.count) else { return nil }
            let frame = Int(frames) + at.count
            return valid.contains(frame) ? frame : nil
        }
        /// The clip under `midpoint`, the frame range of the unit time base that a stored word is
        /// clamped to, the root file of the clip, and the shift from that time base to root frames.
        func located(at midpoint: Int) -> (clip: Clip, bounds: Range<Int>, root: FileID, shift: Int)? {
            switch time {
            case .timeline:
                guard let index = clips.index(holding: Frames(midpoint)) else { return nil }
                let clip = clips[index]
                let root = self.root(of: clip.file)
                return (
                    clip, clip.start.count..<clip.end.count, root.file,
                    clip.offset.count - clip.start.count + root.offset.count
                )
            case .take(let take, let map):
                guard let piece = map.playing(atTake: midpoint, take: take, on: track).first,
                    let file = files[piece.clip.file]
                else { return nil }
                let root = self.root(of: piece.clip.file)
                return (
                    piece.clip, piece.origin.frame..<(piece.origin.frame + file.length.count), root.file,
                    root.offset.count - piece.origin.frame
                )
            }
        }
        var untimed = file.untimed
        var number = 0
        var skipped = 0
        var repeats = 0
        var added: [FileID: [Anchor]] = [:]
        // Each clip that gave a word: its root file and its frames in that root.
        var heard: [ClipID: (root: FileID, span: Range<Frames>)] = [:]
        for unit in file.units {
            guard let start = frame(unit.start), let end = frame(unit.end) else {
                untimed += 1
                continue
            }
            number += 1
            let midpoint = (start + end) / 2
            guard let (clip, bounds, root, shift) = located(at: midpoint) else {
                skipped += 1
                continue
            }
            // A repeat of audio that another clip of the file gave already shows there: no second anchor.
            // A take time names the file frame, so a take import has no repeat.
            if case .timeline = time {
                let repeated = heard.contains { id, other in
                    id != clip.id && other.root == root && other.span.contains(Frames(midpoint + shift))
                }
                guard !repeated else {
                    repeats += 1
                    continue
                }
                heard[clip.id] = (root, Frames(bounds.lowerBound + shift)..<Frames(bounds.upperBound + shift))
            }
            let range = Frames(max(start, bounds.lowerBound) + shift)..<Frames(min(end, bounds.upperBound) + shift)
            added[root, default: []].append(Anchor(number: number, range: range, text: unit.text))
        }
        guard !added.isEmpty else { throw .noWordOnTrack(track) }
        // The ID comes before the replace, so a re-import never gives the ID of a transcript that it empties.
        let id = nextTranscriptID
        let dropped = transcriptsNotLoaded
        for transcript in dropped { transcripts[transcript.id] = nil }
        for (fileID, anchors) in added {
            let span = anchors.map(\.range.lowerBound).min()!...anchors.map(\.range.upperBound).max()!
            for old in transcripts.keys {
                guard let words = transcripts[old]?.words?[fileID] else { continue }
                setWords(words.all.filter { !span.contains($0.midpoint) }, file: fileID, transcript: old)
            }
        }
        try insertTranscript(Transcript(id: id, name: name, words: added.mapValues(Anchors.init)))
        return (id, added.values.map(\.count).reduce(0, +), skipped, untimed, repeats, dropped.map(\.name))
    }

    /// Sets the words of `file` in transcript `id`. No word removes the file from the transcript,
    /// and a transcript with no file left goes (decision 0055).
    mutating func setWords(_ anchors: [Anchor], file: FileID, transcript id: TranscriptID) {
        transcripts[id]?.words?[file] = anchors.isEmpty ? nil : Anchors(anchors)
        if transcripts[id]?.words?.isEmpty == true { transcripts[id] = nil }
    }

    /// The transcripts by ID, with their names.
    public var transcriptNames: [(id: TranscriptID, name: String)] {
        transcripts.values.sorted { $0.id < $1.id }.map { ($0.id, $0.name) }
    }

    /// The transcripts whose file did not load at the open, by ID (decision 0055).
    public var transcriptsNotLoaded: [(id: TranscriptID, name: String)] {
        transcripts.values.filter { $0.words == nil }.sorted { $0.id < $1.id }.map { ($0.id, $0.name) }
    }

    /// The ID of a new transcript: one more than the largest ID.
    // shortcut: an undo, or a removeFile that empties the top transcript, lets a later import take
    // its ID again, because session.xml keeps no counter; add one in the run that changes how a
    // transcript gets its ID.
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
    /// edit keep the file (decision 0055). The words of a file that is not in the pool (a
    /// `removeFile` while the transcript did not load) go, which gives a new file name; a
    /// transcript with no word left goes. A word of a file with an origin keeps the transcript
    /// unloaded: the words of a rendered file are on its root (decision 0057 D11).
    mutating func resolveTranscripts(_ words: (Transcript) -> [FileID: Anchors]?) {
        for transcript in transcripts.values where transcript.words == nil {
            guard let found = words(transcript), !found.isEmpty else { continue }
            let kept = found.filter { files[$0.key] != nil }
            guard !kept.keys.contains(where: { files[$0]?.origin != nil }), (try? checkWords(kept)) != nil
            else { continue }
            var loaded = Transcript(id: transcript.id, name: transcript.name, file: transcript.file, words: found)
            loaded.words = kept
            transcripts[transcript.id] = kept.isEmpty ? nil : loaded
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
