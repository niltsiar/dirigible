import Foundation

/// The measure of one side of a voice match (decision 0074 D5), from the frames that lie inside
/// BS.1770 blocks that pass both gates.
public struct BandSpectrum: Hashable, Sendable {
    /// The mean power of each one-third-octave band over the gated frames: 0 with no gated frame.
    public let powers: [Double]
    /// The noise estimate of each band: the 10th percentile of the band powers of the frames over
    /// the absolute gate, 0 with no such frame.
    public let noise: [Double]
    /// The frames that the gated blocks cover, at the session rate.
    public let voiceFrames: Int

    /// Precondition: 25 finite powers and 25 finite noise values, each 0 or more.
    public init(powers: [Double], noise: [Double], voiceFrames: Int) {
        precondition(
            [powers, noise].allSatisfy {
                $0.count == ThirdOctave.bandCount && $0.allSatisfy { $0.isFinite && $0 >= 0 }
            },
            "a band spectrum has \(ThirdOctave.bandCount) finite powers of 0 or more")
        self.powers = powers
        self.noise = noise
        self.voiceFrames = voiceFrames
    }
}

/// The curve of a voice match at amount 100 (decision 0074 D3, D5).
public enum VoiceCurve {
    /// A band whose target power is less than this many dB over its noise estimate gets no boost.
    public static let noiseMargin = 10.0
    /// A band whose target power is more than this many dB under the loudest target band gets no
    /// boost while its reference band is within this many dB of the loudest reference band.
    public static let bandwidthSpan = 30.0

    /// The gain of each band in dB: the reference powers scaled to the total target power, over
    /// the target powers. Each gain is clamped to `VoiceMatch.curveLimit`; a band that a guard
    /// stops gets no boost, and a band with its center at or over 0.45 x `sampleRate` gets 0 dB.
    public static func curve(reference: BandSpectrum, target: BandSpectrum, sampleRate: Int) -> ThirdOctave.Gains {
        let bands = ThirdOctave.centers.indices.filter { ThirdOctave.centers[$0] < 0.45 * Double(sampleRate) }
        let total = { (powers: [Double]) in bands.reduce(0) { $0 + powers[$1] } }
        let (referenceTotal, targetTotal) = (total(reference.powers), total(target.powers))
        var decibels = [Double](repeating: 0, count: ThirdOctave.bandCount)
        guard referenceTotal > 0, targetTotal > 0 else { return ThirdOctave.Gains(decibels: decibels)! }
        let scale = targetTotal / referenceTotal
        let span = pow(10, -bandwidthSpan / 10)
        let (referenceLoudest, targetLoudest) = (
            bands.map { reference.powers[$0] }.max()!, bands.map { target.powers[$0] }.max()!
        )
        for band in bands {
            let (wanted, heard) = (reference.powers[band] * scale, target.powers[band])
            // A zero power on one side gives an infinite ratio, which the clamp takes to the limit.
            let gain = wanted == heard ? 0 : 10 * log10(wanted / heard)
            let clamped = min(max(gain, -VoiceMatch.curveLimit), VoiceMatch.curveLimit)
            let noisy = heard < target.noise[band] * pow(10, noiseMargin / 10)
            let outOfBand = heard < targetLoudest * span && reference.powers[band] >= referenceLoudest * span
            decibels[band] = clamped > 0 && (noisy || outOfBand) ? 0 : clamped
        }
        return ThirdOctave.Gains(decibels: decibels)!
    }
}
