import DirigibleCore
import Foundation

/// A point of the timeline in document points, tagged with its view, so a ruler y never reaches
/// a lane test (decision 0020).
public enum Place: Equatable, Sendable {
    case lanes(x: Double, y: Double)
    case ruler(x: Double, y: Double)
}

/// A box in document points. `CGRect` has no geometry functions without CoreGraphics, which this
/// module does not import.
public struct Rect: Equatable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }

    func contains(_ x: Double, _ y: Double) -> Bool { x >= minX && x < maxX && y >= minY && y < maxY }
}

/// The one conversion between document points and frames, for the hit test and the drawing
/// (decision 0020): the lanes, the ruler, and `LaneRenderer` draw with it.
public struct LaneGeometry: Equatable, Sendable {
    public let scale: TimelineScale
    /// Points.
    public let laneHeight: Double

    /// Nil unless the frames per point and the lane height are more than 0.
    public init?(scale: TimelineScale, laneHeight: Double) {
        guard scale.framesPerPoint > 0, laneHeight > 0 else { return nil }
        (self.scale, self.laneHeight) = (scale, laneHeight)
    }

    /// The frame at `x`; an x before 0 gives frame 0.
    public func frame(at x: Double) -> Frames { Frames(Int(max(0, x) * scale.framesPerPoint)) }

    public func x(of frame: Frames) -> Double { Double(frame.count) / scale.framesPerPoint }

    /// The box of `clip` in lane `lane`: the box that the lanes draw and that the hit test reads.
    public func box(of clip: Clip, lane: Int) -> Rect {
        Rect(
            x: x(of: clip.start), y: Double(lane) * laneHeight, width: Double(clip.length.count) / scale.framesPerPoint,
            height: laneHeight)
    }

    /// The lane that holds `y`. Internal: no public API gives a lane index.
    func lane(at y: Double) -> Int { Int((max(0, y) / laneHeight).rounded(.down)) }

    /// The lanes of `count` lanes that are in view between the document y `top` and `bottom`: a
    /// lane is in view when half of its height or more shows (timeline-clarity U-a5).
    public func lanesInView(top: Double, bottom: Double, count: Int) -> Range<Int> {
        func shows(_ lane: Int) -> Bool {
            min(bottom, Double(lane + 1) * laneHeight) - max(top, Double(lane) * laneHeight) >= laneHeight / 2
        }
        var (first, end) = (lane(at: top), min(count, lane(at: bottom) + 1))
        if first < end, !shows(first) { first += 1 }
        if first < end, !shows(end - 1) { end -= 1 }
        return first..<max(first, end)
    }

    /// The highest New Track zone (points) at the bottom of the lanes in view (run 13c).
    private static let newTrackZone = 32.0

    /// The top of the New Track zone: the end of the last lane, or, when the lanes reach the view
    /// bottom `bottom`, min(`newTrackZone`, half a lane) above it. The zone is at most half a lane
    /// high, so each lane fully in view keeps at least half its height as a target.
    public func newTrackTop(lanes: Int, bottom: Double) -> Double {
        min(Double(lanes) * laneHeight, bottom - min(Self.newTrackZone, laneHeight / 2))
    }

    /// The import target of a drop of `files` files at the lane point `x`, `y` (run 13c): the frame
    /// under the pointer, and the track of the lane for one file. A drop of 2 or more files, or a
    /// drop at or under `newTrackTop`, goes to new tracks (a nil track).
    public func dropTarget(x: Double, y: Double, files: Int, bottom: Double, in session: Session) -> ImportTarget {
        let lane = lane(at: y)
        let newTrack =
            files > 1 || y >= newTrackTop(lanes: session.tracks.count, bottom: bottom) || lane >= session.tracks.count
        return ImportTarget(track: newTrack ? nil : session.tracks[lane].id, start: frame(at: x))
    }

