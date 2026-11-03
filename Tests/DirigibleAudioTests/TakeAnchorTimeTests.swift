import DirigibleCore
import Testing

@testable import DirigibleAudio

/// Criterion P1 (run 2026-10-28-pre-roll): the take start host time H_T of a pre-roll take is
/// the real start, the output term, and the span from S to T.
struct TakeAnchorTimeTests {
    let rate = 48_000
    let realStart: UInt64 = 10_000_000_000

    /// 892 device frames at 48 kHz are 18,583,333 ns. A dropped term gives 13,000,000,000 ns, and
    /// a term counted twice 13,037,166,666 ns.
    @Test func addsTheLatency() {
        let playhead = Frames(5 * rate)
        let start = preRollStart(playhead: playhead, seconds: 3, rate: rate)
        #expect(start == Frames(2 * rate))
        let anchor = takeStartHostNanos(realStart: realStart, term: .builtIn, from: start, to: playhead, rate: rate)
        #expect(anchor == 13_018_583_333)
    }

    /// A playhead at 1 s with a pre-roll of 3 s starts at 0, so T is 1 s after the real start.
    @Test func clampsAtZero() {
        let playhead = Frames(rate)
        let start = preRollStart(playhead: playhead, seconds: 3, rate: rate)
        #expect(start == .zero)
        let anchor = takeStartHostNanos(realStart: realStart, term: .builtIn, from: start, to: playhead, rate: rate)
        #expect(anchor == 11_018_583_333)
    }

    @Test func zeroLatency() {
        let playhead = Frames(5 * rate)
        let start = Frames(2 * rate)
        #expect(
            takeStartHostNanos(realStart: realStart, term: .manual(0), from: start, to: playhead, rate: rate)
                == 13_000_000_000)
    }
}
