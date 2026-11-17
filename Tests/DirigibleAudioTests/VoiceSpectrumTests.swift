import Accelerate
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Criterion C8 of decision 0074: the band spectrum of a voice match read (Hann frames of 8,192,
/// hop 4,096, inside gated BS.1770 blocks, with the clip gain).
struct VoiceSpectrumTests {
    /// Noise whose band powers rise 6 dB per decade.
    static let shaped = shapedNoise(slope: 6)

    /// `seconds` of the shaped noise, times `level(second)` in dB.
    static func noise(seconds: Int, level: (Int) -> Double = { _ in 0 }) -> [Float] {
        repeated(shaped, seconds: Double(seconds), level: level)
    }

    /// The spectrum of one mono file read whole, or in `parts` of it.
    static func spectrum(_ samples: [Float], parts: [(Range<Int>, Double)]? = nil) throws -> BandSpectrum {
        let package = try MixPackage()
        try package.addFile("f", channels: [samples])
        let reads = (parts ?? [(0..<samples.count, 0)]).map { range, gain in
            VoicePart(
                file: "f", frames: Frames(range.lowerBound)..<Frames(range.upperBound), gain: Gain(dB: gain)!)
        }
        return try voiceSpectrum(
            reads, in: package.session, package: package.url, progress: { _ in }, isCancelled: { false })
    }

    static func levels(_ spectrum: BandSpectrum) -> [Double] {
        spectrum.powers.map { 10 * log10($0 / spectrum.powers[12]) }
    }

    @Test func recoversAKnownTilt() throws {
        let levels = Self.levels(try Self.spectrum(Self.noise(seconds: 60)))
        let errors = zip(levels, ThirdOctave.centers).map { abs($0 - 6 * log10($1 / 1_000)) }
        #expect(errors.allSatisfy { $0 <= 0.5 }, "band errors \(errors)")
    }

    /// Bursts of 2 s, with hiss 40 dB down in the 2 s pauses, give the spectrum of the bursts with
    /// digital silence in the pauses.
    @Test func silenceDoesNotCount() throws {
        let isBurst = { (frame: Int) in frame / 48_000 % 4 < 2 }
        let bursts = Self.noise(seconds: 60).enumerated().map { isBurst($0) ? $1 : 0 }
        let rms = sqrt(bursts.map { Double($0 * $0) }.reduce(0, +) / Double(bursts.count / 2))
        var noise = ProbeNoise()
        // ProbeNoise is uniform from -1 to 1: an RMS of 1 / sqrt(3).
        let hiss = Float(rms * 0.01 * sqrt(3))
        let hissed = bursts.enumerated().map { isBurst($0) ? $1 : noise.next() * hiss }
        let (alone, withHiss) = (try Self.spectrum(bursts), try Self.spectrum(hissed))
        let differences = zip(alone.powers, withHiss.powers).map { abs(10 * log10($1 / $0)) }
        #expect(differences.allSatisfy { $0 <= 0.5 }, "band differences \(differences)")
        #expect(alone.voiceFrames >= 30 * 48_000 && alone.voiceFrames < 40 * 48_000, "\(alone.voiceFrames)")
    }

    /// Two parts of one file, 12 dB apart in the file, with clip gains that make them equal: both
    /// count. With the gain after the gate, the quiet part of 10 s fails the relative gate (the mean
    /// of the blocks is -1.2 dB, so the gate is at -11.2 dB).
    @Test func clipGainCounts() throws {
        let samples = Self.noise(seconds: 40) { $0 < 30 ? 0 : -12 }
        let spectrum = try Self.spectrum(samples, parts: [(0..<1_440_000, 0), (1_440_000..<1_920_000, 12)])
        #expect(spectrum.voiceFrames == 1_920_000, "voice frames \(spectrum.voiceFrames)")
    }
}

/// Noise whose band powers change by `slope` dB per decade (a power density of f^(slope / 10 - 1)),
/// periodic over 2^19 frames at 48 kHz, with random phases from `seed`, at a peak of 0.5.
func shapedNoise(slope: Double, seed: UInt64 = 7) -> [Float] {
    let points = 1 << 19
    let half = points / 2
    var state = seed
    var real = [Float](repeating: 0, count: half)
    var imaginary = [Float](repeating: 0, count: half)
    for bin in 1..<half {
        let frequency = Double(bin) * 48_000 / Double(points)
        guard (30...21_000).contains(frequency) else { continue }
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let phase = Double(state >> 11) / Double(1 << 53) * 2 * .pi
        let magnitude = pow(frequency, (slope / 10 - 1) / 2)
        (real[bin], imaginary[bin]) = (Float(magnitude * cos(phase)), Float(magnitude * sin(phase)))
    }
    var output = [Float](repeating: 0, count: points)
    let log2n = vDSP_Length(19)
    let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    real.withUnsafeMutableBufferPointer { real in
        imaginary.withUnsafeMutableBufferPointer { imaginary in
            var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
            output.withUnsafeMutableBufferPointer {
                $0.withMemoryRebound(to: DSPComplex.self) {
                    vDSP_ztoc(&split, 1, $0.baseAddress!, 2, vDSP_Length(half))
                }
            }
        }
    }
    let peak = output.map(abs).max()!
    return output.map { $0 * 0.5 / peak }
}

/// `seconds` of the periodic `noise` at 48 kHz, times `level(second)` in dB.
func repeated(_ noise: [Float], seconds: Double, level: (Int) -> Double = { _ in 0 }) -> [Float] {
    (0..<Int(seconds * 48_000)).map { frame in noise[frame % noise.count] * Float(pow(10, level(frame / 48_000) / 20)) }
}
