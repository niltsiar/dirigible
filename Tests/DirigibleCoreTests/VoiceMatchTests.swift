import Foundation
import Testing

@testable import DirigibleCore

/// The stored value of a voice match (decision 0074 D3): the checked init, the gains at an amount
/// with the K-weighted loudness offset, and the extremes of the popover.
struct VoiceMatchTests {
    static let flat = [Double](repeating: 1, count: ThirdOctave.bandCount)

    static func match(
        _ curve: [Double], target: [Double] = flat, amount: Int = 75, bypassed: Bool = false,
        reference: String = "Host 01"
    ) throws -> VoiceMatch {
        try VoiceMatch(
            amount: #require(VoiceMatch.Amount(amount)), isBypassed: bypassed, reference: reference, curve: curve,
            targetPowers: target)
    }

    /// A curve of 0 dB with `gains` at the given bands.
    static func curve(_ gains: [Int: Double]) -> [Double] {
        (0..<ThirdOctave.bandCount).map { gains[$0] ?? 0 }
    }

    /// The K-weighted power of `target` through `gains`, in dB against the power with no gain.
    static func weightedChange(_ gains: ThirdOctave.Gains, _ target: [Double]) -> Double {
        let weights = ThirdOctave.centers.map(VoiceMatch.kWeight)
        var (through, plain) = (0.0, 0.0)
        for band in 0..<ThirdOctave.bandCount {
            through += weights[band] * target[band] * pow(10, gains.decibels[band] / 10)
            plain += weights[band] * target[band]
        }
        return 10 * log10(through / plain)
    }

    /// C5: the init refuses each value outside its range and keeps each value at the range end.
    @Test func checkedInit() throws {
        var short = Self.flat
        short.removeLast()
        let refused: [([Double], [Double], String, VoiceMatch.Field)] = [
            (short, Self.flat, "Host 01", .curve), (Self.flat + [0], Self.flat, "Host 01", .curve),
            (Self.curve([3: 12.01]), Self.flat, "Host 01", .curve),
            (Self.curve([3: -12.01]), Self.flat, "Host 01", .curve),
            (Self.curve([3: .nan]), Self.flat, "Host 01", .curve),
            (Self.curve([3: .infinity]), Self.flat, "Host 01", .curve),
            (Self.flat, short, "Host 01", .targetPowers), (Self.flat, Self.curve([5: -1]), "Host 01", .targetPowers),
            (Self.flat, Self.curve([5: .nan]), "Host 01", .targetPowers),
            (Self.flat, Self.curve([5: .infinity]), "Host 01", .targetPowers),
            (Self.flat, Self.flat, "Host\n01", .reference),
        ]
        for (curve, target, reference, field) in refused {
            #expect(throws: field, "\(field)") { try Self.match(curve, target: target, reference: reference) }
        }
        let kept = try Self.match(Self.curve([0: 12, 24: -12]), target: Self.curve([5: 0]), amount: 100)
        #expect(kept.curve.decibels[0] == 12 && kept.curve.decibels[24] == -12 && kept.targetPowers[5] == 0)
        #expect(kept.amount.percent == 100 && kept.reference == "Host 01" && !kept.isBypassed)
        #expect(VoiceMatch.Amount(0) == nil && VoiceMatch.Amount(101) == nil)
        #expect(VoiceMatch.Amount(1)?.percent == 1 && VoiceMatch.defaultAmount.percent == 75)
    }

    /// The K weighting of BS.1770 at 48 kHz: +0.691 dB at 997 Hz (the constant of the loudness
    /// formula) and the +4 dB shelf at 16 kHz.
    @Test func kWeightingIsTheBS1770Filter() {
        #expect(abs(10 * log10(VoiceMatch.kWeight(997)) - 0.691) < 0.001)
        let top = 10 * log10(VoiceMatch.kWeight(16_000))
        #expect(top > 4.0 && top < 4.1, "\(top)")
    }

