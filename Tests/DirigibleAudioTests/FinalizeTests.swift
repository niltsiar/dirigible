import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Finalize on disk: segment files in, WAVs and session edits out (criteria 4, 6, 7, 14, 24).
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
        #expect(unplacedSegments(in: package.url, session: session) == [])
    }

    @Test func aCAFWithNoSidecarIsUnplacedAndTheTakeEnds() throws {
        try package.segment(samples: sine(seconds: 1, rate: 48_000))
        try FileManager.default.removeItem(at: package.capture.appending(path: "take1-1-1.sidecar"))

        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(session.recording == nil)
        #expect(session.files.isEmpty)
        #expect(unplacedSegments(in: package.url, session: session) == ["take1-1-1"])
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
}
