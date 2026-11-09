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

/// The gain layers of one clip in the columns of a draw (decision 0060): the envelope and the ride,
/// from the file frame of the first column, with the frames per column. In each layer a binary
/// search finds the first point of the draw rect, and a walk over the columns in order reads each
/// point once: the cursor `next` of each layer only moves forward.
struct ColumnEnvelope {
    /// One layer with a point, and its cursors.
    struct Layer {
        let points: [GainEnvelope.Point]
        /// The index of the first point after the first column start: the cursor of a walk from there.
        let seed: Int
        /// The index of the first point after the start of the last column read.
        fileprivate(set) var next: Int
        /// The index of the first point after the frame of the walk inside a column.
        fileprivate var after = 0

        /// The gain at `frame`, where `after` is the index of the first point past it.
        func value(at frame: Int) -> Double {
            if after == 0 { return points[0].gain.dB }
            if after == points.count { return points[after - 1].gain.dB }
            let (a, b) = (points[after - 1], points[after])
            return a.gain.dB + (b.gain.dB - a.gain.dB) * Double(frame - a.frame.count)
                / Double(b.frame.count - a.frame.count)
        }

        /// Moves `after` past each point at or before `frame`.
        fileprivate mutating func walk(through frame: Int) {
            while after < points.count, points[after].frame.count <= frame { after += 1 }
        }
    }

    private(set) var layers: [Layer]
    private let first: Double
    private let step: Double
    private var last = Int.min

    init(layers: [GainEnvelope], first: Double, step: Double) {
        (self.first, self.step) = (first, step)
        let start = Frames(Int(first.rounded(.down)) + 1)
        self.layers = layers.filter { !$0.isEmpty }.map {
            let seed = $0.index(atOrAfter: start)
            return Layer(points: $0.points, seed: seed, next: seed)
        }
    }

    /// The highest sum of the layer gains in dB over the file frames of column `index`, as the
    /// column keeps the highest peak of its frames. The sum is linear between the points of the
    /// layers, so the maximum is at an end of the column or at a point of a layer inside it. The
    /// `index` of a call is not under the one before.
    mutating func gain(_ index: Int) -> Double {
        let start = first + Double(index) * step
        let (low, high) = (Int(start.rounded(.down)), Int((start + step).rounded(.up)))
        let reset = low < last
        last = low
        for n in layers.indices {
            if reset { layers[n].next = layers[n].seed }
            layers[n].after = layers[n].next
            layers[n].walk(through: low)
            layers[n].next = layers[n].after
        }
        var best = sum(at: low)
        // Each point inside the column in frame order, then the column end.
        var frame = low
        while frame < high {
            frame = high
            for layer in layers where layer.after < layer.points.count {
                frame = min(frame, layer.points[layer.after].frame.count)
            }
            for n in layers.indices { layers[n].walk(through: frame) }
            best = max(best, sum(at: frame))
        }
        return best
    }

    /// The sum of the layer gains at `frame`, with `after` of each layer past it. 0 with no layer.
    private func sum(at frame: Int) -> Double {
        var total = 0.0
        for layer in layers { total += layer.value(at: frame) }
        return total
    }
}
