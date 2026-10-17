import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Track fader C3b: the A11 gain of the conversion stays inside `Gain.range`.
extension ImportTests {
    /// A sine of 0.5 at 1 kHz, 48 000 frames, with one sample of `spike` at frame 100.
    private func spiked(_ spike: Float) -> [Float] {
        var samples = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        samples[100] = spike
        return samples
    }

    /// A finite peak that needs more than +96 dB still gets the second pass: no sample saturates,
    /// and the clip gain stops at the range end.
    @Test func aHugeFloatPeakGetsTheSecondPass() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        try writeSource(package.source("Spike.wav"), .wavFloat, rate: 48_000, channels: [spiked(1e5)])

        let result = try importAudio(
            package.source("Spike.wav"), to: ImportTarget(track: "t1", start: 0), of: package.session,
            in: package.url, level: false)

        let wav = try ImportedWAV(package.clip("Spike.wav"))
        let peak = wav.channels[0].map(abs).max() ?? 0
        #expect(peak < 1, "C3b: the second pass scales the spike under full scale")
        #expect(result.session.clip(result.clip)?.clip.gain.dB == 96, "C3b: the clip gain stops at +96 dB")
    }

    /// Agent-pack C4: a given gain is the clip gain, and no level runs. The level gives this sine
    /// another gain, so the fixture shows the level.
    @Test func anImportWithAGainRunsNoLevel() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        try writeSource(package.source("Voice.wav"), .wav24, rate: 48_000, channels: [sine(seconds: 3, rate: 48_000)])
        let gain = try #require(Gain(dB: -6))

        let leveled = try importAudio(
            package.source("Voice.wav"), to: ImportTarget(track: "t1", start: 0), of: package.session,
            in: package.url)
        let given = try importAudio(
            package.source("Voice.wav"), to: ImportTarget(track: "t1", start: 192_000, gain: gain),
            of: leveled.session, in: package.url)

        let levelGain = try #require(given.session.clip(leveled.clip)?.clip.gain.dB)
        #expect(abs(levelGain + 6) > 1, "the level gives another gain: \(levelGain) dB")
        #expect(given.session.clip(given.clip)?.clip.gain.dB == -6, "the given gain, with no level")
    }

    /// A peak that is not finite keeps one pass and 0 dB, so the other samples keep their level.
    @Test func anInfinitePeakKeepsOnePass() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        try writeSource(package.source("Inf.wav"), .wavFloat, rate: 48_000, channels: [spiked(.infinity)])

        let result = try importAudio(
            package.source("Inf.wav"), to: ImportTarget(track: "t1", start: 0), of: package.session,
            in: package.url, level: false)

        let wav = try ImportedWAV(package.clip("Inf.wav"))
        let quarter = abs(wav.channels[0][12])  // sin(pi / 2) x 0.5 at frame 12
        #expect(result.session.clip(result.clip)?.clip.gain == .zero, "C3b: an infinite peak keeps 0 dB")
        #expect(abs(quarter - 0.5) < 0.01, "C3b: the other samples keep their level")
    }
}
