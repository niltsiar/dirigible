import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The bins of a take in progress (live take view, criteria C4 to C8): `LivePeaks` places each
/// written span by host time, subtracts the latency at the frame conversion, and keeps the
/// largest peak and RMS of each 50 ms bin.
struct LivePeaksTests {
    /// The host time of the take start: 1000 s after boot.
    let start: UInt64 = 1_000_000_000_000
    /// A `now` far after every span of these tests.
    var later: UInt64 { start + 14_400_000_000_000 }

    func live(start: UInt64? = nil, rate: Int = 48_000) -> LivePeaks {
        LivePeaks(origin: 0, startHostNanos: start ?? self.start, rate: rate)
    }

    /// The host span from `from` to `to` milliseconds after the take start. A negative value is
    /// before the take start.
    func span(_ from: Double, _ to: Double) -> Range<UInt64> {
        func host(_ ms: Double) -> UInt64 {
            ms < 0 ? start - UInt64(-ms * 1_000_000) : start + UInt64(ms * 1_000_000)
        }
        return host(from)..<host(to)
    }

    func column(_ peak: UInt16, _ rms: UInt16) -> PeakColumn { PeakColumn(peak: peak, rms: rms) }

    // MARK: C4

    /// Six spans of 30 ms, the last after a gap. At 48 kHz a bin is 2400 frames and 1 ms is 48
    /// frames. Each value is exact in `Float`, so the quantized value is a literal.
    @Test func theOrderOfTheSpansDoesNotMatter() {
        let spans: [(Float, Float, Range<UInt64>)] = [
            (0.125, 0.0625, span(0, 30)), (0.5, 0.25, span(30, 60)), (0.375, 0.3125, span(60, 90)),
            (0.25, 0.125, span(90, 120)), (0.875, 0.25, span(120, 150)), (0.625, 0.5, span(200, 250)),
        ]
        func add(_ order: [Int]) -> LivePeaks {
            var peaks = live()
            for index in order {
                let (peak, rms, span) = spans[index]
                peaks.add(peak: peak, rms: rms, span: span, latencyNanos: 0, now: later)
            }
            return peaks
        }
        let first = add(Array(0..<6))

        #expect(
            first.bins == [
                column(32768, 16384), column(32768, 20480), column(57343, 16384), .zero, column(40959, 32768),
            ],
            "a bin does not hold the largest peak and RMS of its spans")
        #expect(first.covered == [Frames(0)..<Frames(7200), Frames(9600)..<Frames(12000)])
        var differ = 0
        for order in permutations(Array(0..<6)) {
            let peaks = add(order)
            if peaks.bins != first.bins || peaks.covered != first.covered { differ += 1 }
        }
        #expect(differ == 0, "the order of the spans changed the bins in \(differ) of 720 orders")
    }

    func permutations(_ items: [Int]) -> [[Int]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index in
            var rest = items
            let item = rest.remove(at: index)
            return permutations(rest).map { [item] + $0 }
        }
    }

    // MARK: C5

    @Test func aSpanBeforeTheStartWritesOnlyItsLaterPart() {
        var peaks = live()
        let added = peaks.add(peak: 0.5, rms: 0.25, span: span(-100, 100), latencyNanos: 0, now: later)
        #expect(added)
        #expect(peaks.covered == [Frames(0)..<Frames(4800)], "the span before the start: \(peaks.covered)")
        #expect(peaks.bins == [column(32768, 16384), column(32768, 16384)])

        var before = live()
        let wholly = before.add(peak: 0.5, rms: 0.25, span: span(-200, -100), latencyNanos: 0, now: later)
        #expect(!wholly)
        #expect(before.covered.isEmpty, "a span wholly before the start wrote \(before.covered)")
        #expect(before.bins.isEmpty)
        #expect(before.addedFrom == nil)

        // The host time 0 is 50 ms before a take start 50 ms after boot: the difference wraps.
        var early = live(start: 50_000_000)
        let wrapped = early.add(peak: 0.5, rms: 0.25, span: 0..<100_000_000, latencyNanos: 0, now: 200_000_000)
        #expect(wrapped)
        #expect(early.covered == [Frames(0)..<Frames(2400)], "the wrapped span: \(early.covered)")
    }

    // MARK: C5b

    @Test func aSpanFarPastNowWritesNothing() {
        let now = start + 1_000_000_000
        let limit = UInt64(LivePeaks.futureLimit)
        var peaks = live()
        let added = peaks.add(peak: 0.5, rms: 0.25, span: span(0, 100), latencyNanos: 0, now: now)
        #expect(added)
        peaks.addedFrom = nil
        let before = peaks

        let farPast = peaks.add(
            peak: 1, rms: 1, span: (now + limit - 99_999_999)..<(now + limit + 1), latencyNanos: 0, now: now)
        #expect(!farPast)
        #expect(peaks == before, "a span that ends past now + \(LivePeaks.futureLimit) ns changed the bins")
        #expect(peaks.bins.count == 2)

        let atLimit = peaks.add(
            peak: 1, rms: 1, span: (now + limit - 1_000_000)..<(now + limit), latencyNanos: 0, now: now)
        #expect(atLimit)
        #expect(peaks.covered.last?.upperBound == Frames(288_000), "a span that ends at now + the limit was refused")
    }

    // MARK: C5c

    @Test func theLatencyMovesTheSpanEarlier() {
        let latency = Int64((512.0 * 1e9 / 48_000).rounded())
        var peaks = live()
        let added = peaks.add(peak: 0.5, rms: 0.25, span: span(1000, 1100), latencyNanos: latency, now: later)
        #expect(added)
        let lower = peaks.covered.first?.lowerBound.count ?? -1
        #expect(abs(lower - (48_000 - 512)) <= 1, "the span starts at frame \(lower), not 47488 ± 1")
        #expect(peaks.covered.first?.upperBound.count == 52_800 - 512)

        // 5 ms after the take start is less than the latency: frame -272 goes to 0.
        var near = live()
        let nearAdded = near.add(peak: 0.5, rms: 0.25, span: span(5, 50), latencyNanos: latency, now: later)
        #expect(nearAdded)
        #expect(near.covered == [Frames(0)..<Frames(2400 - 512)], "the span near the start: \(near.covered)")
    }

    // MARK: C6

    @Test func aGapStaysAGap() {
        var gap = live()
        gap.add(peak: 0.5, rms: 0.25, span: span(0, 1000), latencyNanos: 0, now: later)
        gap.add(peak: 0.5, rms: 0.25, span: span(2000, 3000), latencyNanos: 0, now: later)
        #expect(gap.covered == [Frames(0)..<Frames(48_000), Frames(96_000)..<Frames(144_000)])

        var touching = live()
        touching.add(peak: 0.5, rms: 0.25, span: span(0, 1000), latencyNanos: 0, now: later)
        touching.add(peak: 0.5, rms: 0.25, span: span(1000, 2000), latencyNanos: 0, now: later)
        #expect(touching.covered == [Frames(0)..<Frames(96_000)], "touching spans did not merge: \(touching.covered)")

        // A gap under one bin (2400 frames) is a rounding of the drain ends, so it merges.
        // 1_000_020_833 ns is frame 48000.99998, so frame 48001: a gap of one frame.
        var oneFrame = live()
        oneFrame.add(peak: 0.5, rms: 0.25, span: span(0, 1000), latencyNanos: 0, now: later)
        oneFrame.add(
            peak: 0.5, rms: 0.25, span: (start + 1_000_020_833)..<(start + 2_000_000_000), latencyNanos: 0, now: later)
        #expect(oneFrame.covered == [Frames(0)..<Frames(96_000)], "a gap of one frame stayed: \(oneFrame.covered)")

        // 1_049_979_167 ns is frame 50399.00002: a gap of 2399 frames merges.
        var underOneBin = live()
        underOneBin.add(peak: 0.5, rms: 0.25, span: span(0, 1000), latencyNanos: 0, now: later)
        underOneBin.add(
            peak: 0.5, rms: 0.25, span: (start + 1_049_979_167)..<(start + 2_000_000_000), latencyNanos: 0, now: later)
        #expect(
            underOneBin.covered == [Frames(0)..<Frames(96_000)], "a gap under one bin stayed: \(underOneBin.covered)")

        var oneBin = live()
        oneBin.add(peak: 0.5, rms: 0.25, span: span(0, 1000), latencyNanos: 0, now: later)
        oneBin.add(peak: 0.5, rms: 0.25, span: span(1050, 2000), latencyNanos: 0, now: later)
        #expect(
            oneBin.covered == [Frames(0)..<Frames(48_000), Frames(50_400)..<Frames(96_000)],
            "a gap of one bin merged: \(oneBin.covered)")
    }

    /// 2 h of 50 ms drains, each odd drain 20,834 ns (one frame) late: the gaps of one frame
    /// merge, so `covered` keeps one range and a live draw walks one range.
    @Test func gapsOfOneFrameKeepOneRange() {
        var peaks = live()
        let drain: UInt64 = 50_000_000
        for n in 0..<UInt64(144_000) {
            let from = start + n * drain + (n % 2 == 1 ? 20_834 : 0)
            peaks.add(peak: 0.5, rms: 0.25, span: from..<(start + (n + 1) * drain), latencyNanos: 0, now: later)
        }
        let one = peaks.covered == [Frames(0)..<Frames(345_600_000)]
        #expect(one, "2 h of one-frame gaps gave \(peaks.covered.count) ranges")
    }

    // MARK: C7

    /// At 5120 Hz a bin is 256 frames, the bin of level 0 of `Peaks`, so both fills read equal
    /// bins. Each step is under the 4096 frames of level 1.
    @Test(arguments: [0.25, 1, 7.5])
    func fillMatchesPeaksFill(bins step: Double) {
        var generator = SeededGenerator(seed: 7)
        var peaks = LivePeaks(origin: 0, startHostNanos: start, rate: 5_120)
        for bin in 0..<40 {
            let peak = Float.random(in: 0...1, using: &generator)
            let host = start + UInt64(bin) * 50_000_000
            peaks.add(
                peak: peak, rms: peak / 2, span: host..<(host + 50_000_000), latencyNanos: 0, now: later)
        }
        #expect(peaks.bins.count == 40)
        let file = Peaks(
            frames: Frames(40 * 256), stamp: FileStamp(size: 0, seconds: 0, nanoseconds: 0), channels: 1,
            sampleRate: 5_120, levels: [peaks.bins, [], []])
        for from in [0.0, 100, -300] {
            var live = [PeakColumn](repeating: column(1, 1), count: Int(60 / step))
            var final = live
            peaks.fill(&live, from: from, step: step * 256)
            file.fill(&final, from: from, step: step * 256)
            let same = live == final
            #expect(same, "the live fill differs from Peaks.fill at \(step) bins from \(from)")
            #expect(live.last == .zero, "a column after the last bin is not zero")
        }
    }

    /// Literal columns at 48 kHz: every bin is 0.0625 but bin 3 (0.5) and bin 12 (0.75), and 20
    /// bins. At 7.5 bins, column 1 covers bins 7 to 14.
    @Test func fillTakesTheLargestBinOfEachColumn() {
        var peaks = live()
        for bin in 0..<20 {
            let value: Float = bin == 3 ? 0.5 : bin == 12 ? 0.75 : 0.0625
            peaks.add(
                peak: value, rms: value, span: span(Double(bin) * 50, Double(bin + 1) * 50), latencyNanos: 0, now: later
            )
        }
        let small = column(4096, 4096)
        let (three, twelve) = (column(32768, 32768), column(49151, 49151))

        var wide = [PeakColumn](repeating: column(1, 1), count: 4)
        peaks.fill(&wide, from: 0, step: 7.5 * 2400)
        #expect(wide == [three, twelve, small, .zero], "the columns at 7.5 bins: \(wide)")

        var narrow = [PeakColumn](repeating: column(1, 1), count: 16)
        peaks.fill(&narrow, from: 0, step: 600)
        #expect(narrow == Array(repeating: small, count: 12) + Array(repeating: three, count: 4))

        var one = [PeakColumn](repeating: column(1, 1), count: 21)
        peaks.fill(&one, from: 0, step: 2400)
        #expect(one[3] == three && one[12] == twelve && one[0] == small && one[20] == .zero)
    }

    // MARK: C8

    @Test func threeHoursHold216000Bins() {
        var peaks = live()
        for second in 0..<10_800 {
            let host = start + UInt64(second) * 1_000_000_000
            peaks.add(peak: 0.5, rms: 0.25, span: host..<(host + 1_000_000_000), latencyNanos: 0, now: later)
        }
        #expect(abs(peaks.bins.count - 216_000) <= 1, "3 h gave \(peaks.bins.count) bins, not 216000")
        #expect(peaks.covered == [Frames(0)..<Frames(518_400_000)])
    }

    // MARK: The dirty start of slice 3 (F1)

    /// `addedFrom` is the start of the lowest bin that an add touched since the last clear.
    @Test func addedFromIsTheStartOfTheLowestTouchedBin() {
        var peaks = live()
        #expect(peaks.addedFrom == nil)
        peaks.add(peak: 0.5, rms: 0.25, span: span(1010, 1060), latencyNanos: 0, now: later)
        #expect(peaks.addedFrom == Frames(48_000))
        peaks.add(peak: 0.5, rms: 0.25, span: span(1100, 1150), latencyNanos: 0, now: later)
        #expect(peaks.addedFrom == Frames(48_000))
        peaks.add(peak: 0.5, rms: 0.25, span: span(500, 550), latencyNanos: 0, now: later)
        #expect(peaks.addedFrom == Frames(24_000))

        peaks.addedFrom = nil
        peaks.add(peak: 0.5, rms: 0.25, span: span(2000, 2050), latencyNanos: 0, now: later)
        #expect(peaks.addedFrom == Frames(96_000))
    }
}
