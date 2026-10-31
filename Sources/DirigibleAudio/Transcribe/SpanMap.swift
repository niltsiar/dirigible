import DirigibleCore

/// The file spans that a transcription job reads as one concatenated audio, and the map from the
/// words of the engine back to file frames (decision 0065 D3, D4). All frames are at the session
/// rate.
struct SpanMap: Hashable, Sendable {
    /// One file range and its start in the concatenated audio.
    struct Span: Hashable, Sendable {
        let file: FileID
        let frames: Range<Frames>
        let time: Frames
    }

    let spans: [Span]
    let sampleRate: Int

    /// One clip as a range of the root of its file (decision 0057 D11): `shift` is the sum of the
    /// origin offsets, so a root frame minus `shift` is a frame of `file`.
    private struct Part {
        let file: FileID
        let shift: Frames
        let root: Range<Frames>
        let first: Int
    }

    /// The distinct file spans of `clips`. Each clip plays the root range of its file range
    /// `offset ..< offset + length` (decision 0057 D11). Root ranges merge per root file when they
    /// touch or overlap, in the timeline order of the first clip of each merged range. Each root
    /// frame reads from the file of the first clip in timeline order that plays it, so a render and
    /// its root never both give a frame. A gap between clips gives no span, and a duplicated
    /// region gives one.
    init(clips: some Sequence<Clip>, session: Session) {
        var groups: [FileID: [Part]] = [:]
        for (index, clip) in clips.sorted(by: { $0.start < $1.start }).enumerated() {
            let chain = session.origins(ofFile: clip.file)
            let shift = chain.reduce(Frames.zero) { $0 + $1.offset }
            let root = (clip.offset + shift)..<(clip.offset + clip.length + shift)
            groups[chain.last?.source ?? clip.file, default: []].append(
                Part(file: clip.file, shift: shift, root: root, first: index))
        }
        var merged: [(parts: [Part], first: Int)] = []
        for parts in groups.values {
            var current: (parts: [Part], end: Frames, first: Int)?
            for part in parts.sorted(by: { $0.root.lowerBound < $1.root.lowerBound }) {
                if let last = current, part.root.lowerBound <= last.end {
                    current = (last.parts + [part], max(last.end, part.root.upperBound), min(last.first, part.first))
                } else {
                    if let last = current { merged.append((last.parts, last.first)) }
                    current = ([part], part.root.upperBound, part.first)
                }
            }
            if let last = current { merged.append((last.parts, last.first)) }
        }
        var time = Frames.zero
        var spans: [Span] = []
        for range in merged.sorted(by: { $0.first < $1.first }) {
            for (part, root) in Self.readers(of: range.parts) {
                spans.append(
                    Span(
                        file: part.file, frames: (root.lowerBound - part.shift)..<(root.upperBound - part.shift),
                        time: time))
                time = time + (root.upperBound - root.lowerBound)
            }
        }
        self.spans = spans
        sampleRate = session.sampleRate
    }

    /// The root ranges of `parts`, which touch or overlap, each with the part that reads it: the
    /// part with the lowest `first` that holds the frame. Touching ranges of one file join, and the
    /// ranges come in root order, so the audio stays continuous.
    private static func readers(of parts: [Part]) -> [(part: Part, root: Range<Frames>)] {
        var owned: [(part: Part, root: Range<Frames>)] = []
        for part in parts.sorted(by: { $0.first < $1.first }) {
            var low = part.root.lowerBound
            for taken in owned.map(\.root).sorted(by: { $0.lowerBound < $1.lowerBound }) {
                guard taken.lowerBound < part.root.upperBound else { break }
                guard taken.upperBound > low else { continue }
                if taken.lowerBound > low { owned.append((part, low..<taken.lowerBound)) }
                low = taken.upperBound
            }
            if low < part.root.upperBound { owned.append((part, low..<part.root.upperBound)) }
        }
        var joined: [(part: Part, root: Range<Frames>)] = []
        for entry in owned.sorted(by: { $0.root.lowerBound < $1.root.lowerBound }) {
            if let last = joined.last, last.part.file == entry.part.file, last.root.upperBound == entry.root.lowerBound
            {
                joined[joined.count - 1].root = last.root.lowerBound..<entry.root.upperBound
            } else {
                joined.append(entry)
            }
        }
        return joined
    }

    /// The length of the concatenated audio.
    var length: Frames { spans.last.map { $0.time + ($0.frames.upperBound - $0.frames.lowerBound) } ?? .zero }

    /// The pieces of the concatenated audio, each at most 10 min (U24). Each cut before the end is
    /// `pause(at, window)` with `at` 2 s before the 10 min limit and a window of 2 s: the nearest
    /// pause of decision 0062, whose cut is in `at - window ..< at + window`, so inside the limit.
    func pieces(pause: (_ at: Frames, _ window: Frames) -> Frames) -> [Range<Frames>] {
        let limit = Frames(600 * sampleRate)
        let window = Frames(2 * sampleRate)
        var pieces: [Range<Frames>] = []
        var start = Frames.zero
        while length - start > limit {
            let cut = pause(start + limit - window, window)
            pieces.append(start..<cut)
            start = cut
        }
        if start < length { pieces.append(start..<length) }
        return pieces
    }

    /// The words of each piece of `ranges`, in ticks of 10 ms of piece time, as file words. A word
    /// goes to the span whose concatenated range holds its midpoint, clamped to that span. A word
    /// with end <= start, a word whose midpoint is in no span, and a word with no frame left after
    /// the clamp are dropped and counted as untimed.
    func fileWords(_ pieces: [[TimedWord]], in ranges: [Range<Frames>]) -> (words: FileWords, untimed: Int) {
        func frames(_ ticks: Int) -> Int { Int((Double(ticks) * Double(sampleRate) / 100).rounded()) }
        var words: [FileWords.Word] = []
        var untimed = 0
        for (piece, range) in zip(pieces, ranges) {
            for word in piece {
                // A range is formed only after this check: `start..<end` with start > end traps.
                guard word.end > word.start else {
                    untimed += 1
                    continue
                }
                let start = range.lowerBound.count + frames(word.start)
                let end = range.lowerBound.count + frames(word.end)
                let midpoint = Frames((start + end) / 2)
                guard
                    let span = spans.first(where: {
                        midpoint >= $0.time && midpoint < $0.time + ($0.frames.upperBound - $0.frames.lowerBound)
                    })
                else {
                    untimed += 1
                    continue
                }
                // start <= midpoint < end, and the span holds the midpoint, so low <= midpoint < high.
                let shift = span.frames.lowerBound.count - span.time.count
                let low = max(start + shift, span.frames.lowerBound.count)
                let high = min(end + shift, span.frames.upperBound.count)
                guard let mapped = FileWords.Word(file: span.file, range: Frames(low)..<Frames(high), text: word.text)
                else {
                    untimed += 1
                    continue
                }
                words.append(mapped)
            }
        }
        return (FileWords(words), untimed)
    }
}
