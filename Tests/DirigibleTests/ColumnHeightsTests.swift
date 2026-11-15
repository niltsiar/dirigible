import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// The rows of a column magnitude equal the rows of the dB formula, for each value, range, row count,
/// and gain that the renderer passes.
struct ColumnHeightsTests {
    /// The rows of the formula: 20 log10(v / `UInt32.max`) dB plus `gain`, on the scale of `range`.
    static func formula(_ value: UInt32, _ gain: Double, _ range: WaveformRange, _ laneRows: Int) -> Int {
        guard value > 0 else { return 0 }
        let decibels = 20 * log10(Double(value) / Double(UInt32.max))
        return Int((range.fraction(dB: decibels + gain) * Double(laneRows)).rounded())
    }

    /// The lowest value that the formula gives `rows` rows or more, or nil when no value does.
    static func threshold(_ rows: Int, _ gain: Double, _ range: WaveformRange, _ laneRows: Int) -> UInt32? {
        var (low, high) = (UInt64(0), UInt64(UInt32.max) + 1)
        while low < high {
            let middle = (low + high) / 2
            if formula(UInt32(middle), gain, range, laneRows) >= rows { high = middle } else { low = middle + 1 }
        }
        return low > UInt64(UInt32.max) ? nil : UInt32(low)
    }

    /// Lanes of 12, 48, 100, and 400 pt at scale 1 and 2. The gains: a cut, none, a boost, a
    /// fractional gain, and the gain of a fade at factor 0.
    @Test(arguments: WaveformRange.allCases)
    func theRowsOfEachValueEqualTheFormula(range: WaveformRange) {
        var random = SplitMix(seed: 7)
        let values =
            [0, 1, 2, 2047, 2048, 2049, UInt32.max - 1, UInt32.max]
            + (0..<3000).map { _ in
                UInt32.random(in: 0...UInt32.max, using: &random) >> UInt32.random(in: 0...31, using: &random)
            }
        for laneRows in [12, 24, 48, 96, 100, 200, 400, 800] {
            for gain: Double in [-24, 0, 6, 1.37, -.infinity] {
                let heights = ColumnHeights(range: range, laneRows: laneRows)
                // The values next to each row edge, where the bounds of a bucket hold two rows.
                let edges = (1...laneRows).compactMap { Self.threshold($0, gain, range, laneRows) }
                let near = edges.flatMap { [$0 - 1, $0, $0 == UInt32.max ? $0 : $0 + 1] }
                let wrong = heights.withRows { rows in
                    (values + near).filter { rows($0, gain) != Self.formula($0, gain, range, laneRows) }
                }
                #expect(wrong.isEmpty, "\(range) dB, \(laneRows) rows, gain \(gain): \(wrong.prefix(5))")
            }
        }
    }
}
