import Foundation

/// The voice match of a track (decision 0074 D3): a live EQ curve that moves the track toward a
/// reference voice. Only the checked init makes one, so each stored value is in range.
public struct VoiceMatch: Hashable, Sendable {
    /// The amount in whole percent, 1 to 100.
    public struct Amount: Hashable, Sendable {
        public let percent: Int

        /// Nil outside 1 to 100.
        public init?(_ percent: Int) {
            guard (1...100).contains(percent) else { return nil }
            self.percent = percent
        }
    }

    /// The value that the init refuses. The raw value is the attribute of `<match>`.
    public enum Field: String, Error, Sendable {
        case curve
        case targetPowers = "target"
        case reference
    }

    /// The amount of a new match (UI council ruling 4).
    public static let defaultAmount = Amount(75)!
    /// The largest boost and cut of the curve, in dB.
    public static let curveLimit = 12.0

    public private(set) var amount: Amount
    /// A bypassed match keeps its values and the mix plays the track with no match stage.
    public private(set) var isBypassed: Bool
    /// The name of the reference clip at the match. It does not follow a later edit of that clip.
    public let reference: String
    /// The gain of each band at amount 100, in dB.
    public let curve: ThirdOctave.Gains
    /// The gated power of each band of the target track: the weights of the loudness offset.
    public let targetPowers: [Double]

    /// Throws for a curve that is not 25 finite gains from -12 to +12 dB, target powers that are
    /// not 25 finite values of 0 or more, and a reference with text that the session cannot store.
    public init(
        amount: Amount, isBypassed: Bool = false, reference: String, curve: [Double], targetPowers: [Double]
    ) throws(Field) {
        guard let gains = ThirdOctave.Gains(decibels: curve), curve.allSatisfy({ abs($0) <= Self.curveLimit }) else {
            throw .curve
        }
        guard targetPowers.count == ThirdOctave.bandCount, targetPowers.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw .targetPowers
        }
        guard reference.unicodeScalars.allSatisfy(\.isStorableInSession) else { throw .reference }
        (self.amount, self.isBypassed, self.reference) = (amount, isBypassed, reference)
        (self.curve, self.targetPowers) = (gains, targetPowers)
    }

    /// The same match with another amount, or another bypass state.
    func with(amount: Amount? = nil, isBypassed: Bool? = nil) -> VoiceMatch {
        var copy = self
        copy.amount = amount ?? self.amount
        copy.isBypassed = isBypassed ?? self.isBypassed
        return copy
    }

    /// The band gains of the stage: the curve times the amount, less the offset that keeps the
    /// K-weighted power of the target bands. The offset keeps on and off at one loudness, not one
    /// peak, so the largest gain can be over the boost cap (C25).
    public func gains(at amount: Amount) -> ThirdOctave.Gains {
        let offset = offset(at: amount)
        return ThirdOctave.Gains(decibels: curve.decibels.map { $0 * Self.fraction(amount) - offset })!
    }

    /// The largest boost and the largest cut of the curve times the amount, with no offset, to
    /// 0.1 dB. Each is +0.0 when the curve has none.
    public func extremes(at amount: Amount) -> (boost: Double, cut: Double) {
        // Adding 0 turns a rounded -0.0 into +0.0.
        let rounded = { (value: Double) in (value * Self.fraction(amount) * 10).rounded() / 10 + 0 }
        return (rounded(max(0, curve.decibels.max()!)), rounded(min(0, curve.decibels.min()!)))
    }

    /// 10 log10 of the K-weighted target power through the scaled curve over that power with no
    /// gain. The powers are divided by the largest one so that no sum overflows. A target of zeros
    /// gets 0 dB.
    func offset(at amount: Amount) -> Double {
        let largest = targetPowers.max()!
        guard largest > 0 else { return 0 }
        var (through, plain) = (0.0, 0.0)
        for band in 0..<ThirdOctave.bandCount {
            let weight = targetPowers[band] / largest * Self.kWeights[band]
            through += weight * pow(10, curve.decibels[band] * Self.fraction(amount) / 10)
            plain += weight
        }
        return 10 * log10(through / plain)
    }

    private static func fraction(_ amount: Amount) -> Double { Double(amount.percent) / 100 }

    private static let kWeights = ThirdOctave.centers.map(kWeight)

    /// The power gain of the K weighting of ITU-R BS.1770 at `frequency`: the shelf and the
    /// high-pass with the coefficients that the standard gives for 48 kHz.
    static func kWeight(_ frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency / 48_000
        func power(_ b: [Double], _ a: [Double]) -> Double {
            let (re, im) = (b[0] + b[1] * cos(w) + b[2] * cos(2 * w), -(b[1] * sin(w) + b[2] * sin(2 * w)))
            let (dr, di) = (1 + a[1] * cos(w) + a[2] * cos(2 * w), -(a[1] * sin(w) + a[2] * sin(2 * w)))
            return (re * re + im * im) / (dr * dr + di * di)
        }
        let shelf = power(
            [1.53512485958697, -2.69169618940638, 1.19839281085285], [1, -1.69065929318241, 0.73248077421585])
        return shelf * power([1, -2, 1], [1, -1.99004745483398, 0.99007225036621])
    }
}
