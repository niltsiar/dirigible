import Foundation

/// The shape of a duck (decision 0060): the music goes to `depth` over `attack` before each speech
/// run and comes back over `release` after it. `threshold` and `hold` are the detection values of
/// `speechRuns`. The CLI and the tool check each value at the boundary.
public struct DuckShape: Hashable, Sendable {
    /// A gain under 0 dB.
    public let depth: Gain
    public let attack: Frames
    public let release: Frames
    /// The 50 ms RMS level in dBFS over which a window is speech: under 0.
    public let threshold: Gain
    public let hold: Frames

    public init(depth: Gain, attack: Frames, release: Frames, threshold: Gain, hold: Frames) {
        (self.depth, self.attack, self.release, self.threshold, self.hold) = (depth, attack, release, threshold, hold)
    }

    /// The defaults of decision 0060 (U5 to U8): -16 dB, attack and release 1 s, -40 dBFS, hold 2 s.
    public static func defaults(sampleRate: Int) -> DuckShape {
        DuckShape(
            depth: Gain(dB: -16)!, attack: Frames(sampleRate), release: Frames(sampleRate),
            threshold: Gain(dB: -40)!, hold: Frames(2 * sampleRate))
    }

    /// A ramp of 0 frames is 1 frame, a step, as in a range gain.
    var attackRamp: Int { max(attack.count, 1) }
    var releaseRamp: Int { max(release.count, 1) }

    /// Two runs with a gap under this merge (U19), so two duck windows never overlap.
    var mergeGap: Frames { Frames(max(hold.count, attackRamp + releaseRamp)) }

    /// `runs` sorted, with each two runs whose gap is under `mergeGap` merged into one.
    public func merged(_ runs: [Range<Frames>]) -> [Range<Frames>] {
        var result: [Range<Frames>] = []
        for run in runs.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, run.lowerBound.count - last.upperBound.count < mergeGap.count {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, run.upperBound)
            } else {
                result.append(run)
            }
        }
        return result
    }
}

/// What a duck did: the merged speech runs, the clips whose envelope changed, the point count of
/// those envelopes, the clips that a run reaches whose envelope already is the duck, the clips of
/// the ducked tracks in the scope that no run reaches, and the speech files that did not read, so
/// their speech is not in the runs. Each music clip in the scope is in one clip list.
public struct DuckResult: Hashable, Sendable {
    public let runs: [Range<Frames>]
    public let ducked: [ClipID]
    public let points: Int
    public let unchanged: [ClipID]
    public let kept: [ClipID]
    public let unread: [FileID]
}

extension Session {
    /// The track lists of a duck (decision 0060, U20): `speech`, else the dialogue-role tracks;
    /// `music`, else the music-role tracks. There is no route fallback. The lists then pass
    /// `checkDuckLists`.
    public func duckTracks(speech: [TrackID], music: [TrackID]) throws(SessionError) -> (
        speech: [TrackID], music: [TrackID]
    ) {
        _ = try trackIndices(speech + music)
        let speech = speech.isEmpty ? tracks.filter { $0.role == .dialogue }.map(\.id) : speech
        let music = music.isEmpty ? tracks.filter { $0.role == .music }.map(\.id) : music
        try checkDuckLists(speech: speech, music: music)
        return (speech, music)
    }

    /// The list rule of a duck, with no role fallback: an unknown track, an empty list, or a track
    /// in both lists (the first in `music`) throws.
    public func checkDuckLists(speech: [TrackID], music: [TrackID]) throws(SessionError) {
        _ = try trackIndices(speech + music)
        guard !speech.isEmpty else { throw .noSpeechTrack }
        guard !music.isEmpty else { throw .noDuckedTrack }
        if let both = music.first(where: speech.contains) { throw .trackInBothDuckLists(both) }
    }

    /// The timeline frames that a duck in `range` reads (nil: the whole session): the range cut to
    /// the session end. A range that starts at or after the end throws `.duckRangePastEnd`.
    public func duckScope(_ range: Range<Frames>?) throws(SessionError) -> Range<Frames> {
        guard let range else { return .zero..<end }
        guard range.lowerBound < end else { throw .duckRangePastEnd(range, end: end) }
        return range.lowerBound..<min(range.upperBound, end)
    }

