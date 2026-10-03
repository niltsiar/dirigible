import DirigibleCore
import Foundation

/// The zoom of a timeline (decision 0017). Window state, never saved.
public struct TimelineScale: Hashable, Sendable {
    public var framesPerPoint: Double

    public init(framesPerPoint: Double) { self.framesPerPoint = framesPerPoint }

    /// From the closest zoom, max(128, end / 2^23) frames per point (one 256-frame bin per 2 px
    /// at 2x; probe D6 drew 10.8 million points), to the fit of max(end, 10 s) + 2% over `width`.
    public static func limits(end: Frames, rate: Int, width: Double) -> ClosedRange<Double> {
        let closest = max(128, Double(end.count) / 8_388_608)
        let fit = Double(max(end.count, 10 * rate)) * 1.02 / max(1, width)
        return closest...max(closest, fit)
    }

    /// The scale times `factor`, clamped to `limits`, and the origin (the frame at the left edge)
    /// that keeps `anchor` at `x` points from the left edge. The origin is never before 0.
    public func zoomed(by factor: Double, anchor: Frames, at x: Double, limits: ClosedRange<Double>)
        -> (scale: TimelineScale, origin: Double)
    {
        let points = (framesPerPoint * factor).clamped(to: limits)
        return (TimelineScale(framesPerPoint: points), max(0, Double(anchor.count) - x * points))
    }

    /// Zoom to Session: 0 to the end + 2% (origin 0).
    public static func fit(end: Frames, width: Double, limits: ClosedRange<Double>) -> TimelineScale {
        TimelineScale(framesPerPoint: (Double(end.count) * 1.02 / max(1, width)).clamped(to: limits))
    }

    /// Zoom to Selection: the range with 5% of its length on each side.
    public static func fit(_ range: Range<Frames>, width: Double, limits: ClosedRange<Double>)
        -> (scale: TimelineScale, origin: Double)
    {
        let length = Double((range.upperBound - range.lowerBound).count)
        let margin = length * 0.05
        let points = ((length + 2 * margin) / max(1, width)).clamped(to: limits)
        return (TimelineScale(framesPerPoint: points), max(0, Double(range.lowerBound.count) - margin))
    }
}

extension Double {
    fileprivate func clamped(to limits: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, limits.lowerBound), limits.upperBound)
    }
}

/// The in point, the out point, and the selected tracks of a window (decision 0017). Window
/// state in `SessionWindow`, never in `Session`.
public struct Marks: Hashable, Sendable {
    public var inPoint: Frames?
    public var outPoint: Frames?
    public var tracks: Set<TrackID> = []

    public init(inPoint: Frames? = nil, outPoint: Frames? = nil, tracks: Set<TrackID> = []) {
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.tracks = tracks
    }

    /// The one read of the selection: nil unless in < out and at least one selected track exists
    /// in `session`. The tracks are in session order, so a track that an undo removed drops out.
    public func selection(in session: Session) -> (range: Range<Frames>, tracks: [TrackID])? {
        guard let inPoint, let outPoint, inPoint < outPoint else { return nil }
        let kept = session.tracks.map(\.id).filter(tracks.contains)
        return kept.isEmpty ? nil : (inPoint..<outPoint, kept)
    }

    /// A drag from the frame `from` to `to` over the lanes `lanes.0` through `lanes.1`, in any
    /// order. A lane past the last one counts as the last one.
    public static func drag(from: Frames, to: Frames, lanes: (Int, Int), in session: Session) -> Marks {
        let last = session.tracks.count - 1
        let low = max(0, min(lanes.0, lanes.1, last))
        let high = min(max(lanes.0, lanes.1), last)
        guard low <= high else { return Marks() }
        return Marks(
            inPoint: min(from, to), outPoint: max(from, to), tracks: Set(session.tracks[low...high].map(\.id)))
    }

    /// Shift-click: the range from the playhead to the click, and the lane joins the tracks.
    public func extended(to frame: Frames, lane: TrackID, playhead: Frames) -> Marks {
        Marks(inPoint: min(frame, playhead), outPoint: max(frame, playhead), tracks: tracks.union([lane]))
    }

    /// Shift-drag (mouse-edits criterion 10): the hull of the set points of both Marks, on the union
    /// of the tracks.
    public func extended(by other: Marks) -> Marks {
        let points = [inPoint, outPoint, other.inPoint, other.outPoint].compactMap { $0 }
        return Marks(inPoint: points.min(), outPoint: points.max(), tracks: tracks.union(other.tracks))
    }

    /// Command-click: the lane goes into or out of the tracks. With no tracks left, no Marks.
    public func toggled(_ track: TrackID) -> Marks {
        var marks = self
        if marks.tracks.remove(track) == nil { marks.tracks.insert(track) }
        return marks.tracks.isEmpty ? Marks() : marks
    }

    /// I: in at the playhead; an out at or before it goes. With no tracks, all tracks.
    public func settingIn(_ playhead: Frames, in session: Session) -> Marks {
        var marks = withTracks(of: session)
        marks.inPoint = playhead
        if let out = outPoint, out <= playhead { marks.outPoint = nil }
        return marks
    }

    /// O: out at the playhead; an in at or after it goes. With no tracks, all tracks.
    public func settingOut(_ playhead: Frames, in session: Session) -> Marks {
        var marks = withTracks(of: session)
        marks.outPoint = playhead
        if let point = inPoint, point >= playhead { marks.inPoint = nil }
        return marks
    }

