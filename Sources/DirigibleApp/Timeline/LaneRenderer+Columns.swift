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
/// from the file frame of column 0, with the frames per column. In each layer a binary search finds
/// the first point after the start of the column `from`, and a walk over the columns in order reads each
/// point once: the cursor `next` of each layer only moves forward. In a column where only one layer
/// has points, each other layer is a line over the column, so a point costs one multiply-add (a
/// ride has about 7 points per column at fit zoom).
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
    }

    private(set) var layers: [Layer]
    private let first: Double
    private let step: Double
    private var last = Int.min

    /// Each `index` of `gain` is `from` or over it.
    init(layers: [GainEnvelope], first: Double, step: Double, from: Int = 0) {
        (self.first, self.step) = (first, step)
        let start = Frames(Int((first + Double(from) * step).rounded(.down)) + 1)
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
        return layers.withUnsafeMutableBufferPointer { Self.gain($0, low: low, high: high, reset: reset) }
    }

    /// The walk of one column over `layers`, read in place: a copy of a `Layer` retains its points.
    private static func gain(_ layers: UnsafeMutableBufferPointer<Layer>, low: Int, high: Int, reset: Bool) -> Double {
        // The layer with a point inside the column, if only one layer has one.
        var (lone, several): (Int?, Bool) = (nil, false)
        var (atLow, atHigh) = (0.0, 0.0)
        for n in layers.indices {
            if reset { layers[n].next = layers[n].seed }
            let next = past(layers[n].points, from: layers[n].next, through: low)
            layers[n].next = next
            if next < layers[n].points.count, layers[n].points[next].frame.count < high {
                several = several || lone != nil
                lone = n
            }
            atLow += value(layers[n].points, after: next, at: low)
            atHigh += value(layers[n].points, after: past(layers[n].points, from: next, through: high), at: high)
        }
        let ends = max(atLow, atHigh)
        guard let lone else { return ends }
        if several { return max(ends, merged(layers, low: low, high: high)) }
        var (base, rise) = (0.0, 0.0)
        for n in layers.indices where n != lone {
            base += value(layers[n].points, after: layers[n].next, at: low)
            rise += slope(layers[n].points, after: layers[n].next)
        }
        var best = ends
        var index = layers[lone].next
        while index < layers[lone].points.count, layers[lone].points[index].frame.count < high {
            let point = layers[lone].points[index]
            best = max(best, point.gain.dB + base + rise * Double(point.frame.count - low))
            index += 1
        }
        return best
    }

    /// The highest sum at the points inside the column of two or more layers, in frame order.
    private static func merged(_ layers: UnsafeMutableBufferPointer<Layer>, low: Int, high: Int) -> Double {
        for n in layers.indices { layers[n].after = layers[n].next }
        var best = -Double.infinity
        while true {
            var frame = high
            for n in layers.indices where layers[n].after < layers[n].points.count {
                frame = min(frame, layers[n].points[layers[n].after].frame.count)
            }
            if frame >= high { return best }
            var total = 0.0
            for n in layers.indices {
                layers[n].after = past(layers[n].points, from: layers[n].after, through: frame)
                total += value(layers[n].points, after: layers[n].after, at: frame)
            }
            best = max(best, total)
        }
    }

    /// The index of the first point past `frame`, from `index` on.
    private static func past(_ points: [GainEnvelope.Point], from index: Int, through frame: Int) -> Int {
        var index = index
        while index < points.count, points[index].frame.count <= frame { index += 1 }
        return index
    }

    /// The gain at `frame`, where `after` is the index of the first point past it.
    private static func value(_ points: [GainEnvelope.Point], after: Int, at frame: Int) -> Double {
        if after == 0 { return points[0].gain.dB }
        if after == points.count { return points[after - 1].gain.dB }
        let (a, b) = (points[after - 1], points[after])
        return a.gain.dB + (b.gain.dB - a.gain.dB) * Double(frame - a.frame.count)
            / Double(b.frame.count - a.frame.count)
    }

    /// The dB per frame of the segment that holds the frames from the point before `after`.
    private static func slope(_ points: [GainEnvelope.Point], after: Int) -> Double {
        if after == 0 || after == points.count { return 0 }
        let (a, b) = (points[after - 1], points[after])
        return (b.gain.dB - a.gain.dB) / Double(b.frame.count - a.frame.count)
    }
}

/// The layer gains of one clip by absolute column (`LaneRenderer.columnGains`), with the inputs
/// they come from: the layers, the file frame of column 0, and the frames per column.
struct LayerColumns {
    let envelope: GainEnvelope
    let ride: GainEnvelope
    let base: Frames
    let pixelFrames: Double
    let columns: Range<Int>
    let gains: [Double]

    func holds(_ clip: Clip, _ pixelFrames: Double) -> Bool {
        envelope == clip.envelope && ride == clip.ride && base == clip.offset - clip.start
            && self.pixelFrames == pixelFrames
    }
}

extension LaneRenderer {
    /// The highest sum of the gain layers of `clip` over the file frames of each of its `columns`,
    /// absolute columns in `clipColumns`. The gains of the last draw serve when they come from the
    /// same inputs and hold the columns. Else one walk; when only the columns differ (a scroll), the
    /// walk takes `margin` more columns on each side, in the clip.
    func columnGains(
        of clip: Clip, _ columns: Range<Int>, in clipColumns: Range<Int>, _ pixelFrames: Double, margin: Int
    ) -> ArraySlice<Double> {
        let kept = layerColumns[clip.id].flatMap { $0.holds(clip, pixelFrames) ? $0 : nil }
        if let kept, kept.columns.lowerBound <= columns.lowerBound, columns.upperBound <= kept.columns.upperBound {
            let start = kept.columns.lowerBound
            return kept.gains[(columns.lowerBound - start)..<(columns.upperBound - start)]
        }
        let walked =
            kept == nil ? columns : (columns.lowerBound - margin..<columns.upperBound + margin).clamped(to: clipColumns)
        let base = clip.offset - clip.start
        var envelope = ColumnEnvelope(
            layers: [clip.envelope, clip.ride], first: Double(base.count), step: pixelFrames, from: walked.lowerBound)
        let entry = LayerColumns(
            envelope: clip.envelope, ride: clip.ride, base: base, pixelFrames: pixelFrames, columns: walked,
            gains: walked.map { envelope.gain($0) })
        layerColumns[clip.id] = entry
        return entry.gains[(columns.lowerBound - walked.lowerBound)..<(columns.upperBound - walked.lowerBound)]
    }
}