    /// The shortest clip that a trim leaves: 1 pt at this zoom, and at least 1 frame (a clip under
    /// 1 pt cannot be seen or hit again; settled Q4 of the mouse-edits run).
    var trimMinimum: Frames { Frames(max(1, Int(scale.framesPerPoint))) }

    /// The narrowest clip box (points) that a move or a trim can grab, and that gives snap targets
    /// (decision 0020): a narrower clip cannot be seen at the zoom.
    public static let grabWidth = 12.0
    /// The narrowest clip box (points) that draws and hits the gain line and the fade handles.
    public static let controlsWidth = 40.0
    /// The side of a fade handle (points).
    public static let handleSize = 8.0
    /// The height of the upper part of a clip box (points): the part that moves and slips. Below it
    /// the box is a range, with every control there, for the plain and the Shift-Command press.
    var moveHeight: Double { laneHeight * 2 / 3 }
    /// The gain band: the points above and below the gain line.
    static let gainReach = 3.0
    /// The width of a trim zone inside each clip edge (points).
    static let trimReach = 4.0

    /// The fraction of the lane height of a 0 dBFS signal at `dB` on the -60 dB to 0 dB scale of
    /// the waveform (decision 0017). `LaneRenderer` draws with it, so the line and the waveform agree.
    public static func gainFraction(dB: Double) -> Double { min(max((dB + 60) / 60, 0), 1) }

    /// The y of the gain line of `clip` in `lane`: the top of a 0 dBFS signal with the clip gain
    /// and the track gain: the lane height times 1 - `gainFraction` under the lane top. Over 0 dB
    /// the line stays at the lane top. The product comes first, so a whole dB gives an exact y.
    public func gainLineY(_ clip: Clip, trackGain: Gain, lane: Int) -> Double {
        lineY(gain: clip.gain.dB + trackGain.dB, lane: lane)
    }

    /// The y of the gain line of `clip` at the document x `x`: the line of `gainLineY` plus the
    /// gain of the envelope at the file frame under `x` (decision 0060).
    func gainLineY(_ clip: Clip, trackGain: Gain, lane: Int, atX x: Double) -> Double {
        let envelope = clip.envelope.isEmpty ? 0 : clip.envelope.gain(at: clip.offset + (frame(at: x) - clip.start))
        return lineY(gain: clip.gain.dB + trackGain.dB + envelope, lane: lane)
    }

    private func lineY(gain: Double, lane: Int) -> Double {
        Double(lane) * laneHeight + laneHeight * min(max(-gain, 0), 60) / 60
    }

    /// A point of the envelope of a clip as the lanes show it: the index in `Clip.envelope.points`
    /// and the center of its disc, in document points.
    public struct EnvelopePoint: Equatable, Sendable {
        public let index: Int
        public let x, y: Double
    }

    /// The radius of the disc of an envelope point (points).
    public static let pointRadius = 3.0
    /// The room that a point needs: no point shows within this distance of another point or of a fade
    /// handle (points).
    static let pointClearance = 8.0
    /// A press within this distance of the center of a shown point (points) hits the point.
    static let pointReach = 5.0
    /// The line of an envelope clip stays this far under the top of the box, and a point this far
    /// from the top and the bottom (points).
    public static let lineClamp = 3.0

