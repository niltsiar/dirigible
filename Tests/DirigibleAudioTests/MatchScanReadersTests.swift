import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Decision 0074: which readers of the mix hear the voice match. The duck scan, the silence scan,
/// and the loudness read go through `MixReader`, so they hear it. Auto Level reads the file and
/// the clip gain, so it does not. The fixture is a 1 kHz tone at -35 dBFS on a track whose match
/// cuts the 1 kHz band by 12 dB: the heard level falls under the -40 dBFS threshold.
struct MatchScanReadersTests {
    static let threshold = Gain(dB: -40)!
    static let frames: Frames = 192_000

    /// Track t1 with a clip of the tone, with a match at amount 100 that cuts the band at 1 kHz.
    static func package(matched: Bool) throws -> MixPackage {
        let package = try MixPackage()
        try package.addFile("f1", channels: [SpeechActivityTests.tone([(4, -35)])])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: frames)
        guard matched else { return package }
        let band = try #require(ThirdOctave.centers.firstIndex(of: 1000))
        let curve = (0..<ThirdOctave.bandCount).map { $0 == band ? -12.0 : 0 }
        let match = try VoiceMatch(
            amount: #require(VoiceMatch.Amount(100)), isBypassed: false, reference: "Host",
            curve: curve, targetPowers: [Double](repeating: 1, count: ThirdOctave.bandCount))
        try package.session.setMatch(["t1": match])
        return package
    }

    @Test func duckAndSilenceScansAndTheLoudnessReadHearTheMatchAndAutoLevelDoesNot() throws {
        let plain = try Self.package(matched: false)
        let matched = try Self.package(matched: true)

        func speech(_ package: MixPackage) throws -> [Range<Frames>] {
            try speechRuns(
                of: ["t1"], in: package.session, package: package.url, scope: 0..<Self.frames,
                shape: .defaults(sampleRate: 48_000)
            ).runs
        }
        #expect(try speech(plain) == [0..<Self.frames], "the plain tone is speech")
        #expect(try speech(matched).isEmpty, "the duck scan hears the cut")

        func silences(_ package: MixPackage) throws -> [Range<Frames>] {
            try checkedMixLevels(
                of: ["t1"], in: package.session, package: package.url, range: 0..<Self.frames, silence: Self.threshold
            ).silences(threshold: Self.threshold, minLength: 24_000, in: 0..<Self.frames)
        }
        #expect(try silences(plain).isEmpty, "the plain tone is no silence")
        #expect(try silences(matched) == [0..<Self.frames], "the silence scan hears the cut")

        func loudness(_ package: MixPackage) throws -> Double {
            let read = try measureMix(
                of: ["t1"], in: package.session, package: package.url, range: 0..<Self.frames)
            return try #require(read.measure.integrated).value
        }
        let drop = try loudness(plain) - loudness(matched)
        #expect(drop > 6, "the loudness read hears the cut: \(drop) LU")

        func gain(_ package: MixPackage) throws -> Gain {
            let (session, levels) = autoLevel(["c1"], .eachClip, of: package.session, in: package.url)
            guard case .leveled = levels["c1"] else { throw LevelFailure(levels: levels) }
            return try #require(session.clip("c1")?.clip.gain)
        }
        let plainGain = try gain(plain)
        #expect(plainGain != Gain.zero, "Auto Level changes the gain of the plain tone")
        #expect(try gain(matched) == plainGain, "Auto Level does not hear the match")
    }

    struct LevelFailure: Error { let levels: [ClipID: ClipLevel] }
}
