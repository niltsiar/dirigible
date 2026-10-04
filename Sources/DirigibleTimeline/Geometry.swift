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

    /// The shortest clip that a trim leaves: 1 pt at this zoom, and at least 1 frame (a clip under
    /// 1 pt cannot be seen or hit again; settled Q4 of the mouse-edits run).
    var trimMinimum: Frames { Frames(max(1, Int(scale.framesPerPoint))) }

    /// The narrowest clip box (points) that draws and hits the gain line and the fade handles.
    public static let controlsWidth = 40.0
    /// The side of a fade handle (points).
    public static let handleSize = 8.0
    /// The gain band: the points above and below the gain line.
    static let gainReach = 3.0

    /// The fraction of the lane height of a 0 dBFS signal at `dB` on the -60 dB to 0 dB scale of
    /// the waveform (decision 0017). `LaneRenderer` draws with it, so the line and the waveform agree.
    public static func gainFraction(dB: Double) -> Double { min(max((dB + 60) / 60, 0), 1) }

    /// The y of the gain line of `clip` in `lane`: the top of a 0 dBFS signal with the clip gain
    /// and the track gain: the lane height times 1 - `gainFraction` under the lane top. Over 0 dB
    /// the line stays at the lane top. The product comes first, so a whole dB gives an exact y.
    public func gainLineY(_ clip: Clip, trackGain: Gain, lane: Int) -> Double {
        Double(lane) * laneHeight + laneHeight * min(max(-(clip.gain.dB + trackGain.dB), 0), 60) / 60
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
    /// a fade handle, 4 pt inside each edge trims, the gain band (3 pt around the gain line, at
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
        let (box, smallest, trim) = (box(of: clip, lane: lane), 12.0, 4.0)
        guard box.width >= smallest else { return .range(lane: lane) }
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
        if x - box.minX < trim { return .trim(clip, .start, lane: lane) }
        if box.maxX - x < trim { return .trim(clip, .end, lane: lane) }
        if box.width >= Self.controlsWidth {
            let line = max(gainLineY(clip, trackGain: track.gain, lane: lane), box.minY + Self.gainReach)
            // Two comparisons, not a range: when the fades fill the clip, the two ends come from two
            // float paths, and the fade-in end can be 1 ulp over the fade-out start (code gate K1).
            let (fadeInEnd, fadeOutStart) = (
                box.minX + self.x(of: clip.reach(.start)), box.maxX - self.x(of: clip.reach(.end))
            )
            if abs(y - line) <= Self.gainReach, x >= fadeInEnd, x <= fadeOutStart { return .gain(clip, lane: lane) }
        }
        return y - box.minY < laneHeight * 2 / 3 ? .move(clip, lane: lane) : .range(lane: lane)
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
    case range(lane: Int?)

    var lane: Int? {
        switch self {
        case .trim(_, _, let lane), .move(_, let lane), .gain(_, let lane), .fade(_, _, let lane): lane
        case .range(let lane): lane
        }
    }

    /// The clip of a clip zone.
    var clip: Clip? {
        switch self {
        case .trim(let clip, _, _), .move(let clip, _), .gain(let clip, _), .fade(let clip, _, _): clip
        case .range: nil
        }
    }

    /// The cursor over the zone, with no gesture.
    var cursor: TimelineCursor {
        switch self {
        case .trim, .fade: .resizeLeftRight
        case .gain: .resizeUpDown
        case .move: .arrow
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