    /// The points of the envelope of the clip at `clipIndex` of `clips` in `lane` that the lanes
    /// draw and the hit test finds, in order: the points inside the clip window, in a box of
    /// `controlsWidth` or more, with no other point of the window and no fade handle within
    /// `pointClearance` (decision 0060). The center is at least `lineClamp` from the box top and bottom,
    /// so the disc stays in its lane.
    public func envelopePoints(of clip: Clip, at clipIndex: Int, in clips: ClipLane, trackGain: Gain, lane: Int)
        -> [EnvelopePoint]
    {
        let box = box(of: clip, lane: lane)
        let window = clip.offset..<(clip.offset + clip.length)
        guard box.width >= Self.controlsWidth, case let inside = clip.envelope.points(in: window), !inside.isEmpty
        else { return [] }
        let handles = fadeHandles(of: clip, at: clipIndex, in: clips, lane: lane)
        let handleXs = [handles.start, handles.end].compactMap { $0.map { $0.minX + $0.width / 2 } }
        let xs = inside.map { box.minX + x(of: $0.frame - clip.offset) }
        var shown: [EnvelopePoint] = []
        for (n, point) in inside.enumerated() {
            let x = xs[n]
            let crowded =
                (n > 0 && x - xs[n - 1] < Self.pointClearance)
                || (n + 1 < xs.count && xs[n + 1] - x < Self.pointClearance)
                || handleXs.contains { abs($0 - x) < Self.pointClearance }
            guard !crowded else { continue }
            let y = lineY(gain: clip.gain.dB + trackGain.dB + point.gain.dB, lane: lane)
            shown.append(
                EnvelopePoint(
                    index: inside.startIndex + n, x: x,
                    y: min(max(y, box.minY + Self.lineClamp), box.maxY - Self.lineClamp)))
        }
        return shown
    }

    /// Whether an edge with `fade` frames of fade and a crossfade of `crossfade` frames has a
    /// handle: an edge at a butt join with no fade and no crossfade has none (decisions 0035 and
    /// 0036). `fadeHandles` and `changedFrames` read it.
    static func hasHandle(fade: Frames, crossfade: Frames, joined: Bool) -> Bool {
        fade > .zero || crossfade > .zero || !joined
    }

    /// The fade handles of the clip at `index` of `clips` in `lane`: a square at the top of the
    /// box, centered on the fade end or on the end of the crossfade half, and kept inside the box.
    /// Nil in a box under `controlsWidth`, and nil for an edge at a butt join with no fade and no
    /// crossfade (decisions 0035 and 0036).
    public func fadeHandles(of clip: Clip, at index: Int, in clips: ClipLane, lane: Int) -> (start: Rect?, end: Rect?) {
        let box = box(of: clip, lane: lane)
        guard box.width >= Self.controlsWidth else { return (nil, nil) }
        let joins = clips.joins(at: index)
        func handle(_ edge: Edge, _ joined: Bool) -> Rect? {
            guard Self.hasHandle(fade: clip.fades[edge], crossfade: clip.crossfades[edge], joined: joined) else {
                return nil
            }
            let end = edge == .start ? box.minX + x(of: clip.reach(.start)) : box.maxX - x(of: clip.reach(.end))
            let x = min(max(end - Self.handleSize / 2, box.minX), box.maxX - Self.handleSize)
            return Rect(x: x, y: box.minY, width: Self.handleSize, height: Self.handleSize)
        }
        return (handle(.start, joins.before), handle(.end, joins.after))
    }

