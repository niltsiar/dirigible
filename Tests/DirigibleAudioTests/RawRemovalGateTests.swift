import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The gate of decision 0071: a placed segment loses its CAF only when its WAV frames, its rate
/// choice, and its alignment to the host clock pass. Each clause has a red input and a near input
/// that passes. The sidecars come from the real encoder.
struct RawRemovalGateTests {
    /// `points` with a parabola added to the host time of checkpoint i: 0 at both ends and `bow`
    /// seconds at the middle checkpoint, which is then the WAV error of that checkpoint.
    static func bowed(_ points: [Checkpoint], bow: Double) -> [Checkpoint] {
        let last = Double(points.count - 1)
        return points.enumerated().map { index, point in
            var point = point
            let u = Double(index) / last
            point.hostTimeNanos += UInt64((bow * 1e9 * 4 * u * (1 - u)).rounded())
            return point
        }
    }

    /// A sidecar of `frames` frames with a header at `rate`, a checkpoint at each second and at the
    /// last frame on a clock that runs at `realRate` (`TakePackage.checkpoints`), and `bow`.
    static func sidecar(
        rate: Double = 48_000, frames: Int = 192_000, realRate: Double? = nil, bow: Double = 0,
        checkpoints: Bool = true
    ) throws -> Sidecar {
        let header = TakePackage.header(rate: rate)
        let points = TakePackage.checkpoints(frames: frames, header: header, realRate: realRate)
        let bytes = (checkpoints ? bowed(points, bow: bow) : []).reduce(Sidecar.encode(header)) {
            $0 + Sidecar.encode($1)
        }
        return try #require(try Sidecar.decode(bytes))
    }

    static func file(length: Int) -> AudioFile {
        AudioFile(id: "take1-1-1", path: "take1-1-1.wav", layout: .mono, length: Frames(length), capture: "take1-1-1")
    }

    static func capture(resampledFrom source: Double? = nil, driftCorrected: Bool = true) -> Capture {
        Capture(
            id: "take1-1-1", deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: takeStart + 10_000_000,
            sampleTime: 512, nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 48,
            resampledFromRate: source, driftCorrected: driftCorrected)
    }

    /// A same-rate segment of 4 s at 48 kHz.
    static func sameRateVerdict(
        bow: Double = 0, wav: Int = 192_000, length: Int = 192_000, capture: Capture = capture(),
        checkpoints: Bool = true
    ) throws -> RawVerdict {
        rawVerdict(
            sidecar: try sidecar(bow: bow, checkpoints: checkpoints), cafFrames: 192_000, wavFrames: wav,
            file: file(length: length), capture: capture, sessionRate: 48_000)
    }

    /// A segment of 2,881,041 CAF frames (60 s) on a 48 kHz device whose clock runs 50 ppm fast
    /// (48,002.4 Hz). The drift passes 1 ms, so finalize resamples from the fitted rate, and the WAV
    /// has 2,881,041 x 48,000 / 48,002.4 = 2,880,896.955 frames (probe in the run folder).
    static let resampledFrames = 2_881_041

    static func resampledVerdict(wav: Int, length: Int? = nil, resampledFrom: Double?? = nil) throws -> RawVerdict {
        let sidecar = try sidecar(frames: resampledFrames, realRate: 48_002.4)
        // The capture that finalize writes: its source rate is the fitted rate.
        let source = RateChoice(header: sidecar.header, checkpoints: sidecar.checkpoints, frames: resampledFrames)
            .source
        #expect(abs(source - 48_002.4) < 1e-3, "the fixture resamples from the fitted rate")
        return rawVerdict(
            sidecar: sidecar, cafFrames: resampledFrames, wavFrames: wav, file: file(length: length ?? wav),
            capture: capture(resampledFrom: resampledFrom ?? source), sessionRate: 48_000)
    }

    /// A finalized take of two arms of 4 s with the real writer and finalize: arm 1 on a 48 kHz
    /// device with `bows.0`, arm 2 on a 44.1 kHz device with `bows.1`, in a 48 kHz session.
    static func twoClockTake(bows: (Double, Double)) throws -> (TakePackage, Session) {
        let package = try TakePackage(tracks: [("t1", .mono), ("t2", .mono)])
        for (arm, rate, bow) in [(1, 48_000.0, bows.0), (2, 44_100.0, bows.1)] {
            let header = TakePackage.header(rate: rate)
            let points = TakePackage.checkpoints(frames: 4 * Int(rate), header: header)
            try package.segment(
                arm: arm, header: header, samples: sine(seconds: 4, rate: rate), checkpoints: bowed(points, bow: bow))
        }
        return (package, try finalizeTake(of: package.read(), in: package.url))
    }