    private func withTracks(of session: Session) -> Marks {
        var marks = self
        if marks.tracks.isEmpty { marks.tracks = Set(session.tracks.map(\.id)) }
        return marks
    }

    /// The tracks of a paste (decision 0018): the first selected track in session order and the
    /// tracks under it, one per lane of `excerpt`; with no selected track, the source tracks. When
    /// the tracks under it are too few, the list is short, and Core refuses the paste with
    /// `trackCount`, so the alert gives the count (code gate 1). Nil when a source track is gone.
    public func pasteTracks(for excerpt: Excerpt, in session: Session) -> [TrackID]? {
        let ids = session.tracks.map(\.id)
        guard let first = ids.firstIndex(where: tracks.contains) else {
            let sources = excerpt.lanes.map(\.source)
            return sources.allSatisfy(ids.contains) ? sources : nil
        }
        return Array(ids[first...].prefix(excerpt.lanes.count))
    }

    /// The frames and tracks of a split (decision 0018): with a selection, its in and out points on
    /// its tracks; else the playhead on the selected tracks, or on every track when none is
    /// selected.
    public func splitPoints(playhead: Frames, in session: Session) -> (frames: [Frames], tracks: [TrackID]) {
        if let selection = selection(in: session) {
            return ([selection.range.lowerBound, selection.range.upperBound], selection.tracks)
        }
        let all = session.tracks.map(\.id)
        let selected = all.filter(tracks.contains)
        return ([playhead], selected.isEmpty ? all : selected)
    }

    /// A nudge by `step` (decision 0018): the clips fully inside the selection, the offset that
    /// keeps every start at 0 or more, and the Marks moved by that offset (the in point not below
    /// 0). Nil when no clip moves.
    public func nudge(by step: Frames, in session: Session) -> (clips: [ClipID], offset: Frames, marks: Marks)? {
        guard let selection = selection(in: session) else { return nil }
        let range = selection.range
        let clips = selection.tracks.compactMap(session.track).flatMap { track in
            track.clips.filter { range.lowerBound <= $0.start && $0.end <= range.upperBound }
        }
        guard let first = clips.map(\.start).min() else { return nil }
        let offset = max(step, .zero - first)
        guard offset != .zero else { return nil }
        let marks = Marks(
            inPoint: max(.zero, range.lowerBound + offset), outPoint: range.upperBound + offset, tracks: tracks)
        return (clips.map(\.id), offset, marks)
    }

    /// The clips of Auto Level (decision 0031): each whole clip on a selected track whose range
    /// overlaps the selection. Nil with no selection.
    public func clipsToLevel(in session: Session) -> Set<ClipID>? {
        guard let selection = selection(in: session) else { return nil }
        let tracks = selection.tracks.compactMap(session.track)
        return Set(tracks.flatMap { $0.clips.filter { $0.range.overlaps(selection.range) }.map(\.id) })
    }

    /// The fades of Command-F (decision 0035) for each clip on a selected track that overlaps the
    /// selection. The range holds the clip start when in <= start, and the clip end when end <= out.
    /// Both: min(0.5 s, length / 2) at each end. The start only: a fade-in to the out point. The end
    /// only: a fade-out from the in point. An edge at a butt join (a lane neighbor touches it) gets
    /// no fade in 11a. The new fade wins, and the other fade yields. Nil with no selection or no
    /// change.
    public func fades(in session: Session) -> [ClipID: Fades]? {
        guard let selection = selection(in: session) else { return nil }
        let (low, high) = (selection.range.lowerBound, selection.range.upperBound)
        var result: [ClipID: Fades] = [:]
        for lane in selection.tracks.compactMap(session.track).map(\.clips) {
            for index in lane.indices where lane[index].range.overlaps(selection.range) {
                let clip = lane[index]
                let (start, end) = (low <= clip.start, clip.end <= high)
                let standard = min(Frames(session.sampleRate / 2), Frames(clip.length.count / 2))
                let joinBefore = index > lane.startIndex && lane[index - 1].end == clip.start
                let joinAfter = index + 1 < lane.endIndex && lane[index + 1].start == clip.end
                let fadeIn = start && !joinBefore ? (end ? standard : high - clip.start) : nil
                let fadeOut = end && !joinAfter ? (start ? standard : clip.end - low) : nil
                let fades: Fades
                switch (fadeIn, fadeOut) {
                case (let fadeIn?, let fadeOut?): fades = Fades(fadeIn: fadeIn, fadeOut: fadeOut)!
                case (let fadeIn?, nil):
                    fades = Fades(fadeIn: fadeIn, fadeOut: clip.fades.fadeOut)!.fitted(to: clip.length, keeping: .start)
                case (nil, let fadeOut?):
                    fades = Fades(fadeIn: clip.fades.fadeIn, fadeOut: fadeOut)!.fitted(to: clip.length, keeping: .end)
                case (nil, nil): continue
                }
                if fades != clip.fades { result[clip.id] = fades }
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Select All: 0 to the end on every track. An empty session gives no Marks.
    public static func all(in session: Session) -> Marks {
        session.end == .zero
            ? Marks() : Marks(inPoint: .zero, outPoint: session.end, tracks: Set(session.tracks.map(\.id)))
    }
}
