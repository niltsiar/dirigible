import Foundation

extension Session {
    /// The default ramp of a range gain: 500 ms (decision 0060).
    public var gainRamp: Frames { Frames(sampleRate / 2) }

    /// Sets the envelope of each clip in one pass over the lanes (decision 0060). Each clip passes
    /// `check`. An unknown ID throws `.unknownClip`. A throw changes nothing.
    package mutating func setEnvelopes(_ envelopes: [ClipID: GainEnvelope]) throws(SessionError) {
        var lanes = tracks
        var found = 0
        for track in lanes.indices {
            for index in lanes[track].clips.indices {
                guard let new = envelopes[lanes[track].clips[index].id] else { continue }
                var clip = lanes[track].clips[index]
                clip.envelope = new
                try check(clip, on: lanes[track])
                lanes[track].clips.replace(at: index, with: clip)
                found += 1
            }
        }
        if found < envelopes.count, let missing = envelopes.keys.sorted().first(where: { clip($0) == nil }) {
            throw .unknownClip(missing)
        }
        tracks = lanes
    }

    /// Replaces the points of the clip inside its window with `points`, whose keys are timeline
    /// frames, and keeps the points outside the window (decision 0060). An empty map clears the
    /// window. A frame outside the clip throws `.pointOutsideClip`.
    public mutating func setEnvelope(_ points: [Frames: Gain], clip id: ClipID) throws(SessionError) {
        guard let clip = clip(id)?.clip else { throw .unknownClip(id) }
        if let outside = points.keys.sorted().first(where: { !clip.range.contains($0) }) {
            throw .pointOutsideClip(id, outside, clip.range)
        }
        let window = clip.offset..<(clip.offset + clip.length)
        let kept = clip.envelope.points.filter { !window.contains($0.frame) }
        let new = points.map { GainEnvelope.Point(frame: $0.key - clip.start + clip.offset, gain: $0.value) }
        try setEnvelopes([id: GainEnvelope(valid: (kept + new).sorted { $0.frame < $1.frame })])
    }

    /// Adds `gain` to the envelope of each clip of `tracks` that plays a frame of `range` or of its
    /// ramps, and returns the IDs of the changed clips (decision 0060). The window is 1 in `range`
    /// and falls to 0 over `ramp` frames on each side outside it; a ramp of 0 frames is 1 frame,
    /// a step. The sum works on the file map of each clip, so it goes on past the clip edges, and
    /// the edge rule fits it to the file. A gain of 0 dB or an empty range changes nothing. An
    /// unknown track, or a bound or a ramp outside `0...Frames.limit` (`.frameOutOfRange`), throws
    /// before a change.
    @discardableResult
    public mutating func changeGain(by gain: Gain, in range: Range<Frames>, on tracks: [TrackID], ramp: Frames)
        throws(SessionError) -> [ClipID]
    {
        guard range.lowerBound.isInRange, range.upperBound.isInRange, ramp.isInRange else { throw .frameOutOfRange }
        let indices = try trackIndices(tracks)
        guard gain != .zero, !range.isEmpty else { return [] }
        let ramp = max(ramp.count, 1)
        let (low, high) = (range.lowerBound.count, range.upperBound.count - 1)
        // The timeline frames where the window is more than 0.
        let reach = Frames(low - ramp + 1)..<Frames(high + ramp)
        var changed: [ClipID: GainEnvelope] = [:]
        var order: [ClipID] = []
        for index in indices {
            for clip in self.tracks[index].clips where clip.soundingRange.overlaps(reach) {
                let shift = clip.start.count - clip.offset.count
                let window = [(low - ramp, 0.0), (low, 1), (high, 1), (high + ramp, 0)].map { ($0.0 - shift, $0.1) }
                var weights = Dictionary(window, uniquingKeysWith: { first, _ in first })
                for point in clip.envelope.points where weights[point.frame.count] == nil {
                    weights[point.frame.count] = Self.weight(at: point.frame.count, window)
                }
                let corners = weights.sorted { $0.key < $1.key }.map { frame, weight in
                    (frame: frame, dB: clip.envelope.gain(at: Frames(frame)) + gain.dB * weight)
                }
                guard let file = files[clip.file] else { throw .unknownFile(clip.file) }
                let new = GainEnvelope.fitted(corners, fileLength: file.length)
                if new != clip.envelope {
                    changed[clip.id] = new
                    order.append(clip.id)
                }
            }
        }
        try setEnvelopes(changed)
        return order
    }

    /// The window of a range gain at `frame`: linear between its four corners, whose frames
    /// ascend, and 0 outside them.
    private static func weight(at frame: Int, _ corners: [(Int, Double)]) -> Double {
        guard let next = corners.firstIndex(where: { $0.0 > frame }), next > 0 else { return 0 }
        let ((f0, w0), (f1, w1)) = (corners[next - 1], corners[next])
        return w0 + (w1 - w0) * Double(frame - f0) / Double(f1 - f0)
    }
}
