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

    /// The zone under a lane point (mouse-edits criterion 1). On a clip: 4 pt inside each edge
    /// trims, the upper two thirds moves, and the lower third is a range. A box under 12 pt is all
    /// range, so a small drag at fit zoom cannot move a clip that the user cannot see.
    func hit(_ x: Double, _ y: Double, in session: Session) -> LaneHit {
        let lane = lane(at: y)
        guard lane < session.tracks.count else { return .range(lane: nil) }
        let clips = session.tracks[lane].clips
        guard let index = clips.index(holding: frame(at: x)) else { return .range(lane: lane) }
        let clip = clips[index]
        let (box, smallest, trim) = (box(of: clip, lane: lane), 12.0, 4.0)
        guard box.width >= smallest else { return .range(lane: lane) }
        if x - box.minX < trim { return .trim(clip, .start, lane: lane) }
        if box.maxX - x < trim { return .trim(clip, .end, lane: lane) }
        return y - box.minY < laneHeight * 2 / 3 ? .move(clip, lane: lane) : .range(lane: lane)
    }
}

/// The edge of a clip.
enum Edge: Equatable, Sendable { case start, end }

/// The zone of a lane point. `lane` nil: under the last lane.
enum LaneHit: Equatable, Sendable {
    case trim(Clip, Edge, lane: Int)
    case move(Clip, lane: Int)
    case range(lane: Int?)

    /// The cursor over the zone, with no gesture.
    var cursor: TimelineCursor {
        switch self {
        case .trim: .resizeLeftRight
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
public enum TimelineCursor: Equatable, Sendable { case arrow, iBeam, closedHand, resizeLeftRight }

/// The frames that an edge of `clip` can reach in a trim (mouse-edits criterion 6): the neighbor
/// in `lane`, the start or the end of its file (`fileLength` frames), frame 0, `Frames.limit`, and
/// a length of `minimum`. The range always holds the current edge, so it is never empty.
func trimLimits(_ clip: Clip, edge: Edge, in lane: ClipLane, fileLength: Frames, minimum: Frames)
    -> ClosedRange<Frames>
{
    let index = lane.firstIndex { $0.id == clip.id }
    switch edge {
    case .start:
        let previous = index.flatMap { $0 > lane.startIndex ? lane[$0 - 1].end : nil } ?? .zero
        let low = max(previous, clip.start - clip.offset, .zero)
        return min(low, clip.start)...max(clip.start, clip.end - minimum)
    case .end:
        let next = index.flatMap { $0 + 1 < lane.endIndex ? lane[$0 + 1].start : nil } ?? .limit
        let high = min(next, clip.start + fileLength - clip.offset, .limit)
        return min(clip.end, clip.start + minimum)...max(clip.end, high)
    }
}
