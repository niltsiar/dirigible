import Foundation

/// The lines of a drift fit that a fix applies (decision 0077 D7 to D9): one slope for the clip,
/// and one lag line for each piece. The lag at clip frame c of piece k is `lags[k] + slope x c`.
public struct DriftLines: Hashable, Sendable {
    /// Lag frames for each clip frame.
    public let slope: Double
    /// The lag of each piece at clip frame 0, in frames.
    public let lags: [Double]
    /// The clip frame of each cut between two pieces.
    public let cuts: [Frames]
    /// The source frames for each new file frame of a first fix: 1 / (1 + slope).
    public let ratio: DriftRatio

    /// Nil for a ratio out of the range of `DriftRatio`, a lag that is not finite or is more than
    /// `Frames.limit` from 0, cuts that do not ascend strictly from over 0 up to `Frames.limit`, or
    /// a lag count other than the cut count + 1.
    public init?(slope: Double, lags: [Double], cuts: [Frames]) {
        let limit = Double(Frames.limit.count)
        guard let ratio = DriftRatio(1 / (1 + slope)), lags.allSatisfy({ abs($0) <= limit }),
            lags.count == cuts.count + 1, zip([.zero] + cuts, cuts).allSatisfy({ $0 < $1 }),
            cuts.allSatisfy(\.isInRange)
        else { return nil }
        (self.slope, self.lags, self.cuts, self.ratio) = (slope, lags, cuts, ratio)
    }

    /// The ratio of a fix of a clip whose file has the drift link `first`: `ratio` times the ratio
    /// of `first` (decision 0077 D5). Nil when the product is out of the range of `DriftRatio`.
    public func ratio(after first: DriftOrigin?) -> DriftRatio? {
        guard let first else { return ratio }
        return DriftRatio(first.ratio.value * ratio.value)
    }
}

/// What a drift fix resamples (decision 0077 D5): the source, the source frames for each new file
/// frame, and the source frames of the new file of each piece, in piece order. New file frame 0 is
/// the first frame of its span.
public struct DriftPlan: Hashable, Sendable {
    public let source: FileID
    public let ratio: DriftRatio
    public let spans: [Range<Frames>]
}

/// A file that a drift fix wrote for one piece: its stem, its written length, and the gain that
/// the conversion returned.
public struct DriftFile: Hashable, Sendable {
    public let stem: String
    public let length: Frames
    public let gain: Gain

    public init(stem: String, length: Frames, gain: Gain) {
        (self.stem, self.length, self.gain) = (stem, length, gain)
    }
}

/// The result of a drift fix: the pieces of the clip in time order (the first keeps the clip ID),
/// the new file of each piece, and what the new places cut.
public struct DriftCorrection: Hashable, Sendable {
    public let clips: [ClipID]
    public let files: [FileID]
    public let cut: SyncCut
}

extension Session {
    /// The plan of a drift fix of `clip` with `lines` (decision 0077 D5). The source is the file
    /// that the clip plays, or the drift source of that file for a second fix, and the ratio is
    /// `lines.ratio(after:)` of the drift link of that file. Piece k is the clip frames between cut
    /// k - 1 and cut k. Its span is that range of the played file with the handles of `clipRuns`
    /// at a clip edge and 10 s at a cut, cut to the file, in source frames. It throws
    /// `.unknownClip`, `.frameOutsideClip` for a cut at or past the clip end, and `.invalidOrigin`
    /// for a ratio out of range or a source with a fault of `driftSourceFault(of:)`.
    public func driftPlan(of clip: ClipID, lines: DriftLines) throws(SessionError) -> DriftPlan {
        try driftFix(of: clip, lines: lines).plan
    }

