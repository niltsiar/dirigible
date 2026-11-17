import Foundation
import Testing

@testable import DirigibleCore

/// Criterion C7 of decision 0074: the curve from two band spectra (the shape scale, the cap,
/// the noise and bandwidth guards, and the rate limit).
struct VoiceCurveTests {
    static let quiet = [Double](repeating: 1e-12, count: ThirdOctave.bandCount)

    static func spectrum(_ powers: [Double], noise: [Double] = quiet) -> BandSpectrum {
        BandSpectrum(powers: powers, noise: noise, voiceFrames: 480_000)
    }

    static func power(_ decibels: Double) -> Double { pow(10, decibels / 10) }

    /// A voice-like reference: 0 dB at 63 Hz down to -12 dB at 16 kHz.
    static let reference = (0..<25).map { power(-0.5 * Double($0)) }

    /// A known curve within the cap, shifted so the target keeps the total power of the reference.
    static let known: [Double] = {
        let raw = (0..<25).map { 8 * sin(Double($0) / 3) }
        let total = zip(reference, raw).map { $0 * power($1) }.reduce(0, +) / reference.reduce(0, +)
        return raw.map { $0 - 10 * log10(total) }
    }()

    static func curve(_ reference: BandSpectrum, _ target: BandSpectrum, rate: Int = 48_000) -> [Double] {
        VoiceCurve.curve(reference: reference, target: target, sampleRate: rate).decibels
    }

    @Test func invertsAKnownCurve() throws {
        let target = zip(Self.reference, Self.known).map { $0 * Self.power($1) }
        let gains = Self.curve(Self.spectrum(Self.reference), Self.spectrum(target))
        let errors = zip(gains, Self.known).map { abs($0 + $1) }
        #expect(errors.max()! <= 1.0, "band errors \(errors)")
        let match = try VoiceMatch(
            amount: #require(VoiceMatch.Amount(50)), reference: "Host 01", curve: gains, targetPowers: target)
        let half = match.gains(at: match.amount).decibels
        let halfErrors = (0..<25).map { abs((half[$0] - half[0]) - (Self.known[0] - Self.known[$0]) / 2) }
        #expect(halfErrors.max()! <= 0.5, "band errors at amount 50 \(halfErrors)")
    }

    @Test func referenceLevelDoesNotMatter() {
        let target = zip(Self.reference, Self.known).map { $0 * Self.power($1) }
        let gains = Self.curve(Self.spectrum(Self.reference), Self.spectrum(target))
        let louder = Self.curve(Self.spectrum(Self.reference.map { $0 * 10 }), Self.spectrum(target))
        let differences = zip(gains, louder).map { abs($0 - $1) }
        #expect(differences.max()! <= 0.1, "\(differences)")
        #expect(gains.map(abs).max()! >= 6, "the fixture has a curve: \(gains)")
    }

    /// Band 12 (1 kHz): the target is 30 dB under the reference there, and only 25 dB under its own
    /// loudest band, so no bandwidth guard acts.
    @Test func boostIsCapped() {
        var (reference, target) = ([Double](repeating: 1, count: 25), [Double](repeating: 1, count: 25))
        (reference[12], target[12]) = (Self.power(5), Self.power(-25))
        let gains = Self.curve(Self.spectrum(reference), Self.spectrum(target))
        #expect(gains[12] == 12, "\(gains)")
    }

    @Test func cutIsCapped() {
        var (reference, target) = ([Double](repeating: 1, count: 25), [Double](repeating: 1, count: 25))
        (reference[12], target[12]) = (Self.power(-15), Self.power(15))
        let gains = Self.curve(Self.spectrum(reference), Self.spectrum(target))
        #expect(gains[12] == -12, "\(gains)")
    }

    /// The target is 8 dB under the reference at 1 kHz. With its voice 6 dB over the noise estimate
    /// the band gets no boost; 14 dB over keeps the boost.
    @Test(arguments: [(6.0, false), (14.0, true)])
    func noBoostOverNoise(overNoise: Double, boosts: Bool) {
        let reference = [Double](repeating: 1, count: 25)
        var target = reference
        target[12] = Self.power(-8)
        var noise = Self.quiet
        noise[12] = target[12] / Self.power(overNoise)
        let gains = Self.curve(Self.spectrum(reference), Self.spectrum(target, noise: noise))
        if boosts {
            #expect(gains[12] > 7, "\(gains[12])")
        } else {
            #expect(gains[12] == 0, "\(gains[12])")
        }
    }

    /// A phone-band target (bands 315 Hz to 3.15 kHz, the others 50 dB down) matched to a flat
    /// studio reference: no boost over 4 kHz and under 250 Hz.
    @Test func bandLimitedTargetGetsNoBoost() {
        let target = ThirdOctave.centers.map { (300...3_400).contains($0) ? 1 : Self.power(-50) }
        let gains = Self.curve(Self.spectrum([Double](repeating: 1, count: 25)), Self.spectrum(target))
        let outside = zip(ThirdOctave.centers, gains).filter { $0.0 >= 4_000 || $0.0 < 250 }.map(\.1)
        #expect(outside.allSatisfy { $0 <= 0 }, "\(gains)")
        let scale = 10 * log10(target.reduce(0, +) / 25)
        let inside = zip(ThirdOctave.centers, gains).filter { (300...3_400).contains($0.0) }.map { abs($0.1 - scale) }
        #expect(inside.max()! <= 0.01, "the phone band gets the shape scale \(scale) dB: \(gains)")
    }

    /// At 32 kHz the 16 kHz band is over 0.45 x the rate, so it gets 0 dB with a 30 dB boost asked.
    @Test func bandsOverTheRateLimitAreFlat() {
        var target = [Double](repeating: 1, count: 25)
        target[24] = Self.power(-20)
        target[23] = Self.power(-20)
        let gains = Self.curve(Self.spectrum([Double](repeating: 1, count: 25)), Self.spectrum(target), rate: 32_000)
        #expect(gains[24] == 0 && gains[23] > 10, "\(gains)")
    }
}
