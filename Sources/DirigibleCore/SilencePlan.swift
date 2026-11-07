import Foundation

/// One row of a silence edit (decision 0066): the frames of a silence and what to do with them.
public struct SilenceEdit: Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        /// Cut the middle of the silence on every track, so `keep` frames stay.
        case shorten
        /// Lower the silence by 96 dB on the mute tracks, with 10 ms ramps inside it.
        case mute
        /// Add a marker at the middle of the silence.
        case mark(name: String)
    }

    public let range: Range<Frames>
    public let action: Action

    public init(range: Range<Frames>, action: Action) {
        self.range = range
        self.action = action
    }
}

/// The checked rows of one silence edit (decision 0066). It has no sample rate: the edited session
/// gives the default keep and the mute ramp, so a tool can check a plan before it opens a session.
public struct SilencePlan: Hashable, Sendable {
    /// Each payload is the 1-based number of the edit in the caller order.
    public enum Refusal: Error, Equatable {
        case outOfRange(Int)
        case overlap(Int)
        case keepOutOfRange
    }

    /// In the caller order. No two ranges overlap.
    public let edits: [SilenceEdit]
    /// The frames that a shorten keeps. Nil is 500 ms at the rate of the edited session.
    public let keep: Frames?

    /// Refuses a bound or a keep outside `0...Frames.limit`, and two ranges that overlap (the
    /// number of the later edit in the caller order). Two ranges that touch are accepted.
    public init(_ edits: [SilenceEdit], keep: Frames?) throws(Refusal) {
        if let keep, !keep.isInRange { throw .keepOutOfRange }
        if let bad = edits.firstIndex(where: { !$0.range.lowerBound.isInRange || !$0.range.upperBound.isInRange }) {
            throw .outOfRange(bad + 1)
        }
        let order = edits.indices.filter { !edits[$0].range.isEmpty }.sorted {
            (edits[$0].range.lowerBound, $0) < (edits[$1].range.lowerBound, $1)
        }
        var reach: Int?
        for index in order {
            if let previous = reach, edits[index].range.lowerBound < edits[previous].range.upperBound {
                throw .overlap(max(previous, index) + 1)
            }
            if reach.map({ edits[index].range.upperBound > edits[$0].range.upperBound }) ?? true { reach = index }
        }
        self.edits = edits
        self.keep = keep
    }

    /// The cut of a shorten of `silence`: its middle, with `keep / 2` frames (rounded down) kept at
    /// the start and the rest of `keep` at the end. Nil when the silence has `keep` frames or less.
    public static func cut(of silence: Range<Frames>, keep: Frames) -> Range<Frames>? {
        guard silence.upperBound - silence.lowerBound > keep else { return nil }
        let head = Frames(keep.count / 2)
        return (silence.lowerBound + head)..<(silence.upperBound - (keep - head))
    }

    /// The frames that a shorten keeps at `sampleRate`: `keep`, else 500 ms.
    public func keepFrames(sampleRate: Int) -> Frames { keep ?? Frames(sampleRate / 2) }

    /// True when a shorten of the plan cuts at least one frame at `sampleRate`. Only then is the
    /// plan a ripple (decision 0037): a shorten of `keep` frames or less changes nothing.
    public func removesFrames(sampleRate: Int) -> Bool {
        let keep = keepFrames(sampleRate: sampleRate)
        return edits.contains { $0.action == .shorten && Self.cut(of: $0.range, keep: keep) != nil }
    }
}

/// What one `Session.editSilences` call did.
public struct SilenceResult: Hashable, Sendable {
    /// The cut of each applied shorten, in plan order, in the frames of the session before the edit.
    public let cuts: [Range<Frames>]
    /// The new marker of each mark, in plan order.
    public let markers: [MarkerID]
    /// The sum of the cut lengths.
    public let removed: Frames
    /// The 1-based numbers of the edits with nothing to change: a shorten of `keep` frames or less,
    /// or a mute of 2 ramps or less.
    public let skipped: [Int]
}

