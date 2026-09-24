import AVFoundation
import Accelerate
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Finalize on disk: segment files in, WAVs and session edits out (criteria 4, 6, 7, 13, 14, 23,
/// 24).
struct FinalizeTests {
    let package: TakePackage

    init() throws { package = try TakePackage() }

    func clip(_ session: Session, _ track: TrackID = "t1") throws -> Clip {
        try #require(session.track(track)?.clips.first)
    }

    @Test func oneSegmentBecomesOneClipAtTheTakeAnchor() throws {
        let samples = sine(seconds: 2, rate: 48_000)
        try package.segment(samples: samples)

        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(session.recording == nil)
        // 96000 + 10 ms at 48 kHz - 48 frames of latency.
        #expect(try clip(session) == Clip(id: "take1-1-1", file: "take1-1-1", start: 96_432, offset: 0, length: 96_000))
        #expect(
            session.files["take1-1-1"]
                == AudioFile(
                    id: "take1-1-1", path: "take1-1-1.wav", layout: .mono, length: 96_000, capture: "take1-1-1"))
        let capture = try #require(session.captures["take1-1-1"])
        #expect(capture.deviceUID == "usb-1")
        #expect(capture.hostTimeNanos == takeStart + 10_000_000)
        #expect(capture.nominalSampleRate == 48_000)
        #expect(abs(capture.measuredSampleRate - 48_000) < 0.01)
        #expect(capture.resampledFromRate == nil)
        #expect(capture.driftCorrected)

        let wav = try readAudio(package.url.appending(path: "Clips/take1-1-1.wav"))
        #expect(wav.rate == 48_000)
        #expect(wav.bits == 24)
        #expect(wav.samples.count == 96_000)
        let error = zip(wav.samples, samples).map { abs($0 - $1) }.max() ?? 1
        #expect(error <= 0x1p-22)
    }

    @Test func aSegmentAt44100IsResampledAndKeepsItsAlignment() throws {
        var samples = [Float](repeating: 0, count: 88_200)
        samples[22_050] = 1
        try package.segment(header: TakePackage.header(rate: 44_100), samples: samples)

        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(session.captures["take1-1-1"]?.resampledFromRate == 44_100)
        let wav = try readAudio(package.url.appending(path: "Clips/take1-1-1.wav")).samples
        #expect(abs(wav.count - 96_000) <= 1)
        let peak = try #require(wav.indices.max { abs(wav[$0]) < abs(wav[$1]) })
        #expect(abs(peak - 24_000) <= 1)
        #expect(try clip(session).length.count == wav.count)
    }

    /// The control of criterion 14: with no resample, the impulse keeps its exact frame.
    @Test func aSegmentAt48000KeepsTheImpulseAtTheExactFrame() throws {
        var samples = [Float](repeating: 0, count: 96_000)
        samples[24_000] = 0.5
        try package.segment(header: TakePackage.header(rate: 48_000), samples: samples)

        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(session.captures["take1-1-1"]?.resampledFromRate == nil)
        let wav = try readAudio(package.url.appending(path: "Clips/take1-1-1.wav")).samples
        #expect(wav.count == 96_000)
        #expect(wav.indices.filter { wav[$0] != 0 } == [24_000])
        #expect(wav[24_000] == 0.5)
    }

    @Test func aHeaderWithNoCheckpointIsPlacedAtTheHeaderRateWithAWarning() throws {
        try package.segment(samples: sine(seconds: 2, rate: 48_000), checkpoints: [])

        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(try clip(session).start == 96_432)
        #expect(session.captures["take1-1-1"]?.driftCorrected == false)
        #expect(session.captures["take1-1-1"]?.resampledFromRate == nil)
    }

    @Test func aCAFWithNoFramesGivesNoClipAndIsNotUnplaced() throws {
        try package.segment(samples: [], checkpoints: [])

        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(session.recording == nil)
        #expect(session.files.isEmpty)
        #expect(unplacedSegments(segmentsWithAudio(in: package.url), session: session) == [])
    }

    @Test func aCAFWithNoSidecarIsUnplacedAndTheTakeEnds() throws {
        try package.segment(samples: sine(seconds: 1, rate: 48_000))
        try FileManager.default.removeItem(at: package.capture.appending(path: "take1-1-1.sidecar"))

        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(session.recording == nil)
        #expect(session.files.isEmpty)
        #expect(unplacedSegments(segmentsWithAudio(in: package.url), session: session) == ["take1-1-1"])
        #expect(FileManager.default.fileExists(atPath: package.capture.appending(path: "take1-1-1.caf").path))
    }

    @Test func noSegmentFilesGiveNoClipAndTheTakeEnds() throws {
        try FileManager.default.removeItem(at: package.capture)
        let before = try package.read()

        let session = try finalizeTake(of: before, in: package.url)

        var expected = before
        try expected.setRecording(nil)
        #expect(session == expected)
    }

    @Test func aLatencyLargerThanTheHostOffsetMovesIntoTheFileOffset() throws {
        let package = try TakePackage(playhead: 0)
        try package.segment(
            header: TakePackage.header(latency: 48, firstHost: takeStart), samples: sine(seconds: 1, rate: 48_000))

        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(try clip(session) == Clip(id: "take1-1-1", file: "take1-1-1", start: 0, offset: 48, length: 47_952))
    }

    @Test func aFirstFrameBeforeTheTakeStartMovesTheClipEarlier() throws {
        try package.segment(
            header: TakePackage.header(firstHost: takeStart - 5_000_000), samples: sine(seconds: 1, rate: 48_000))

        let session = try finalizeTake(of: package.read(), in: package.url)

        // 96000 - 5 ms at 48 kHz - 48 frames of latency.
        #expect(try clip(session).start == 95_712)
    }

    @Test func aSecondRunGivesTheSameSessionAndTheSameWAVBytes() throws {
        try package.segment(samples: sine(seconds: 2, rate: 48_000))
        let wav = package.url.appending(path: "Clips/take1-1-1.wav")

        let first = try finalizeTake(of: package.read(), in: package.url)
        let bytes = try Data(contentsOf: wav)
        // A crash in the first run left half the WAV.
        try bytes.prefix(bytes.count / 2).write(to: wav)
        let second = try finalizeTake(of: package.read(), in: package.url)

        #expect(second == first)
        #expect(try Data(contentsOf: wav) == bytes)
    }

    @Test func aSegmentAt24kHzIsRuleOneAndGetsTwiceItsFrames() throws {
        try package.segment(header: TakePackage.header(rate: 24_000), samples: sine(seconds: 1, rate: 24_000))

        let session = try finalizeTake(of: package.read(), in: package.url)

        let capture = try #require(session.captures["take1-1-1"])
        #expect(capture.resampledFromRate == 24_000)
        #expect(capture.driftCorrected)
        #expect(abs(try clip(session).length.count - 48_000) <= 1)
    }

    @Test func aFitThatIsNoAvailableRateIsRuleThree() throws {
        var header = TakePackage.header()
        header.availableRates = [44_100...48_000]
        let checkpoints = TakePackage.checkpoints(frames: 48_000, header: header, realRate: 44_100)
        try package.segment(header: header, samples: sine(seconds: 1, rate: 48_000), checkpoints: checkpoints)

        let session = try finalizeTake(of: package.read(), in: package.url)

        let capture = try #require(session.captures["take1-1-1"])
        #expect(capture.driftCorrected == false)
        #expect(capture.resampledFromRate == nil)
        #expect(abs(capture.measuredSampleRate - 44_100) < 0.01)
        #expect(try clip(session).length == 48_000)
    }

    /// 48002.4 Hz is 50 ppm over the header rate: 1 ms of drift at 48000 Hz is 960,048 frames.
    @Test(arguments: [(2_880_144, 2_880_000), (480_024, 480_024)])
    func aDriftOver1MillisecondIsCorrected(frames: Int, expected: Int) throws {
        let header = TakePackage.header()
        let checkpoints = TakePackage.checkpoints(frames: frames, header: header, realRate: 48_002.4)
        try package.segment(
            header: header, samples: [Float](repeating: 0, count: frames), checkpoints: checkpoints)

        let session = try finalizeTake(of: package.read(), in: package.url)

        let capture = try #require(session.captures["take1-1-1"])
        #expect(capture.driftCorrected)
        #expect(abs(capture.measuredSampleRate - 48_002.4) < 0.01)
        if frames == expected {
            // 10 s: 0.5 ms of drift.
            #expect(capture.resampledFromRate == nil)
            #expect(try clip(session).length.count == expected)
        } else {
            // 60 s: 3 ms of drift.
            #expect(abs(try #require(capture.resampledFromRate) - 48_002.4) < 0.01)
            #expect(abs(try clip(session).length.count - expected) <= 2)
        }
    }

    /// One converter for all blocks keeps its state, so 4096-frame blocks give the output of one
    /// whole-buffer conversion (criterion 23).
    @Test func smallBlocksGiveTheOutputOfOneWholeConversion() throws {
        let header = TakePackage.header()
        var samples = [Float](repeating: 0, count: 2_880_120)
        samples[2_400_100] = 1
        let checkpoints = TakePackage.checkpoints(frames: samples.count, header: header, realRate: 48_002.4)
        try package.segment(header: header, samples: samples, checkpoints: checkpoints)
        let session = try package.read()
        let rate = try #require(fittedRate(checkpoints))

        _ = try finalizeTake(of: session, in: package.url, blockFrames: 4096)

        let wav = try readAudio(package.url.appending(path: "Clips/take1-1-1.wav")).samples
        let whole = try convertWhole(samples, from: rate, to: 48_000)
        #expect(wav.count == 2_879_977)
        #expect(whole.count == wav.count)
        // vDSP, because a Swift closure over 2.9 million samples takes seconds in a debug build.
        #expect(vDSP.indexOfMaximumMagnitude(wav).0 == 2_399_980)
        #expect(vDSP.indexOfMaximumMagnitude(whole).0 == 2_399_980)
        #expect(vDSP.maximumMagnitude(vDSP.subtract(wav, whole)) <= 0x1p-22)
    }

    /// One call of one converter on the whole buffer, with the settings of finalize.
    func convertWhole(_ samples: [Float], from source: Double, to rate: Double) throws -> [Float] {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: source, channels: 1))
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let converter = try #require(AVAudioConverter(from: input, to: output))
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        let whole = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)))
        whole.frameLength = whole.frameCapacity
        try #require(whole.floatChannelData)[0].update(from: samples, count: samples.count)
        let converted = try #require(
            AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(samples.count + 4096)))
        let feed = OneBuffer(whole)
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            let buffer = feed.take()
            inputStatus.pointee = buffer == nil ? .endOfStream : .haveData
            return buffer
        }
        try #require(status != .error)
        return Array(
            UnsafeBufferPointer(start: try #require(converted.floatChannelData)[0], count: Int(converted.frameLength)))
    }
}

/// Gives its buffer once, then nil. The converter calls the input block on the calling thread.
private final class OneBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