    static let first = SegmentName(stem: "take1-1-1")!
    static let second = SegmentName(stem: "take1-2-1")!

    // MARK: C2c G3

    @Test func aBowOverOneMillisecondKeepsTheCAF() throws {
        guard case .alignment(let error) = try Self.sameRateVerdict(bow: 1.07e-3) else {
            Issue.record("a 1.07 ms bow is not an alignment verdict")
            return
        }
        #expect(abs(error - 1.07e-3) < 1e-6)
        #expect(try Self.sameRateVerdict(bow: 0.875e-3) == .removable)
    }

    // MARK: C2a G1

    @Test func aSameRateWAVOneFrameShortKeepsTheCAF() throws {
        #expect(try Self.sameRateVerdict(wav: 191_999, length: 191_999) == .frames)
        #expect(try Self.sameRateVerdict() == .removable)
    }

    @Test func aResampledWAVTwoFramesShortKeepsTheCAF() throws {
        #expect(try Self.resampledVerdict(wav: 2_880_895) == .frames)
        #expect(try Self.resampledVerdict(wav: 2_880_896) == .removable, "-0.955 frames")
        #expect(try Self.resampledVerdict(wav: 2_880_897) == .removable, "+0.045 frames")
        #expect(try Self.resampledVerdict(wav: 2_880_898) == .frames)
    }

    @Test func aPoolLengthOneFrameOffTheDiskWAVKeepsTheCAF() throws {
        #expect(try Self.sameRateVerdict(length: 192_001) == .frames)
        #expect(try Self.resampledVerdict(wav: 2_880_896, length: 2_880_897) == .frames)
    }

    // MARK: C2b G2

    @Test func aCaptureWithNoDriftCorrectionKeepsTheCAF() throws {
        #expect(try Self.sameRateVerdict(capture: Self.capture(driftCorrected: false)) == .rateChoice)
    }

    @Test func aCaptureWhoseSourceRateIsNotTheSidecarChoiceKeepsTheCAF() throws {
        #expect(try Self.sameRateVerdict(capture: Self.capture(resampledFrom: 48_000.5)) == .rateChoice)
        #expect(try Self.resampledVerdict(wav: 2_880_896, resampledFrom: .some(nil)) == .rateChoice)
        #expect(try Self.resampledVerdict(wav: 2_880_896, resampledFrom: 48_002.5) == .rateChoice)
    }

    /// No checkpoint gives no usable fit. G3 alone would pass it: no checkpoint has an error.
    @Test func aSidecarWithNoUsableFitKeepsTheCAF() throws {
        #expect(try Self.sameRateVerdict(checkpoints: false) == .rateChoice)
    }

    @Test(arguments: ["missing", "refused", "newer"])
    func aSegmentWhoseSidecarDoesNotReadKeepsTheCAF(fault: String) throws {
        let (package, session) = try Self.twoClockTake(bows: (0, 0))
        #expect(rawCaptures(of: session, in: package.url)[Self.first] == .removable)
        let sidecar = package.capture.appending(path: "take1-1-1.sidecar")
        switch fault {
        case "missing": try FileManager.default.removeItem(at: sidecar)
        case "refused": try setMagicDigit(sidecar, "0")
        default: try setMagicDigit(sidecar, "2")
        }

        let verdicts = rawCaptures(of: session, in: package.url)

        #expect(verdicts[Self.first] == .rateChoice)
        #expect(verdicts[Self.second] == .removable)
    }

    // MARK: C2f

    /// The gate is per track: two tracks of one take on two clocks get their own verdicts.
    @Test(arguments: [false, true])
    func eachTrackOfATwoClockTakeHasItsOwnVerdict(swapped: Bool) throws {
        let (package, session) = try Self.twoClockTake(bows: swapped ? (1.1e-3, 0.9e-3) : (0.9e-3, 1.1e-3))
        #expect(session.captures["take1-2-1"]?.resampledFromRate == 44_100, "the 44.1 kHz track resamples")
        let (passing, kept) = swapped ? (Self.second, Self.first) : (Self.first, Self.second)

        let verdicts = rawCaptures(of: session, in: package.url)

        #expect(verdicts.count == 2)
        #expect(verdicts[passing] == .removable)
        guard case .alignment(let error) = verdicts[kept] else {
            Issue.record("the 1.1 ms track \(kept) has no alignment verdict")
            return
        }
        #expect(abs(error - 1.1e-3) < 1e-6)
    }
}
