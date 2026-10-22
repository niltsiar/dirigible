import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The speech detection of a duck (decision 0060, C14), offline through `MixReader`. The fixtures
/// are 1 kHz tone bursts over a floor, each level the RMS level in dBFS.
struct SpeechActivityTests {
    /// A 1 kHz tone at 48 kHz for each part: its length in seconds and its RMS level in dBFS.
    static func tone(_ parts: [(seconds: Double, dBFS: Double)]) -> [Float] {
        var samples: [Float] = []
        for part in parts {
            let amplitude = 2.0.squareRoot() * pow(10, part.dBFS / 20)
            let start = samples.count
            for frame in start..<(start + Int(part.seconds * 48_000)) {
                samples.append(Float(amplitude * sin(2 * .pi * 1000 * Double(frame) / 48_000)))
            }
        }
        return samples
    }

    /// The runs of the tone of `parts` on track `t1`, with the default shape.
    func runs(_ parts: [(seconds: Double, dBFS: Double)]) throws -> [Range<Frames>] {
        let package = try MixPackage()
        let samples = Self.tone(parts)
        try package.addFile("f1", channels: [samples])
        let length = Frames(samples.count)
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: length)
        return try speechRuns(
            of: ["t1"], in: package.session, package: package.url, scope: 0..<length,
            shape: .defaults(sampleRate: 48_000)
        ).runs
    }

    /// Bursts at -20 dBFS over a -60 dBFS floor: the runs join across a 1.5 s gap and split at a
    /// 3 s gap, with the 2 s hold.
    @Test func aShortGapJoinsAndALongGapSplits() throws {
        let found = try runs([(1, -60), (2, -20), (1.5, -60), (2, -20), (3, -60), (2, -20), (1, -60)])
        #expect(found == [Frames(48_000)..<Frames(312_000), Frames(456_000)..<Frames(552_000)], "\(found)")
    }

    /// The threshold is -40 dBFS: a burst at -39 dBFS is speech, a burst at -41 dBFS is not.
    @Test func theThresholdIsMinus40() throws {
        #expect(try runs([(1, -60), (1, -39), (1, -60)]) == [Frames(48_000)..<Frames(96_000)])
        #expect(try runs([(1, -60), (1, -41), (1, -60)]).isEmpty)
    }

    /// A muted speech track and a soloed other track change no run: the read ignores the flags.
    @Test func muteAndSoloDoNotChangeTheRuns() throws {
        let package = try MixPackage()
        try package.addFile("f1", channels: [Self.tone([(1, -60), (1, -20), (1, -60)])])
        try package.addFile("f2", channels: [Self.tone([(3, -60)])])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 144_000)
        try package.addTrack("t2", clip: "c2", file: "f2", start: 0, offset: 0, length: 144_000)
        try package.session.setMuted(true, tracks: ["t1"])
        try package.session.setSoloed(true, tracks: ["t2"])
        let found = try speechRuns(
            of: ["t1"], in: package.session, package: package.url, scope: 0..<144_000,
            shape: .defaults(sampleRate: 48_000)
        ).runs
        #expect(found == [Frames(48_000)..<Frames(96_000)], "\(found)")
    }
}
