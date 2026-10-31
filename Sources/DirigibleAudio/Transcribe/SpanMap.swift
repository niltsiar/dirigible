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

    /// The distinct file spans of `clips`: the file range `offset ..< offset + length` of each clip,
    /// merged per file when ranges touch or overlap, in the timeline order of the first clip of
    /// each span. A gap between clips gives no span, and a duplicated region gives one.
    init(clips: some Sequence<Clip>, sampleRate: Int) {
        var merged: [(file: FileID, frames: Range<Frames>, first: Int)] = []
        let ordered = clips.sorted { $0.start < $1.start }.enumerated()
        for (file, group) in Dictionary(grouping: ordered, by: \.element.file) {
            let ranges = group.map {
                (frames: $0.element.offset..<($0.element.offset + $0.element.length), first: $0.offset)
            }
            var current: (frames: Range<Frames>, first: Int)?
            for range in ranges.sorted(by: { $0.frames.lowerBound < $1.frames.lowerBound }) {
                if let last = current, range.frames.lowerBound <= last.frames.upperBound {
                    let end = max(last.frames.upperBound, range.frames.upperBound)
                    current = (last.frames.lowerBound..<end, min(last.first, range.first))
                } else {
                    if let last = current { merged.append((file, last.frames, last.first)) }
                    current = range
                }
            }
            if let last = current { merged.append((file, last.frames, last.first)) }
        }
        var time = Frames.zero
        spans = merged.sorted { $0.first < $1.first }.map { span in
            defer { time = time + (span.frames.upperBound - span.frames.lowerBound) }
            return Span(file: span.file, frames: span.frames, time: time)
        }
        self.sampleRate = sampleRate
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