    /// The drift fix of `clip` (decision 0077 D9) on a copy, so it is one undo entry. The clip splits
    /// at the cuts of `lines`, and each piece moves to the file of `files` with the same index, which
    /// the caller wrote from the span of `driftPlan` with the same arguments. Each new file gets the
    /// largest record length, up to its written length, whose last frame is in the source (the bound
    /// of D4). For the first clip frame c0 of piece k and its source frame f0, the piece plays from
    /// round((f0 - span start) / ratio) for round(length / `lines.ratio`) frames, up to the file end,
    /// and starts at round(clip start + c0 + lag k + slope x c0). Its gain is the clip gain without
    /// the gain of the first fix plus the returned gain, clamped to `Gain.range`; the drift link
    /// holds the difference of the new and that clip gain. The envelope and the ride move through
    /// the time map, the clips under the new range are cut, and a start under frame 0 cuts the head,
    /// as `sync` does. It throws the errors of `driftPlan`, `.frameOutOfRange` for a file count
    /// other than the piece count or a record with no frame, each refusal of `addDriftFile`, and
    /// each refusal of `check`. A throw changes nothing.
    @discardableResult
    public mutating func correctDrift(_ clip: ClipID, lines: DriftLines, files written: [DriftFile])
        throws(SessionError) -> DriftCorrection
    {
        let fix = try driftFix(of: clip, lines: lines)
        guard written.count == fix.plan.spans.count else { throw .frameOutOfRange }
        let old = fix.clip
        let base = old.gain.dB - (fix.first?.addedGain.dB ?? 0)
        let others = tracks[fix.track].clips.filter { $0.id != clip }
        var copy = self
        var taken = clipIDs
        var (placed, made, head) = ([ClipID](), [FileID](), Frames.zero)
        copy.tracks[fix.track].clips.remove(ids: [clip])
        for (k, file) in written.enumerated() {
            let (first, last, span) = (fix.edges[k], fix.edges[k + 1], fix.plan.spans[k])
            let gain = Gain(clamping: base + file.gain.dB)!
            let link = DriftOrigin(
                source: fix.plan.source, offset: span.lowerBound, ratio: fix.plan.ratio,
                addedGain: Gain(clamping: gain.dB - base)!)
            let length = Self.recordLength(of: link, written: file.length, sourceLength: fix.sourceLength)
            guard length > .zero else { throw .frameOutOfRange }
            let id = try copy.addDriftFile(stem: file.stem, length: length, drift: link, wordsFrom: old.file)
            let map = { (frame: Frames) in
                link.fileFrame(ofSource: fix.first?.sourceFrame(of: frame) ?? Double(frame.count)).count
            }
            let pieceID = k == 0 ? clip : Self.derivedID(of: clip, at: old.start + first, taken: &taken)
            var new = old.cut(to: (old.start + first)..<(old.start + last), id: pieceID)
            let start = Double((old.start + first).count) + lines.lags[k] + lines.slope * Double(first.count)
            new.start = Frames(Int(start.rounded()))
            new.file = id
            new.offset = Frames(map(new.offset))
            let played = Frames(Int((Double((last - first).count) / lines.ratio.value).rounded()))
            new.length = min(played, length - new.offset)
            new.gain = gain
            new.crossfades = .zero
            new.envelope = old.envelope.mapped(map, fileLength: length)
            new.ride = old.ride.mapped(map, fileLength: length)
            if new.start < .zero {
                guard new.end > .zero else { throw .frameOutOfRange }
                head = head + (.zero - new.start)
                new = new.cut(to: .zero..<new.end, id: pieceID)
            }
            try copy.check(new, on: copy.tracks[fix.track])
            copy.tracks[fix.track].clips.overwrite(with: new) { Self.derivedID(of: $0.id, at: $1, taken: &taken) }
            placed.append(pieceID)
            made.append(id)
        }
        let replaced = others.filter { old in
            guard let new = copy.clip(old.id)?.clip else { return true }
            return new.range != old.range || new.offset != old.offset
        }.map(\.id)
        self = copy
        return DriftCorrection(clips: placed, files: made, cut: SyncCut(head: head, replaced: replaced))
    }

    /// The plan of `driftPlan`, the source length, the clip and its track index, the drift link of
    /// the played file, and the clip frame of each piece edge: 0, the cuts, and the clip length.
    private func driftFix(of id: ClipID, lines: DriftLines) throws(SessionError)
        -> (plan: DriftPlan, sourceLength: Frames, clip: Clip, track: Int, first: DriftOrigin?, edges: [Frames])
    {
        let (track, index) = try position(of: id)
        let clip = tracks[track].clips[index]
        guard let played = files[clip.file] else { throw .unknownFile(clip.file) }
        if let cut = lines.cuts.last, cut >= clip.length { throw .frameOutsideClip(id, clip.start + cut) }
        let first = played.drift
        let source = first?.source ?? played.id
        guard driftSourceFault(of: source) == nil, let sourceLength = files[source]?.length,
            let ratio = lines.ratio(after: first)
        else { throw .invalidOrigin(played.id) }
        let edges = [.zero] + lines.cuts + [clip.length]
        let handle = Frames(10 * sampleRate)
        let spans = edges.indices.dropLast().map { k in
            let before = k == 0 ? max(handle, clip.crossfades.start.half) : handle
            let after = k == lines.cuts.count ? max(handle, clip.crossfades.end.half) : handle
            let low = max(.zero, clip.offset + edges[k] - before)
            let high = min(played.length, clip.offset + edges[k + 1] + after)
            guard let first else { return low..<high }
            let end = Frames(Int(first.sourceFrame(of: high).rounded(.up)))
            return Frames(Int(first.sourceFrame(of: low).rounded(.down)))..<min(sourceLength, end)
        }
        return (DriftPlan(source: source, ratio: ratio, spans: spans), sourceLength, clip, track, first, edges)
    }

    /// The largest length up to `written` whose last frame maps to a source frame up to
    /// `sourceLength`: the bound of `check(_:of:)` for a drift link. The converter writes up to 1
    /// frame past the exact length, so the record can be shorter than its file.
    private static func recordLength(of link: DriftOrigin, written: Frames, sourceLength: Frames) -> Frames {
        let fits = { (length: Int) in link.sourceFrame(of: Frames(length - 1)) <= Double(sourceLength.count) }
        let exact = Double((sourceLength - link.offset).count) / link.ratio.value
        var length = min(written.count, Int(exact.rounded(.down)) + 1)
        while length > 0, !fits(length) { length -= 1 }
        while length < written.count, fits(length + 1) { length += 1 }
        return Frames(length)
    }
}