    /// C6, the pure part: the gains at amounts 1, 50, and 100 keep the K-weighted power of the
    /// target bands within 0.01 dB, also for a target with power in one band only (then that band
    /// gets 0 dB), a target of zeros, and a target at the top of the Double range.
    @Test func offsetKeepsTheWeightedPower() throws {
        var random = SplitMix(seed: 74_006)
        for _ in 0..<50 {
            let curve = (0..<ThirdOctave.bandCount).map { _ in Double.random(in: -12...12, using: &random) }
            let target = (0..<ThirdOctave.bandCount).map { _ in pow(10, Double.random(in: -6...0, using: &random)) }
            let match = try Self.match(curve, target: target)
            for percent in [1, 50, 100] {
                let amount = try #require(VoiceMatch.Amount(percent))
                let change = Self.weightedChange(match.gains(at: amount), target)
                #expect(abs(change) < 0.01, "amount \(percent): \(change) dB")
            }
        }
        let curve = Self.curve([2: 9, 12: -7.5, 20: 4])
        let amount = try #require(VoiceMatch.Amount(100))
        for band in [2, 12, 20] {
            let gains = try Self.match(curve, target: Self.curve([band: 0.3])).gains(at: amount)
            #expect(abs(gains.decibels[band]) < 1e-9, "band \(band): \(gains.decibels[band])")
        }
        let silent = try Self.match(curve, target: Self.curve([:])).gains(at: amount)
        #expect(silent.decibels == curve, "a target of zeros gets no offset")
        let huge = [Double](repeating: .greatestFiniteMagnitude, count: ThirdOctave.bandCount)
        #expect(abs(Self.weightedChange(try Self.match(curve, target: huge).gains(at: amount), Self.flat)) < 0.01)
    }

    /// C25, the pure part: G(a), the largest value of `gains(at:)`, is the largest curve value
    /// times a / 100 less the offset. Cuts on the bands that K weighting favors give a negative
    /// offset, so G(100) is over the 12 dB boost cap.
    @Test func largestStageGain() throws {
        let cuts = (1..<ThirdOctave.bandCount).reduce(into: [0: 12.0]) { $0[$1] = -12 }
        let lifted = try Self.match(Self.curve(cuts))
        let boosted = try Self.match(Self.curve([12: 6]))
        for (match, peak) in [(lifted, 12.0), (boosted, 6.0)] {
            for percent in [50, 75, 100] {
                let amount = try #require(VoiceMatch.Amount(percent))
                let largest = try #require(match.gains(at: amount).decibels.max())
                #expect(abs(largest - (peak * Double(percent) / 100 - match.offset(at: amount))) < 1e-12)
            }
        }
        let full = try #require(VoiceMatch.Amount(100))
        #expect(lifted.offset(at: full) < 0 && boosted.offset(at: full) > 0)
        #expect(try #require(lifted.gains(at: full).decibels.max()) > 12)
    }

    /// C24, the pure part: the largest boost and cut of the curve times the amount, with no
    /// offset, to 0.1 dB. A curve with no cut, or a cut that rounds to 0, gives +0.0 dB.
    @Test func extremesAtTheAmount() throws {
        let curve = Self.curve([4: 8.4, 18: -6.2])
        for target in [Self.flat, Self.curve([4: 1])] {
            let match = try Self.match(curve, target: target)
            let half = match.extremes(at: try #require(VoiceMatch.Amount(50)))
            let near = match.extremes(at: try #require(VoiceMatch.Amount(49)))
            #expect(half.boost == 4.2 && half.cut == -3.1, "\(half)")
            #expect(near.boost == 4.1 && near.cut == -3.0, "\(near)")
        }
        let one = try #require(VoiceMatch.Amount(1))
        let noCut = try Self.match(Self.curve([4: 8.4])).extremes(at: one)
        let tinyCut = try Self.match(Self.curve([4: -0.01])).extremes(at: one)
        #expect(noCut.boost == 0.1 && noCut.cut == 0 && noCut.cut.sign == .plus, "\(noCut)")
        #expect(tinyCut.boost == 0 && tinyCut.cut == 0 && tinyCut.cut.sign == .plus, "\(tinyCut)")
    }
}