    /// The zone under a lane point (mouse-edits criterion 1, run 11b-1). On a clip, in this order:
    /// a fade handle, a shown envelope point (the nearest within `pointReach`; before the trim zones,
    /// so a point at a clip edge can be grabbed), 4 pt inside each edge trims, the gain band (3 pt around the gain line, at
    /// least 3 pt under the box top, between the fades and the crossfade halves), the upper two
    /// thirds moves, and the lower third is a range. The handles and the band need a box of
    /// `controlsWidth`. A box under 12 pt is all range, so a small drag at fit zoom cannot move a
    /// clip that the user cannot see.
    func hit(_ x: Double, _ y: Double, in session: Session) -> LaneHit {
        let lane = lane(at: y)
        guard lane < session.tracks.count else { return .range(lane: nil) }
        let track = session.tracks[lane]
        guard let index = track.clips.index(holding: frame(at: x)) else { return .range(lane: lane) }
        let clip = track.clips[index]
        let box = box(of: clip, lane: lane)
        guard box.width >= Self.grabWidth else { return .range(lane: lane) }
        let handles = fadeHandles(of: clip, at: index, in: track.clips, lane: lane)
        switch (
            handles.start.flatMap { $0.contains(x, y) ? $0 : nil }, handles.end.flatMap { $0.contains(x, y) ? $0 : nil }
        ) {
        case (let start?, let end?):
            // Two handles that overlap split the overlap at its midpoint.
            return .fade(clip, x < (end.minX + start.maxX) / 2 ? .start : .end, lane: lane)
        case (.some, nil): return .fade(clip, .start, lane: lane)
        case (nil, .some): return .fade(clip, .end, lane: lane)
        case (nil, nil): break
        }
        let point = envelopePoints(of: clip, at: index, in: track.clips, trackGain: track.gain, lane: lane)
            .map { ($0, hypot(x - $0.x, y - $0.y)) }.filter { $0.1 <= Self.pointReach }.min { $0.1 < $1.1 }
        if let point { return .point(clip, index: point.0.index, lane: lane) }
        if x - box.minX < Self.trimReach { return .trim(clip, .start, lane: lane) }
        if box.maxX - x < Self.trimReach { return .trim(clip, .end, lane: lane) }
        if box.width >= Self.controlsWidth {
            let line = max(gainLineY(clip, trackGain: track.gain, lane: lane, atX: x), box.minY + Self.lineClamp)
            // Two comparisons, not a range: when the fades fill the clip, the two ends come from two
            // float paths, and the fade-in end can be 1 ulp over the fade-out start (code gate K1).
            let (fadeInEnd, fadeOutStart) = (
                box.minX + self.x(of: clip.reach(.start)), box.maxX - self.x(of: clip.reach(.end))
            )
            if abs(y - line) <= Self.gainReach, x >= fadeInEnd, x <= fadeOutStart { return .gain(clip, lane: lane) }
        }
        return y - box.minY < moveHeight ? .move(clip, lane: lane) : .range(lane: lane)
    }
}

/// The edge of a clip: one enum for the trim and the fades.
typealias Edge = Fades.Edge

/// The zone of a lane point. `lane` nil: under the last lane.
enum LaneHit: Equatable, Sendable {
    case trim(Clip, Edge, lane: Int)
    case move(Clip, lane: Int)
    case gain(Clip, lane: Int)
    case fade(Clip, Edge, lane: Int)
    /// A point of the envelope of the clip: its index in `Clip.envelope.points`.
    case point(Clip, index: Int, lane: Int)
    case range(lane: Int?)

    var lane: Int? {
        switch self {
        case .trim(_, _, let lane), .move(_, let lane), .gain(_, let lane), .fade(_, _, let lane),
            .point(_, _, let lane):
            lane
        case .range(let lane): lane
        }
    }

    /// The clip of a clip zone.
    var clip: Clip? {
        switch self {
        case .trim(let clip, _, _), .move(let clip, _), .gain(let clip, _), .fade(let clip, _, _),
            .point(let clip, _, _):
            clip
        case .range: nil
        }
    }

    /// The cursor over the zone, with no gesture. Under the last lane it is the arrow of the clip view.
    var cursor: TimelineCursor {
        switch self {
        case .trim, .fade: .resizeLeftRight
        case .gain: .resizeUpDown
        case .move, .range(lane: nil): .arrow
        case .point: .openHand
        case .range: .iBeam
        }
    }
}

/// The in point or the out point of the Marks.
enum MarkPoint: Equatable, Sendable { case inPoint, outPoint }

/// The target of a ruler point: a triangle of the Marks, a flag, or the time area (a seek).
enum RulerHit: Equatable, Sendable {
    case triangle(MarkPoint)
    case flag(MarkerID)
    case time(Frames)

    var cursor: TimelineCursor {
        switch self {
        case .triangle, .flag: .resizeLeftRight
        case .time: .arrow
        }
    }
}

/// The ruler constants that the ruler draws with and the hit test reads (decision 0020). The
/// ruler is flipped: y 0 is its top.
public enum RulerGeometry {
    public static let thickness = 24.0
    /// The in and out triangles: the bottom 8 pt.
    public static let triangleBand = 16.0...24.0
    public static let triangleHalfWidth = 5.0
    /// A flag: its 1 pt line at the position and its 6 pt box right of it.
    public static let flagReach = -3.0...6.0

