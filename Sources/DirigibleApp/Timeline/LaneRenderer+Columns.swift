import DirigibleCore
import Foundation

/// The fades of one clip in the columns of a draw (decision 0035): the clip frame of the first
/// column, and the frames per column.
struct ColumnFades {
    let fades: Fades
    let curves: Fades.Curves
    let length: Frames
    let first: Double
    let step: Double
    /// A 1 px fade line, only in clip boxes of 12 pt or more wide (0035).
    let line: Bool

    /// The maximum of the fade factor over the frames of column `index` (plan gate F2): the fade-in
    /// at min(k + step, I), the fade-out at max(k, N - O). Nil when that maximum is 1, so a column
    /// that holds a fade end costs nothing: at fit zoom almost every column holds one (bench C25).
    func factor(_ index: Int) -> Double? {
        // A rounded column can start at the clip end; the curve takes a frame of the clip.
        let k = min(max(0, Int((first + Double(index) * step).rounded(.down))), length.count - 1)
        let end = k + Int(step.rounded(.up))
        let rising = end < fades.fadeIn.count
        let falling = fades.fadeOut > .zero && k > length.count - fades.fadeOut.count
        guard rising || falling else { return nil }
        var factor = 1.0
        if rising { factor *= fades.gain(at: Frames(end), length: length, curves: curves) }
        if falling { factor *= fades.gain(at: Frames(k), length: length, curves: curves) }
        return factor
    }
}

/// The gain envelope of one clip in the columns of a draw (decision 0060): the file frame of the
/// first column, and the frames per column. A binary search finds the first point of the draw rect,
/// and a walk over the columns in order reads each point once: the cursor `next` only moves forward.
struct ColumnEnvelope {
    private let points: [GainEnvelope.Point]
    private let first: Double
    private let step: Double
    /// The index of the first point after the first column start: the cursor of a walk from there.
    private let seed: Int
    /// The index of the first point after the start of the last column read.
    private(set) var next: Int
    private var last = Int.min

    init(envelope: GainEnvelope, first: Double, step: Double) {
        (points, self.first, self.step) = (envelope.points, first, step)
        seed = envelope.index(atOrAfter: Frames(Int(first.rounded(.down)) + 1))
        next = seed
    }

    /// The highest gain in dB over the file frames of column `index`, as the column keeps the
    /// highest peak of its frames. The envelope is linear between points, so the maximum is at an
    /// end of the column or at a point inside it. The `index` of a call is not under the one before.
    mutating func gain(_ index: Int) -> Double {
        let start = first + Double(index) * step
        let (low, high) = (Int(start.rounded(.down)), Int((start + step).rounded(.up)))
        if low < last { next = seed }
        last = low
        while next < points.count, points[next].frame.count <= low { next += 1 }
        var best = max(value(at: low, after: next), points.isEmpty ? 0 : value(at: high))
        var inside = next
        while inside < points.count, points[inside].frame.count < high {
            best = max(best, points[inside].gain.dB)
            inside += 1
        }
        return best
    }

    /// The gain at `frame` for a frame at or after the start of the column, by the points from
    /// `next` on.
    private func value(at frame: Int) -> Double {
        var after = next
        while after < points.count, points[after].frame.count <= frame { after += 1 }
        return value(at: frame, after: after)
    }

    /// The gain at `frame`, where `after` is the index of the first point past it.
    private func value(at frame: Int, after: Int) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if after == 0 { return first.gain.dB }
        if after == points.count { return last.gain.dB }
        let (a, b) = (points[after - 1], points[after])
        return a.gain.dB + (b.gain.dB - a.gain.dB) * Double(frame - a.frame.count)
            / Double(b.frame.count - a.frame.count)
    }
}
