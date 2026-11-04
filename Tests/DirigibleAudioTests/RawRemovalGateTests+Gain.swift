import AVFoundation
import Accelerate
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// `rawGain` (decision 0071, C2d): the conversion gain of a segment with no finalize record, from
/// its WAV peak first and else from one converter pass of its CAF.
extension RawRemovalGateTests {
    static let segment = SegmentName(stem: "take1-1-1")!

    /// The peak magnitude of the WAV of `package` as a 24-bit code.
    static func wavCode(_ package: TakePackage) throws -> Int {
        let samples = try readAudio(package.url.appending(path: "Clips/take1-1-1.wav")).samples
        return Int((Double(vDSP.maximumMagnitude(samples)) * 8_388_608).rounded())
    }

    /// Writes `samples` (mono, 48 kHz) as the 24-bit WAV of the segment with the clip writer of
    /// finalize, as a build before the clip gain did: a sample over full scale saturates.
    static func writeWAV(_ samples: [Float], in package: TakePackage) throws {
        let clips = package.url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let top = Float(8_388_607) / 8_388_608
        for (index, sample) in samples.enumerated() { buffer.floatChannelData![0][index] = min(max(sample, -1), top) }
        let writer = try ClipWriter(
            url: clips.appending(path: "take1-1-1.wav"), file: "Clips/take1-1-1.wav", format: format)
        try writer.write(buffer)
        try writer.close()
    }

    /// `rawGain` of the segment, and the count of its passes over the CAF (block 0 reads).
    static func gain(_ package: TakePackage) throws -> (gain: Gain?, cafPasses: Int) {
        let reads = StepCounter()
        let gain = try rawGain(
            of: segment, in: package.url, isCancelled: { false },
            readFault: ReadFault(stem: segment.stem, block: 0) { _ = reads.next() })
        return (gain, reads.calls)
    }

    /// A WAV peak at code 8388604 or less is a WAV that no rescale wrote, so its gain is 0 dB and
    /// the CAF stays unread. At code 8388605 the CAF pass gives the gain.
    @Test func aWAVPeakAtCode8388604ReadsNoCAFBlock() throws {
        let package = try TakePackage()
        try package.segment(samples: sine(seconds: 1, rate: 48_000).map { $0 * 4 })
        for (code, gain, passes) in [(8_388_604, 0.0, 0), (8_388_605, 20 * log10(2 / (1 - 0x1p-22)), 1)] {
            var samples = [Float](repeating: 0.25, count: 48_000)
            samples[100] = Float(code) / 8_388_608
            try Self.writeWAV(samples, in: package)
            try #require(try Self.wavCode(package) == code)

            let result = try Self.gain(package)

            #expect(abs((result.gain?.dB ?? .nan) - gain) < 1e-4, "code \(code)")
            #expect(result.cafPasses == passes, "code \(code)")
        }
    }

    /// The real writer puts a rescaled peak at code 8388605 or 8388606, on each side: so the WAV
    /// peak alone cannot give the gain, and the converter pass gives the gain of the finalize.
    @Test(arguments: [Float(1), -1])
    func aRescaledWAVGetsTheClipGainOfItsConvert(side: Float) throws {
        let package = try TakePackage()
        // Peak 2.0 on `side` only: the other side stays at 0.5.
        try package.segment(samples: sine(seconds: 1, rate: 48_000).map { $0 * side > 0 ? $0 * 4 : $0 })
        let session = try finalizeTake(of: package.read(), in: package.url)
        let clipGain = try #require(session.track("t1")?.clips.first).gain
        #expect(abs(clipGain.dB - 6.0206) < 1e-3)
        #expect([8_388_605, 8_388_606].contains(try Self.wavCode(package)))

        let result = try Self.gain(package)

        #expect(result.gain == clipGain)
        #expect(result.cafPasses == 1)
    }

    /// A 44.1 kHz tone at a quarter of the rate, 45 degrees off its peaks: each CAF sample is at
    /// 0.92, but the resampled tone reaches 1.3. So only the pass through the converter gives the
    /// gain.
    @Test func aResampledPeakOverFullScaleFromASourceUnderItGetsTheClipGain() throws {
        let package = try TakePackage()
        let samples = (0..<88_200).map { Float(1.3 * sin(Double.pi / 2 * Double($0) + Double.pi / 4)) }
        #expect(vDSP.maximumMagnitude(samples) < 1, "the raw peak is under full scale")
        try package.segment(header: TakePackage.header(rate: 44_100), samples: samples)
        let session = try finalizeTake(of: package.read(), in: package.url)
        #expect(session.captures["take1-1-1"]?.resampledFromRate == 44_100)
        let clipGain = try #require(session.track("t1")?.clips.first).gain
        #expect(clipGain.dB > 0, "the resampled peak is over full scale")

        let result = try Self.gain(package)

        #expect(result.gain == clipGain)
    }

    /// A WAV of a build before the clip gain saturates at full scale with gain 0 dB. Its CAF peak
    /// is 2.0, but its gain stays 0 dB: a boost would play it louder than the take.
    @Test(arguments: [Float(1), -1])
    func aSaturatedWAVKeepsGainZero(side: Float) throws {
        let package = try TakePackage()
        let samples = sine(seconds: 1, rate: 48_000).map { $0 * side > 0 ? $0 * 4 : $0 }
        try package.segment(samples: samples)
        try Self.writeWAV(samples, in: package)
        #expect(try Self.wavCode(package) == (side > 0 ? 8_388_607 : 8_388_608))

        let result = try Self.gain(package)

        #expect(result.gain == .zero)
        #expect(result.cafPasses == 1, "the CAF pass ran")
    }
}