    /// The target at the document x `x` and the ruler y `y`: a triangle first, then the nearest flag
    /// (at a tie a marker before a chapter, then the lower ID), else the time area. Nil left of
    /// the lanes (the corner over the track headers).
    static func hit(
        _ x: Double, _ y: Double, markers: [MarkerID: Marker], marks: Marks, geometry: LaneGeometry
    ) -> RulerHit? {
        guard x >= 0 else { return nil }
        if triangleBand.contains(y) {
            let near = [(MarkPoint.inPoint, marks.inPoint), (.outPoint, marks.outPoint)]
                .compactMap { point, frame in frame.map { (point, abs(x - geometry.x(of: $0))) } }
                .filter { $0.1 <= triangleHalfWidth }
                .min { $0.1 < $1.1 }
            if let near { return .triangle(near.0) }
        }
        let flag = markers.values
            .filter { flagReach.contains(x - geometry.x(of: $0.position)) }
            .min { a, b in
                let (da, db) = (abs(x - geometry.x(of: a.position)), abs(x - geometry.x(of: b.position)))
                if da != db { return da < db }
                if a.kind != b.kind { return a.kind == .marker }
                return a.id < b.id
            }
        if let flag { return .flag(flag.id) }
        return .time(geometry.frame(at: x))
    }
}

/// The cursor kinds of the timeline (probe C1: all exist at the macOS 14 target). The views map
/// them to `NSCursor`.
public enum TimelineCursor: Equatable, Sendable {
    case arrow, iBeam, openHand, closedHand, resizeLeftRight, resizeUpDown
    /// An Option press or drag on a trim zone of this edge (decision 0037).
    case rippleTrim(Fades.Edge)
}

/// The deltas that an edge of `clip` can take in a ripple trim (decision 0037): the limits of
/// `trimLimits` with no neighbor term. The start of its file (the offset only: the clip start
/// stays, so frame 0 does not limit it), the end of its file, `Frames.limit` for its end, and a
/// length of `minimum` or of half the crossfade at the other edge, the larger. The range always
/// holds 0.
func rippleTrimLimits(_ clip: Clip, edge: Edge, fileLength: Frames, minimum: Frames) -> ClosedRange<Frames> {
    let other = edge == .start ? clip.crossfades.end : clip.crossfades.start
    let shortest = clip.length - max(minimum, Frames(other.count / 2))
    switch edge {
    case .start: return min(.zero, .zero - clip.offset)...max(.zero, shortest)
    case .end:
        let longest = min(fileLength - clip.offset - clip.length, .limit - clip.end)
        return min(.zero, .zero - shortest)...max(.zero, longest)
    }
}

/// The frames that an edge of `clip` can reach in a trim (mouse-edits criterion 6): the neighbor
/// in `lane`, the start or the end of its file (`fileLength` frames), frame 0, `Frames.limit`, and
/// a length of `minimum` or of half the crossfade at the other edge, the larger (decision 0036).
/// The range always holds the current edge, so it is never empty.
func trimLimits(_ clip: Clip, edge: Edge, in lane: ClipLane, fileLength: Frames, minimum: Frames)
    -> ClosedRange<Frames>
{
    let index = lane.firstIndex { $0.id == clip.id }
    switch edge {
    case .start:
        let previous = index.flatMap { $0 > lane.startIndex ? lane[$0 - 1].end : nil } ?? .zero
        let low = max(previous, clip.start - clip.offset, .zero)
        return min(low, clip.start)...max(clip.start, clip.end - max(minimum, Frames(clip.crossfades.end.count / 2)))
    case .end:
        let next = index.flatMap { $0 + 1 < lane.endIndex ? lane[$0 + 1].start : nil } ?? .limit
        let high = min(next, clip.start + fileLength - clip.offset, .limit)
        return min(clip.end, clip.start + max(minimum, Frames(clip.crossfades.start.count / 2)))...max(clip.end, high)
    }
}
