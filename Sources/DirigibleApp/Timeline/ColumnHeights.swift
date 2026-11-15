import DirigibleTimeline
import Foundation

/// The rows of a column magnitude v at a gain: the rows of 20 log10(v / `UInt32.max`) + gain dB on
/// the scale of a waveform range, with no log10 call for most values. The dB of a value does not
/// fall as the value grows, so the dB of the start of its bucket (the top 11 bits of the value) and
/// of the next bucket start bound it. When the bound under the value gives row r and the bound over
/// it is under the edge of row r + 1, the row is r. Else the formula gives the row. For a 16-bit
/// value v x 65537 the quotient is the same `Double` as v / 65535.
struct ColumnHeights {
    let range: WaveformRange
    let laneRows: Int
    /// edges[k]: the lowest dB that draws k rows or more, for k in 1...laneRows, with -infinity
    /// first and infinity last.
    private let edges: [Double]
    private let starts = Self.bucketStarts
    private let rangeDB: Double
    private let rowsPerDB: Double

    /// The bits of a value that select its bucket: from the highest bit that is set.
    private static let bits = 11
    /// The dB of the first value of each bucket. A value under 2^11 is a bucket of its own.
    private static let bucketStarts: [Double] = (0..<((UInt32.bitWidth - bits + 2) << (bits - 1)) + 1).map { index in
        let shift = max(index >> (bits - 1) - 1, 0)
        return decibels(Double(UInt64(index - shift << (bits - 1)) << shift))
    }

    init(range: WaveformRange, laneRows: Int) {
        (self.range, self.laneRows, rangeDB) = (range, laneRows, range.dB)
        rowsPerDB = Double(laneRows) / range.dB
        func exact(_ dB: Double) -> Int { Int((range.fraction(dB: dB) * Double(laneRows)).rounded()) }
        edges =
            [-.infinity]
            + (1..<laneRows + 1).map { rows in
                var dB = (Double(rows) - 0.5) / Double(laneRows) * range.dB - range.dB
                while exact(dB) >= rows { dB = dB.nextDown }
                while exact(dB) < rows { dB = dB.nextUp }
                return dB
            } + [.infinity]
    }

    private static func decibels(_ value: Double) -> Double { 20 * log10(value / Double(UInt32.max)) }

    /// Runs `body` with the rows of a value at a gain. The tables open once for all the calls of
    /// `body`: a draw calls it for each column.
    func withRows<Result>(_ body: (_ rows: (_ value: UInt32, _ gain: Double) -> Int) -> Result) -> Result {
        starts.withUnsafeBufferPointer { starts in
            edges.withUnsafeBufferPointer { edges in
                /// The rows of `dB`: a product gives a near row, and the edges give the exact one.
                func row(_ dB: Double) -> Int {
                    var row = Int(min(max((dB + rangeDB) * rowsPerDB, 0), Double(laneRows)) + 0.5)
                    while dB < edges[row] { row -= 1 }
                    while dB >= edges[row + 1] { row += 1 }
                    return row
                }
                func rows(_ value: UInt32, _ gain: Double) -> Int {
                    guard value > 0 else { return 0 }
                    let shift = max(UInt32.bitWidth - value.leadingZeroBitCount - Self.bits, 0)
                    let index = shift << (Self.bits - 1) + Int(value &>> UInt32(shift))
                    let low = row(starts[index] + gain)
                    if starts[index + 1] + gain < edges[low + 1] { return low }
                    return row(Self.decibels(Double(value)) + gain)
                }
                return body(rows)
            }
        }
    }
}
