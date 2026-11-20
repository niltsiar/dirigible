import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Decision 0077 D10: with a `DriftCause`, the fix moves the clip by the 0076 lag, writes no file,
/// and names the cause.
extension StudioDriftTests {
    /// A clip on a take file, a clip on a rendered file, and a clip with points in 2 cells of 5 (no
    /// fit). Each clip "T" on track "t" plays a copy of the 5 min drift clip.
    @Test func eachCauseMovesTheClipAndWritesNoFile() async throws {
        let voice = DriftSignal(seed: 1, seconds: 30 + 300 * 1.01 + 60)
        let cases: [(String, DriftCause, (DriftPackage) throws -> Void, DriftPackage.Make?)] = [
            ("take file", .takeFile, { try Self.addCopy("take", of: $0, capture: "take") }, nil),
            (
                "rendered file", .renderedFile,
                { drift in
                    let origin = RenderOrigin(
                        source: "c", offset: 0, treatment: Treatment(.noise(.standard)), addedGain: .zero)
                    try Self.addCopy("rendered", of: drift, origin: origin)
                }, nil
            ),
            (
                "no fit", .noFit(.tooFewPoints), { try Self.addCopy("quiet", of: $0) },
                { drift, range in
                    var samples = voice.clip(drift, range)
                    for frame in (60 * drift.rate..<240 * drift.rate).clamped(to: range) {
                        samples[frame - range.lowerBound] = 0
                    }
                    return samples
                }
            ),
        ]
        for (name, cause, edit, clip) in cases {
            let drift = try DriftPackage(seconds: 300, voice: voice, clip: clip)
            try edit(drift)
            try await Self.expectMovedByTheLag("T", drift, cause: cause, name)
        }
    }

    /// A split half of a take has a capture that is not its own ID: it is no take file, and it is
    /// not corrected either.
    @Test func aSplitHalfOfATakeIsNotCorrected() async throws {
        let drift = try DriftPackage(seconds: 300)
        try Self.addCopy("half", of: drift, capture: "take")
        #expect(drift.package.session.files["half"]?.isTakeFile == false)
        try await Self.expectMovedByTheLag("T", drift, cause: .takeFile, "split half")
    }

    /// Clip "T" plays a copy of the 5 min clip at 100 ppm with a drift link to "c" of ratio
    /// 1 - 950e-6: the composed ratio is about 1 - 1050e-6, so the fix writes no file. With a link
    /// of ratio 1 - 800e-6 the composed ratio is about 1 - 900e-6, and the fix resamples "c".
    @Test func aComposedRatioOverTheLimitWritesNoFile() async throws {
        let over = try DriftPackage(seconds: 300)
        try Self.addCopy("first", of: over, drift: try Self.link(ratio: 1 - 950e-6))
        try await Self.expectMovedByTheLag("T", over, cause: .composedRateOutOfRange, "1050 ppm")

        let under = try DriftPackage(seconds: 300)
        let first = try Self.link(ratio: 1 - 800e-6)
        try Self.addCopy("first", of: under, drift: first)
        let studio = try await Self.open(under)
        let fix = try Self.fix(try await studio.correctDrift("T", to: "ref"))
        let link = try #require(studio.session.files[fix.files[0]]?.drift)
        #expect(link.source == "c" && abs(link.ratio.value - (1 - 900e-6)) < 2e-6, "\(link)")
    }

    /// A 10 min line whose lag changes by 0.9 ms (1.5 ppm) is not corrected; 1.1 ms is.
    @Test func theOneMillisecondLine() async throws {
        try await Self.expectMovedByTheLag("C", try DriftPackage(seconds: 600, ppm: 1.5), cause: .underOneMillisecond)
        let drift = try DriftPackage(seconds: 600, ppm: 1.1 / 600 * 1000)
        let studio = try await Self.open(drift)
        _ = try Self.fix(try await studio.correctDrift("C", to: "ref"))
    }

    /// A clip of 299 s is not measured; a clip of 300 s is corrected.
    @Test func theFiveMinuteLine() async throws {
        try await Self.expectMovedByTheLag("C", try DriftPackage(seconds: 299), cause: .clipTooShort)
        let drift = try DriftPackage(seconds: 300)
        let studio = try await Self.open(drift)
        _ = try Self.fix(try await studio.correctDrift("C", to: "ref"))
    }
}

extension StudioDriftTests {
    /// The fix of `clip` on the package of `drift` names `cause`, moves the clip by the lag of
    /// `syncLag`, writes no file in `Clips/`, and saves the move as one undo entry.
    static func expectMovedByTheLag(
        _ clip: ClipID, _ drift: DriftPackage, cause: DriftCause, _ name: String = ""
    ) async throws {
        let session = drift.package.session
        let url = drift.package.url
        let lag = try syncLag(
            of: clip, to: "ref", in: session, package: url, span: session.syncSpan(clip, to: "ref")
        ).lag
        let start = try #require(session.clip(clip)?.clip.start)
        let studio = try await Self.open(drift)
        let names = Self.clipsNames(url)

        let report = try await studio.correctDrift(clip, to: "ref")

        #expect(report.outcome == .notCorrected(cause), "\(name): \(report.outcome)")
        #expect(report.sync.lag == lag && studio.session.clip(clip)?.clip.start == start + lag, "\(name)")
        #expect(Self.clipsNames(url) == names, "\(name): a file was written")
        #expect(try Session(contentsOf: url) == studio.session && studio.canUndo, "\(name): the move did not save")
    }

    /// Copies the WAV of clip "C" to `<id>.wav`, adds it to the pool as `id` with `capture`,
    /// `origin`, or `drift`, and puts it on the new track "t" as clip "T" at the place of "C". A
    /// capture gets a session capture record.
    static func addCopy(
        _ id: FileID, of drift: DriftPackage, capture: CaptureID? = nil, origin: RenderOrigin? = nil,
        drift link: DriftOrigin? = nil
    ) throws {
        let clips = drift.package.url.appending(path: clipsFolderName)
        try FileManager.default.copyItem(
            at: clips.appending(path: "c.wav"), to: clips.appending(path: "\(id.rawValue).wav"))
        if let capture {
            try drift.package.session.addCapture(
                Capture(
                    id: capture, deviceUID: "mic", deviceName: "Mic", hostTimeNanos: 0, sampleTime: 0,
                    nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0))
        }
        let length = Frames(drift.length)
        try drift.package.session.addFile(
            AudioFile(
                id: id, path: "\(id.rawValue).wav", layout: .mono, length: length, capture: capture, origin: origin,
                drift: link))
        let start = try #require(drift.package.session.clip("C")?.clip.start)
        try drift.package.addTrack("t", clip: "T", file: id, start: start, offset: 0, length: length)
    }

    /// A drift link to "c" at offset 0 with `ratio` and no added gain.
    static func link(ratio: Double, addedGain: Gain = .zero) throws -> DriftOrigin {
        DriftOrigin(source: "c", offset: 0, ratio: try #require(DriftRatio(ratio)), addedGain: addedGain)
    }
}

extension DriftPackage {
    /// The samples of a frame range of the clip file.
    typealias Make = (DriftPackage, Range<Int>) -> [Float]
}
