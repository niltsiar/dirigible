import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Feeds stereo `channels` at 48 kHz to a new range meter in blocks of 48 000 frames.
func rangeMeasure(_ channels: [[Float]]) throws -> MixMeasure {
    var meter = RangeMeter(sampleRate: 48_000)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
    var start = 0
    while start < channels[0].count {
        let count = min(48_000, channels[0].count - start)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![index].update(from: $0.baseAddress! + start, count: count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        meter.feed(buffer)
        start += count
    }
    return meter.result()
}

/// A Tech 3342 loudness range case: 1 kHz stereo tone parts at per-channel peak levels, and the
/// hand value of probe P4 of run 2026-10-23-read-by-time.
struct RangeCase: Sendable, CustomStringConvertible {
    let name: String
    let parts: [(seconds: Double, dBFS: Double)]
    let expected: Double

    var description: String { name }

    /// EBU Tech 3342 Table 1 cases 1 to 4, and a case that tells P95 from P90 (P90 gives 2.79 LU).
    static let all = [
        RangeCase(name: "case 1", parts: [(20, -20), (20, -30)], expected: 10),
        RangeCase(name: "case 2", parts: [(20, -20), (20, -15)], expected: 5),
        RangeCase(name: "case 3", parts: [(20, -40), (20, -20)], expected: 20),
        RangeCase(name: "case 4", parts: [(20, -50), (20, -35), (20, -20), (20, -35), (20, -50)], expected: 15),
        RangeCase(name: "90 s at -30, then 10 s at -20", parts: [(90, -30), (10, -20)], expected: 10),
    ]
}

/// The range meter of `meter` (decision 0062, criteria C5 and C6): BS.1770 integrated loudness,
/// the Tech 3342 loudness range, max momentary, max short-term, true peak, and sample peak.
struct RangeMeterTests {
    /// The relative gate at -10 LU reads 1.33 LU for case 3.
    @Test(arguments: RangeCase.all)
    func loudnessRangeOfTheTech3342Cases(_ check: RangeCase) throws {
        let range = try rangeMeasure(tone(check.parts)).loudnessRange
        let near = range.map { abs($0 - check.expected) <= 0.05 } ?? false
        #expect(near, "\(check): read \(range.map { "\($0)" } ?? "nil") LU, not \(check.expected)")
    }

    /// Tech 3341 cases 1, 9, and 12, and case 19 for the peaks. In case 9 the largest 400 ms block
    /// reads -20, so a max short-term over the blocks fails.
    @Test func valuesOfTheTech3341Cases() throws {
        let case1 = try rangeMeasure(tone([(20, -23)]))
        expectLUFS(case1.integrated, -23, "I of case 1")
        expectLUFS(case1.maxMomentary, -23, "max M of case 1")
        expectLUFS(case1.maxShortTerm, -23, "max S of case 1")

        let case9 = try rangeMeasure(tone(Array(repeating: [(1.34, -20), (1.66, -30)], count: 5).flatMap { $0 }))
        expectLUFS(case9.maxShortTerm, -23, "max S of case 9")
        expectLUFS(case9.maxMomentary, -20, "max M of case 9")

        let case12 = try rangeMeasure(tone(Array(repeating: [(0.18, -20), (0.22, -30)], count: 25).flatMap { $0 }))
        expectLUFS(case12.maxMomentary, -23, "max M of case 12")

        let case19 = try #require(TruePeakCase.all.last)
        let peaks = try rangeMeasure(case19.signal(rate: 48_000))
        expectDBTP(peaks.truePeak, 3, "true peak of case 19")
        // The fs/4 samples at 45 degrees are 1.41 x sin(45 degrees): -0.03 dBFS.
        let samplePeak = peaks.samplePeak ?? .nan
        #expect(abs(samplePeak + 0.03) <= 0.01, "sample peak of case 19: \(samplePeak) dBFS")

        let fullScale = try rangeMeasure(tone([(1, 0)])).samplePeak
        #expect(fullScale == 0, "sample peak of a full-scale sine: \(fullScale.map { "\($0)" } ?? "nil") dBFS")
    }

    /// A value with no data is none: under 400 ms max momentary, under 3 s max short-term and the
    /// range, and for digital silence every loudness value.
    @Test func aShortRangeHasNoMaxShortTermAndNoRange() throws {
        let short = try rangeMeasure(tone([(0.3, -23)]))
        #expect(
            short.maxMomentary == nil && short.maxShortTerm == nil && short.loudnessRange == nil
                && short.integrated == nil, "0.3 s: \(short)")
        let two = try rangeMeasure(tone([(2, -23)]))
        expectLUFS(two.maxMomentary, -23, "max M of 2 s")
        #expect(two.maxShortTerm == nil && two.loudnessRange == nil, "2 s: \(two)")
        let silence = try rangeMeasure(tone([(5, -.infinity)]))
        #expect(
            silence.integrated == nil && silence.maxMomentary == nil && silence.maxShortTerm == nil
                && silence.loudnessRange == nil && silence.truePeak == nil && silence.samplePeak == nil,
            "silence: \(silence)")
    }

    /// Two mono tracks of a 1 kHz tone at a peak of 0.75 sum to 1.5: +3.5 dBFS.
    @Test func aMixOverFullScaleReportsAPositivePeak() throws {
        let package = try MixPackage()
        try package.addFile("f1", channels: [tone([(1, 20 * log10(0.75))])[0]])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 48_000)
        try package.addTrack("t2", clip: "c2", file: "f1", start: 0, offset: 0, length: 48_000)
        let peak = try measureMix(of: nil, in: package.session, package: package.url, range: 0..<48_000)
            .measure.samplePeak
        let near = peak.map { abs($0 - 20 * log10(1.5)) <= 0.01 } ?? false
        #expect(near, "sample peak: \(peak.map { "\($0)" } ?? "nil") dBFS, not +3.5")
    }

    /// Track t1 has a tone at -20 dBFS, t2 a tone at -10 dBFS. A muted track is not in the meter,
    /// a soloed track alone is, and an envelope of -20 dB on t1 reads -40.
    @Test func measureMixReadsTheEnvelopeAndTheHeardTracks() throws {
        let package = try MixPackage()
        try package.addFile("quiet", channels: [tone([(10, -20)])[0]])
        try package.addFile("loud", channels: [tone([(10, -10)])[0]])
        try package.addTrack("t1", clip: "c1", file: "quiet", start: 0, offset: 0, length: 480_000)
        try package.addTrack("t2", clip: "c2", file: "loud", start: 0, offset: 0, length: 480_000)
        func integrated() throws -> LUFS? {
            try measureMix(of: nil, in: package.session, package: package.url, range: 0..<480_000).measure.integrated
        }
        try package.session.setMuted(true, tracks: ["t2"])
        expectLUFS(try integrated(), -20, "t2 muted")
        try package.session.setMuted(false, tracks: ["t2"])
        try package.session.setSoloed(true, tracks: ["t2"])
        expectLUFS(try integrated(), -10, "t2 soloed")

        let ducked = try MixPackage()
        try ducked.addFile("quiet", channels: [tone([(10, -20)])[0]])
        let minus20 = try #require(Gain(dB: -20))
        let envelope = try #require(GainEnvelope([.init(frame: 0, gain: minus20)]))
        try ducked.addTrack("t1", clip: "c1", file: "quiet", start: 0, offset: 0, length: 480_000, envelope: envelope)
        let measure = try measureMix(of: nil, in: ducked.session, package: ducked.url, range: 0..<480_000).measure
        expectLUFS(measure.integrated, -40, "envelope -20 dB")
    }

    /// A session with a muted loud track and an envelope ramp: the integrated value of the whole
    /// session equals the measure of a WAV export with a target.
    @Test func theMeterOfTheWholeSessionIsTheExportMeasure() throws {
        let package = try MixPackage()
        try package.addFile("voice", channels: [tone([(4, -30), (6, -18)])[0]])
        try package.addFile("loud", channels: [tone([(10, -6)])[0]])
        let minus12 = try #require(Gain(dB: -12))
        let envelope = try #require(
            GainEnvelope([.init(frame: 96_000, gain: .zero), .init(frame: 288_000, gain: minus12)]))
        try package.addTrack("t1", clip: "c1", file: "voice", start: 0, offset: 0, length: 480_000, envelope: envelope)
        try package.addTrack("t2", clip: "c2", file: "loud", start: 0, offset: 0, length: 480_000)
        try package.session.setMuted(true, tracks: ["t2"])
        let source = try #require(ExportSource(range: 0..<480_000))
        let exported = try exportMix(
            package.session, source: source,
            options: ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .session, loudness: .podcast),
            to: package.folder.url.appending(path: "mix.wav"), package: { package.url })
        let reference = try #require(exported.loudness?.measured)
        let read = try measureMix(of: nil, in: package.session, package: package.url, range: 0..<480_000)
        expectLUFS(read.measure.integrated, reference.value, tolerance: 0.05, "the export measure")
    }

    /// A mono track goes to both channels at unity: a -23 dBFS tone reads -23 LUFS, 3.0 LU over
    /// the one-channel value of -26 (`LoudnessTests.monoSineReadsThreeLower`).
    @Test func aMonoTrackReadsAsItsStereoMix() throws {
        let package = try MixPackage()
        try package.addFile("f1", channels: [tone([(20, -23)])[0]])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 960_000)
        let read = try measureMix(of: nil, in: package.session, package: package.url, range: 0..<960_000)
        expectLUFS(read.measure.integrated, -23, "a mono track")
    }
}