    /// Ducks the clips of `music` under the speech `runs`, in timeline frames, inside `scope` (nil:
    /// each whole clip) cut by `duckScope` (decision 0060). The runs merge by `shape.mergeGap`. The
    /// duck replaces the envelope inside the scope of each clip that a run, widened by the attack
    /// and the release, reaches, and keeps the points outside that scope; a clip that no run
    /// reaches keeps its envelope. It works on the file map of each clip, so a ramp goes on past a
    /// clip edge, and the edge rule fits it to the file. `unread` names the speech files that the
    /// read of `runs` could not read, for the result. No runs in the scope throws `.noSpeech`.
    /// A throw changes nothing.
    @discardableResult
    public mutating func duck(
        runs: [Range<Frames>], unread: [FileID] = [], shape: DuckShape, music: [TrackID], scope: Range<Frames>?
    ) throws(SessionError) -> DuckResult {
        let whole = try duckScope(scope)
        let runs = shape.merged(runs.map { $0.clamped(to: whole) })
        guard !runs.isEmpty else { throw .noSpeech(whole, threshold: shape.threshold.dB, unread: unread) }
        let indices = try trackIndices(music)
        let (attack, release) = (shape.attackRamp, shape.releaseRamp)
        // The corners of the duck function in timeline frames. The merge keeps two windows apart,
        // so only a corner of value 0 can repeat a frame.
        var corners: [(frame: Int, dB: Double)] = []
        for run in runs {
            let (start, end) = (run.lowerBound.count, run.upperBound.count)
            for corner in [(start - attack, 0), (start, shape.depth.dB), (end, shape.depth.dB), (end + release, 0)]
            where corners.last?.frame != corner.0 {
                corners.append(corner)
            }
        }
        var changed: [ClipID: GainEnvelope] = [:]
        var (ducked, unchanged, kept, points): ([ClipID], [ClipID], [ClipID], Int) = ([], [], [], 0)
        for index in indices {
            for clip in tracks[index].clips {
                let reach = clip.range.clamped(to: whole)
                guard !reach.isEmpty else { continue }
                let reached = runs.contains { run in
                    (Frames(run.lowerBound.count - attack)..<Frames(run.upperBound.count + release)).overlaps(reach)
                }
                guard reached else {
                    kept.append(clip.id)
                    continue
                }
                guard let file = files[clip.file] else { throw .unknownFile(clip.file) }
                let new = Self.ducked(
                    clip, in: reach,
                    rangeEdges: (
                        scope != nil && reach.lowerBound > clip.start, scope != nil && reach.upperBound < clip.end
                    ),
                    corners: corners, ramp: gainRamp.count, fileLength: file.length)
                guard new != clip.envelope else {
                    unchanged.append(clip.id)
                    continue
                }
                changed[clip.id] = new
                ducked.append(clip.id)
                points += new.points.count
            }
        }
        try setEnvelopes(changed)
        return DuckResult(
            runs: runs, ducked: ducked, points: points, unchanged: unchanged, kept: kept, unread: unread)
    }

    /// The new envelope of `clip`: the duck function inside `reach`, the timeline frames of its
    /// scope, and the old points outside it. At a scope edge inside the clip (`rangeEdges`), the old
    /// value joins the duck function over `ramp` frames inside the scope. At a clip edge, the
    /// nearest corner of the duck function past the edge keeps the played frames on the function;
    /// a kept point past the edge that is not on the function gets a point at the edge.
    private static func ducked(
        _ clip: Clip, in reach: Range<Frames>, rangeEdges: (low: Bool, high: Bool),
        corners timeline: [(frame: Int, dB: Double)], ramp: Int, fileLength: Frames
    ) -> GainEnvelope {
        let shift = clip.start.count - clip.offset.count
        let corners = timeline.map { (frame: $0.frame - shift, dB: $0.dB) }
        func duck(_ frame: Int) -> Double { GainEnvelope.value(of: corners.lazy.map { ($0.frame, $0.dB) }, at: frame) }
        let old = clip.envelope
        let (low, high) = (reach.lowerBound.count - shift, reach.upperBound.count - shift)
        let ramp = max(1, min(ramp, (high - low) / 2))
        let outside = old.points.filter { $0.frame.count < low || $0.frame.count >= high }
            .map { (frame: $0.frame.count, dB: $0.gain.dB) }
        // Of two corners on one frame, the first stays. So the old values at the range edges come
        // first: in a range of 1 frame, the ramp end of one edge is the other edge.
        var result: [(frame: Int, dB: Double)] = []
        var inner = low..<high
        if rangeEdges.low { result.append((low, old.gain(at: Frames(low)))) }
        if rangeEdges.high { result.append((high, old.gain(at: Frames(high)))) }
        if rangeEdges.low {
            result.append((low + ramp, duck(low + ramp)))
            inner = (low + ramp)..<inner.upperBound
        }
        if rangeEdges.high {
            result.append((high - ramp, duck(high - ramp)))
            inner = inner.lowerBound..<max(inner.lowerBound, high - ramp)
        }
        result += outside
        if !rangeEdges.low {
            let past = corners.last { $0.frame < low }
            let point = outside.last { $0.frame < low }
            if let past, point.map({ $0.frame < past.frame }) ?? true {
                result.append(past)
            } else if let point, point.dB != duck(point.frame) {
                result.append((low, duck(low)))
            }
        }
        if !rangeEdges.high {
            let past = corners.first { $0.frame >= high }
            let point = outside.first { $0.frame >= high }
            if let past, point.map({ $0.frame > past.frame }) ?? true {
                result.append(past)
            } else if let point, point.dB != duck(point.frame) {
                result.append((high, duck(high)))
            }
        }
        result += corners.filter { inner.contains($0.frame) }
        let unique = Dictionary(result.map { ($0.frame, $0.dB) }, uniquingKeysWith: { first, _ in first })
        return GainEnvelope.fitted(
            unique.sorted { $0.key < $1.key }.map { (frame: $0.key, dB: $0.value) }, fileLength: fileLength)
    }
}
