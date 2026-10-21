import Foundation

/// The gain envelope of a clip (decision 0060): points at file frames, each with a gain in dB on top
/// of the clip gain. Between two points the gain is linear in dB; before the first point and after
/// the last point it holds. The envelope is a function of the file frames and the clip window only
/// selects the part that plays, so no cut changes a point.
public struct GainEnvelope: Hashable, Sendable {
    public struct Point: Hashable, Sendable {
        /// A frame of the audio file, as `Clip.offset`.
        public let frame: Frames
        public let gain: Gain

        public init(frame: Frames, gain: Gain) {
            self.frame = frame
            self.gain = gain
        }
    }

    /// The frames ascend strictly, each in `0...Frames.limit`.
    public let points: [Point]

    public static let empty = GainEnvelope(valid: [])

    /// Nil for a negative frame, a frame over `Frames.limit`, or frames that do not ascend strictly.
    /// `Session.check` refuses a point after the end of the file.
    public init?(_ points: [Point]) {
        guard points.allSatisfy(\.frame.isInRange), zip(points, points.dropFirst()).allSatisfy({ $0.frame < $1.frame })
        else { return nil }
        self.points = points
    }

    init(valid points: [Point]) { self.points = points }

    public var isEmpty: Bool { points.isEmpty }

    /// The gain in dB at the file frame `frame`: 0 with no point.
    public func gain(at frame: Frames) -> Double {
        Self.value(of: points.lazy.map { ($0.frame.count, $0.gain.dB) }, at: frame.count)
    }

    /// The envelope with a point at the file frame `frame`: of `gain`, or with `gain` nil of the
    /// envelope value there, so no sample changes. A point there is replaced when `gain` is given.
    /// Nil when the result is this envelope: a point there and no `gain`, or a point with that
    /// `gain`; also for a frame outside `0...Frames.limit`. Every add of a point calls it, so the
    /// mouse and the keyboard add the same point.
    public func withPoint(at frame: Frames, gain: Gain? = nil) -> GainEnvelope? {
        guard frame.isInRange, let new = gain ?? Gain(clamping: self.gain(at: frame)) else { return nil }
        var points = points
        let index = points.firstIndex { $0.frame >= frame } ?? points.endIndex
        if index < points.endIndex, points[index].frame == frame {
            guard gain != nil, points[index].gain != new else { return nil }
            points[index] = Point(frame: frame, gain: new)
        } else {
            points.insert(Point(frame: frame, gain: new), at: index)
        }
        return GainEnvelope(valid: points)
    }

    /// The index of the first point with a file frame at or after `frame`, by binary search.
    public func index(atOrAfter frame: Frames) -> Int {
        var (low, high) = (points.startIndex, points.endIndex)
        while low < high {
            let middle = (low + high) / 2
            if points[middle].frame < frame { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The points with a file frame in `window`, found by binary search. The lanes draw and hit
    /// the points of the clip window with it.
    public func points(in window: Range<Frames>) -> ArraySlice<Point> {
        points[index(atOrAfter: window.lowerBound)..<index(atOrAfter: window.upperBound)]
    }

    /// The function through `corners`, whose frames ascend strictly: linear between two corners
    /// and held outside them, 0 with no corner.
    private static func value<C: RandomAccessCollection>(of corners: C, at frame: Int) -> Double
    where C.Element == (Int, Double), C.Index == Int {
        // The first corner after `frame`, by binary search.
        var (low, high) = (corners.startIndex, corners.endIndex)
        while low < high {
            let middle = (low + high) / 2
            if corners[middle].0 <= frame { low = middle + 1 } else { high = middle }
        }
        if low == corners.startIndex { return corners.first?.1 ?? 0 }
        if low == corners.endIndex { return corners[low - 1].1 }
        let (f0, g0) = corners[low - 1]
        let (f1, g1) = corners[low]
        return g0 + (g1 - g0) * Double(frame - f0) / Double(f1 - f0)
    }

    /// True when both envelopes give the same gain at each file frame of `frames`. Both are piecewise
    /// linear, so equal values at the two ends and at each point frame inside give equal values at
    /// each frame. The values compare exactly.
    func hasEqualGain(to other: GainEnvelope, in frames: ClosedRange<Frames>) -> Bool {
        if self == other { return true }
        let inside = (points + other.points).lazy.map(\.frame).filter(frames.contains)
        return ([frames.lowerBound, frames.upperBound] + inside).allSatisfy { gain(at: $0) == other.gain(at: $0) }
    }

    /// The heal of two clips (decision 0060): the points of `left` before the file frame `join` and
    /// the points of `right` from `join`.
    static func joined(_ left: GainEnvelope, _ right: GainEnvelope, at join: Frames) -> GainEnvelope {
        GainEnvelope(valid: left.points.filter { $0.frame < join } + right.points.filter { $0.frame >= join })
    }

    /// The envelope of a file converted to another rate (decision 0042): `scale` maps each frame as
    /// it maps a clip offset, and a frame stops at `fileLength`. Of two points on one frame, the
    /// first stays.
    func resampled(_ scale: (Frames) -> Frames, fileLength: Frames) -> GainEnvelope {
        var scaled: [Point] = []
        for point in points {
            let frame = min(scale(point.frame), fileLength)
            if let last = scaled.last, last.frame >= frame { continue }
            scaled.append(Point(frame: frame, gain: point.gain))
        }
        return GainEnvelope(valid: scaled)
    }

    /// The edge rule (decision 0060) of a write that computes a function on the file map of a clip
    /// (range gain, duck). The frames of `corners` ascend strictly and can lie outside the file. The
    /// result drops each corner outside `0...fileLength`. Then it puts a point at frame 0 and at
    /// `fileLength`, with the value of the function there, only at an edge that had a dropped corner
    /// beyond it and has no point yet. Each gain clamps to `Gain.range`.
    static func fitted(_ corners: [(frame: Int, dB: Double)], fileLength: Frames) -> GainEnvelope {
        let file = 0...fileLength.count
        func point(_ frame: Int, _ dB: Double) -> Point { Point(frame: Frames(frame), gain: Gain(clamping: dB)!) }
        var points = corners.filter { file.contains($0.frame) }.map { point($0.frame, $0.dB) }
        let function = corners.lazy.map { ($0.frame, $0.dB) }
        if corners.contains(where: { $0.frame < 0 }), points.first?.frame != .zero {
            points.insert(point(0, value(of: function, at: 0)), at: 0)
        }
        if corners.contains(where: { $0.frame > fileLength.count }), points.last?.frame != fileLength {
            points.append(point(fileLength.count, value(of: function, at: fileLength.count)))
        }
        return GainEnvelope(valid: points)
    }
}