/// Why a silence row starts as Mark in the window (decision 0066).
public enum SilenceWarning: Hashable, Sendable {
    /// The cut holds the anchor midpoint of a transcript word.
    case word
    /// A track outside the scan has a window over the threshold in the cut.
    case soundOutsideScan
}

extension Session {
    /// The mute ramp of a silence edit: 10 ms, and 1 frame at least, so the windows of two rows do
    /// not overlap.
    var silenceRamp: Frames { Frames(max(1, sampleRate / 100)) }

    /// Applies `plan` in one edit (decision 0066). First each mark and each mute at the plan frames,
    /// then one ripple delete of the cuts on all tracks, so Rule M moves the new markers too and the
    /// envelopes keep their file frames. A mute lowers `tracks` by 96 dB with its ramps inside the
    /// silence. A nil keep is 500 ms. An unknown track throws, and a throw changes nothing.
    @discardableResult
    public mutating func editSilences(_ plan: SilencePlan, muting tracks: [TrackID]) throws(SessionError)
        -> SilenceResult
    {
        _ = try trackIndices(tracks)
        let keep = plan.keepFrames(sampleRate: sampleRate)
        let ramp = silenceRamp
        let floor = Gain(dB: Gain.range.lowerBound)!
        var copy = self
        var (cuts, markers, skipped) = ([Range<Frames>](), [MarkerID](), [Int]())
        var mutes: [Range<Frames>] = []
        for (index, edit) in plan.edits.enumerated() {
            let (start, end) = (edit.range.lowerBound, edit.range.upperBound)
            switch edit.action {
            case .shorten:
                if let cut = SilencePlan.cut(of: edit.range, keep: keep) {
                    cuts.append(cut)
                } else {
                    skipped.append(index + 1)
                }
            case .mute:
                guard end - start > ramp + ramp else {
                    skipped.append(index + 1)
                    continue
                }
                mutes.append((start + ramp)..<(end - ramp))
            case .mark(let name):
                let id = MarkerID()
                try copy.setMarker(
                    Marker(id: id, name: name, position: Frames((start.count + end.count) / 2), kind: .marker))
                markers.append(id)
            }
        }
        try copy.changeGains(by: floor, in: mutes, on: tracks, ramp: ramp)
        try copy.rippleDelete(cuts, on: copy.tracks.map(\.id), naming: [])
        self = copy
        let removed = cuts.reduce(Frames.zero) { $0 + ($1.upperBound - $1.lowerBound) }
        return SilenceResult(cuts: cuts, markers: markers, removed: removed, skipped: skipped)
    }

    /// For each cut, the warnings of its row (decision 0066): `.word` when the cut holds the anchor
    /// midpoint of a word on any track, mapped through each clip whose file window holds it
    /// (decision 0055), and `.soundOutsideScan` when a window of `outside` over `threshold` meets
    /// the cut. It reads no audio.
    public func silenceEditWarnings(cuts: [Range<Frames>], outside: LevelSeries?, threshold: Gain)
        -> [Set<SilenceWarning>]
    {
        let midpoints = tracks.flatMap { track in
            shownAnchors(on: track).map { $0.clip.start + $0.anchor.midpoint - $0.file.lowerBound }
        }.sorted()
        let sound = outside?.runs(over: threshold) ?? []
        return cuts.map { cut in
            var warnings = Set<SilenceWarning>()
            let word = Self.first(in: midpoints) { $0 >= cut.lowerBound }
            if word < midpoints.endIndex, midpoints[word] < cut.upperBound { warnings.insert(.word) }
            let run = Self.first(in: sound) { $0.upperBound > cut.lowerBound }
            if run < sound.endIndex, sound[run].lowerBound < cut.upperBound { warnings.insert(.soundOutsideScan) }
            return warnings
        }
    }

    /// The index of the first element of `sorted` that passes `test`, by binary search; `test`
    /// fails on a prefix of `sorted` and passes on the rest.
    private static func first<T>(in sorted: [T], where test: (T) -> Bool) -> Int {
        var (low, high) = (0, sorted.count)
        while low < high {
            let middle = (low + high) / 2
            if test(sorted[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
